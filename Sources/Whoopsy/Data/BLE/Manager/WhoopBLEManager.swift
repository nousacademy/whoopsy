import Foundation
import CoreBluetooth

/// Real CoreBluetooth manager handling discovery, bonding, and telemetry streaming from WHOOP hardware.
public final class WhoopBLEManager: NSObject, @unchecked Sendable {
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private let decoder = WhoopPacketDecoder()

    // Continuations for async streams, keyed by subscriber.
    //
    // These were single stored properties, and the stream's getter **replaced** whichever continuation
    // was already there. Every `AsyncStream` is built by a closure that runs on each access, so a
    // second subscriber silently orphaned the first: its `for await` loop simply stopped receiving
    // and the stream never finished, which is indistinguishable from a strap that went quiet.
    //
    // That was not hypothetical. `liveTelemetryStream` is read by `StreamBiometricsUseCase`, which is
    // driven from both `HomeViewModel.load(for:)` and `MainContainerView`'s workout HUD; and
    // `deviceStream` is read by `HomeViewModel.observeDevice()` and `DeviceViewModel.load()`. In both
    // pairs the later subscriber was the only one still receiving.
    //
    // A dictionary plus `onTermination` pruning rather than a broadcast type, because the failure the
    // registry has to prevent is a *stale* continuation: one whose consumer is gone but which is
    // still held here, yielding into a stream nobody drains. `onTermination` is what removes it, and
    // it fires on cancellation and on the consumer leaving the loop, which are the two ways these end.
    //
    // Locked because this class is `@unchecked Sendable`: the properties are written from whatever
    // thread builds the stream (a SwiftUI `.task`, a use case) and read from the BLE dispatch queue
    // inside the CoreBluetooth delegate callbacks. Without the lock that is a data race on a
    // dictionary, which is worse than the bug being fixed.
    private let continuationLock = NSLock()
    private var deviceContinuations: [UUID: AsyncStream<WhoopDevice>.Continuation] = [:]
    private var telemetryContinuations: [UUID: AsyncStream<BiometricSample>.Continuation] = [:]

    private var currentDeviceState: WhoopDevice?

    /// The user's per-strap model choices, and an in-memory copy of them.
    ///
    /// The copy exists because `didDiscover` is a **synchronous** CoreBluetooth callback and
    /// `StrapModelRepository` is `async` — there is no way to await inside the callback, and resolving
    /// the generation after the fact would mean the device is briefly described as the wrong strap.
    /// So the map is loaded once (at scan start, and again whenever the user changes a choice) and
    /// read synchronously here.
    ///
    /// `nil` repository leaves the resolver on the name heuristic alone, which is what the mock and
    /// any hand-built manager get.
    private let strapModelRepository: (any StrapModelRepository)?
    private let strapModelLock = NSLock()
    private var strapModelCache: [String: WhoopHardwareGeneration] = [:]

    /// Sequence numbers for outgoing command frames, which are a field of the inner record.
    private let sequence = WhoopCommandSequence()

    /// Whether the one-shot discovery/0x2A37 diagnostics have been logged for this connection.
    ///
    /// Reset on connect and disconnect, so each session logs once. The 0x2A37 branch fires per
    /// notification, and a strap sending at 1 Hz would otherwise write a line a second into the log
    /// — which is the kind of noise that gets logging deleted rather than read.
    private var hasLoggedCharacteristicInventory = false
    private var hasLoggedHeartRateFrames = false

    /// Whether the one-shot proprietary-frame diagnostic has been logged for this connection.
    ///
    /// Same reason as the two above: the branch runs per notification. This is the log that would
    /// carry a capture's first evidence — a real strap's packet type, sequence number, opcode and
    /// payload length — so it is worth exactly one line per connection and no more.
    private var hasLoggedProprietaryFrame = false

