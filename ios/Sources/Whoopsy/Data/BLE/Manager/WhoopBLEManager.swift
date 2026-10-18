import Foundation
import CoreBluetooth

/// Real CoreBluetooth manager handling discovery, bonding, and telemetry streaming from WHOOP hardware.
public final class WhoopBLEManager: NSObject, @unchecked Sendable {
    private var centralManager: CBCentralManager!
    /// The serial queue every CoreBluetooth callback runs on, kept for the keep-alive timer.
    ///
    /// The timer is a `DispatchSourceTimer` on **this** queue rather than a second thread, so the
    /// keep-alive state below needs no lock: it is written from ticks and from delegate callbacks,
    /// which are serialized here by construction. That is the same reason `reassembler` and the
    /// `hasLogged*` flags are plain properties — see `reassembler`'s comment.
    private let bleQueue: DispatchQueue
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
    // `DeviceViewModel.load()`; and `motionStream` by
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

    /// Whether the 5.0/MG bond handshake has been written and is waiting on its acknowledgement.
    ///
    /// **This flag exists because `didWriteValueFor` cannot say which write it is reporting.** The
    /// callback carries the characteristic and an error and not the bytes, and the hello and the
    /// enable sequence that follows it go to the *same* characteristic — so "am I waiting on the
    /// handshake?" is state this type has to keep rather than a question it can ask.
    ///
    /// **It is cleared on the first acknowledgement and never set again in that connection**, which
    /// is a correctness guard rather than tidiness: `didWriteValueFor` re-fires on every later
    /// confirmed write, and a handshake re-run mid-drain is the documented cause of a strap refusing
    /// to stream its type-47 records. See `didWriteValueFor` below.
    private var isAwaitingBondHandshakeAck = false

    /// The identifier iOS uses to summon this app back for Bluetooth events after terminating it.
    ///
    /// One per app for the life of the install, because a second `CBCentralManager` constructed with
    /// the same identifier is invalid — and there is exactly one manager here. Without it iOS is free
    /// to kill a backgrounded app and never tell it the strap came back; with it, a pending
    /// `connect` outlives the process and the app is relaunched to be told the link is up.
    private static let restoreIdentifier = "org.whoopsy.ble.central"

    /// Whether the drop in progress is one the user asked for.
    ///
    /// **This is the difference between a fault and an instruction.** Every involuntary disconnect is
    /// answered with a standing connect, which is what keeps the strap reachable while the app is
    /// suspended — so an explicit `disconnect()` that did not set this would undo itself immediately.
    /// It is cleared by a new connection and by nothing else, because cancelling a *pending* connect
    /// can arrive as `didFailToConnect`, and that failure must stay suppressed by the same instruction
    /// that caused it.
    private var intentionalDisconnect = false

    /// When the most recent standing connect was issued, and the delayed retry waiting on the floor.
    ///
    /// The timestamp exists only to tell a strap that answered and refused from one that has not
    /// answered yet; see `ReconnectPolicy.step`. The task is what carries a retry across the floor
    /// without leaving a `connect` outstanding in the refused case.
    private var standingConnectAttemptedAt: Date?
    private var reconnectTask: Task<Void, Never>?

    /// The restored peripheral, when `willRestoreState` ran before the central reported powered on.
    ///
    /// `willRestoreState` is the **first** delegate method after a background relaunch, and a central
    /// that has not reported its state cannot be asked to connect. This hands the peripheral to
    /// `centralManagerDidUpdateState`, which is the first place it is safe to issue the call.
    private var pendingRestorePeripheral: CBPeripheral?

    /// Guards the four properties above.
    ///
    /// `didDisconnectPeripheral`, `didFailToConnect` and `willRestoreState` run on the BLE queue;
    /// `disconnect()` and `rearmConnection()` run on whichever thread the UI action is on. That is the
    /// same three-thread shape as the drain's, so it gets the same answer.
    private let reconnectLock = NSLock()

    /// How many fast refusals in a row the most recent failure makes.
    ///
    /// Only a 5.0/MG acts on it — see `ReconnectPolicy.consecutiveRefusalCap` — but every generation
    /// carries the count so the reset rule is one rule. Guarded by `reconnectLock`, beside the
    /// timestamp and the retry task it is decided with.
    private var consecutiveRefusals = 0

    // MARK: - Keep-alive
    //
    // Every property in this block is touched **only from the BLE queue**: by the timer below, whose
    // source is created on that queue, and by the delegate callbacks, which CoreBluetooth serializes
    // there. `disconnect()` and `rearmConnection()` hop onto it before starting or stopping anything,
    // which is what keeps that sentence true from the UI side.

