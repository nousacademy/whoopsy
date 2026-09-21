import Foundation
import CoreBluetooth

/// Real CoreBluetooth manager handling discovery, bonding, and telemetry streaming from WHOOP hardware.
public final class WhoopBLEManager: NSObject, @unchecked Sendable {
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private let decoder = WhoopPacketDecoder()

    /// Accumulates a frame that arrives split across notifications.
    ///
    /// A plain `var` with no lock, like the `hasLogged*` flags below and for the same reason: it is
    /// written only from `didUpdateValueFor`, and every CoreBluetooth delegate callback runs on the
    /// one serial queue this class hands `CBCentralManager` at construction. Reset on connect and on
    /// disconnect, because the buffer holds a *previous* stream's partial frame across either.
    private var reassembler = WhoopFrameReassembler()

    // Continuations for async streams, keyed by subscriber.
    //
    // These were single stored properties, and the stream's getter **replaced** whichever continuation
    // was already there. Every `AsyncStream` is built by a closure that runs on each access, so a
    // second subscriber silently orphaned the first: its `for await` loop simply stopped receiving
    // and the stream never finished, which is indistinguishable from a strap that went quiet.
    //
    // That was not hypothetical. `liveTelemetryStream` is read by `StreamBiometricsUseCase`, driven
    // from `HomeViewModel.load(for:)`; `deviceStream` is read by `HomeViewModel.observeDevice()`,
    // `DeviceViewModel.load()` and `DeviceDetailViewModel`; and `motionStream` by
    // `TrackStepsUseCase`. In each case the later subscriber was the only one still receiving.
    //
    // **The counts are per-stream and they move.** They fell by one when the workout HUD was deleted,
    // and none of it was visible: a screen that stops reading a stream leaves no other trace. So the
    // registry is not justified by a named pair of consumers — it is justified by the failure being
    // silent, which does not depend on how many readers there happen to be today.
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
    private var motionContinuations: [UUID: AsyncStream<MotionBatch>.Continuation] = [:]

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

    // The flash drain in progress.
    //
    // Locked, unlike `reassembler` and the `hasLogged*` flags, and the difference is the reason: those
    // are touched only from the BLE queue, while these are also read and written by the caller that
    // *started* the drain (a SwiftUI action, through a use case) and by the watchdog task below. That
    // is three threads, so it is a lock rather than a comment.
    //
    // The continuation is stored rather than the caller polling, because a drain's whole point is that
    // it finishes when the *strap* says so — `HISTORY_COMPLETE` — and a caller that returned at the
    // request would be reporting a sync that had not happened. Its `nil` case is the state a caller
    // must not be left in: a continuation dropped without being resumed is a task that hangs forever,
    // so every path that clears this one resumes it.
    private let drainLock = NSLock()
    private var drainSession: HistoricalDrainSession?
    private var drainCompletion: CheckedContinuation<HistoricalDrainSession?, Never>?
    private var drainWatchdog: Task<Void, Never>?

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