    public init(strapModelRepository: (any StrapModelRepository)? = nil) {
        self.strapModelRepository = strapModelRepository
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "org.whoopsy.ble.queue"))
    }

    // MARK: - Strap generation

    /// Re-reads the stored model choices and re-resolves the connected strap's generation.
    ///
    /// Called before a scan, and again when the user changes a choice — the second is what makes a
    /// change take effect without a reconnect, which matters because the generation decides the
    /// envelope every subsequent command is framed with and the disposition of every frame received.
    public func refreshStrapModels() async {
        guard let strapModelRepository else { return }
        let models = await strapModelRepository.allModels()
        storeStrapModels(models)

        // Re-resolve the device that is already connected, so the screen and the codec agree with the
        // choice the moment it is saved rather than at the next discovery.
        guard let current = currentDeviceState, !current.id.isEmpty else { return }
        let resolved = resolveGeneration(advertisedName: current.name, deviceId: current.id)
        guard resolved != current.hardwareGeneration else { return }
        updateDeviceState {
            WhoopDevice(
                id: current.id,
                name: current.name,
                hardwareGeneration: resolved,
                batteryPercentage: current.batteryPercentage,
                connectionState: current.connectionState,
                isOnBody: current.isOnBody,
                isCharging: current.isCharging,
                firmwareVersion: current.firmwareVersion,
                serialNumber: current.serialNumber,
                signalStrengthRssi: current.signalStrengthRssi,
                lastSyncTime: current.lastSyncTime
            )
        }
    }

    /// The model for a strap: **the user's stored choice if there is one, otherwise a guess.**
    private func resolveGeneration(advertisedName: String, deviceId: String) -> WhoopHardwareGeneration {
        strapModelLock.lock()
        let stored = strapModelCache[deviceId]
        strapModelLock.unlock()
        return Self.resolvedGeneration(stored: stored, advertisedName: advertisedName)
    }

    /// The precedence rule itself, as a pure function of its two inputs.
    ///
    /// Separated from the cache read above for one reason that is not tidiness: this is the rule the
    /// whole generation-aware path rests on, and every way it can be wrong is silent. A guess that
    /// overrode a choice would put the app back on the wrong envelope with the screen still showing
    /// the user's selection; the guess itself cannot tell a 5.0 from a 5.0 MG at all, and a strap
    /// advertising nothing arrives as `"WHOOP Strap"` — no `5` in it, so it is called a 4.0. As a
    /// static taking both inputs it is assertable without a `CBCentralManager`, which the suite has no
    /// way to build (constructing one raises a system Bluetooth prompt).
    ///
    /// The heuristic is kept as the fallback rather than deleted, because a strap the user has never
    /// been asked about still has to be described as something.
    public static func resolvedGeneration(
        stored: WhoopHardwareGeneration?,
        advertisedName: String
    ) -> WhoopHardwareGeneration {
        if let stored { return stored }
        return advertisedName.contains("5") ? .whoop5 : .whoop4
    }

    /// The cache write, kept synchronous on purpose.
    ///
    /// `NSLock.lock()` is unavailable from an `async` context under Swift 6 — "use async-safe scoped
    /// locking instead" — and `refreshStrapModels` is async because the repository is. Hopping the
    /// critical section into a plain function is the honest fix here: the lock genuinely guards
    /// nothing but a dictionary assignment, and this class is `@unchecked Sendable` with the lock as
    /// its only synchronisation, so an `actor` or a `Mutex` would be a larger change than the problem.
    private func storeStrapModels(_ models: [String: WhoopHardwareGeneration]) {
        strapModelLock.lock()
        strapModelCache = models
        strapModelLock.unlock()
    }

    /// The envelope for the strap currently connected, or `nil` when this build has none for it.
    ///
    /// `nil` is not "unknown" — it is "no proprietary framing is implemented for this generation", and
    /// everything that writes to the command characteristic refuses on it. See `WhoopProtocolProfile`.
    public var currentProfile: WhoopProtocolProfile? {
        guard let generation = currentDeviceState?.hardwareGeneration else { return nil }
        return WhoopProtocolProfile.profile(for: generation)
    }

    /// The sequence number for the next outgoing command.
    public var commandSequence: WhoopCommandSequence { sequence }

    public var deviceStream: AsyncStream<WhoopDevice> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            deviceContinuations[id] = continuation
            // The current state is replayed to a new subscriber on its own, so a screen that
            // subscribes after the strap has already connected is not left showing a stale dash.
            // Read under the same lock as the registration, so a concurrent `updateDeviceState`
            // either yields to this subscriber or is replayed to it — never neither.
            let current = currentDeviceState
            continuationLock.unlock()
            if let current {
                continuation.yield(current)
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeDeviceContinuation(id)
            }
        }
    }

    public var liveTelemetryStream: AsyncStream<BiometricSample> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            telemetryContinuations[id] = continuation
            continuationLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeTelemetryContinuation(id)
            }
        }
    }

    private func removeDeviceContinuation(_ id: UUID) {
        continuationLock.lock()
        deviceContinuations[id] = nil
        continuationLock.unlock()
    }

    private func removeTelemetryContinuation(_ id: UUID) {
        continuationLock.lock()
        telemetryContinuations[id] = nil
        continuationLock.unlock()
    }

    /// Fans a sample out to every live subscriber.
    ///
    /// The dictionary is copied under the lock and yielded to outside it, so a slow or terminating
    /// consumer cannot block the BLE queue behind the lock — and `onTermination` mutating the
    /// dictionary while this iterates cannot invalidate the iteration.
    private func yieldTelemetry(_ sample: BiometricSample) {
        continuationLock.lock()
        let targets = Array(telemetryContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(sample) }
    }

    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            AppLogger.ble.warning("Cannot start scan: Bluetooth state is \(String(describing: self.centralManager.state))")
            return
        }
        AppLogger.ble.info("Starting scan for WHOOP devices...")
        updateDeviceState {
            WhoopDevice(id: "", name: "Scanning...", connectionState: .scanning)
        }
        centralManager.scanForPeripherals(
            withServices: WhoopGATTConstants.scannableServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func stopScanning() {
        centralManager.stopScan()
        if currentDeviceState?.connectionState == .scanning {
            updateDeviceState {
                WhoopDevice(id: "", name: "Idle", connectionState: .disconnected)
            }
        }
    }

    public func connect(to deviceId: String) {
        // If peripheral is discovered, initiate connection
        guard let peripheral = connectedPeripheral, peripheral.identifier.uuidString == deviceId else {
            return
        }
        updateDeviceState {
            WhoopDevice(id: deviceId, name: peripheral.name ?? "WHOOP Strap", connectionState: .connecting)
        }
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    public func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Writes a frame to the command characteristic — **the only place in the app that does.**
    ///
    /// The profile guard is the last line of defence and the reason this method is the choke point.
    /// The packet-type numberings do not overlap between generations, so a 4.0-framed command written
    /// to a 5.0 strap is not a command the strap rejects — it is a *different command*, and one of the
    /// documented opcodes is a destructive flash erase (`0x19 FORCE_TRIM`). Every builder in
    /// `WhoopPacketEncoder` already returns `nil` for an unimplemented envelope; this guard means that
    /// even a frame built by some future path cannot reach the wire without a profile behind it.
    public func sendCommand(_ data: Data) {
        guard currentProfile != nil else {
            AppLogger.ble.warning("""
                Refused to transmit \(data.count, privacy: .public) bytes: no protocol profile for \
                \(self.currentDeviceState?.hardwareGeneration.rawValue ?? "no device", privacy: .public)
                """)
            return
        }
        guard let peripheral = connectedPeripheral, let char = commandCharacteristic else { return }
        let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: type)
    }

    public func getCurrentDevice() -> WhoopDevice? {
        currentDeviceState
    }

    private func updateDeviceState(_ transform: () -> WhoopDevice) {
        let updated = transform()
        // The state write and the subscriber snapshot are taken under one lock, so the replay in
        // `deviceStream` cannot observe a state that was set before a subscriber it will not be
        // yielded to — which is how a screen ends up showing a stale dash until the next update.
        continuationLock.lock()
        currentDeviceState = updated
        let targets = Array(deviceContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(updated) }
    }
}