    /// The battery characteristic, kept so a keep-alive tick can ask for a fresh reading.
    private var batteryCharacteristic: CBCharacteristic?

    private var keepAliveTimer: DispatchSourceTimer?

    /// The start of the window this process could actually observe, and the clocks read off it.
    ///
    /// `lastActivityAt` advanced on every inbound notification and on a successful confirmed write, and
    /// it is **advanced forward on a resumed tick** — see `KeepAlivePolicy.suspensionGapSeconds`. It is
    /// therefore "when the silence began, as far as this process can tell", not a claim about the
    /// strap.
    private var lastActivityAt: Date?
    private var lastActivationSentAt: Date?
    private var lastBatteryReadAt: Date?
    private var lastKeepAliveTickAt: Date?

    /// Whether the enable sequence has been written on this link.
    ///
    /// It exists for one case: a 5.0/MG whose bond handshake was never acknowledged. `sendConnectCommands`
    /// is deliberately never called there — a pre-bond command is refused — so a silent-stream re-send
    /// must not call it either, and the liveness fuse's bounce is what recovers that link instead.
    private var hasSentConnectCommands = false

    /// Whether the unreadable-battery log has fired for this link.
    private var hasLoggedUnreadableBattery = false

    public init(strapModelRepository: (any StrapModelRepository)? = nil) {
        self.strapModelRepository = strapModelRepository
        let queue = DispatchQueue(label: "org.whoopsy.ble.queue")
        self.bleQueue = queue
        super.init()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
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

    /// Re-arms the path to the strap when the app returns to the foreground.
    ///
    /// **Nothing is guaranteed to be outstanding after a suspension, and that is what this covers.** A
    /// standing connect survives the app being suspended, but not the system moving it out of memory,
    /// and a scan is not resumed for an app that is already running. So on `.active` an unchanged link
    /// is left alone, a link that is down is given another standing connect, and a process that never
    /// found a strap scans again.
    ///
    /// **An explicit `disconnect()` wins.** A strap the user switched off must not come back on its own
    /// the next time the app is opened; only the Device page's scan can link it again.
    public func rearmConnection() {
        guard !isIntentionalDisconnect(), centralManager.state == .poweredOn else { return }
        if let peripheral = connectedPeripheral {
            // `.connected` here means there is nothing to arm. The keep-alive window is restarted
            // anyway, because the app may have spent the intervening time suspended with no ticks —
            // and the fuse must not read that as silence.
            guard peripheral.state != .connected else {
                bleQueue.async { [weak self] in self?.restartKeepAliveWindow() }
                return
            }
            // `.disconnected` covers both a drop with a standing connect still pending and a process
            // that was suspended long enough for the system to forget one; re-issuing is idempotent
            // from CoreBluetooth's side.
            issueStandingConnect(for: peripheral, after: .failedToConnect)
        } else {
            startScanning()
        }
    }

    public func connect(to deviceId: String) {
        // If peripheral is discovered, initiate connection
        guard let peripheral = connectedPeripheral, peripheral.identifier.uuidString == deviceId else {
            return
        }
        // An explicit connect is the instruction that cancels an earlier explicit disconnect, and it
        // also supersedes a retry still waiting on the refusal floor.
        reconnectLock.lock()
        intentionalDisconnect = false
        standingConnectAttemptedAt = Date()
        // An explicit connect is a person's answer to a capped loop, so it clears the count too.
        consecutiveRefusals = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectLock.unlock()
        updateDeviceState {
            WhoopDevice(id: deviceId, name: peripheral.name ?? "WHOOP Strap", connectionState: .connecting)
        }
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    public func disconnect() {
        // The instruction has to precede the cancel: the delegate callback can arrive on the BLE queue
        // while this call is still returning, and a callback that runs first sees an involuntary drop
        // and brings the link straight back.
        reconnectLock.lock()
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectLock.unlock()
        // Hopped rather than called directly: the timer and the clocks it reads belong to the BLE
        // queue. The disconnect callback below stops it too; this is the path that runs before that
        // callback when the user is the one ending the link.
        bleQueue.async { [weak self] in self?.stopKeepAlive() }
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

    /// Writes a command that **must** be acknowledged, and reports whether the write was dispatched.
    ///
    /// **This is not `sendCommand` with a different type, and the difference is the whole point of the
    /// method.** `sendCommand` above picks `.withoutResponse` whenever the characteristic offers it —
    /// a reasonable default for a command, and a fatal one for the 5.0's first move. CoreBluetooth
    /// completes a just-works bond **as a confirmed write is acknowledged**, so an unconfirmed write
    /// of the same bytes over the same characteristic binds nothing and produces no callback to read
    /// the result from. The 5.0/MG therefore needs a write path that cannot degrade: if the
    /// characteristic does not carry `.write`, this refuses rather than silently falling back to the
    /// unconfirmed form, because a fallback would look exactly like a handshake that was sent.
    ///
    /// The `Bool` is *dispatched*, not *succeeded*. Success is `didWriteValueFor`'s to report, and
    /// that callback is the only place the bond's outcome is knowable — see below.
    ///
    /// - Returns: `true` when the write went to CoreBluetooth, `false` when there is no command
    ///   characteristic, no connected peripheral, or no `.write` property to write with.
    @discardableResult
    private func sendConfirmedCommand(_ data: Data) -> Bool {
        guard let peripheral = connectedPeripheral, let char = commandCharacteristic else { return false }
        guard char.properties.contains(.write) else {
            AppLogger.ble.warning("""
                Cannot handshake on \(char.uuid, privacy: .public): the characteristic does not carry \
                .write, so a confirmed write — and therefore the just-works bond — cannot be triggered \
                from here.
                """)
            return false
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
        return true
    }

    /// Everything this app sends on a command characteristic once the link is ready to take it.
    ///
    /// **Extracted so the handshake can defer it rather than duplicate it.** On a 4.0 these two go out
    /// the moment the characteristic is discovered, which is unchanged; on a 5.0/MG they are sent when
    /// the hello is acknowledged instead, because arming a producer on an unauthenticated link is the
    /// documented no-op — a command written pre-bond is refused by the strap regardless of which one
    /// it is.
    private func sendConnectCommands() {
        guard let profile = currentProfile else { return }

        // Send telemetry start command — under the connected strap's own envelope, and only
        // if this build has one *and* knows that generation's command opcodes. The 4.0's
        // `0x05` has no published 5.0 counterpart, so the 5.0 falls to the IMU enable below
        // rather than getting a frame this builder cannot build.
        if let frame = WhoopPacketEncoder.enableLiveTelemetry(
            profile: profile, seq: sequence.next(), enable: true) {
            sendCommand(frame)
        }

        // The IMU enable, for the step counter. Sent from here rather than from a screen's
        // `.task` for the same reason the telemetry enable is: the discovery callback fires
        // once per connection, and a command sent per screen appearance would toggle the IMU
        // off and on as the user moved between tabs.
        //
        // **Goes through `WhoopCommandFrames`, which is what makes a 5.0 strap produce motion at
        // all.** It routes by envelope: three frames on the 4.0 (`0x6A`, `0x3F`, `0x6B`) and two on
        // the 5.0 / MG (`0x51 START_RAW_DATA` then the toggle). This call used to go straight to the
        // 4.0 builder, whose refusal of the 5.0 envelope was correct and left the 5.0 with no
        // producer running — the 5.0 leg's whole first step.
        //
        // An **empty** array is still the state for an unknown generation rather than an error, so
        // `TrackStepsUseCase` holds a subscription with nothing arriving, which is the honest state
        // for a strap this build cannot write to.
        for frame in WhoopCommandFrames.motionEnableSequence(
            profile: profile, seq: sequence.next(), enable: true) {
            sendCommand(frame)
        }

        // The keep-alive's clock starts here, and only here. A re-send is worth attempting once these
        // bytes have actually gone out on this link; a 5.0/MG whose handshake was never acknowledged
        // never reaches this line, which is exactly what stops the watchdog writing pre-bond.
        hasSentConnectCommands = true
        lastActivationSentAt = Date()
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

    // MARK: - Reconnection

    /// Issues the call that keeps the link recoverable, now or after a refusal floor.
    ///
    /// **This is the whole recovery mechanism, and its shape is the point.** `connect` has no timeout:
    /// it stays outstanding until the strap answers, survives the app being suspended, and lets iOS
    /// relaunch the app when the strap re-advertises. A retry loop — `asyncAfter`, a periodic scan, a
    /// `Task.sleep` in place of the call — does the opposite: at the instant iOS suspends the app it
    /// leaves *nothing* outstanding, so the strap returning wakes nobody and the reconnect waits for the
    /// user to open the app instead. The one exception is the refusal floor, where the failure itself is
    /// proof the app was running when it happened.
    ///
    /// `reason` decides between the two answers; `ReconnectPolicy` owns that decision, the numbers,
    /// and — for a bond-gated generation — when the sequence has gone on long enough to stop.
    private func issueStandingConnect(for peripheral: CBPeripheral, after reason: ReconnectReason) {
        guard !isIntentionalDisconnect() else { return }

        let now = Date()
        reconnectLock.lock()
        let previous = standingConnectAttemptedAt
        let priorRefusals = consecutiveRefusals
        reconnectLock.unlock()

        let generation = resolveGeneration(
            advertisedName: peripheral.name ?? "WHOOP Strap",
            deviceId: peripheral.identifier.uuidString)
        let decision = ReconnectPolicy.decision(
            for: reason,
            previousAttemptStartedAt: previous,
            now: now,
            priorRefusals: priorRefusals,
            generation: generation)

        reconnectLock.lock()
        consecutiveRefusals = decision.consecutiveRefusals
        reconnectLock.unlock()

        switch decision.step {
        case .standingConnect:
            beginStandingConnect(for: peripheral, at: now)
        case .standingConnectAfter(let seconds):
            AppLogger.ble.notice("Standing connect refused quickly; retrying in \(Int(seconds)) s")
            scheduleStandingConnect(after: seconds)
        case .giveUp:
            // **The one place this app stops trying, and it names no new claim.** The sentence a
            // person needs is already on the device page's ADVANCED tab — `DeviceViewModel.protocolCaveat`
            // says the 5.0/MG's command characteristic needs a bond nothing here has established — so
            // this line exists for the log rather than for the screen.
            AppLogger.ble.warning("""
                Giving up after \(decision.consecutiveRefusals) consecutive refused connection \
                attempts on a \(generation.rawValue, privacy: .public). No further attempt is made \
                automatically; opening the app or pairing again gives it one more. The device page's \
                ADVANCED tab carries the caveat that explains a 5.0/MG which never answers.
                """)
        }
    }

    /// Issues one `connect` and records when it began.
    private func beginStandingConnect(for peripheral: CBPeripheral, at now: Date) {
        reconnectLock.lock()
        standingConnectAttemptedAt = now
        reconnectLock.unlock()

        // A connect issued before the central is powered on is a no-op, and losing it would leave the
        // strap with nothing pending at all. `centralManagerDidUpdateState` picks the peripheral up.
        guard centralManager.state == .poweredOn else {
            AppLogger.ble.notice("Standing connect deferred: central reported \(String(describing: self.centralManager.state))")
            return
        }
        peripheral.delegate = self
        AppLogger.ble.notice("Issuing standing connect to \(peripheral.name ?? "Strap") [\(peripheral.identifier.uuidString)]")
        centralManager.connect(peripheral, options: nil)
    }

    /// Waits out the refusal floor and issues the next attempt.
    ///
    /// A `Task` rather than a dispatch timer so the wait is cancellable by the two instructions that
    /// supersede it — an explicit `connect` and an explicit `disconnect` — and so a cancelled sleep
    /// cannot run its body anyway.
    private func scheduleStandingConnect(after seconds: TimeInterval) {
        reconnectLock.lock()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.resumeStandingConnect()
        }
        reconnectLock.unlock()
    }

    private func resumeStandingConnect() {
        reconnectLock.lock()
        reconnectTask = nil
        let peripheral = connectedPeripheral
        reconnectLock.unlock()

        guard let peripheral, !isIntentionalDisconnect() else { return }
        beginStandingConnect(for: peripheral, at: Date())
    }

    private func isIntentionalDisconnect() -> Bool {
        reconnectLock.lock()
        defer { reconnectLock.unlock() }
        return intentionalDisconnect
    }

    /// Resets everything that belongs to one link, ready for a connection **or a restore**.
    ///
    /// `didConnect` and the connected arm of `willRestoreState` both need it. The second is the reason
    /// it is a method: a peripheral iOS restores *already connected* never fires `didConnect`, so its
    /// one-shot diagnostics and its bond flag would otherwise be inherited from the process that died.
    private func prepareForNewLink() {
        hasLoggedCharacteristicInventory = false
        hasLoggedHeartRateFrames = false
        hasLoggedProprietaryFrame = false
        // A link that has gone away is not a link that is bonded, and iOS exposes no bond state to
        // ask: CoreBluetooth has no link-encryption property at all, so this flag is the only record
        // of whether this connection reached the strap. Reset on both transitions.
        isAwaitingBondHandshakeAck = false
        // A new connection is a new byte stream. Held bytes would be prepended to its first frame and
        // move every field in it.
        reassembler.reset()
        // The keep-alive clocks describe one link and are meaningless on the next: `lastActivityAt`
        // is set again by `beginKeepAliveWindow` when the link is actually up, so a fresh link starts
        // with an empty window rather than inheriting the previous one's silence.
        batteryCharacteristic = nil
        lastActivityAt = nil
        lastActivationSentAt = nil
        lastBatteryReadAt = nil
        hasSentConnectCommands = false
        hasLoggedUnreadableBattery = false
    }

    // MARK: - Keep-alive

    /// Starts watching a link CoreBluetooth still calls connected.
    ///
    /// **This is not the reconnect and must never become one.** The standing `connect` is what
    /// survives suspension; this timer only runs while the process does, and its job is the failure
    /// the link state cannot show — a GATT link that is up while the strap's producers are not.
    private func startKeepAlive() {
        stopKeepAlive()
        lastKeepAliveTickAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(
            deadline: .now() + KeepAlivePolicy.tickSeconds,
            repeating: KeepAlivePolicy.tickSeconds,
            leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.keepAliveTick() }
        timer.resume()
        keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        lastKeepAliveTickAt = nil
    }

    /// Begins the observation window for a link that has just come up.
    private func beginKeepAliveWindow() {
        lastActivityAt = Date()
        startKeepAlive()
    }

    /// Restarts the window after the app has been away, without claiming a frame arrived.
    ///
    /// Called from `rearmConnection`, which fires on `.active`. The timer's own gap check covers the
    /// same case; this is the earlier of the two and the one that runs before the first resumed tick
    /// can judge a link over time the app spent suspended.
    private func restartKeepAliveWindow() {
        guard connectedPeripheral?.state == .connected else { return }
        let now = Date()
        let gap = lastKeepAliveTickAt.map { now.timeIntervalSince($0) } ?? 0
        lastActivityAt = now
        if keepAliveTimer == nil {
            startKeepAlive()
        } else {
            lastKeepAliveTickAt = now
        }
        if gap >= KeepAlivePolicy.suspensionGapSeconds {
            AppLogger.ble.notice("""
                Keep-alive window restarted after \(Int(gap)) s without a tick; the liveness fuse \
                does not count time this process could not observe.
                """)
        }
    }

    private func keepAliveTick() {
        let now = Date()
        let previousTick = lastKeepAliveTickAt
        lastKeepAliveTickAt = now

        guard let peripheral = connectedPeripheral, peripheral.state == .connected,
              !isIntentionalDisconnect() else {
            stopKeepAlive()
            return
        }

        // **A tick this late is not a late tick.** The app was suspended, and the wall time since the
        // previous one is time in which nothing could have been observed. Advancing the window and
        // returning is what stops a resume from being read as two minutes of silence.
        if let previousTick {
            let gap = now.timeIntervalSince(previousTick)
            if gap > KeepAlivePolicy.suspensionGapSeconds {
                lastActivityAt = now
                AppLogger.ble.notice("""
                    Keep-alive resumed after \(Int(gap)) s without a tick; the silence window restarts \
                    rather than counting time this process could not observe.
                    """)
                return
            }
        }

        guard let lastActivityAt else { return }
        let generation = connectedGeneration(for: peripheral)
        let action = KeepAlivePolicy.action(
            for: generation,
            lastActivityAt: lastActivityAt,
            lastActivationSentAt: lastActivationSentAt,
            lastBatteryReadAt: lastBatteryReadAt,
            now: now,
            isDraining: isDraining())

        if action.bounceLink {
            bounceStalledLink(
                peripheral,
                silentFor: now.timeIntervalSince(lastActivityAt),
                generation: generation)
            return
        }
        if action.readBattery { readBatteryLevel() }
        if action.resendActivation {
            resendActivationCommands(silentFor: now.timeIntervalSince(lastActivityAt))
        }
    }

    private func connectedGeneration(for peripheral: CBPeripheral) -> WhoopHardwareGeneration {
        if let generation = currentDeviceState?.hardwareGeneration { return generation }
        return resolveGeneration(
            advertisedName: peripheral.name ?? "WHOOP Strap",
            deviceId: peripheral.identifier.uuidString)
    }

    private func isDraining() -> Bool {
        drainLock.lock()
        defer { drainLock.unlock() }
        return drainSession != nil
    }

    /// Ends a link that has been up and silent past its family's fuse.
    ///
    /// The recovery is the ordinary one rather than a second mechanism: cancelling the connection is
    /// an involuntary drop as far as `didDisconnectPeripheral` can tell, so the standing connect goes
    /// out and discovery re-runs — which is the only thing that re-arms a producer that will not
    /// answer a write.
    private func bounceStalledLink(
        _ peripheral: CBPeripheral,
        silentFor: TimeInterval,
        generation: WhoopHardwareGeneration
    ) {
        // Stopped first: the disconnect callback re-arms the standing connect, and a tick landing
        // between the cancel and that callback would judge a link that is already going away.
        stopKeepAlive()
        AppLogger.ble.warning("""
            No data from \(peripheral.name ?? "Strap", privacy: .public) in \(Int(silentFor)) s on a \
            \(generation.rawValue, privacy: .public) link. Bouncing it so the standing connect can \
            recover the link and discovery can re-arm the producers.
            """)
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Asks the strap for a fresh `0x2A19`, which doubles as the probe the fuse reads.
    ///
    /// The floor is applied by the policy before this is called. `lastBatteryReadAt` is stamped at
    /// dispatch rather than on the answer, so a strap that never answers does not turn the floor into
    /// a per-tick request.
    private func readBatteryLevel() {
        guard let peripheral = connectedPeripheral, let characteristic = batteryCharacteristic else {
            return
        }
        guard characteristic.properties.contains(.read) else {
            if !hasLoggedUnreadableBattery {
                hasLoggedUnreadableBattery = true
                AppLogger.ble.info("""
                    Battery level characteristic (\(characteristic.uuid, privacy: .public)) carries no \
                    .read property; the keep-alive cannot use it as a probe on this link.
                    """)
            }
            return
        }
        lastBatteryReadAt = Date()
        peripheral.readValue(for: characteristic)
    }

    /// Writes the enable sequence again after the stream has been silent.
    private func resendActivationCommands(silentFor: TimeInterval) {
        guard hasSentConnectCommands else {
            // A 5.0/MG whose bond handshake was never acknowledged: writing the enables now is a
            // pre-bond write the strap refuses. The liveness fuse is the recovery for that link.
            return
        }
        let name = connectedPeripheral?.name ?? "Strap"
        AppLogger.ble.notice("""
            No data from \(name, privacy: .public) in \(Int(silentFor)) s; re-sending the activation \
            commands.
            """)
        sendConnectCommands()
    }

    /// Records that the link produced something. BLE queue only.
    private func noteLinkActivity() {
        lastActivityAt = Date()
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
        guard central.state == .poweredOn else {
            // Nothing can be heard from the strap while the radio is off, and a tick firing into
            // that state would read it as silence. The link, if it survives, re-arms below.
            stopKeepAlive()
            return
        }

        // A restore can happen before this callback — `willRestoreState` is documented as the *first*
        // method invoked after a background relaunch — so a disconnect it handed over waited here.
        reconnectLock.lock()
        let restored = pendingRestorePeripheral
        pendingRestorePeripheral = nil
        reconnectLock.unlock()

        if let restored {
            issueStandingConnect(for: restored, after: .disconnected)
        } else if let peripheral = connectedPeripheral {
            // A restore that found the link up has already re-armed it; the tick is restarted here
            // because it was stopped when the radio went away, and the window is restarted with it.
            guard peripheral.state != .connected else {
                beginKeepAliveWindow()
                return
            }
            // Bluetooth was cycled, or a connect was refused while it was off. Either way the pending
            // connection is gone, and only a new one gets the strap back.
            issueStandingConnect(for: peripheral, after: .failedToConnect)
        } else {
            startScanning()
        }
    }

    /// Adopts the peripheral iOS preserved when it terminated this app.
    ///
    /// **A restored, already-connected peripheral never fires `didConnect`**, which is why the device
    /// state is seeded here rather than left to that callback — without it the app would show
    /// `Disconnected` over a live link until something else moved the state. Services are re-discovered
    /// rather than trusted: a restored subscription can report `isNotifying == true` while delivering
    /// nothing, and `didDiscoverCharacteristicsFor` subscribes every notify characteristic again.
    /// Re-running that callback also re-sends the telemetry and motion enables, which is the point —
    /// the process that armed the strap is gone.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let peripheral = peripherals.first
        else {
            AppLogger.ble.notice("Bluetooth state restored with no peripheral to adopt")
            return
        }

        AppLogger.ble.notice("Restored \(peripheral.name ?? "Strap") [\(peripheral.identifier.uuidString)], state \(peripheral.state.rawValue)")
        connectedPeripheral = peripheral
        peripheral.delegate = self

        if peripheral.state == .connected {
            prepareForNewLink()
            reconnectLock.lock()
            consecutiveRefusals = 0
            reconnectLock.unlock()
            updateDeviceState {
                resolvedDevice(for: peripheral, connectionState: .connected, fallback: currentDeviceState)
            }
            peripheral.discoverServices(nil)
            // A restored link is inherited, not observed: start its window now rather than letting a
            // tick judge time this process spent dead.
            beginKeepAliveWindow()
        } else {
            stopKeepAlive()
            updateDeviceState {
                resolvedDevice(for: peripheral, connectionState: .disconnected, fallback: currentDeviceState)
            }
            if central.state == .poweredOn {
                issueStandingConnect(for: peripheral, after: .disconnected)
            } else {
                // `centralManagerDidUpdateState` is the first callback allowed to connect; it picks
                // this up when the central reports powered on.
                reconnectLock.lock()
                pendingRestorePeripheral = peripheral
                reconnectLock.unlock()
            }
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
        // **The scan has done its job once a strap is in hand.** Everything after this point is
        // addressed to a retained peripheral, which a pending `connect` reaches whether or not it is
        // advertising — so leaving the scan running would only let a second discovery race the
        // connection this line starts, and would keep the radio listening for no one.
        stopScanning()
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLogger.ble.info("Connected to \(peripheral.name ?? "Strap")")
        // A link is up, so an earlier explicit disconnect has been superseded. A retry waiting on the
        // refusal floor has nothing left to do.
        reconnectLock.lock()
        intentionalDisconnect = false
        // A link is the one fact that ends a refusal streak, whatever preceded it.
        consecutiveRefusals = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectLock.unlock()
        stopScanning()
        prepareForNewLink()
        updateDeviceState {
            resolvedDevice(
                for: peripheral,
                connectionState: .connected,
                fallback: currentDeviceState
            )
        }
        peripheral.discoverServices(nil)
        beginKeepAliveWindow()
    }

    /// The answer to an attempt that did not become a link.
    ///
    /// New in the lifecycle, and the missing half of `didDisconnectPeripheral`: a strap that refuses a
    /// connection previously left the app with nothing outstanding and nothing to try, which is the
    /// same dead end as an unanswered drop. `ReconnectPolicy` decides whether the retry is immediate or
    /// waits out the floor — a refusal that arrived in under a second is the strap saying no, and
    /// retrying it at once is how a transient refusal is made permanent.
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        AppLogger.ble.warning("Failed to connect to \(peripheral.name ?? "Strap"), error: \(String(describing: error))")
        stopKeepAlive()
        prepareForNewLink()
        updateDeviceState {
            resolvedDevice(
                for: peripheral,
                connectionState: .disconnected,
                fallback: currentDeviceState
            )
        }
        issueStandingConnect(for: peripheral, after: .failedToConnect)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        AppLogger.ble.warning("Disconnected peripheral: \(peripheral.name ?? "Strap"), error: \(String(describing: error))")
        stopKeepAlive()
        prepareForNewLink()
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
        // **The recovery, and the reason the log above is not the last word.** An answer to "why does it
        // disconnect when I stop watching it?" is not a better log line; it is a `connect` that is
        // still outstanding when the app is suspended, so the strap coming back is an event iOS wakes
        // the app for. The user's own disconnect is the one case that is not a fault.
        if isIntentionalDisconnect() {
            AppLogger.ble.notice("Not reconnecting: the disconnect was requested")
        } else {
            issueStandingConnect(for: peripheral, after: .disconnected)
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
            // Kept so the keep-alive tick can ask for a fresh reading. It is also subscribed below if
            // it notifies — the two are independent, and a strap that only notifies still updates
            // the screen while a strap that only reads is still readable.
            if char.uuid == WhoopGATTConstants.batteryLevelCharacteristicUUID {
                self.batteryCharacteristic = char
            }

            if char.uuid == WhoopGATTConstants.whoop4CommandUUID || char.uuid == WhoopGATTConstants.whoop5CommandUUID {
                self.commandCharacteristic = char

                // **The 5.0/MG handshake goes first, and it goes alone.** Both generations' first
                // moves used to be sent from here unconfirmed and in one burst, which for a 5.0 is two
                // mistakes at once: the strap's command characteristic is gated on a just-works bond
                // this app never asked for, and a command written pre-bond is refused whatever it
                // carries. So the hello is written, confirmed, and everything else waits for its
                // acknowledgement — see `didWriteValueFor`.
                //
                // `WhoopPacketEncoder5.hello` is the discriminator as well as the frame: it returns
                // bytes only for a profile with the CRC16 envelope, which is exactly `.whoop5` and
                // `.whoop5MG`. A 4.0 takes the `else`, and its path is byte-for-byte what it was.
                if let profile = currentProfile,
                   let hello = WhoopPacketEncoder5.hello(profile: profile, seq: sequence.next()) {
                    // A `false` here means the write never reached CoreBluetooth — no `.write`
                    // property to handshake with. The enables still go out, because a 5.0 that cannot
                    // be bonded from this app is the state it was in before this change and there is no
                    // reason to withhold the commands that might still land.
                    isAwaitingBondHandshakeAck = sendConfirmedCommand(hello)
                    if !isAwaitingBondHandshakeAck { sendConnectCommands() }
                } else {
                    sendConnectCommands()
                }
            }

            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    /// The acknowledgement of a confirmed write, and **the only place this app can learn whether the
    /// 5.0/MG bond completed.**
    ///
    /// **It logs every write and acts on exactly one.** The log line is most of why this method
    /// exists: CoreBluetooth publishes no link-encryption or bond state, so a client cannot ask
    /// whether it is bonded — but a command the strap refuses on an unauthenticated link comes back
    /// here as `insufficientAuthentication` (or `insufficientEncryption`), and nothing else in the app
    /// would ever see it. The worse outcome is the one with no error at all: a *refused* hello can
    /// simply drop the link, which is indistinguishable from the strap going out of range. So
    /// "connected, then silence" is a result to read as a refusing strap rather than as a stray
    /// disconnect.
    ///
    /// **The handshake runs once per connection and this is the guard.** `didWriteValueFor` re-fires
    /// on every later confirmed write — the drain's acknowledgements go out `.withResponse` too — and
    /// re-running the connect sequence mid-drain is the documented cause of a strap refusing to stream
    /// its type-47 records. The flag is therefore cleared before anything else, and a later
    /// acknowledgement falls straight through to the log line.
    ///
    /// A failed handshake does **not** arm the producers: a command written pre-bond is refused
    /// whatever it carries, so sending them would be noise over a link that has already said no.
    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // A successful confirmed write is the strap answering, so it is activity for the fuse even
        // though it is not a frame. A failed one is not counted: the error can be a timeout delivered
        // after the link has already gone.
        if error == nil { noteLinkActivity() }

        if let error {
            AppLogger.ble.warning("""
                Confirmed write to \(characteristic.uuid, privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
        } else {
            AppLogger.ble.info("""
                Confirmed write to \(characteristic.uuid, privacy: .public) acknowledged
                """)
        }

        guard isAwaitingBondHandshakeAck else { return }
        isAwaitingBondHandshakeAck = false

        guard error == nil else {
            let nsError = error! as NSError
            let refusedForBond = nsError.domain == CBATTErrorDomain
                && (nsError.code == CBATTError.insufficientAuthentication.rawValue
                    || nsError.code == CBATTError.insufficientEncryption.rawValue)
            AppLogger.ble.warning("""
                5.0/MG handshake not acknowledged — the bond did not complete. \
                \(refusedForBond
                    ? "The strap refused the write on an unauthenticated link."
                    : "The write failed for a reason that is not the bond.", privacy: .public) \
                The producers are left unarmed, because a command written pre-bond is refused anyway.
                """)
            return
        }

        // `.notice`, not `.info`, and the level is the point rather than the volume. `.info` is
        // memory-only — it reaches a live stream and is never written to the log store — while the
        // failure arm above logs at `.warning` and is persisted. At `.info` a log archive collected
        // after the run would hold this handshake's failure and not its success: an artifact that can
        // only report one of the two answers. This is the line the whole test is read from.
        AppLogger.ble.notice("""
            5.0/MG handshake acknowledged — the link is bonded, so the producers are being armed now.
            """)
        sendConnectCommands()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        // Every notification is evidence the link is carrying data — including the battery read,
        // which is why that one request can double as the keep-alive's probe. Recorded before the
        // branches so a frame this build cannot decode still counts, since the fuse is about the
        // link rather than about what was understood.
        noteLinkActivity()

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
        // what `docs/BLE_PROTOCOL.md` §7 asks to be captured.
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
