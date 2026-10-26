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
    private var stepCounterContinuations: [UUID: AsyncStream<StepCounterSample>.Continuation] = [:]
    private var historicalTelemetryContinuations: [UUID: AsyncStream<BiometricSample>.Continuation] = [:]

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

    /// Generations the strap itself proved, one entry per peripheral identifier.
    ///
    /// **This is evidence, and it outranks the name heuristic.** `resolvedGeneration` reads `"5"` out
    /// of the advertised name, but a strap's name is whatever its owner set — the one on this
    /// machine advertises as `"Alex WHOOP"` — and a strap advertising nothing at all arrives as
    /// `"WHOOP Strap"`. Neither contains the digit, so both were resolved as a 4.0 and every command
    /// was framed under the CRC8 envelope the strap does not speak.
    ///
    /// A strap that exposes `FD4B0001` is a 5.0/MG: no 4.0 has that service. So discovery records the
    /// answer here, and every later resolve in this process — a reconnect, the keep-alive's re-arm —
    /// gets the strap right without re-guessing. It is in-memory rather than persisted because it is
    /// re-learned on the first connection and the stored-model map is the user's choice, not the
    /// app's observation.
    private var serviceObservedGenerations: [String: WhoopHardwareGeneration] = [:]

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
    /// The oxygen candidate's counters for the drain in progress. Guarded by `drainLock` like
    /// `drainSession`, because `routeToDrain` runs on the BLE queue and `concludeDrain` can run from
    /// there or from a caller's task. See `Spo2CandidateProbe`.
    private var spo2Probe = Spo2CandidateAccumulator()
    private var drainWatchdog: Task<Void, Never>?

    /// Whether the one-shot 0x2A37 diagnostic has been logged for this connection.
    ///
    /// Reset on connect and disconnect, so each session logs once. The 0x2A37 branch fires per
    /// notification, and a strap sending at 1 Hz would otherwise write a line a second into the log
    /// — which is the kind of noise that gets logging deleted rather than read.
    private var hasLoggedHeartRateFrames = false

    /// Whether the first decoded 5.0/MG live heart-rate record has been logged for this connection.
    ///
    /// Same once-per-link shape as the flags above. Packet 40 arrives about once a second once the
    /// strap is armed, so its first appearance is the line that distinguishes "armed and streaming"
    /// from "subscribed but silent" in a log archive collected after the fact.
    private var hasLoggedLiveHeartRate = false

    /// Whether the one-shot proprietary-frame diagnostic has been logged for this connection.
    ///
    /// Same reason as the two above: the branch runs per notification. This is the log that would
    /// carry a capture's first evidence — a real strap's packet type, sequence number, opcode and
    /// payload length — so it is worth exactly one line per connection and no more.
    private var hasLoggedProprietaryFrame = false

    /// Whether the first record routed into a drain has been reported for this connection.
    ///
    /// One line per link, and it is the one that says *what shape* history arrived in when the drain
    /// summary says the strap sent records — the summary counts them, this names the type, sequence
    /// and payload length. `routeToDrain` runs per record, so it cannot be a line per frame.
    private var hasReportedHistoricalRecord = false

    /// Whether the first decoded step counter has been recorded for this connection.
    ///
    /// **The offsets are NOOP's finding and this app has not captured them**, so the first sample is
    /// the evidence that the walk is reading a counter rather than a coincidence in the bytes. One per
    /// link, because `routeToDrain` runs per record and a counter line per record would bury it.
    private var hasReportedStepCounter = false

    /// Whether the one-shot command-response diagnostic has been logged for this connection.
    ///
    /// **The clock read-back has no parser, so its reply is captured as bytes.** The first
    /// `commandResponse` frame per link is logged whole, and every response whose `cmd` is
    /// `setClock`/`getClock` is logged after it — that pair is what a capture compares against the
    /// clock that was sent, and no field is decoded or claimed.
    private var hasLoggedCommandResponse = false

    /// The Device Information Service characteristics discovery found, keyed by UUID.
    ///
    /// A read has to be issued from the characteristic object discovery handed over, and DIS discovery
    /// and the connect pass can arrive in either order — so discovery stores them here and
    /// `requestDeviceInformationReadIfPossible` decides *when* a read is legal. Cleared with the rest
    /// of the link's state in `prepareForNewLink`.
    private var deviceInformationCharacteristics: [CBUUID: CBCharacteristic] = [:]

    /// Whether this link has already issued its one DIS read pass.
    ///
    /// **Set only when at least one read was actually issued.** A DIS that has not been discovered yet,
    /// or that exposes no readable characteristic, leaves it false so the later trigger can still try —
    /// which is what keeps a 5.0 whose DIS arrives before its bond from never being read.
    private var hasRequestedDeviceInformationRead = false

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

    /// The 5.0/MG notify characteristics discovery found **before** the bond was acknowledged.
    ///
    /// **Subscribing these at discovery is what wedges a 5.0.** noop's field evidence is explicit: the
    /// puffin characteristics (`fd4b0003`/`0004`/`0005`/`0007`) are subscribed only *after* the confirmed
    /// `CLIENT_HELLO` is acknowledged, and a pre-bond subscription is refused with "Authentication is
    /// insufficient" and leaves the bond in a state the strap does not recover from. So discovery
    /// retains them here and `subscribePendingNotifications()` attaches them on the acknowledgement —
    /// the one callback that says the link is bonded.
    ///
    /// **BLE-queue only**, like `reassembler`: written and read from `didDiscoverCharacteristicsFor` and
    /// `didWriteValueFor`, both of which CoreBluetooth serialises on the manager's own queue. The
    /// standard `0x2A37` and `0x2A19` characteristics are never held here — they work unbonded and
    /// deferring them would hide the one producer that already functions.
    private var pendingNotifyCharacteristics: [CBCharacteristic] = []

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

    /// When the strap's own clock was last logged, so a per-second record cannot flood the archive.
    private var lastStrapClockLogAt: Date?
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

    /// The model for a strap, in precedence order: **the user's choice, then the strap's own GATT
    /// evidence, then the name guess.**
    ///
    /// The middle rung is why this is not simply `resolvedGeneration(stored:advertisedName:)` any
    /// more. A 5.0/MG strap exposes a service no 4.0 does, and that is a fact about the hardware
    /// rather than an inference from what its owner renamed it to. Evidence outranks a stored 4.0
    /// only because a 4.0 choice for a strap exposing `FD4B0001` cannot be true — and writing 4.0
    /// opcodes down the 5.0 command characteristic is the cross-generation write this build exists to
    /// refuse. The choice between 5.0 and 5.0 MG still comes from the user; the service cannot tell
    /// those two apart.
    private func resolveGeneration(advertisedName: String, deviceId: String) -> WhoopHardwareGeneration {
        strapModelLock.lock()
        let stored = strapModelCache[deviceId]
        let observed = serviceObservedGenerations[deviceId]
        strapModelLock.unlock()
        return Self.resolvedGeneration(
            stored: stored, observed: observed, advertisedName: advertisedName)
    }

    /// Records the strap's own answer, and persists it when the user has never chosen a model.
    ///
    /// **Evidence, not a guess, so writing it is not the "guess overriding a choice" this app
    /// forbids** — the rule is about a *stored choice*, and `strapModelCache[deviceId] == nil` is the
    /// absence of one. Without this, a strap whose advertised name carries no digit ("Alex WHOOP")
    /// resolves as a 4.0 on every launch, and the device page shows 4.0 until service discovery
    /// corrects it. With it, the second launch starts from what the hardware said.
    ///
    /// The user's 5.0-vs-MG answer still wins over the service list, which cannot separate the two —
    /// but the model string *can*, so a stored `5.0` beside an observed `5.0 MG` keeps the user's
    /// choice and the log says so rather than silently overruling either.
    private func adoptObservedGeneration(modelNumber: String) {
        guard let observed = WhoopHardwareGeneration.from(modelNumber: modelNumber) else {
            AppLogger.ble.notice("""
                Model number \(modelNumber, privacy: .public) names no generation this build knows; \
                the advertised-name rung still decides.
                """)
            return
        }
        adoptObservedGeneration(observed, persist: true)
    }

    /// The one place an observed generation is recorded, shared by the service list and the model
    /// string — so the two rungs cannot come to disagree about what "observed" means.
    /// - Parameter persist: `true` only for the **model string**, which is the one rung that can name
    ///   a 5.0 MG as well as a 5.0. The service list runs first and cannot tell the two apart, so it
    ///   records the observation without writing it — otherwise a stored `5.0` would be in place by
    ///   the time the model string arrived with the better answer, and the user-choice rule would
    ///   then correctly refuse to correct it.
    private func adoptObservedGeneration(_ observed: WhoopHardwareGeneration, persist: Bool) {
        guard let current = currentDeviceState, !current.id.isEmpty else { return }
        let deviceId = current.id

        strapModelLock.lock()
        let stored = strapModelCache[deviceId]
        serviceObservedGenerations[deviceId] = observed
        if stored == nil { strapModelCache[deviceId] = observed }
        strapModelLock.unlock()

        if persist, stored == nil, let repository = strapModelRepository {
            Task { await repository.setModel(observed, forDeviceId: deviceId) }
        }

        let keepsUserChoice = stored == .whoop5 || stored == .whoop5MG
        guard !keepsUserChoice, current.hardwareGeneration != observed else { return }

        updateDeviceState {
            WhoopDevice(
                id: current.id,
                name: current.name,
                hardwareGeneration: observed,
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
        AppLogger.ble.notice("""
            The strap reports itself as \(observed.rawValue, privacy: .public); it was resolved as \
            \(current.hardwareGeneration.rawValue, privacy: .public) before that read.
            """)
    }

    /// Records the strap's own answer when its service list contains the 5.0/MG service.
    ///
    /// **Runs from `didDiscoverServices`, before any characteristic is discovered**, so the command
    /// characteristic discovered next is framed under the CRC16 envelope the first time. Doing this
    /// from the characteristic callback would be too late on a strap whose 4.0-looking name had
    /// already put the app on the other envelope.
    ///
    /// The user's 5.0-vs-MG answer is preserved; only a generation that cannot be the connected strap
    /// is corrected. The recorded answer also outlives this connection in memory, so a reconnect —
    /// which resolves from the advertised name again — does not fall back to 4.0 between links.
    private func adoptWhoop5FromDiscoveredService(for peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        strapModelLock.lock()
        let alreadyObserved = serviceObservedGenerations[deviceId]
        strapModelLock.unlock()

        // **Not persisted.** The service list proves a 5.0 from a 4.0 and cannot separate the MG;
        // the model string arrives moments later and can. Writing `.whoop5` here would put a stored
        // choice in place that the user-choice rule then refuses to correct to `.whoop5MG`.
        adoptObservedGeneration(.whoop5, persist: false)

        guard let current = currentDeviceState, current.id == deviceId,
              current.hardwareGeneration == .whoop5 else { return }

        if alreadyObserved != .whoop5 {
            AppLogger.ble.notice("""
                The strap exposes \(WhoopGATTConstants.whoop5ServiceUUID, privacy: .public), so it is \
                treated as a 5.0/MG — advertised name \(current.name, privacy: .public) does not say, \
                and was resolved as \(current.hardwareGeneration.rawValue, privacy: .public) before \
                discovery. Commands now use the CRC16 envelope.
                """)
        }
    }

    /// The precedence rule itself, as a pure function of its three inputs.
    ///
    /// Separated from the cache read above for one reason that is not tidiness: this is the rule the
    /// whole generation-aware path rests on, and every way it can be wrong is silent. A guess that
    /// overrode a choice would put the app back on the wrong envelope with the screen still showing
    /// the user's selection; the guess itself cannot tell a 5.0 from a 5.0 MG at all, and a strap
    /// advertising nothing arrives as `"WHOOP Strap"` — no `5` in it, so it is called a 4.0. As a
    /// static taking its inputs it is assertable without a `CBCentralManager`, which the suite has no
    /// way to build (constructing one raises a system Bluetooth prompt).
    ///
    /// **`observed` is the strap's own GATT answer and sits between the choice and the guess.** It is
    /// `.whoop5` when service discovery found `FD4B0001`; no 4.0 exposes that service, so it is
    /// hardware evidence rather than an inference. Two things follow. It is overruled by a stored
    /// 5.0/5.0 MG choice because the service cannot distinguish those two and only the user can. It
    /// *does* overrule a stored 4.0 (or a non-strap transport) because that choice cannot be true for
    /// this hardware, and honouring it would frame 4.0 opcodes for a 5.0 strap.
    ///
    /// The heuristic is kept as the fallback rather than deleted, because a strap the user has never
    /// been asked about still has to be described as something.
    public static func resolvedGeneration(
        stored: WhoopHardwareGeneration?,
        observed: WhoopHardwareGeneration?,
        advertisedName: String
    ) -> WhoopHardwareGeneration {
        if let stored {
            let storedIsFour = stored == .whoop4
                || stored == .standardBleHR
                || stored == .simulator
            if storedIsFour, let observed { return observed }
            return stored
        }
        if let observed { return observed }
        return advertisedName.contains("5") ? .whoop5 : .whoop4
    }

    /// The two-input form, kept for callers that have no GATT observation — and for the suite, which
    /// has asserted this precedence since before the observation rung existed.
    public static func resolvedGeneration(
        stored: WhoopHardwareGeneration?,
        advertisedName: String
    ) -> WhoopHardwareGeneration {
        resolvedGeneration(stored: stored, observed: nil, advertisedName: advertisedName)
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

    /// The heart-rate samples a drain recovers from the strap's flash, one per R18 record.
    ///
    /// **A second stream rather than more traffic on `liveTelemetryStream`, and the split is the point.**
    /// The two producers answer different questions — the live stream is *what the strap is measuring
    /// now*, stamped with the arrival instant, while these samples carry the timestamp of the moment
    /// they were stored, which is a day or more old. Merging them would put a drained sample from three
    /// days ago into every live consumer (the Home badge, the Live Activity), which reads as a current
    /// pulse. `SyncHistoricalDataUseCase` is this stream's consumer and it is what writes the rows.
    ///
    /// It is a multicast registry like the other three, and the same rule applies: anything that yields
    /// goes through `yieldHistoricalTelemetry`, never the dictionary.
    ///
    /// **Finishing the continuations is how a consumer learns the drain ended.** `concludeDrain` calls
    /// `finish()`, and `AsyncStream.finish()` delivers buffered elements before ending — so a consumer
    /// awaiting this stream sees every decoded record before its loop exits. Cancelling the consumer
    /// instead would discard whatever had not yet been pulled.
    public var historicalTelemetryStream: AsyncStream<BiometricSample> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            historicalTelemetryContinuations[id] = continuation
            continuationLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeHistoricalTelemetryContinuation(id)
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

    /// The strap's own pedometer, decoded from drained R18 records.
    ///
    /// Registered exactly as `motionStream` is, and **never finished**: the consumer is
    /// `TrackStepsUseCase`, which is attached for the life of the process, and a stream that ended
    /// with a drain would have to be re-attached before the next one. A drain that returns no R18
    /// records simply yields nothing, which is the same empty answer a strap without the field gives.
    public var stepCounterStream: AsyncStream<StepCounterSample> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            stepCounterContinuations[id] = continuation
            continuationLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeStepCounterContinuation(id)
            }
        }
    }

    private func removeStepCounterContinuation(_ id: UUID) {
        continuationLock.lock()
        stepCounterContinuations[id] = nil
        continuationLock.unlock()
    }

    /// Fans a decoded counter sample out to every live subscriber. See `yieldTelemetry`.
    private func yieldStepCounter(_ sample: StepCounterSample) {
        continuationLock.lock()
        let targets = Array(stepCounterContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(sample) }
    }

    private func removeHistoricalTelemetryContinuation(_ id: UUID) {
        continuationLock.lock()
        historicalTelemetryContinuations[id] = nil
        continuationLock.unlock()
    }

    /// Logs the strap's own clock against this phone's, at most once a minute.
    ///
    /// **The one continuous view of the RTC, and it is free.** Every R21 record carries the strap's
    /// unix time whether it is live or banked; the live path ignores it for day-keying (a live record
    /// keys on arrival) but that leaves it available to *observe*. `GET_CLOCK` is the documented
    /// read-back and this strap answered it once and then stopped, so the record's own field is the
    /// reliable instrument — and it is exactly the field a drain would file history by, which makes
    /// the drift it prints the number that matters for recovering a night.
    private func noteStrapClock(_ strapStamp: Date?, arrival: Date) {
        guard let strapStamp else { return }
        let now = arrival
        if let last = lastStrapClockLogAt, now.timeIntervalSince(last) < 60 { return }
        lastStrapClockLogAt = now
        let drift = strapStamp.timeIntervalSince(now) / 3600
        AppLogger.ble.notice("""
            Motion record clock: strap=\(strapStamp.description, privacy: .public) \
            phone=\(now.description, privacy: .public), drift \
            \(String(format: "%.1f", drift), privacy: .public) h
            """)
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

    /// Fans a drained sample out to every historical subscriber. See `yieldTelemetry`.
    private func yieldHistoricalTelemetry(_ sample: BiometricSample) {
        continuationLock.lock()
        let targets = Array(historicalTelemetryContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(sample) }
    }

    /// Ends every historical consumer's stream, because the drain it was reading has ended.
    ///
    /// **`finish()` rather than cancelling the consumers**, on the rule `AsyncStream` documents: a
    /// finished stream delivers what it buffered and then ends, while a cancelled consumer discards the
    /// buffer. A drain whose final batch arrived just before `HISTORY_COMPLETE` would otherwise lose
    /// exactly those samples — the last ones, and the only ones near the present.
    ///
    /// Called from `concludeDrain`, so every exit path ends the consumers: the strap's own
    /// `HISTORY_COMPLETE`, the live edge, the idle window, an abort, a disconnect. The dictionaries are
    /// cleared here rather than left to `onTermination`, because `finish()` does not remove the entry
    /// synchronously and a later drain must not resume a stream that has already finished.
    private func finishHistoricalTelemetry() {
        continuationLock.lock()
        let targets = Array(historicalTelemetryContinuations.values)
        historicalTelemetryContinuations.removeAll()
        continuationLock.unlock()
        for continuation in targets { continuation.finish() }
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
        guard !isIntentionalDisconnect() else { return }
        guard centralManager.state == .poweredOn else {
            // **The second place a stale `.connected` is corrected.** The powered-off callback can
            // have been missed while the app was suspended, so the foreground asks the radio again —
            // and if it is off, no link exists, whatever the last device object said. Hopped to the
            // BLE queue because it mutates the same state that queue owns.
            bleQueue.async { [weak self] in self?.markLinkLost() }
            return
        }
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
    /// Sends a command the strap must not miss — the drain's ACK is the caller.
    ///
    /// **Confirmed first, because the reference writes its ACK that way.** `HISTORICAL_DATA_RESULT`
    /// is what advances the strap's trim cursor; a write dropped without a response leaves history
    /// un-reclaimed and the next drain asking for the same records. The fallback keeps a characteristic
    /// that only advertises `writeWithoutResponse` working rather than dropping the ACK outright.
    private func sendReliableCommand(_ data: Data) {
        if sendConfirmedCommand(data) { return }
        sendCommand(data)
    }

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

    /// Plays the strap's haptic pattern — the buzz — `loops` times.
    ///
    /// **The caller does not know which opcode its strap uses, and must not.** A 4.0 takes command
    /// `0x4F` with a pattern id; a 5.0/MG takes the puffin remap `0x13` and a fixed notification preset,
    /// because a real MG rejects 79 outright. `WhoopCommandFrames.hapticsPattern` is where that split
    /// lives, and this method is the seam a screen or the Live Activity would call.
    ///
    /// **`true` means a frame was built and handed to the write path, not that the strap buzzed.** A
    /// write can still be refused for a link this app cannot address; no acknowledgement is parsed.
    /// **No screen calls this yet** — it is added here so the first call site does not have to know the
    /// remap, and it is exercised by the suite rather than by a device.
    @discardableResult
    public func buzz(loops: UInt8 = 1, pattern: UInt8 = 2) -> Bool {
        guard let profile = currentProfile,
              let frame = WhoopCommandFrames.hapticsPattern(
                  profile: profile, seq: sequence.next(), pattern: pattern, loops: loops)
        else {
            AppLogger.ble.warning("Refused to send haptics: no pattern frame for this strap")
            return false
        }
        sendCommand(frame)
        AppLogger.ble.notice("Haptics pattern sent (\(frame.count, privacy: .public) bytes, loops \(loops)).")
        return true
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

    /// Sends the strap's advertising-name command, and reports only whether the write reached the link.
    ///
    /// **A sent frame is not a stored name.** Neither generation's write has been confirmed in a
    /// device capture, and the reference says radio visibility may lag the reply — so the only proof
    /// this app has is the name in the *next* advertisement, which is what the device page tells the
    /// user to look at. `false` means nothing was written: no command path, an empty name, or a
    /// generation this build cannot frame for.
    public func setAdvertisingName(_ name: String) -> Bool {
        guard let profile = currentProfile,
              let frame = WhoopCommandFrames.setAdvertisingName(
                profile: profile, seq: commandSequence.next(), name: name)
        else {
            let generation = currentDeviceState?.hardwareGeneration.rawValue ?? "none"
            AppLogger.ble.warning("""
                Refused SET_ADVERTISING_NAME: cannot frame it for \(generation, privacy: .public).
                """)
            return false
        }

        let handedToTheLink = sendConfirmedCommand(frame)
        AppLogger.ble.notice("""
            Sent SET_ADVERTISING_NAME (requested, not confirmed): \
            \(WhoopCommandFrames.clampedAdvertisingName(name), privacy: .public) — the name in the \
            next advertisement is what will settle it.
            """)
        return handedToTheLink
    }

    /// The opcodes whose reply states the strap's stored advertising name — 141/140 on a 5.0/MG and
    /// 76/77 on a 4.0.
    static let advertisingNameCommands: Set<UInt8> = [0x8D, 0x8C, 0x4C, 0x4D]

    /// Asks the strap for the name it has stored, logging the reply for the capture file.
    ///
    /// **This is the read that settles a rename**, because the advertisement a phone shows may be
    /// CoreBluetooth's cache rather than the radio's current state. Nothing here decodes the answer —
    /// the reference documents a 19-byte body but marks field validation incomplete, and a decoder
    /// built on an unverified layout would report a plausible name it had guessed at. The raw reply
    /// goes to `Documents/capture.txt` and that is read before any field is claimed.
    public func requestAdvertisingName() -> Bool {
        guard let profile = currentProfile,
              let frame = WhoopCommandFrames.getAdvertisingName(
                profile: profile, seq: commandSequence.next())
        else { return false }
        let handedToTheLink = sendConfirmedCommand(frame)
        CaptureLog.shared.append(
            "ADVERTISING_NAME_READ_REQUESTED generation=\(profile.generation.rawValue) sent=\(handedToTheLink)")
        return handedToTheLink
    }

    /// Sends `0x9A TOGGLE_PERSISTENT_R21`, and reports only whether the write reached the link.
    ///
    /// **It does not report that recording is on, and no caller may say so.** The strap acknowledges
    /// the write and does not confirm the programming; only a later drain can. `false` means nothing
    /// was written — not a 5.0/MG, no command path, or the characteristic refused a confirmed write —
    /// and that is *unknown*, not *off*.
    ///
    /// **Deliberately not part of any connect sequence.** It is reachable only from the device page's
    /// ADVANCED tab, behind a confirmation that names the battery cost. See
    /// `WhoopCommandFrames.persistentR21` for the opcode's caveats and `docs/TODO.md` §7.2 for the
    /// experiment this exists for.
    public func setPersistentRecording(_ enabled: Bool) -> Bool {
        guard let profile = currentProfile,
              profile.generation == .whoop5 || profile.generation == .whoop5MG,
              profile.canTransmitCommands,
              let frame = WhoopCommandFrames.persistentR21(
                profile: profile, seq: commandSequence.next(), enabled: enabled)
        else {
            AppLogger.ble.warning("""
                Refused PERSISTENT_R21 (0x9A): the connected strap is not a command-capable 5.0/MG.
                """)
            return false
        }

        let handedToTheLink = sendConfirmedCommand(frame)
        AppLogger.ble.notice("""
            Sent TOGGLE_PERSISTENT_R21 (0x9A) state=\(enabled ? 1 : 0, privacy: .public) — the ACK does \
            not confirm programming; verify with a drain.
            """)
        Diagnostics.record("persistent_r21_requested", ["state": enabled ? "on" : "off"])
        return handedToTheLink
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

        // **The 5.0/MG's clock goes first, before anything is armed.** noop sends SET_CLOCK then
        // GET_CLOCK as the opening pair of its connect sequence and records why: an un-clocked 5.0
        // does not bank sensor data to flash at all, so an offload completes with zero body frames.
        // That is the empty-drain failure this app has been chasing, and it is a *connect-time*
        // problem rather than a drain-time one — a strap that never banked anything has nothing to
        // send later. A 4.0 keeps its clock set at the drain, where both of its firmware-specific
        // forms are already sent; this branch is the CRC16 envelope only.
        if profile.headerChecksum == .crc16ModbusOverHeader {
            // **Confirmed writes, and that is the change.** A clock set sent `.withoutResponse` is
            // acknowledged by CoreBluetooth but gives the strap no reason to answer it, and the
            // measured state of this strap is a clock **not latching**: `GET_CLOCK` reports
            // `2024-05-06 05:56 UTC` against a phone at 2026-10-20, across reconnects. Sending it
            // confirmed puts the strap's own verdict in `didWriteValueFor`, where `sendCommand`'s
            // unconfirmed form leaves it silent.
            let epoch = UInt32(Date().timeIntervalSince1970)
            AppLogger.ble.notice("""
                SET_CLOCK: sending epoch \(epoch, privacy: .public) \
                (\(Date(timeIntervalSince1970: TimeInterval(epoch)).description, privacy: .public))
                """)
            for frame in WhoopCommandFrames.setClockFrames(
                profile: profile, seq: sequence.next(), epochSeconds: epoch) {
                if !sendConfirmedCommand(frame) {
                    AppLogger.ble.warning("SET_CLOCK could not be written confirmed on this link")
                }
            }
            if let readBack = WhoopCommandFrames.clockReadBack(
                profile: profile, seq: sequence.next()) {
                sendConfirmedCommand(readBack)
            }
        }

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

        // The 5.0/MG's live heart rate. That generation has no live-telemetry opcode — the 4.0's
        // `0x05` above — so without this arm a bonded 5.0 links, streams motion and notifies nothing
        // heart-rate-shaped at all: `0x03 TOGGLE_REALTIME_HR` with a `[0x01]` body is what makes it
        // send packet 40, and `HeartRatePayloadDecoder.decodeLive` is what reads it. This is reached
        // only on a bonded link for a 5.0 (the hello acknowledgement) and unconditionally on a 4.0,
        // where the dispatcher answers `nil` — a 4.0's live heart rate is the standard `0x2A37`
        // characteristic, subscribed at discovery.
        let armedRealtime = WhoopCommandFrames.realtimeHeartRate(
            profile: profile, seq: sequence.next())
        if let frame = armedRealtime {
            sendCommand(frame)
        }

        // The keep-alive's clock starts here, and only here. A re-send is worth attempting once these
        // bytes have actually gone out on this link; a 5.0/MG whose handshake was never acknowledged
        // never reaches this line, which is exactly what stops the watchdog writing pre-bond.
        hasSentConnectCommands = true
        lastActivationSentAt = Date()

        // **After the flag, deliberately.** On a 5.0/MG this function runs on the hello
        // acknowledgement, so this is the first moment a DIS read can succeed; a read issued before
        // the bond is refused. It also has to run *after* the flag rather than before it, because the
        // characteristics may already have been discovered and this is the only call that will ever
        // be made for them — see `requestDeviceInformationReadIfPossible`.
        requestDeviceInformationReadIfPossible()

        // The connect pass's own receipt, at a level an archive keeps. Whether `0x03` was built is
        // the difference between "the strap was asked for a pulse and did not send one" and "nothing
        // ever asked" — the two states a live-HR-less screen cannot tell apart.
        AppLogger.ble.notice("""
            Connect pass sent under \(profile.generation.rawValue, privacy: .public): \
            motion enable \(WhoopCommandFrames.motionEnableSequence(profile: profile, seq: 0, enable: true).count) \
            frame(s), realtime HR arm \(armedRealtime == nil ? "not built for this envelope" : "sent", privacy: .public).
            """)
        // The same receipt, in the shape a remote sink can carry. **The arm's presence rather than
        // the heart rate** — see `DiagnosticsEvent` for the metadata rule.
        Diagnostics.record("connect_pass", [
            "generation": profile.generation.rawValue,
            "motionFrames": "\(WhoopCommandFrames.motionEnableSequence(profile: profile, seq: 0, enable: true).count)",
            "realtimeArm": armedRealtime == nil ? "not-built" : "sent"
        ])
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
            Diagnostics.record("drain_refused", ["reason": "no-command-path"])
            return nil
        }
        guard let request = WhoopCommandFrames.historicalSyncRequest(
            profile: profile, seq: sequence.next()) else {
            AppLogger.ble.warning("Refused to start a historical drain: the request builder returned no frame")
            Diagnostics.record("drain_refused", ["reason": "no-request-frame"])
            return nil
        }

        // **Ask what the strap holds before touching the cursor.** Every drain on 2026-10-20/21 came
        // back with ~58 records in one batch — about a minute, roughly the time since connect — which
        // is what reading from the live edge looks like. The obvious fix is `0x21 SET_READ_POINTER`
        // with a zero offset, and `WhoopCommandFrames.rewindReadPointer` builds it and §16 pins it…
        // **but this app records that opcode as never sent**, because a reference groups it with forced
        // trim as one that mutates history ownership. That is not a write to make blind against a strap
        // holding the only copy of a night.
        //
        // `0x22 GET_DATA_RANGE` is the read-only question that decides whether a seek is even needed:
        // if the range says the strap holds a minute, there is no backlog and the seek is irrelevant;
        // if it says hours, the seek is the next step and worth doing deliberately. The reply is logged
        // raw by `logClockReplyCandidate`'s first-response arm rather than parsed — its layout is
        // undocumented, which is the same position `GET_CLOCK` was in.
        if let range = WhoopCommandFrames.dataRangeRequest(profile: profile, seq: sequence.next()) {
            sendConfirmedCommand(range)
            AppLogger.ble.notice("Drain: asked GET_DATA_RANGE for the backlog window before requesting")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // A second drain concludes the first rather than overwriting it. `drainSession` is a single
        // slot, so replacing it without resuming the continuation it was waiting on would leave that
        // caller suspended forever — the leak this whole arrangement exists to avoid.
        //
        // **The historical streams are left open**, because this call is about to install a drain the
        // caller has just subscribed to: finishing them here would end the new subscription before a
        // single record arrived. The previous drain's consumer learns of the supersession from its
        // own resumed continuation and cancels itself.
        concludeDrain(reason: .aborted, finishHistoricalStreams: false)

        let session = HistoricalDrainSession(profile: profile, startedAt: Date())
        Diagnostics.record("drain_started", ["generation": profile.generation.rawValue])

        return await withCheckedContinuation { (continuation: CheckedContinuation<HistoricalDrainSession?, Never>) in
            drainLock.lock()
            drainSession = session
            drainCompletion = continuation
            spo2Probe.reset()
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
            // The read-back, on both generations. Issuing it is not checking it — the reply's layout
            // is undocumented on either envelope and nothing here decodes it; what this buys is that
            // the reply reaches the frame loop, where it is logged raw. See `clockReadBack`.
            if let readBack = WhoopCommandFrames.clockReadBack(
                profile: profile, seq: sequence.next()) {
                sendCommand(readBack)
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
        // The oxygen candidate is read under the same lock as the session: both are per-drain state,
        // and a line the accumulator decided to dump must be paired with the counters that produced
        // it. Only the first few in-band records of a drain return a line; the accounting covers
        // every record and is emitted once by `concludeDrain`.
        var spo2Line: String?
        if let observation = Spo2CandidateProbe.decode(frame: frame) {
            spo2Line = spo2Probe.observe(observation)
        }
        drainLock.unlock()

        // The first record of the first drain on this link, one-shot. The summary `concludeDrain`
        // emits counts the records but says nothing about their *shape*, and "the strap sent 400
        // records" and "the strap sent 400 records of a type nothing decodes" look identical
        // everywhere else. Recorded outside the lock because it touches no drain state.
        if !hasReportedHistoricalRecord {
            hasReportedHistoricalRecord = true
            Diagnostics.record("historical_record", [
                "type": String(format: "0x%02X", frame.type),
                "seq": "\(frame.seq)",
                "cmd": String(format: "0x%02X", frame.cmd),
                "payloadBytes": "\(frame.payload.count)"
            ])
        }

        if let spo2Line { recordSpo2ProbeLine(spo2Line) }

        // **The record's heart rate and R-R intervals are what the drain exists for, and until this
        // call they were counted and discarded.** Decoding happens here rather than in
        // `didUpdateValueFor` because the drain gate above is what says this frame is history: a
        // packet-40 live frame is not a record any session is walking, and the decoder's own layout
        // and clock checks refuse everything that is not R18. The sample carries the strap's stored
        // timestamp, so it is yielded on the historical stream and never the live one.
        if let sample = HeartRatePayloadDecoder.decodeHistorical(frame: frame) {
            yieldHistoricalTelemetry(sample)
        }

        // **The strap's own pedometer, decoded for the same reason and from the same record.** R18 is
        // historical-only, so this is the one place a counter sample can arrive; the decoder refuses
        // anything that is not an exact 109-byte R18 under this generation's envelope and refuses a
        // stamp before 2020, and `TrackStepsUseCase` decides what the delta is worth. The one-shot
        // line is what a sideloaded run reads to prove the offsets before trusting them.
        if let counter = StepCounterPayloadDecoder.decode(frame: frame) {
            if !hasReportedStepCounter {
                hasReportedStepCounter = true
                AppLogger.ble.notice("""
                    Step counter: value=\(counter.counter, privacy: .public) \
                    class=\(counter.activityClass.map(String.init) ?? "none", privacy: .public) \
                    source=\(counter.counterIsSoftware ? "software" : "hardware", privacy: .public) \
                    at \(counter.timestamp.description, privacy: .public)
                    """)
                Diagnostics.record("step_counter", [
                    "counter": "\(counter.counter)",
                    "activityClass": counter.activityClass.map(String.init) ?? "none",
                    "source": counter.counterIsSoftware ? "software" : "hardware",
                    "timestamp": ISO8601DateFormatter().string(from: counter.timestamp)
                ])
            }
            yieldStepCounter(counter)
        }

        switch action {
        case .none:
            break

        case .acknowledge(let token):
            if let profile = currentProfile,
               let ack = WhoopCommandFrames.historicalDataAck(
                   profile: profile, seq: sequence.next(), token: token) {
                sendReliableCommand(ack)
            }

        case .acknowledgeAndFinish(let token):
            // The live edge: ack the batch that just ended, then stop. The ACK is still owed — the
            // strap's cursor does not move without it — so it is sent before the session concludes.
            if let profile = currentProfile,
               let ack = WhoopCommandFrames.historicalDataAck(
                   profile: profile, seq: sequence.next(), token: token) {
                sendReliableCommand(ack)
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

    /// Applies a decoded strap event, logging every one and acting only on the four state events.
    ///
    /// **The battery event is logged and not decoded.** noop's event schema carries the event number
    /// and its timestamp and nothing else, so there is no published level byte to read; `0x2A19`
    /// remains this app's only battery source. A capture that shows the event's body is what would
    /// change that, which is why the full payload is in the log line.
    private func handleStrapEvent(_ event: StrapEvent) {
        let stamp = event.timestamp.map { ISO8601DateFormatter().string(from: $0) } ?? "no timestamp"
        AppLogger.ble.notice("""
            Strap event \(event.rawEvent) \(String(describing: event.kind), privacy: .public) at \
            \(stamp, privacy: .public) payload=\(self.hexPreview(event.payload), privacy: .public)
            """)
        // The event number, the state it named and how much payload it carried — not the payload.
        // `RTC_LOST` is the one worth seeing remotely: it is what files history onto a wrong day.
        Diagnostics.record("strap_event", [
            "event": "\(event.rawEvent)",
            "kind": String(describing: event.kind),
            "hasTimestamp": event.timestamp == nil ? "false" : "true",
            "payloadBytes": "\(event.payload.count)"
        ])

        switch event.kind {
        case .chargingOn:
            updateDeviceState { $0.updating(isCharging: true) }
        case .chargingOff:
            updateDeviceState { $0.updating(isCharging: false) }
        case .wristOn:
            updateDeviceState { $0.updating(isOnBody: true) }
        case .wristOff:
            updateDeviceState { $0.updating(isOnBody: false) }
        case .rtcLost:
            // The one event with a consequence beyond the device page: every record the strap stamps
            // from here cannot be filed onto a day until the clock is set again, and the next drain's
            // SET_CLOCK is what repairs it. Recorded at `.warning` because it is the failure that files
            // history onto a wrong day rather than onto no day.
            AppLogger.ble.warning("""
                Strap reported RTC_LOST at \(stamp, privacy: .public): drained records cannot be \
                trusted to a day until the next clock set.
                """)
        case .batteryLevel, .boot, .setRTC, .other:
            break
        }
    }

    /// The strap's own backlog report, to `os.log`, `capture.txt` and the diagnostics sink.
    ///
    /// **This is the line that answers "two days or fourteen".** Event 29 carries a page backlog and
    /// an hours figure, so the streak a 14-day wear used to be needed for is readable on any connect.
    /// It stays a log line: the body is a reported layout and this app does not draw an unconfirmed
    /// figure, which is also why the charge percentage here is not fed to the battery badge.
    private func logStrapCondition(_ report: StrapConditionReport) {
        let line = "STRAP_CONDITION backlog_pages=\(report.pageBacklog) "
            + "backlog_hours=\(String(format: "%.1f", report.backlogHours)) "
            + "soc=\(String(format: "%.1f", report.batteryPercentage)) "
            + "flash=\(report.flashState) charging=\(report.isCharging) wrist=\(report.wristState)"
        AppLogger.ble.notice("\(line, privacy: .public) (reported layout, unconfirmed)")
        CaptureLog.shared.append(line)
        Diagnostics.record("strap_condition", [
            "pageBacklog": "\(report.pageBacklog)",
            "backlogHours": String(format: "%.1f", report.backlogHours),
            "soc": String(format: "%.1f", report.batteryPercentage),
            "charging": report.isCharging ? "true" : "false",
            "wrist": "\(report.wristState)"
        ])
    }

    /// Logs a command-response frame raw, so the GET_CLOCK reply is in the archive.
    ///
    /// **Bounded on purpose.** The first `commandResponse` frame on a link is logged, and after that
    /// only a response whose `cmd` is the clock pair — a drain can otherwise produce a response per
    /// batch, and a per-frame log is a log an archive drops. Nothing here is decoded: the reply's
    /// layout is undocumented on both generations and no code claims the clock latched.
    private func logClockReplyCandidate(_ frame: WhoopRawFrame, profile: WhoopProtocolProfile) {
        let isClockReply = frame.cmd == profile.commandOpcodes?.setClock
            || frame.cmd == profile.commandOpcodes?.getClock
            || frame.cmd == profile.syncOpcodes?.setClock
            || frame.cmd == profile.syncOpcodes?.getClock
            || frame.cmd == profile.commandOpcodes?.getDataRange
            || frame.cmd == profile.syncOpcodes?.getDataRange
            // The advertising-name pair, on both generations. A reply to these is the only place the
            // strap states what it has stored — the advertisement a phone prints may be its cache.
            || Self.advertisingNameCommands.contains(frame.cmd)
        let isFirstResponse = frame.type == profile.packetTypes.commandResponse && !hasLoggedCommandResponse

        guard isClockReply || isFirstResponse else { return }
        if isFirstResponse { hasLoggedCommandResponse = true }

        // A plain string first, then one logger call: the `privacy:` annotations only exist inside a
        // Logger's interpolation, not in a `String` literal built before it.
        let rawResponse = "Command response (raw, not decoded): "
            + "type=0x\(String(frame.type, radix: 16, uppercase: true)) "
            + "seq=\(frame.seq) cmd=0x\(String(frame.cmd, radix: 16, uppercase: true)) "
            + "payload=\(self.hexPreview(frame.payload))"
        AppLogger.ble.notice("\(rawResponse, privacy: .public)")
        // The same line into `Documents/capture.txt`, on the drain's terms: a rename's result is read
        // minutes later, and `/usr/bin/log`'s device archive is two to four minutes deep.
        CaptureLog.shared.append("COMMAND_RESPONSE cmd=0x\(String(frame.cmd, radix: 16, uppercase: true)) payload=\(self.hexPreview(frame.payload))")

        // **The advertising name is the second reply worth decoding**, and unlike the data range it
        // has a consumer: the device page prints the strap's stored name rather than the advertisement
        // a phone may be caching. `AdvertisingNamePayload` tolerates the envelope's leading length
        // byte; a reply that does not fit its shape is left alone rather than guessed at.
        if frame.cmd == 0x8D || frame.cmd == 0x4C,
           let stored = AdvertisingNamePayload.decode(payload: frame.payload) {
            CaptureLog.shared.append(
                "ADVERTISING_NAME_READ stored=\(stored.value) source=\(stored.source.rawValue)")
            if stored.source == .custom {
                updateDeviceState { $0.updating(advertisingName: stored.value) }
            }
        }

        // **The one reply worth decoding is the data range, and only for the log.** Its write page
        // answers whether the strap is storing history at all: two drains either side of a wear with
        // the same write page is evidence that nothing was written, which no amount of draining can
        // fix. The layout is reported and unconfirmed on 5.0/MG, so this changes no behaviour — see
        // `WhoopDataRange`.
        if frame.cmd == profile.commandOpcodes?.getDataRange
            || frame.cmd == profile.syncOpcodes?.getDataRange,
            let range = WhoopDataRange.decode(payload: frame.payload)
        {
            AppLogger.ble.notice("""
                Data range: read=\(range.readPage, privacy: .public) \
                write=\(range.writePage, privacy: .public) \
                acked=\(range.acknowledgedPage, privacy: .public) \
                capacity=\(range.capacity, privacy: .public) \
                backlog=\(range.backlog, privacy: .public) (reported layout, unconfirmed)
                """)
        }

        // **The clock is deliberately not decoded from this reply.** A best-effort read of it was
        // tried and removed: the `GET_CLOCK` payload is undocumented, and once the RTC was actually
        // correct the same decode still produced `2046-03-31` — a number that contradicts the one
        // clock reading this app *can* verify (`noteStrapClock`'s motion-record field, which read a
        // 0.0 h drift at the same moment). A log line that reports a wrong answer is worse than no
        // line: it is exactly the "plausible number out of the wrong offset" failure this file
        // documents elsewhere. The raw payload above stays for a capture to settle.
        // Bounded the same way the log line is — this is the path a per-batch response would flood.
        // The payload is a length here, not its bytes: what a remote reader needs is *that* a clock
        // answer arrived and from which opcode, and the raw body stays in the local archive.
        Diagnostics.record("command_response", [
            "type": String(format: "0x%02X", frame.type),
            "seq": "\(frame.seq)",
            "cmd": String(format: "0x%02X", frame.cmd),
            "payloadBytes": "\(frame.payload.count)"
        ])
    }

    /// The first 64 payload bytes as uppercase hex — enough for a DIS or event body, bounded so a
    /// drained 1,229-byte motion record cannot flood a log line.
    private func hexPreview(_ data: Data) -> String {
        let prefix = data.prefix(64)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > prefix.count ? "\(hex) … (\(data.count) bytes)" : hex
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
    private func concludeDrain(
        reason: HistoricalDrainSession.FinishReason,
        finishHistoricalStreams: Bool = true
    ) {
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
        // The one summary per drain: the boundary is the session's, because the accumulator's counters
        // describe exactly the frames `accept` saw. Reset here rather than at the next install so a
        // drain that ends without a successor does not leave its counts to be printed by the next one.
        let spo2Summary = spo2Probe.summary()
        spo2Probe.reset()
        drainLock.unlock()

        if let spo2Summary { recordSpo2ProbeLine(spo2Summary) }

        // The drain's outcome, in counts and a reason name. This is the line a remote reader uses to
        // tell "the strap sent nothing" from "the strap sent records this build could not decode",
        // and it is why the event carries `records` even when it is zero.
        Diagnostics.record("drain_concluded", [
            "records": "\(finished.recordCount)",
            "batches": "\(finished.batchCount)",
            "reason": finished.finishReason.map { String(describing: $0) } ?? "none"
        ])
        // The persistent copy, on `recordSpo2ProbeLine`'s terms: the log's archive is minutes deep and
        // a drain is read when the phone comes back, so the outcome that outlives the session belongs
        // in `Documents/capture.txt` beside the batches rather than only in `os.log`.
        // **The line that has to survive a rotation.** A night's drain is hundreds of one-minute
        // bursts, and the per-batch lines are the ones a 64 KB cap can take; this one carries the
        // facts a morning reader needs — when the drain started, how far back its records reach, how
        // many batches re-sent a stretch, and the cursor it finished on.
        CaptureLog.shared.append(
            "DRAIN_END started=\(finished.startedAt.ISO8601Format()) "
                + "records=\(finished.recordCount) batches=\(finished.batchCount) "
                + "oldest=\(finished.lowestRecordTimestamp?.ISO8601Format() ?? "-") "
                + "newest=\(finished.highestRecordTimestamp?.ISO8601Format() ?? "-") "
                + "repeats=\(finished.repeatedStartBatchCount) "
                + "trim=\(finished.lastTrimCursor?.trimPage.description ?? "-") "
                + "reason=\(finished.finishReason.map { String(describing: $0) } ?? "none")")

        watchdog?.cancel()
        continuation?.resume(returning: finished)

        // After the session has been resumed, so a consumer awaiting the drain is already unblocked
        // when its record stream ends. `finish()` delivers buffered samples before ending, which is
        // why the final batch is not lost — see `finishHistoricalTelemetry`.
        if finishHistoricalStreams { finishHistoricalTelemetry() }
    }

    /// Records one oxygen-candidate line where a capture can read it.
    ///
    /// **`.notice`, not `.info`, and the file as well as the log.** `os.log`'s `.debug` and `.info` go to
    /// a memory buffer and never reach disk, so a probe at those levels can be gone by the time the
    /// phone is picked up; `docs/TODO.md` §5 records that as the reason a capture log exists at all.
    /// The line is a raw byte and its neighbours, labelled `spo2probe`, and it is evidence rather than
    /// a reading — nothing here writes a percentage to a row, a sample or a screen.
    private func recordSpo2ProbeLine(_ line: String) {
        AppLogger.ble.notice("\(line, privacy: .public)")
        CaptureLog.spo2Probe.append(line)
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
        hasLoggedLiveHeartRate = false
        // Characteristics belong to one connection — the ones discovered on the previous link must
        // not be written on the next one, and `setNotifyValue` on a stale `CBCharacteristic` fails
        // silently. The pending list is the bond-deferred subscriptions (see
        // `didDiscoverCharacteristicsFor`), and a new link re-discovers them from scratch.
        commandCharacteristic = nil
        pendingNotifyCharacteristics.removeAll()
        hasLoggedHeartRateFrames = false
        hasLoggedProprietaryFrame = false
        hasLoggedCommandResponse = false
        hasReportedHistoricalRecord = false
        hasReportedStepCounter = false
        deviceInformationCharacteristics.removeAll()
        hasRequestedDeviceInformationRead = false
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
        // The oxygen candidate's counters describe one drain on one link. A link that went away mid-
        // drain never reaches `concludeDrain` for its counts to be printed, so reset here as well —
        // under the lock, because `routeToDrain` mutates the accumulator from the BLE queue.
        drainLock.lock()
        spo2Probe.reset()
        drainLock.unlock()
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

    /// A `WhoopDevice` built from scratch, replacing the current one.
    private func updateDeviceState(_ transform: () -> WhoopDevice) {
        applyDeviceState(transform())
    }

    /// The current device with some fields changed — the shape a reading takes.
    ///
    /// **The alternative is the loss this overload exists to prevent.** A notification that carries one
    /// field (battery, charging state, a DIS string) rebuilt the entity from scratch and silently reset
    /// everything it did not mention: firmware and serial fell back to their defaults, RSSI to `nil`,
    /// last-sync to `nil`. A notification that arrives after a read therefore erased the read, and the
    /// screen showed the loss as "not read yet". `WhoopDevice.updating` keeps every unnamed field.
    private func updateDeviceState(_ transform: (WhoopDevice) -> WhoopDevice) {
        guard let current = currentDeviceState else { return }
        applyDeviceState(transform(current))
    }

    /// Moves the device to `.disconnected` when the link ended without a callback that would have.
    ///
    /// **The peripheral is deliberately kept.** `connectedPeripheral` is what the powered-on branch
    /// re-arms from, and a `CBPeripheral` reference survives a radio cycle; what changes here is only
    /// the state the two screens draw. A strap whose radio went off is not linked, so the dot goes
    /// yellow and the battery figure — which `batteryReading` admits only for `.connected` — is
    /// withheld rather than left at whatever it last read.
    private func markLinkLost() {
        guard let current = currentDeviceState, current.connectionState != .disconnected else { return }
        applyDeviceState(current.updating(connectionState: .disconnected))
    }

    private func applyDeviceState(_ updated: WhoopDevice) {
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
            // **The radio going away is the link ending, and CoreBluetooth does not promise a
            // `didDisconnectPeripheral` for it.** Measured on 2026-10-24 with Airplane Mode on: the
            // device page read "Connected" and Home's badge kept a green dot beside the last battery
            // figure, because nothing had moved `currentDeviceState` — there is no peripheral to
            // disconnect when the central itself is off. `.resetting` is excluded because it is
            // transient; the manager settles on `.poweredOn` or one of the three below.
            if central.state == .poweredOff || central.state == .unauthorized
                || central.state == .unsupported {
                // A drain cannot outlive its radio either, and its caller must not stay suspended.
                concludeDrain(reason: .aborted)
                markLinkLost()
            }
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
            // **A link iOS still holds after a radio cycle is not a link this app can use.**
            // `didDisconnectPeripheral` is never delivered for a power-off, so the per-link flags
            // survived: `hasSentConnectCommands` still said the handshake had run, so discovery would
            // skip it — no `SET_CLOCK`, no `GET_DATA_RANGE`, no history request, no battery read —
            // and the strap would look connected while nothing worked. That is noop's #2787, reported
            // there with a Mac asleep overnight and `didBond` still true on wake; the same shape was
            // measured here on 2026-10-24 as a reconnect that drained nothing.
            //
            // So the state is reset and the services are re-discovered rather than the keep-alive
            // being restarted over stale flags. Re-discovery re-runs `didDiscoverCharacteristicsFor`,
            // which is what re-sends the connect pass.
            guard peripheral.state == .connected else {
                // Bluetooth was cycled, or a connect was refused while it was off. Either way the
                // pending connection is gone, and only a new one gets the strap back.
                issueStandingConnect(for: peripheral, after: .failedToConnect)
                return
            }
            prepareForNewLink()
            AppLogger.ble.notice("""
                Radio returned with the strap still attached — per-link state reset and services \
                re-discovered so the connect pass runs again.
                """)
            peripheral.discoverServices(nil)
            beginKeepAliveWindow()
            return
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
        // The advertisement may already carry the generation, and when it does the device is
        // described correctly from the first frame rather than after service discovery. GATT is still
        // asked below and remains authoritative; this only moves the answer earlier.
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertisedServices.contains(WhoopGATTConstants.whoop5ServiceUUID) {
            strapModelLock.lock()
            serviceObservedGenerations[peripheral.identifier.uuidString] = .whoop5
            strapModelLock.unlock()
        }

        let devName = peripheral.name ?? "WHOOP Strap"
        let gen = resolveGeneration(advertisedName: devName, deviceId: peripheral.identifier.uuidString)
        AppLogger.ble.notice("""
            Discovered \(devName, privacy: .public) [\(peripheral.identifier.uuidString, privacy: .public)] \
            RSSI \(RSSI.intValue, privacy: .public), resolved as \(gen.rawValue, privacy: .public), \
            advertised services \(advertisedServices.map(\.uuidString).joined(separator: ", "), privacy: .public)
            """)
        self.connectedPeripheral = peripheral
        peripheral.delegate = self

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

        // **The service list is the generation's proof, and it arrives before any characteristic.**
        // The advertised name is not: it is whatever the owner renamed the strap to, and this is the
        // one place the strap's actual GATT surface can correct it — early enough that the command
        // characteristic discovered below is framed under the right envelope the first time.
        if services.contains(where: { $0.uuid == WhoopGATTConstants.whoop5ServiceUUID }) {
            adoptWhoop5FromDiscoveredService(for: peripheral)
        }

        let inventory = services.map(\.uuid.uuidString).joined(separator: ", ")
        AppLogger.ble.notice("""
            Discovered service(s) on \(peripheral.name ?? "Strap", privacy: .public): \
            \(inventory, privacy: .public)
            """)

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        // Once per service per connection, and the only evidence this app will ever have about which
        // GATT surface a given strap generation actually exposes. `didDiscoverCharacteristicsFor`
        // fires once for each service `didDiscoverServices` asked about, so this is not a per-
        // notification branch and needs no one-shot flag — the earlier single flag logged whichever
        // service happened to answer first, which was usually the standard HR service and said
        // nothing about the proprietary one this app's whole data path depends on.
        //
        // `.notice` rather than `.info`: `.info` is memory-only and absent from a log archive, which
        // is exactly the artifact this line exists to be read from after a strap has been tested.
        let uuids = characteristics.map { "\($0.uuid)[\(Self.describe($0.properties))]" }
        let hasHeartRate = characteristics.contains {
            $0.uuid == WhoopGATTConstants.heartRateMeasurementCharacteristicUUID
        }
        AppLogger.ble.notice("""
            GATT \(service.uuid, privacy: .public): \(uuids.joined(separator: ", "), privacy: .public). \
            0x2A37 present: \(hasHeartRate)
            """)

        for char in characteristics {
            // Kept so the keep-alive tick can ask for a fresh reading. It is also subscribed below if
            // it notifies — the two are independent, and a strap that only notifies still updates
            // the screen while a strap that only reads is still readable.
            if char.uuid == WhoopGATTConstants.batteryLevelCharacteristicUUID {
                self.batteryCharacteristic = char
            }

            // The Device Information Service's values are reads, not notifications, so discovery's
            // only job is to remember the characteristic object the read needs. `nil` from
            // `DeviceInformationField` means a characteristic on 180A this build does not name.
            if service.uuid == WhoopGATTConstants.deviceInformationServiceUUID,
               DeviceInformationField(uuid: char.uuid) != nil {
                deviceInformationCharacteristics[char.uuid] = char
            }

            // **A 5.0/MG that also exposes the legacy service must never be sent a 4.0 frame.** The
            // two opcode tables are not interchangeable; `sendCommand`'s guard checks the profile but
            // cannot see which characteristic a frame is addressed to, and the 4.0 table contains
            // opcodes the 5.0 document does not name. When the strap's own service list has already
            // proven it is a 5.0, the 4.0 command characteristic is ignored and `FD4B0002` is the
            // only write target.
            let isWhoop5Command = char.uuid == WhoopGATTConstants.whoop5CommandUUID
            if isWhoop5Command || char.uuid == WhoopGATTConstants.whoop4CommandUUID {
                if char.uuid == WhoopGATTConstants.whoop4CommandUUID,
                   currentDeviceState?.hardwareGeneration == .whoop5
                    || currentDeviceState?.hardwareGeneration == .whoop5MG {
                    AppLogger.ble.notice("""
                        Ignoring the 4.0 command characteristic \(char.uuid, privacy: .public): this \
                        strap exposes the 5.0/MG service, so commands go to \
                        \(WhoopGATTConstants.whoop5CommandUUID, privacy: .public) instead.
                        """)
                    continue
                }
                self.commandCharacteristic = char

                // Last line of defence against addressing the 5.0 characteristic with the other
                // envelope: if discovery somehow reaches here without the generation correction
                // having taken effect, refuse rather than write 4.0 opcodes down `FD4B0002`.
                if isWhoop5Command, currentProfile?.headerChecksum != .crc16ModbusOverHeader {
                    AppLogger.ble.warning("""
                        Refusing to write to the 5.0/MG command characteristic under a non-CRC16 \
                        profile — the two opcode tables are not interchangeable.
                        """)
                    continue
                }

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
                    let outcome = isAwaitingBondHandshakeAck
                        ? "written with response; awaiting acknowledgement"
                        : "could not be written — no .write property"
                    AppLogger.ble.notice("""
                        5.0/MG: CLIENT_HELLO (\(hello.count) bytes) \(outcome, privacy: .public) on \
                        \(char.uuid, privacy: .public).
                        """)
                    if !isAwaitingBondHandshakeAck {
                        sendConnectCommands()
                        // No handshake is possible, so the acknowledgement that would normally
                        // release these will never arrive — attach them now rather than leave the
                        // strap with a live link and no notification path.
                        subscribePendingNotifications()
                    }
                } else {
                    AppLogger.ble.notice("""
                        Connect pass for \(self.currentProfile?.generation.rawValue ?? "unknown", privacy: .public) \
                        on \(char.uuid, privacy: .public) (no CRC16 hello for this envelope).
                        """)
                    sendConnectCommands()
                }
            }

            // **The 5.0/MG service's notifications wait for the bond.** A pre-bond subscription to
            // the puffin characteristics (`fd4b0003`/`0004`/`0005`/`0007`) is refused as
            // "Authentication is insufficient" and leaves the bond wedged — the failure that silenced
            // this generation's data path even when the hello itself was accepted. So discovery
            // retains them in `pendingNotifyCharacteristics` and `subscribePendingNotifications()`
            // attaches them from the acknowledgement (or from the no-`.write` fallback just above).
            //
            // **The condition is the service, not `isAwaitingBondHandshakeAck`**, because
            // characteristics arrive in an order CoreBluetooth does not promise: a notify
            // characteristic can be discovered before the command characteristic has even been
            // seen, so at that moment no hello has been sent and the flag is still false. The
            // standard HR and battery services are never deferred — they work unbonded and are this
            // app's only producer that already functioned. `.indicate` is subscribed alongside
            // `.notify`; CoreBluetooth services both through `setNotifyValue`, and the previous loop
            // ignored indications, which is what the puffin characteristics are.
            let isFiveService = service.uuid == WhoopGATTConstants.whoop5ServiceUUID
            let wantsNotifications = char.properties.contains(.notify)
                || char.properties.contains(.indicate)
            if isFiveService && !hasSentConnectCommands {
                if wantsNotifications {
                    pendingNotifyCharacteristics.append(char)
                }
            } else if wantsNotifications {
                peripheral.setNotifyValue(true, for: char)
            }
        }

        // DIS can be discovered before or after the proprietary service, so this is one of the two
        // triggers; the other is the end of `sendConnectCommands`. Whichever comes second issues the
        // read — and on a 5.0/MG the helper itself refuses until the connect pass has run, because a
        // pre-bond read is refused by the strap.
        if service.uuid == WhoopGATTConstants.deviceInformationServiceUUID {
            requestDeviceInformationReadIfPossible()
        }
    }

    /// Issues the one DIS read pass this link is allowed, or defers until the link can take it.
    ///
    /// **The ordering is the whole design.** DIS discovery and the proprietary service's discovery
    /// arrive in an order CoreBluetooth does not promise, and a 5.0/MG refuses reads before its bond
    /// completes — so this is called from both discovery and the end of `sendConnectCommands` (which
    /// only runs post-bond on a 5.0), and the checks here decide whether the moment is legal:
    ///
    /// - a CRC16 link that has not sent its connect pass is deferred rather than attempted;
    /// - at least one characteristic with `.read` must be present, or the flag stays unset and the
    ///   later trigger can still try;
    /// - once a read has actually been issued, the flag stops a re-read on every later callback.
    private func requestDeviceInformationReadIfPossible() {
        guard !hasRequestedDeviceInformationRead else { return }
        if currentProfile?.headerChecksum == .crc16ModbusOverHeader, !hasSentConnectCommands {
            return
        }
        guard let peripheral = connectedPeripheral else { return }

        var issued = false
        for uuid in WhoopGATTConstants.deviceInformationCharacteristicUUIDs {
            guard let char = deviceInformationCharacteristics[uuid],
                  char.properties.contains(.read) else { continue }
            peripheral.readValue(for: char)
            issued = true
        }
        if issued {
            hasRequestedDeviceInformationRead = true
            AppLogger.ble.notice("""
                Device Information Service read pass issued over \
                \(self.deviceInformationCharacteristics.count) characteristic(s) known.
                """)
        }
    }

    /// Applies one DIS value: firmware and serial reach `WhoopDevice`, the model resolves the strap's
    /// generation, and the other two are logged.
    ///
    /// **The model string is evidence rather than a display string**, and it is the strongest rung
    /// this app has: written by the strap, read from it, and able to tell a 5.0 from a 5.0 MG where the
    /// service list cannot. It resolves the generation and, when the user has never chosen one for this
    /// strap, is persisted so the next launch does not fall back to the advertised name. Hardware
    /// revision and manufacturer still have no home beyond the log — inventing a `WhoopDevice`
    /// property for either would put a value on the device page that nothing asked to show.
    private func handleDeviceInformation(_ uuid: CBUUID, data: Data) {
        guard let field = DeviceInformationField(uuid: uuid) else { return }
        guard let text = DeviceInformationPayload.text(from: data) else {
            AppLogger.ble.warning("""
                Device Information Service \(field.rawValue, privacy: .public) returned no readable \
                text (\(data.count) bytes).
                """)
            return
        }

        AppLogger.ble.notice("""
            Device Information Service \(field.rawValue, privacy: .public) = \(text, privacy: .public)
            """)

        switch field {
        case .firmware:
            updateDeviceState { $0.updating(firmwareVersion: text) }
        case .serial:
            updateDeviceState { $0.updating(serialNumber: text) }
        case .model:
            adoptObservedGeneration(modelNumber: text)
        case .hardwareRevision, .manufacturer:
            break
        }
    }

    /// Attaches the notifications discovery held back until the link was authorised.
    ///
    /// Called from exactly the two paths that mean proprietary traffic can flow: a successful hello
    /// acknowledgement, and the no-`.write` fallback where no handshake exists to wait for. The array
    /// is emptied as it is subscribed, so a later `didWriteValueFor` — which fires on every confirmed
    /// write, including the drain's ACKs — cannot re-subscribe anything.
    ///
    /// A strap that was never acknowledged keeps its characteristics here for the life of the link:
    /// the producers were not armed either, so there is nothing this app could do with a notification
    /// that the strap would refuse anyway.
    private func subscribePendingNotifications() {
        guard let peripheral = connectedPeripheral else {
            pendingNotifyCharacteristics.removeAll()
            return
        }
        let pending = pendingNotifyCharacteristics
        pendingNotifyCharacteristics.removeAll()
        for char in pending {
            peripheral.setNotifyValue(true, for: char)
        }
        if !pending.isEmpty {
            AppLogger.ble.notice("""
                Subscribed \(pending.count) proprietary notification(s) after the 5.0/MG link was \
                authorised.
                """)
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
        // The notification characteristics discovery deferred for the bond. Subscribed here rather
        // than at discovery for the reason stated in `didDiscoverCharacteristicsFor`: pre-bond they
        // are refused and wedge the bond.
        subscribePendingNotifications()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // **A DIS read's answer arrives here, and a refused one arrives with no value at all** — so the
        // error has to be read before the value guard, or the only diagnostic that says a strap refused
        // its own information service is silently dropped.
        if DeviceInformationField(uuid: characteristic.uuid) != nil {
            guard error == nil else {
                AppLogger.ble.warning("""
                    Device Information Service read failed: \(String(describing: error), privacy: .public)
                    """)
                return
            }
            guard let data = characteristic.value, !data.isEmpty else { return }
            noteLinkActivity()
            handleDeviceInformation(characteristic.uuid, data: data)
            return
        }

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
                    AppLogger.ble.notice("""
                        0x2A37 frame: flags=0x\(String(data[0], radix: 16, uppercase: true)) \
                        bytes=\(data.count) hr=\(hr) rrIntervals=\(rrs.count)
                        """)
                    // Metadata only — no bpm. The flags byte says whether the R-R field is present
                    // and how the value is encoded, and the count is what decides whether a night is
                    // reconstructible; the heart rate itself is a biometric and never leaves the phone
                    // through this path.
                    Diagnostics.record("standard_hr_frame", [
                        "flags": String(format: "0x%02X", data[0]),
                        "bytes": "\(data.count)",
                        "rrIntervals": "\(rrs.count)"
                    ])
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
            // **A copy, not a fresh device.** Constructing a `WhoopDevice` here applied every default,
            // so a battery notification erased the firmware and serial DIS had just reported, reset
            // RSSI to `-65` and cleared last-sync — a field loss invisible on this branch and visible
            // on the device page as values that stopped arriving.
            if let current = currentDeviceState {
                updateDeviceState { current.updating(batteryPercentage: battery) }
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
                AppLogger.ble.notice("""
                    Proprietary frame: type=0x\(String(frame.type, radix: 16, uppercase: true), privacy: .public) \
                    seq=\(frame.seq) cmd=0x\(String(frame.cmd, radix: 16, uppercase: true), privacy: .public) \
                    payload=\(frame.payload.count) bytes
                    """)
                Diagnostics.record("proprietary_frame", [
                    "type": String(format: "0x%02X", frame.type),
                    "seq": "\(frame.seq)",
                    "cmd": String(format: "0x%02X", frame.cmd),
                    "payloadBytes": "\(frame.payload.count)"
                ])
            }

            let now = Date()
            if let batch = MotionPayloadDecoder.decode(frame: frame, receivedAt: now) {
                noteStrapClock(batch.strapTimestamp, arrival: now)
                yieldMotion(batch)
            }

            // Packet 40, the 5.0/MG's live `REALTIME_DATA` — the record `0x03 TOGGLE_REALTIME_HR`
            // arms. It is decoded *before* the drain routing below because it is not and never will
            // be a historical record: the two producers share no layout, and `routeToDrain` yields
            // only what the drain's own session is walking. The arrival instant is its timestamp,
            // per the same convention as `0x2A37` above.
            if let sample = HeartRatePayloadDecoder.decodeLive(frame: frame, receivedAt: now) {
                if !hasLoggedLiveHeartRate {
                    hasLoggedLiveHeartRate = true
                    AppLogger.ble.notice("""
                        5.0/MG live heart rate: type=0x\(String(frame.type, radix: 16, uppercase: true), privacy: .public) \
                        bpm=\(sample.heartRate) rrIntervals=\(sample.rrIntervalsMs?.count ?? 0)
                        """)
                    // No bpm — the same metadata rule as the standard characteristic above.
                    Diagnostics.record("live_hr_frame", [
                        "type": String(format: "0x%02X", frame.type),
                        "rrIntervals": "\(sample.rrIntervalsMs?.count ?? 0)"
                    ])
                }
                yieldTelemetry(sample)
            }

            // Strap events — packet 48 on 5.0/MG, `0x30` on 4.0 — carry the wrist and charger state
            // `WhoopDevice` has fields for. Decoded here rather than in `routeToDrain` because they
            // arrive on a connected strap with no drain running, and that call returns immediately
            // when there is none.
            if let event = StrapEventDecoder.decode(frame: frame) {
                handleStrapEvent(event)
            }

            // **The strap volunteers how much history it is holding.** Event 29 carries a page backlog
            // and an hours figure, which is the difference between "two days" and "fourteen" answered
            // on every connect instead of by wearing the strap for a fortnight. Logged, never drawn:
            // the layout is reported and unconfirmed, and this app does not put an unconfirmed figure
            // on a screen.
            if let condition = StrapConditionReport.decode(frame) {
                logStrapCondition(condition)
            }

            // The 5.0/MG clock read-back's answer, captured raw. No offset is decoded from it — the
            // reference logs it and parses none of it either — so this exists so a sideloaded run has
            // both sides of the SET_CLOCK/GET_CLOCK pair in its archive.
            logClockReplyCandidate(frame, profile: profile)

            // The drain sees every frame, including the ones the motion decoder just consumed: a
            // banked type-47 record *is* an R21 batch, so the same frame is both a step contribution
            // and a batch the strap is waiting to have acknowledged. That is the whole reason the
            // shared core is shared, and it is why this call is not an `else`.
            routeToDrain(frame, now: now)
        }
    }
}