// MARK: - CBCentralManagerDelegate
extension WhoopBLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLogger.ble.info("Central manager state changed to \(central.state.rawValue)")
        if central.state == .poweredOn {
            startScanning()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        AppLogger.ble.info("Discovered peripheral: \(peripheral.name ?? "Unknown") [\(peripheral.identifier.uuidString)] RSSI: \(RSSI)")
        self.connectedPeripheral = peripheral
        peripheral.delegate = self

        let devName = peripheral.name ?? "WHOOP Strap"
        let gen = resolveGeneration(advertisedName: devName, deviceId: peripheral.identifier.uuidString)

        let device = WhoopDevice(
            id: peripheral.identifier.uuidString,
            name: devName,
            hardwareGeneration: gen,
            batteryPercentage: 100,
            connectionState: .connecting,
            signalStrengthRssi: RSSI.intValue
        )
        updateDeviceState { device }
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLogger.ble.info("Connected to \(peripheral.name ?? "Strap")")
        hasLoggedCharacteristicInventory = false
        hasLoggedHeartRateFrames = false
        hasLoggedProprietaryFrame = false
        updateDeviceState {
            resolvedDevice(
                for: peripheral,
                connectionState: .connected,
                fallback: currentDeviceState
            )
        }
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        AppLogger.ble.warning("Disconnected peripheral: \(peripheral.name ?? "Strap"), error: String(describing: error))")
        hasLoggedCharacteristicInventory = false
        hasLoggedHeartRateFrames = false
        hasLoggedProprietaryFrame = false
        updateDeviceState {
            resolvedDevice(
                for: peripheral,
                connectionState: .disconnected,
                fallback: currentDeviceState
            )
        }
    }

    /// The device state for a lifecycle transition, preserving what discovery already worked out.
    ///
    /// **These two callbacks used to throw the generation away.** Both built a bare
    /// `WhoopDevice(id:name:connectionState:)`, whose `hardwareGeneration` defaults to `.whoop4`, so
    /// the value guessed at discovery was replaced by a literal the instant the strap connected — the
    /// generation was not merely unread, it did not survive the connection that would have used it.
    /// Now they carry it, together with the fields discovery populated, and fall back to the last
    /// known values for anything the peripheral object does not carry.
    private func resolvedDevice(
        for peripheral: CBPeripheral,
        connectionState: WhoopConnectionState,
        fallback: WhoopDevice?
    ) -> WhoopDevice {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? fallback?.name ?? "WHOOP Strap"
        // Re-resolve rather than carry: a `disconnect`/`connect` cycle is exactly when the user may
        // have been to the device screen and changed the model.
        let generation = resolveGeneration(advertisedName: name, deviceId: id)
        return WhoopDevice(
            id: id,
            name: name,
            hardwareGeneration: generation,
            batteryPercentage: fallback?.batteryPercentage ?? 100,
            connectionState: connectionState,
            isOnBody: fallback?.isOnBody ?? true,
            isCharging: fallback?.isCharging ?? false,
            firmwareVersion: fallback?.firmwareVersion,
            serialNumber: fallback?.serialNumber,
            signalStrengthRssi: fallback?.signalStrengthRssi,
            lastSyncTime: fallback?.lastSyncTime
        )
    }
}