    /// The strap's decoded 100 Hz motion, for the step counter.
    ///
    /// Registered exactly as `liveTelemetryStream` is — a dictionary keyed by `UUID`, pruned in
    /// `onTermination` — and **that is not a copied idiom but the same defect being avoided**:
    /// `TrackStepsUseCase` is this stream's only consumer today and it is still registered rather
    /// than read directly, because a registry that let a second subscriber orphan the first would
    /// fail silently — no error, no gap, just a `for await` that stops receiving, which is
    /// indistinguishable from a strap that went quiet.
    ///
    /// Nothing yields into it on a strap this build cannot frame for: `didUpdateValueFor`'s
    /// proprietary branch is the only writer, and a 5.0 or MG reaches it with no enable sequence sent
    /// — so this is an honest empty stream there rather than a fabricated one, and `TrackStepsUseCase`
    /// writes no row for a day it measured nothing on.
    public var motionStream: AsyncStream<MotionBatch> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            motionContinuations[id] = continuation
            continuationLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeMotionContinuation(id)
            }
        }
    }

    private func removeTelemetryContinuation(_ id: UUID) {
        continuationLock.lock()
        telemetryContinuations[id] = nil
        continuationLock.unlock()
    }

    private func removeMotionContinuation(_ id: UUID) {
        continuationLock.lock()
        motionContinuations[id] = nil
        continuationLock.unlock()
    }

    /// Fans a decoded motion batch out to every live subscriber. See `yieldTelemetry`.
    private func yieldMotion(_ batch: MotionBatch) {
        continuationLock.lock()
        let targets = Array(motionContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(batch) }
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
    /// The guard is the last line of defence and the reason this method is the choke point. The
    /// opcodes this build knows are 4.0's, and a 4.0-framed command written to a 5.0 strap is not a
    /// command the strap rejects — it is a *different command*, and one of the documented 4.0 opcodes
    /// is a destructive flash erase (`0x19 FORCE_TRIM`). Every builder in `WhoopPacketEncoder` already
    /// returns `nil` for a generation with no opcode set; this guard means that even a frame built by
    /// some future path cannot reach the wire without one.
    ///
    /// **It tests `canTransmitCommands`, not the profile's existence**, and the difference is now
    /// load-bearing: `.whoop5` and `.whoop5MG` answer with a real envelope because the app can
    /// validate their inbound frames, so a guard on `currentProfile != nil` would have opened the wire
    /// to a strap this build has no command for. A generation that can be read is not a generation
    /// that can be written to.
    public func sendCommand(_ data: Data) {
        guard let profile = currentProfile, profile.canTransmitCommands else {
            let reason = currentProfile == nil ? "no envelope" : "no command opcode set"
            AppLogger.ble.warning("""
                Refused to transmit \(data.count, privacy: .public) bytes: \(reason, privacy: .public) for \
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

    // MARK: - The flash drain

    /// Starts a historical drain and returns when it ends — **not when the request is written.**
    ///
    /// This is the difference between a sync and a claim of one. `DeviceViewModel` used to print
    /// "History sync complete." the instant `requestHistoricalSync` returned, which was before the
    /// strap had been asked anything. A drain's end is the strap's own `HISTORY_COMPLETE` (or one of
    /// the two ways this side gives up), so the caller has to be able to wait for it — which is what
    /// the stored continuation is for.
    ///
    /// **Returns the finished session, or `nil` when nothing was started** — a strap this build cannot
    /// write to, an envelope it cannot frame, or a request the builder refused. The session carries
    /// `recordCount`, `batchCount` and a `finishReason`, so a caller can tell "the strap said it was
    /// done" from "we gave up waiting" rather than reporting both as a completed sync.
    public func drainHistoricalData() async -> HistoricalDrainSession? {
        guard let profile = currentProfile, profile.canTransmitCommands else {
            AppLogger.ble.warning("Refused to start a historical drain: no command opcode set for this strap")
            return nil
        }
        guard let request = WhoopCommandFrames.historicalSyncRequest(
            profile: profile, seq: sequence.next()) else {
            AppLogger.ble.warning("Refused to start a historical drain: the request builder returned no frame")
            return nil
        }

        // A second drain concludes the first rather than overwriting it. `drainSession` is a single
        // slot, so replacing it without resuming the continuation it was waiting on would leave that
        // caller suspended forever — the leak this whole arrangement exists to avoid.
        concludeDrain(reason: .aborted)

        let session = HistoricalDrainSession(profile: profile, startedAt: Date())

        return await withCheckedContinuation { (continuation: CheckedContinuation<HistoricalDrainSession?, Never>) in
            drainLock.lock()
            drainSession = session
            drainCompletion = continuation
            drainLock.unlock()

            // The clock goes first, and it is a prerequisite rather than a courtesy: a strap whose RTC
            // is invalid stops banking sensor data to flash **entirely** while looking connected and
            // healthy, and a drained record is stamped by that same RTC — so an unset clock files
            // history onto a wrong day rather than onto no day. Both 4.0 forms are sent, because a
            // wrong-length set is acknowledged but not latched.
            for frame in WhoopCommandFrames.setClockFrames(
                profile: profile, seq: sequence.next(), epochSeconds: UInt32(Date().timeIntervalSince1970)) {
                sendCommand(frame)
            }
            sendCommand(request)

            armDrainWatchdog(session)
        }
    }

    /// Ends a drain in progress from this side and acknowledges it as aborted.
    ///
    /// Both generations have a real abort and both use `0x14`, so the frame differs in envelope and
    /// not in byte — see `WhoopCommandFrames.abortHistoricalTransmits`, which used to send the 5.0 its
    /// `0x52 STOP_RAW_DATA` on the false premise that this generation publishes no abort. What this
    /// function does beyond sending it is conclude the session either way, because leaving a caller
    /// suspended on a strap that has stopped answering is the worse failure.
    public func abortHistoricalDrain() {
        if let profile = currentProfile,
           let frame = WhoopCommandFrames.abortHistoricalTransmits(profile: profile, seq: sequence.next()) {
            sendCommand(frame)
        }
        concludeDrain(reason: .aborted)
    }

    /// Routes one inbound frame to the drain, if one is running, and performs whatever it asks for.
    ///
    /// Called from the frame loop in `didUpdateValueFor`, so it runs on the BLE queue — which is why
    /// the session's mutation goes through `drainSession?` under the lock rather than through a local
    /// `if let`. `HistoricalDrainSession` is a **struct**: `if let session = drainSession { session.accept(…) }`
    /// mutates a copy and silently discards every count, every `lastActivity` and the finish reason.
    private func routeToDrain(_ frame: WhoopRawFrame, now: Date) {
        drainLock.lock()
        guard drainSession != nil else {
            drainLock.unlock()
            return
        }
        let action = drainSession!.accept(frame, now: now)
        drainLock.unlock()

        switch action {
        case .none:
            break

        case .acknowledge(let token):
            if let profile = currentProfile,
               let ack = WhoopCommandFrames.historicalDataAck(
                   profile: profile, seq: sequence.next(), token: token) {
                sendCommand(ack)
            }

        case .acknowledgeAndFinish(let token):
            // The live edge: ack the batch that just ended, then stop. The ACK is still owed — the
            // strap's cursor does not move without it — so it is sent before the session concludes.
            if let profile = currentProfile,
               let ack = WhoopCommandFrames.historicalDataAck(
                   profile: profile, seq: sequence.next(), token: token) {
                sendCommand(ack)
            }
            concludeDrain(reason: .liveEdge)

        case .finish:
            // `HISTORY_COMPLETE` is not a batch and is **not** acknowledged — §4 is explicit, and
            // answering it is answering a question the strap did not ask.
            concludeDrain(reason: .complete)
        }

        // The idle window is checked here rather than only on the watchdog's own schedule, so a drain
        // that stops mid-stream ends on the next frame's arrival rather than a full window later.
        drainLock.lock()
        let expired = drainSession?.checkIdleTimeout(now: now) ?? false
        drainLock.unlock()
        if expired { concludeDrain(reason: .idleTimeout) }
    }

    /// Arms the idle watchdog for a session, replacing any watchdog the previous drain left.
    ///
    /// A `Task` rather than a `Timer`, because the drain's window is the profile's own (8 s on the 4.0,
    /// 60 s on the 5.0) and the check is a comparison against `lastActivity` rather than a countdown —
    /// so a watchdog that wakes late is still correct, and one that wakes after activity has arrived
    /// simply re-arms.
    private func armDrainWatchdog(_ session: HistoricalDrainSession) {
        let window = session.idleTimeoutSeconds
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(window))
                guard !Task.isCancelled, let self else { return }

                // The lock lives in a synchronous helper rather than here: Swift 6 makes `NSLock.lock()`
                // unavailable from an `async` context, and the watchdog's body is one. The check has to
                // be atomic with respect to `routeToDrain` anyway — both mutate the same session.
                let (expired, finished) = self.checkDrainIdle()

                if expired {
                    self.concludeDrain(reason: .idleTimeout)
                    return
                }
                // A session that ended by another route (the live edge, `HISTORY_COMPLETE`) has
                // already resumed its continuation; the watchdog just stops.
                if finished { return }
            }
        }
        drainLock.lock()
        drainWatchdog?.cancel()
        drainWatchdog = task
        drainLock.unlock()
    }

    /// Whether the drain in progress has passed its generation's idle window, and whether it has
    /// finished for some other reason.
    ///
    /// Synchronous on purpose: this is the watchdog's lock acquisition, and `NSLock` is unavailable
    /// from the `async` context the watchdog body runs in.
    private func checkDrainIdle() -> (expired: Bool, finished: Bool) {
        drainLock.lock()
        defer { drainLock.unlock() }
        let expired = drainSession?.checkIdleTimeout(now: Date()) ?? false
        return (expired, drainSession?.isFinished ?? false)
    }

    /// Ends the session in progress, resumes whoever is waiting on it, and stops the watchdog.
    ///
    /// **The single exit path for a drain**, which is what keeps the continuation from being dropped:
    /// every route out — the strap's `HISTORY_COMPLETE`, the live edge, the idle window, an abort, a
    /// disconnect, and a second drain starting — comes through here.
    ///
    /// The `reason` is applied to the session rather than carried separately, so the session a caller
    /// receives describes why it stopped. `.aborted` is applied only when the session is not already
    /// finished: a drain that ended because the strap said so must not be relabelled by the
    /// disconnect that follows it.
    private func concludeDrain(reason: HistoricalDrainSession.FinishReason) {
        drainLock.lock()
        guard let session = drainSession else {
            drainLock.unlock()
            return
        }
        drainSession = nil
        var finished = session
        // A no-op when the session ended itself, which is every path where it could: `accept` records
        // `HISTORY_COMPLETE` and the live edge, and `checkIdleTimeout` records the window. This line
        // is what gives the reason for the ones it could not — a disconnect, or a second drain
        // starting.
        finished.conclude(reason)
        let continuation = drainCompletion
        drainCompletion = nil
        let watchdog = drainWatchdog
        drainWatchdog = nil
        drainLock.unlock()

        watchdog?.cancel()
        continuation?.resume(returning: finished)
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
        // A new connection is a new byte stream. Held bytes would be prepended to its first frame and
        // move every field in it.
        reassembler.reset()
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
        // The frame in flight when the link dropped will never be completed: its remaining bytes
        // belong to a stream that ended.
        reassembler.reset()
        // A drain cannot outlive its link, and its caller must not be left suspended: no further
        // frame can arrive, so nothing else will ever conclude it. This resumes the continuation with
        // an `.aborted` session — unless the strap had already sent `HISTORY_COMPLETE`, in which case
        // the session keeps that reason and reads as the completed sync it was.
        concludeDrain(reason: .aborted)
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
                // if this build has one *and* knows that generation's command opcodes. The 4.0's
                // `0x05` has no published 5.0 counterpart, so the 5.0 falls to the IMU enable below
                // rather than getting a frame this builder cannot build.
                if let profile = currentProfile,
                   let frame = WhoopPacketEncoder.enableLiveTelemetry(
                       profile: profile, seq: sequence.next(), enable: true) {
                    sendCommand(frame)
                }

                // The IMU enable, for the step counter. Sent from here rather than from a screen's
                // `.task` for the same reason the telemetry enable is: this callback fires once per
                // connection, and a command sent per screen appearance would toggle the IMU off and on
                // as the user moved between tabs.
                //
                // **Goes through `WhoopCommandFrames`, which is what makes a 5.0 strap produce motion
                // at all.** It routes by envelope: three frames on the 4.0 (`0x6A`, `0x3F`, `0x6B`) and
                // two on the 5.0 / MG (`0x51 START_RAW_DATA` then the toggle). This call used to go
                // straight to the 4.0 builder, whose refusal of the 5.0 envelope was correct and left
                // the 5.0 with no producer running — the 5.0 leg's whole first step.
                //
                // An **empty** array is still the state for an unknown generation rather than an
                // error, so `TrackStepsUseCase` holds a subscription with nothing arriving, which is
                // the honest state for a strap this build cannot write to.
                if let profile = currentProfile {
                    for frame in WhoopCommandFrames.motionEnableSequence(
                        profile: profile, seq: sequence.next(), enable: true) {
                        sendCommand(frame)
                    }
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
        // Reassembled, validated, and then **dispatched by type and generation**. Until the motion
        // decoder landed this branch only logged: a frame arrived validated and undecoded, which was
        // the honest state while no payload layout had a reader. The motion record now has one, so a
        // decoded `MotionBatch` is yielded to `motionStream` — and everything else still goes no
        // further than the one-shot log below, which is where a real strap's frame is first seen and
        // what `BLE_PROTOCOL.md` §7 asks to be captured.
        //
        // **The dispatch is by generation, never by falling back.** `MotionPayloadDecoder.decode`
        // chooses R21 or R10 from `frame.generation` and refuses anything else, so a 4.0 record is
        // never walked with the 5.0's offsets — they overlap on shape and a fallback would decode one
        // strap's record silently.
        //
        // A `nil` profile means this build cannot frame for the strap at all, so there is no boundary
        // to reassemble against and the bytes are not buffered — a strap whose envelope this build does
        // not know would otherwise accumulate them forever while never producing a frame.
        guard let profile = currentProfile else { return }
        for frame in reassembler.append(data, profile: profile) {
            if !hasLoggedProprietaryFrame {
                hasLoggedProprietaryFrame = true
                AppLogger.ble.info("""
                    Proprietary frame: type=0x\(String(frame.type, radix: 16, uppercase: true)) \
                    seq=\(frame.seq) cmd=0x\(String(frame.cmd, radix: 16, uppercase: true)) \
                    payload=\(frame.payload.count) bytes
                    """)
            }

            let now = Date()
            if let batch = MotionPayloadDecoder.decode(frame: frame, receivedAt: now) {
                yieldMotion(batch)
            }

            // The drain sees every frame, including the ones the motion decoder just consumed: a
            // banked type-47 record *is* an R21 batch, so the same frame is both a step contribution
            // and a batch the strap is waiting to have acknowledged. That is the whole reason the
            // shared core is shared, and it is why this call is not an `else`.
            routeToDrain(frame, now: now)
        }
    }
}
