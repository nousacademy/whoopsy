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

    /// Whether the one-shot discovery/0x2A37 diagnostics have been logged for this connection.
    ///
    /// Reset on connect and disconnect, so each session logs once. The 0x2A37 branch fires per
    /// notification, and a strap sending at 1 Hz would otherwise write a line a second into the log
    /// — which is the kind of noise that gets logging deleted rather than read.
    private var hasLoggedCharacteristicInventory = false
    private var hasLoggedHeartRateFrames = false

    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "org.whoopsy.ble.queue"))
    }

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

    public func sendCommand(_ data: Data) {
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
        let gen: WhoopHardwareGeneration = devName.contains("5") ? .whoop5 : .whoop4

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
        updateDeviceState {
            WhoopDevice(
                id: peripheral.identifier.uuidString,
                name: peripheral.name ?? "WHOOP Strap",
                connectionState: .connected
            )
        }
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        AppLogger.ble.warning("Disconnected peripheral: \(peripheral.name ?? "Strap"), error: String(describing: error))")
        hasLoggedCharacteristicInventory = false
        hasLoggedHeartRateFrames = false
        updateDeviceState {
            WhoopDevice(
                id: peripheral.identifier.uuidString,
                name: peripheral.name ?? "WHOOP Strap",
                connectionState: .disconnected
            )
        }
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
                // Send telemetry start command
                sendCommand(WhoopPacketEncoder.enableLiveTelemetry(enable: true))
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
        if let decoded = decoder.decodeProprietaryFrame(data: data) {
            switch decoded {
            case .liveBiometric(let sample):
                yieldTelemetry(sample)
            case .batteryStatus(let battery, let isCharging, let onBody):
                if let current = currentDeviceState {
                    updateDeviceState {
                        WhoopDevice(
                            id: current.id,
                            name: current.name,
                            hardwareGeneration: current.hardwareGeneration,
                            batteryPercentage: battery,
                            connectionState: .connected,
                            isOnBody: onBody,
                            isCharging: isCharging
                        )
                    }
                }
            case .historicalBatch(let samples):
                for s in samples { yieldTelemetry(s) }
            case .rawData:
                break
            }
        }
    }
}