// MARK: - CBPeripheralDelegate
extension WhoopBLEManager: CBPeripheralDelegate {
    /// The characteristic's properties as short letters, for the one-shot discovery log.
    ///
    /// Spelled out rather than using `CBCharacteristicProperties`' own description, which prints as
    /// an option-set bitmask in hex. Whether a characteristic is `notify` is the question this log
    /// exists to answer — a service can expose 0x2A37 and still never notify, and that would look
    /// exactly like a strap whose R-R field is always empty.
    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var letters = ""
        if properties.contains(.read) { letters += "r" }
        if properties.contains(.write) { letters += "w" }
        if properties.contains(.writeWithoutResponse) { letters += "W" }
        if properties.contains(.notify) { letters += "n" }
        if properties.contains(.indicate) { letters += "i" }
        return letters.isEmpty ? "-" : letters
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        // One-shot per connection, and the only evidence this app will ever have about which GATT
        // surface a given strap generation actually exposes. Everything downstream — whether the
        // 0x2A37 R-R series is worth a column, or whether the work belongs in the proprietary `0x01`
        // payload instead — is decided from this line and the one in the 0x2A37 branch below.
        if !hasLoggedCharacteristicInventory {
            hasLoggedCharacteristicInventory = true
            let uuids = characteristics.map { "\($0.uuid)[\(Self.describe($0.properties))]" }
            let hasHeartRate = characteristics.contains {
                $0.uuid == WhoopGATTConstants.heartRateMeasurementCharacteristicUUID
            }
            AppLogger.ble.info("""
                Discovered \(characteristics.count) characteristic(s) on service \
                \(service.uuid): \(uuids.joined(separator: ", ")). \
                0x2A37 Heart Rate Measurement present: \(hasHeartRate)
                """)
        }

        for char in characteristics {
            if char.uuid == WhoopGATTConstants.whoop4CommandUUID || char.uuid == WhoopGATTConstants.whoop5CommandUUID {
                self.commandCharacteristic = char
                // Send telemetry start command — under the connected strap's own envelope, and only
                // if this build has one. `sendCommand` refuses a profileless generation too, so a
                // 5.0 strap gets silence here rather than a 4.0-framed `0x05`.
                if let profile = currentProfile,
                   let frame = WhoopPacketEncoder.enableLiveTelemetry(
                       profile: profile, seq: sequence.next(), enable: true) {
                    sendCommand(frame)
                }
            }

            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        // 1. Standard Heart Rate characteristic
        if characteristic.uuid == WhoopGATTConstants.heartRateMeasurementCharacteristicUUID {
            if let (hr, rrs) = decoder.decodeStandardHeartRate(data: data) {
                // Once per connection, for the same reason as the inventory above: this branch runs
                // per notification. What it answers is whether the strap populates the R-R field at
                // all (`k == 0` means it does not) and how many intervals a notification carries —
                // the number that decides whether a night's series is reconstructible from the
                // per-notification arrival instants or not.
                if !hasLoggedHeartRateFrames {
                    hasLoggedHeartRateFrames = true
                    AppLogger.ble.info("""
                        0x2A37 frame: flags=0x\(String(data[0], radix: 16, uppercase: true)) \
                        bytes=\(data.count) hr=\(hr) rrIntervals=\(rrs.count)
                        """)
                }

                let sample = BiometricSample(
                    timestamp: Date(),
                    heartRate: hr,
                    rrIntervalsMs: rrs.isEmpty ? nil : rrs
                )
                yieldTelemetry(sample)
            }
            return
        }

        // 2. Battery level
        if characteristic.uuid == WhoopGATTConstants.batteryLevelCharacteristicUUID {
            let battery = Int(data[0])
            if let current = currentDeviceState {
                updateDeviceState {
                    WhoopDevice(
                        id: current.id,
                        name: current.name,
                        hardwareGeneration: current.hardwareGeneration,
                        batteryPercentage: battery,
                        connectionState: .connected,
                        isOnBody: current.isOnBody,
                        isCharging: current.isCharging
                    )
                }
            }
            return
        }

        // 3. Proprietary 0xAA packets
        //
        // Validated and logged, not decoded. The envelope is checked (start of frame, declared
        // length, header checksum, payload checksum) and the bytes are carried up raw, because no
        // payload layout on this path has been verified against a strap — see `WhoopRawFrame`. The
        // 4.0 historical record *is* documented (`BLE_PROTOCOL.md` §4: a 96-byte header with heart
        // rate at `[17]`) and parsing it is the drain's work, not something to approximate here.
        //
        // What this branch is for right now is the one-shot log below: it is the only place a real
        // strap's frame would ever be seen, and those bytes are what `BLE_PROTOCOL.md` §6 asks for.
        guard let profile = currentProfile else { return }
        if let frame = decoder.decodeProprietaryFrame(data: data, profile: profile) {
            if !hasLoggedProprietaryFrame {
                hasLoggedProprietaryFrame = true
                AppLogger.ble.info("""
                    Proprietary frame: type=0x\(String(frame.type, radix: 16, uppercase: true)) \
                    seq=\(frame.seq) cmd=0x\(String(frame.cmd, radix: 16, uppercase: true)) \
                    payload=\(frame.payload.count) bytes
                    """)
            }
        }
    }
}
