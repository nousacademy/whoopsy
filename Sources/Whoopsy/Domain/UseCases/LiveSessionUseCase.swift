import Foundation
import Observation

/// A live activity session: the app's **only recording path**, and the app-lifetime holder that lets it
/// outlive its screen.
///
/// The user's requirement is what shapes the whole type:
///
/// > no bottom bar, so if user presses back [the] session will still be live recording strain and heart
/// > statistics, and if phone is closed, it will show a preview on lock screen while running with timer
///
/// So this is not a screen's view model. It is built once in `DIContainer`, held by
/// `MainContainerView`'s `HomeDashboardView` for the life of the process, and the screen that draws it
/// is free to come and go. `LiveSessionView` owns no `.onDisappear { end() }` — that absence is the
/// feature.
///
/// ## Why `@MainActor @Observable` and not an actor
///
/// It has to be **observed**: a screen draws `snapshot` as it changes. An `actor` can only be pulled,
/// and an `AsyncStream` taken from one is not a broadcast — a second consumer starves silently, which
/// is the exact failure `CLAUDE.md` records against the BLE streams. `HomeViewModel` already runs a
/// main-actor `for await` over the same telemetry stream this reads, and that is the precedent.
///
/// **This amends a documented invariant**: `CLAUDE.md` says `Domain/` imports only `Foundation`. It now
/// imports `Foundation` and `Observation`. The rule's purpose is that no GRDB, CoreBluetooth, SwiftUI or
/// HealthKit reaches the domain layer, and `Observation` is none of those — it is the macro that makes a
/// value observable, with no platform dependency. The alternative was an app-lifetime holder in
/// `Presentation/`, which has no precedent in this repo at all.
///
/// ## Why the controller is `nonisolated let`
///
/// `Activity` is not `Sendable`, so the card's handle needs an isolated home, which is why
/// `LiveActivityControlling` is `@MainActor`. A `@MainActor @Observable` class **cannot** initialise a
/// main-actor-isolated stored property from a `nonisolated init` — that was prototyped and it is a
/// compile error, not a warning — so the dependency is stored `nonisolated` and the protocol refines
/// `Sendable` to allow it. That is the only shape that lets `DIContainer` construct this, which is what
/// keeps the wiring rule ("`DIContainer` is the only place its use cases come from") unbroken.
@MainActor
@Observable
public final class LiveSessionUseCase {

    /// What `end()` produced, for the screen that called it.
    public struct Summary: Sendable, Equatable {
        /// The activity that was written, as Home's `ACTIVITIES` row will read it back.
        public let workout: WorkoutSession
        /// The session's calorie estimate — **`nil` when no body weight is on file**, and deliberately
        /// not part of `WorkoutSession`, which has no energy field. The live figure the user watched is
        /// therefore not persisted anywhere; adding a column for it is a separate change.
        public let calories: Double?
    }

    /// Whether a session is recording. The screen's `LIVE` badge reads this, and it is the guard that
    /// makes `start()` idempotent — `TrackStepsUseCase`'s pattern.
    public private(set) var isRunning = false
    public private(set) var startedAt: Date?

    /// What the picker chose for this session, and what `end()` writes to the row.
    ///
    /// **The fallback is WHOOP's own abstention word, and a name is not a measurement.** This app does
    /// not classify an activity, so the only name it can honestly give a session is the one the user
    /// picked — and when they were not asked, `WhoopActivityCatalog.abstentionName` is the word
    /// WHOOP's own classifier writes for the same case, on 197 rows of the bundled export. The row
    /// stores it rather than leaving a `NULL` for a screen to turn back into a label, which is what
    /// makes this app's session and the export's row the same shape.
    ///
    /// **It moves in lockstep with `isRunning`, and `reset()` is the only thing that clears it.** So a
    /// non-`nil` name here implies a session those two belong to; there is no state in which a stale
    /// name is waiting to be written onto somebody else's row. A `nil` name is therefore possible only
    /// on a payload that never started, and `end()`'s `??` covers that rather than a screen having to.
    public private(set) var activityName: String?

    /// Everything the session screen draws, or `nil` before the first sample of a session.
    ///
    /// It is `nil` rather than a zeroed snapshot so a screen cannot draw a `0.0` strain on a session
    /// that has measured nothing. Once it is non-`nil`, `snapshot.strain` is `nil` until a sample
    /// arrives and `0.0` only for a measured session that never reached zone 1 — see
    /// `LiveSessionAccumulator`.
    public private(set) var snapshot: LiveSessionAccumulator.Snapshot?

    /// Whether the lock-screen card is up. `false` when the platform has no Live Activity **or** when
    /// `Activity.request` was refused.
    public private(set) var isLiveActivityActive = false

    /// Why the card is not up, for a screen that wants to say so. `nil` when there is nothing to report.
    ///
    /// **A refused card is not a failed session.** Live Activities can be switched off per-app, the
    /// system caps how many an app may have, and a build without `NSSupportsLiveActivities` is refused
    /// outright — all properties of the device or the build, none a reason to stop recording. The
    /// catch sets this and the session runs on. That is the absence rule applied to a capability.
    public private(set) var liveActivityError: String?

    /// Whether this session is recording a GPS route. The screen's toggle reads this, and it is the
    /// guard that makes `setRouteRecording(true)` idempotent.
    ///
    /// **Off by default, and it is off for a reason.** Not every session is outdoors: a session in a
    /// living room would record a cloud of jitter around a sofa, and the app deliberately does not
    /// classify an activity, so it cannot decide this for the user. The toggle is the user's answer.
    public private(set) var isRecordingRoute = false

    /// Why no route is being recorded, for a screen that wants to say so. `nil` when there is nothing
    /// to report.
    ///
    /// **A refused permission is not a failed session.** Whether the phone will share its position has
    /// nothing to do with the strap, so this is set and the session runs on — the absence rule applied
    /// to a capability, exactly as `liveActivityError` above it is.
    ///
    /// Unlike that field, this carries **a whole sentence the app authorises rather than a system
    /// message**. A refused `Activity.request` arrives with a `localizedDescription` worth relaying, so
    /// `liveActivityError` passes one through and the screen writes the frame around it. CoreLocation
    /// gives no such string for a refused permission — the answer is an enum case — so the sentence has
    /// to be written here, next to the case that chose it, and the screen prints it as it stands.
    public private(set) var routeError: String?

    /// Whether the user has asked for an offline map of this session's area.
    ///
    /// **A switch the user throws before losing signal, and never a reaction to losing it.** The app
    /// cannot detect that the next ten miles have no coverage, and by the time it noticed it would be
    /// too late to download anything — the tiles have to arrive while there is still a network. So this
    /// is the user's own prediction about where they are going, which is the only source that
    /// information has. Off by default.
    ///
    /// **Independent of `isRecordingRoute`, and that is the user's own ruling rather than an
    /// implementation convenience.** Neither switch gates the other: the map is useful on a walk the
    /// user is navigating rather than measuring, and a route is worth recording by someone who never
    /// lost signal in their life. What the pair decides is the *card* — see ``RouteMapRenderer``.
    public private(set) var isOfflineMapRequested = false

    /// Whether this build has a map SDK behind the switch at all.
    ///
    /// **Read by the screen before the switch is offered**, so a build with no SDK draws it disabled and
    /// says why, rather than accepting a flip and quietly doing nothing. `false` on every host build, in
    /// the test runner, and in an iOS build whose package failed to resolve — see `OfflineMapState` for
    /// why the SDK cannot be named here. It is a fact about the build rather than about the session, so
    /// it is a plain read-through and not observable state.
    public var isOfflineMapSupported: Bool { offlineMaps.isSupported }

    /// What is on disk for this session's region. Read by the session screen to draw progress or a
    /// failure, and by nothing else — the route card's own gate is ``RouteMapRenderer/resolve(session:state:)``.
    ///
    /// `.absent` rather than `.unsupported` as the initial value, because this field says nothing about
    /// the build: `offlineMaps.isSupported` is the question about the build, and a screen must ask it
    /// before it draws a switch at all.
    public private(set) var offlineMapState: OfflineMapState = .absent

    /// Why no map is being downloaded, for a screen that wants to say so. `nil` when there is nothing
    /// to report.
    ///
    /// `routeError`'s shape and its reason: an **authored sentence** rather than a system message,
    /// because the failures that reach here are a refused permission and an absent position fix, and
    /// neither arrives with a string worth relaying. A refusal is not a reason to stop the session, so
    /// it is recorded and the session runs on.
    public private(set) var offlineMapError: String?

    /// The name of the tile region this session downloaded, or `nil` when it asked for none.
    ///
    /// **Minted when the switch goes on, not derived from the session, and that is forced rather than
    /// chosen.** `end()` builds its `WorkoutSession` without passing an `id`, so the `UUID` is minted by
    /// `WorkoutSession.init` at that moment — which means **a session has no id while it is recording**
    /// and the region cannot simply be named after the session it belongs to. See
    /// `v19_workout_offline_region` for the two alternatives and why both are worse.
    ///
    /// Cleared when the switch goes off, so this and `isOfflineMapRequested` cannot disagree: the row
    /// `end()` writes names a region **exactly when the user left the switch on**, which is what makes
    /// the independence table in ``RouteMapRenderer`` true of the stored row rather than only of the
    /// screen.
    public private(set) var offlineRegionID: String?

    /// The download, from finding a centre to the last tile.
    ///
    /// Held so the switch going off can abandon it, and **deliberately not cancelled by `end()`**. A
    /// download that outlives the session is the desired behaviour: the row already names the region,
    /// the tiles keep arriving, and the detail page — which is opened after the session ends — asks the
    /// store what it found and draws the offline card if the answer is `.ready`. Cancelling here would
    /// make the switch pointless for anyone who stops recording before the tiles land.
    private var offlineMapTask: Task<Void, Never>?

    /// Whether a fast is running, and which one.
    ///
    /// **An enum rather than a plain `ActiveFast?`, and it is the `@Observable` macro that decides
    /// that.** Every stored property here is rewritten into a computed one whose setter is an ordinary
    /// isolated mutation, and the macro's own backing store is what the initialiser would have to
    /// write. For an optional the compiler *also* implicitly initialises it to `nil`, which counts as
    /// an assignment — so `var activeFast: ActiveFast?` is main-actor state being mutated from the
    /// `nonisolated init` below and is refused outright, seeded-from-store or not. `case none` as a
    /// **declared default** is an initial value rather than an assignment, so it is legal there, and
    /// the store is read by `restoreFast()` instead.
    ///
    /// `@Observable` instruments this property like any other stored one, so a reader of `activeFast`
    /// below still registers the dependency and the bar still redraws when a fast starts or ends.
    private enum FastSlot: Sendable {
        case none
        case running(ActiveFast)
    }

    private var fastSlot: FastSlot = .none

    /// The fast running underneath this session, or `nil` when none is.
    ///
    /// **A second live state, and deliberately not a second `isRunning`.** A fast measures nothing —
    /// no strain, no heart rate, no zones, no steps — so it has no accumulator, no BLE consumer, no
    /// step consumer, no route and no lock-screen card. It has one instant and that is the whole of
    /// it, which is why it is a single optional value beside the activity's state rather than a
    /// parallel copy of it. `isRunning` stays the **activity's** flag; nothing about a fast moves it.
    ///
    /// **The two genuinely run at once, which is the point of the field.** Starting a run mid-fast
    /// neither ends the fast nor disturbs it, and `end()` does not touch it either — so when the run
    /// ends, the bar returns to a fast still counting from its original start. A fast writes exactly
    /// one row, when the user ends it, and that writer is `endFast()` rather than `end()`: `end()`'s
    /// four guards are the only thing between a mis-tapped toggle and a workout row, and a fast has no
    /// figures for them to test.
    ///
    /// **It is the one live session that survives a relaunch, and it is restored in `init`** — see
    /// `ActiveFastRepository` for why a run cannot be. A phone restarted on day two of a three-day
    /// fast finds it still running. No sweep may end one, either: `endOrphanedLiveActivities()` ends a
    /// stale lock-screen card because a card is system state with no tie to a process lifetime, and a
    /// fast that came back is a fast the user meant.
    ///
    /// Read-only from outside by construction: `fastSlot` above is `private`, so there is no setter
    /// here for a screen to reach.
    public var activeFast: ActiveFast? {
        guard case .running(let fast) = fastSlot else { return nil }
        return fast
    }

    /// The floor between live-activity pushes. See `shouldPush`.
    private static let minimumPushIntervalSeconds: TimeInterval = 1.0

    private var accumulator: LiveSessionAccumulator?
    private var consumer: Task<Void, Never>?
    private var lastPushedAt: Date?

    /// The fixes collected so far, in arrival order. Handed to `WorkoutSession` by `end()`.
    ///
    /// Kept on the use case rather than handed straight to the repository because a route is only
    /// written when the session ends, and because a session that is backed out of and returned to must
    /// find its route still accumulating — the same reason `snapshot` lives here.
    private var routePoints: [WorkoutRoutePoint] = []
    private var routeConsumer: Task<Void, Never>?

    /// The **session's own** step count, accumulated off the same motion stream `TrackStepsUseCase`
    /// reads for the day.
    ///
    /// `TrackStepsUseCase` cannot supply this: its accumulator is day-scoped and seeded from a stored
    /// day row, so the figure it holds at the end of a session is the whole day's, not the session's.
    /// Two independent `StepAccumulator`s over one multicast stream is the shape the registry exists
    /// for — `StepAccumulator` is a pure `Sendable` value with no globals, so the second instance
    /// cannot disturb the first. `TrackStepsUseCase` is registered on the stream once at launch from
    /// `MainContainerView`, and **this subscription is not a replacement for it**: the day's tile would
    /// stop moving if it were.
    ///
    /// **Never seeded and never written until `end()`.** A session has no stored baseline to resume
    /// from — the row does not exist yet — so this starts from zero every time, and a session the
    /// strap sent no motion during leaves it at `measuredSeconds == 0`, which `end()` turns into a
    /// `nil` step count rather than a `0`.
    private var stepAccumulator: StepAccumulator?
    private var stepConsumer: Task<Void, Never>?

    private nonisolated let controller: any LiveActivityControlling
    private nonisolated let locationTracking: any LocationTracking
    private nonisolated let streamBiometricsUseCase: StreamBiometricsUseCase
    private nonisolated let saveWorkoutUseCase: SaveWorkoutUseCase
    private nonisolated let userProfileRepository: any UserProfileRepository
    private nonisolated let bleRepository: any WhoopBLEDeviceRepository
    private nonisolated let activeFastRepository: any ActiveFastRepository

    /// The offline map. A capability seam like `locationTracking` above, and reached through
    /// `OfflineMapServing` for the same reason: the implementation is Mapbox, which this package cannot
    /// depend on at all. See that protocol.
    private nonisolated let offlineMaps: any OfflineMapServing

    /// **`activeFastRepository` is required rather than defaulted**, which is the one dependency here
    /// that is. A defaulted one would let a production path ship without it and silently lose the
    /// user's fast at the next launch — a failure with no symptom until someone restarts their phone
    /// on day two. The runner passes a spy, which is also what makes persistence assertable at all:
    /// "the fast came back after a relaunch" is otherwise a claim only a human with a phone can check.
    public nonisolated init(
        controller: any LiveActivityControlling,
        locationTracking: any LocationTracking,
        streamBiometricsUseCase: StreamBiometricsUseCase,
        saveWorkoutUseCase: SaveWorkoutUseCase,
        userProfileRepository: any UserProfileRepository,
        bleRepository: any WhoopBLEDeviceRepository,
        activeFastRepository: any ActiveFastRepository,
        offlineMaps: any OfflineMapServing
    ) {
        self.controller = controller
        self.locationTracking = locationTracking
        self.streamBiometricsUseCase = streamBiometricsUseCase
        self.saveWorkoutUseCase = saveWorkoutUseCase
        self.userProfileRepository = userProfileRepository
        self.bleRepository = bleRepository
        self.activeFastRepository = activeFastRepository
        self.offlineMaps = offlineMaps
        // **The stored fast is deliberately not read here**, though it is the one thing this type keeps
        // that outlives the process. A `nonisolated init` may not assign main-actor-isolated state, and
        // `@Observable` rewrites every stored property into exactly that — so `fastSlot` cannot be
        // seeded from this body however it is declared. `restoreFast()` is the same read, made by the
        // main actor at the first moment it can; see its own comment for why that is still ahead of the
        // first frame and not the `.task` below it.
    }

    // MARK: - Starting

    /// Begins a session. Idempotent: a second call while one is running returns immediately.
    ///
    /// **`name` is what the picker chose, and it defaults to WHOOP's abstention word.** The default is
    /// load-bearing rather than convenient: `START ACTIVITY` opens `ActivityPickerView` and the chosen
    /// name is what the session records, but a session started by any other route has no name to
    /// record, and `WhoopActivityCatalog.abstentionName` is the word WHOOP's own classifier writes for
    /// exactly that case. It is a parameter with a default rather than a second entry point, so there
    /// is one recording path and not two that could drift apart.
    ///
    /// The zone table is built **once, here**, from the profile as it stands at the start, and never
    /// recomputed per sample. The profile cannot change mid-session in a way that should retroactively
    /// re-score the minutes already recorded, and re-reading it per sample would be a SQLite round trip
    /// per heartbeat.
    public func start(name: String = WhoopActivityCatalog.abstentionName) async {
        guard !isRunning else { return }

        guard let profile = try? await userProfileRepository.getUserProfile() else {
            // Unreachable in practice — `GRDBUserProfileRepository` falls back to a cold-start pair
            // rather than throwing when there is no row, so this needs a broken database. Recorded
            // rather than swallowed, because the symptom is a START button that does nothing.
            AppLogger.database.error("Live session not started: the user profile could not be read.")
            // Redundant today, and stated rather than left implicit: the only exit above that has
            // already set a name is the one for a session still running, which the first guard takes.
            // It is here because it is the invariant that keeps a stale name off somebody else's row.
            activityName = nil
            return
        }

        let now = Date()
        startedAt = now
        isRunning = true
        activityName = name
        liveActivityError = nil
        accumulator = LiveSessionAccumulator(
            zones: StrainAccumulatorMath.computeZones(
                maxHR: profile.maxHeartRate, restHR: profile.restingHeartRate),
            restingHeartRate: profile.restingHeartRate,
            weightKg: profile.weightKg
        )
        lastPushedAt = nil

        requestLiveActivity(state: LiveSessionActivityState(startedAt: now))

        // `[weak self]` because the task runs for the length of the session: a strong capture would
        // make this type retain itself through the task until the stream ends, and a stream that never
        // ends is exactly what a live session is.
        consumer = Task { [weak self] in
            guard let stream = self?.streamBiometricsUseCase.execute() else { return }
            for await sample in stream {
                guard let self else { return }
                self.ingest(sample)
            }
        }

        startStepConsumer()
    }

    /// Attaches the session's own reader to the motion stream.
    ///
    /// No accumulator is built here. One is built on the session's **first batch**, off that batch's
    /// own rate, for the reason `TrackStepsUseCase.ingest` builds its day's accumulator on first sight
    /// of the day: `StepDetectionMath.Detector` turns the rate into a **sample count** for its gravity
    /// and threshold windows at construction, so a rate written down here rather than read off the
    /// batch would size both windows wrongly and count the same waveform differently from the day's
    /// own accumulator. `[weak self]` for `consumer`'s reason: the task runs for the length of the
    /// session, and a strong capture would retain this type until a stream that never ends does.
    ///
    /// **This is a second subscriber and the first must survive it.** `motionStream` is multicast and
    /// keyed by `UUID`, so this is an addition rather than a theft — but the failure if the registry
    /// were ever replaced by a single continuation is silent, and it is the day's step tile that stops
    /// moving. §19 drives both readers over one batch as the assertion that catches it.
    private func startStepConsumer() {
        stepConsumer = Task { [weak self] in
            guard let stream = self?.bleRepository.motionStream else { return }
            for await batch in stream {
                guard let self else { return }
                self.ingestMotion(batch)
            }
        }
    }

    /// Folds one motion batch into the session's step count, building the accumulator on the first.
    ///
    /// Nothing is written and nothing is published: unlike the day's accumulator there is no reader
    /// for this figure until the session ends, so there is no row to keep current and no card to push.
    ///
    /// **No baseline and no seeding.** `TrackStepsUseCase` resumes a day from its stored row; a session
    /// has no stored row to resume from — it does not exist until `end()` — so this always starts from
    /// zero, and the rate is pinned by whichever batch arrived first exactly as the day's is.
    private func ingestMotion(_ batch: MotionBatch) {
        // A non-positive interval is not a rate, and `StepAccumulator.accept` refuses such a batch
        // anyway — but the accumulator would already have been built with the bad rate, so the guard
        // belongs here rather than only there.
        guard batch.sampleIntervalSeconds > 0 else { return }
        var stepAccumulator = stepAccumulator
            ?? StepAccumulator(sampleRateHz: 1.0 / batch.sampleIntervalSeconds)
        stepAccumulator.accept(
            accelerometerXG: batch.accelerometerG.x,
            accelerometerYG: batch.accelerometerG.y,
            accelerometerZG: batch.accelerometerG.z,
            sampleIntervalSeconds: batch.sampleIntervalSeconds,
            // The samples' own instants on the batch's scale. `StepAccumulator` reads only
            // *differences* — the refractory interval is the sole consumer — so a live batch's arrival
            // instant and a banked record's strap unix time are both usable here, which is the same
            // argument `TrackStepsUseCase.ingest` makes.
            startSeconds: batch.start.timeIntervalSince1970)
        self.stepAccumulator = stepAccumulator
    }

    /// Folds one sample in, republishes the snapshot, and pushes the card if the throttle allows.
    private func ingest(_ sample: BiometricSample) {
        guard var accumulator else { return }
        accumulator.accept(
            heartRate: sample.heartRate,
            at: sample.timestamp,
            isOnBody: sample.isOnBody
        )
        self.accumulator = accumulator

        let snapshot = accumulator.snapshot
        self.snapshot = snapshot

        guard let startedAt, shouldPush(at: sample.timestamp) else { return }
        lastPushedAt = sample.timestamp
        pushCard(snapshot, startedAt: startedAt, isRunning: true)
    }

    /// Whether this sample may become a card update.
    ///
    /// The rule is **the first sample of the session, then at most one push per second**, timed off the
    /// sample's own instant rather than `Date()` so it follows the measurement clock and a burst of
    /// samples stamped alike costs one push rather than one each.
    ///
    /// **A ≥ 5 bpm jump deliberately does not bypass the interval**, which is a departure from the
    /// plan this was built to. The clause can only ever fire *inside* the one-second floor — outside it
    /// the elapsed test has already passed — so its only effect is to push faster than the responsiveness
    /// budget on a fast-rising heart rate, which is when the system is most likely to start dropping
    /// updates. A one-second ceiling is well inside what a lock-screen glance needs.
    private func shouldPush(at timestamp: Date) -> Bool {
        guard let lastPushedAt else { return true }
        return timestamp.timeIntervalSince(lastPushedAt) >= Self.minimumPushIntervalSeconds
    }

    // MARK: - The route

    /// Turns GPS recording on or off for this session, asking for permission the first time.
    ///
    /// `async` because a permission grant is: the first call puts a system prompt on screen and only
    /// returns once the user has answered it. That is also why the screen hands this to a `Task` from
    /// its `Toggle`'s setter — see `LiveSessionView`.
    ///
    /// **The session's start is not gated on this.** `LiveSessionView` calls `start()` from its
    /// `.task`, so the session is already recording by the time the user reaches the toggle, and
    /// turning it on begins the route **at that moment** rather than at `startedAt`. That is the
    /// honest reading of what the toggle means, and it costs the first seconds of a route — which is
    /// nothing against a run. A sticky "always record" preference was considered and left out: it
    /// would need a field on `AppPreferences` and a fifth injected dependency here, and it is cheap to
    /// add later if the toggle proves annoying to flick every time.
    public func setRouteRecording(_ on: Bool) async {
        guard on else {
            guard isRecordingRoute else { return }
            stopRoute()
            return
        }

        guard !isRecordingRoute else { return }

        // Only ask when nobody has been asked. `permission` alone cannot distinguish "refused" from
        // "not yet asked", and prompting on a settled answer does nothing but waste a round trip.
        let permission = locationTracking.permission == .undetermined
            ? await locationTracking.requestPermission()
            : locationTracking.permission

        guard permission == .authorized else {
            // Still `.undetermined` after a request means Location Services are switched off for the
            // whole device, which is a different fix from refusing this app — so it gets a different
            // sentence. Neither is a reason to stop the session.
            routeError = permission == .denied
                ? "Whoopsy is not allowed to use your location, so this session is recording without "
                    + "a route. You can allow it in Settings › Privacy & Security › Location Services."
                : "Location Services appear to be switched off, so this session is recording without "
                    + "a route."
            isRecordingRoute = false
            AppLogger.ui.info("Route recording not started: location permission is \(String(describing: permission)).")
            return
        }

        routeError = nil
        isRecordingRoute = true

        routeConsumer = Task { [weak self] in
            guard let stream = self?.locationTracking.start() else { return }
            for await point in stream {
                guard let self else { return }
                self.appendRoutePoint(point)
            }
        }
    }

    /// Stops delivery and finishes the consumer, keeping the fixes already collected.
    ///
    /// Called both by the toggle going off and by `end()`, so it is written to tolerate a second call:
    /// `stop()` on a service that was never started is a documented no-op on the protocol.
    private func stopRoute() {
        isRecordingRoute = false
        routeConsumer?.cancel()
        routeConsumer = nil
        locationTracking.stop()
    }

    // MARK: - The offline map

    /// How long to wait for a position fix before giving up on a download.
    ///
    /// A cold GPS fix outdoors is a few seconds; ten is generous enough that a genuinely slow fix still
    /// succeeds, and short enough that a user standing indoors is told something rather than watching a
    /// spinner until the session ends. The failure is honest and recoverable — the tiles have to be
    /// fetched while there is still a network, so "no fix" is a reason to say so now rather than later.
    private static let offlineMapFixTimeoutSeconds: Double = 10

    /// How often to look for a fix the route's own consumer is delivering.
    private static let offlineMapFixPollMilliseconds: Int = 200

    /// Turns the offline map on or off for this session.
    ///
    /// **It does its own permission check rather than borrowing the route's**, because the two switches
    /// are independent and either can be the first one the user touches. Turning this on with
    /// `RECORD ROUTE` off therefore asks for location itself, takes the one fix it needs, and **releases
    /// the GPS again** — a map tile download is a one-shot, and leaving the radio running for it would
    /// put the blue indicator up for a session that is recording no route.
    ///
    /// **Nothing here can stop the session.** Every failure — an unsupported build, a refused
    /// permission, no fix, no network — is recorded in ``offlineMapError`` and the session records on,
    /// which is the absence rule applied to a capability exactly as `setRouteRecording(_:)` applies it.
    public func setOfflineMap(_ on: Bool) async {
        guard on else {
            guard isOfflineMapRequested else { return }
            // **Only a download still in flight is cancelled**, which is the contract
            // `OfflineMapServing.cancelDownload` states and the reason it states it. Turning the switch
            // off *after* the tiles landed leaves them on disk: the region is already recorded on the
            // session's row and possibly read by a page, so revoking it here would take back the very
            // thing the user asked for a moment earlier — and on a session that has already ended, a
            // region nothing on screen is left to explain. `delete(regionID:)` is what removes a region,
            // and there is deliberately no screen that calls it yet.
            //
            // **Asked here, above the clears, and not after them.** `.absent` is one of the answers this
            // reads, and it is the answer the flag-clearing below assigns — so the same guard placed one
            // line lower is a guard no switch position can satisfy, and the cancel becomes a call that
            // never happens while still reading as though it does.
            var wasDownloading = false
            if case .downloading = offlineMapState { wasDownloading = true }
            // Cancelled before the flags are cleared, so a download that lands during this call cannot
            // see itself as still wanted.
            offlineMapTask?.cancel()
            offlineMapTask = nil
            isOfflineMapRequested = false
            offlineRegionID = nil
            offlineMapError = nil
            offlineMapState = .absent
            if wasDownloading { offlineMaps.cancelDownload() }
            // The fix was taken on a stream this call started, and only when no route was running. If
            // the route is recording, that stream is the route's and is not ours to stop.
            if !isRecordingRoute { locationTracking.stop() }
            return
        }

        guard !isOfflineMapRequested else { return }

        // Checked before the switch is honoured rather than left to fail later: a build with no map SDK
        // behind it has no version of this that works, and the honest answer is a sentence rather than a
        // download that silently does nothing.
        guard offlineMaps.isSupported else {
            offlineMapError = "Offline maps are not available in this build, so this session will draw "
                + "its route on the standard map."
            AppLogger.ui.info("Offline map not started: this build has no map SDK behind it.")
            return
        }

        // Only ask when nobody has been asked — `setRouteRecording(_:)`'s rule, and for its reason.
        let permission = locationTracking.permission == .undetermined
            ? await locationTracking.requestPermission()
            : locationTracking.permission

        guard permission == .authorized else {
            offlineMapError = permission == .denied
                ? "Whoopsy is not allowed to use your location, so it cannot download a map of this "
                    + "area. You can allow it in Settings › Privacy & Security › Location Services."
                : "Location Services appear to be switched off, so no map can be downloaded for this "
                    + "session."
            AppLogger.ui.info("Offline map not started: location permission is \(String(describing: permission)).")
            return
        }

        let regionID = Self.makeOfflineRegionID()
        offlineMapError = nil
        isOfflineMapRequested = true
        offlineRegionID = regionID
        offlineMapState = .downloading(fraction: 0)

        offlineMapTask = Task { [weak self] in
            guard let self else { return }

            guard let center = await self.offlineMapCenter() else {
                guard self.offlineRegionID == regionID else { return }
                self.failOfflineMap(
                    "Whoopsy could not get a position fix, so no map was downloaded. The tiles have to "
                        + "be fetched while you still have signal, so try again somewhere with a clearer "
                        + "view of the sky.")
                return
            }

            await self.offlineMaps.download(
                regionID: regionID, latitude: center.latitude, longitude: center.longitude
            ) { fraction in
                // Guarded on every tick, not only at the end: the switch can be turned off — or the
                // session ended — while tiles are still arriving, and a progress write after that would
                // put a downloading state back on a session that has moved on.
                guard self.offlineRegionID == regionID else { return }
                self.offlineMapState = .downloading(fraction: fraction)
            }

            // **The session that asked may be gone.** A download outlives `end()` on purpose, and a
            // second session may already have minted its own region by the time these tiles land — so
            // this reports back only if the region it was asked for is still the one on screen.
            guard self.offlineRegionID == regionID else { return }

            let state = self.offlineMaps.state(for: regionID)
            self.offlineMapState = state
            if case .failed(let reason) = state { self.failOfflineMap(reason) }
        }
    }

    /// Records a failure and returns the switch to off.
    ///
    /// The switch goes back off rather than staying on with a note under it, because a download that
    /// failed is not a download in progress: leaving it on would promise a map on the detail page that
    /// `RouteMapRenderer` is going to resolve to MapKit anyway. The sentence is what tells the user why.
    private func failOfflineMap(_ sentence: String) {
        offlineMapError = sentence
        isOfflineMapRequested = false
        offlineRegionID = nil
        offlineMapState = .absent
        offlineMapTask = nil
    }

    /// A name no other session can collide with, prefixed so a region found in Mapbox's own tile store is
    /// recognisable as this app's.
    private static func makeOfflineRegionID() -> String { "whoopsy-\(UUID().uuidString)" }

    /// One plausible fix to centre the region on, or `nil` if none arrived in time.
    ///
    /// **It does not open a second stream when the route already has one.** `LocationTracking.start()`
    /// is a call on the one `CLLocationManager` the container holds, so asking twice while the route is
    /// recording would be two consumers on one manager — and the route's fixes are already arriving into
    /// `routePoints`, so the centre is a read rather than a request.
    private func offlineMapCenter() async -> WorkoutRoutePoint? {
        if isRecordingRoute { return await firstRouteFix() }

        let stream = locationTracking.start()
        defer { locationTracking.stop() }
        return await Self.firstPlausibleFix(
            in: stream, timeoutSeconds: Self.offlineMapFixTimeoutSeconds)
    }

    /// Waits for the route's own consumer to deliver a usable fix, bounded by the same timeout.
    private func firstRouteFix() async -> WorkoutRoutePoint? {
        let deadline = ContinuousClock.now + .seconds(Self.offlineMapFixTimeoutSeconds)
        while ContinuousClock.now < deadline {
            if let fix = routePoints.first(where: \.isPlausible) { return fix }
            // A cancellation here is the switch going off, and it must not be swallowed into a retry.
            do {
                try await Task.sleep(for: .milliseconds(Self.offlineMapFixPollMilliseconds))
            } catch {
                return nil
            }
        }
        return routePoints.first(where: \.isPlausible)
    }

    /// The first plausible fix on `stream`, or `nil` when `timeoutSeconds` pass first.
    ///
    /// **The race is the whole function, and it is not avoidable.** An `AsyncStream` that never yields
    /// cannot be waited on with a deadline — `for await` simply suspends — so a timeout needs a second
    /// task to run against it. Without one, a phone indoors would sit in `.downloading` until the user
    /// ended the session, which is a spinner that never resolves and no explanation anywhere.
    ///
    /// `nonisolated` because it touches none of this type's state: the stream is `Sendable` and is handed
    /// in, so the two children need no actor hop.
    private nonisolated static func firstPlausibleFix(
        in stream: AsyncStream<WorkoutRoutePoint>, timeoutSeconds: Double
    ) async -> WorkoutRoutePoint? {
        await withTaskGroup(of: WorkoutRoutePoint?.self) { group in
            group.addTask {
                for await point in stream where point.isPlausible { return point }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            // Whichever finishes first, and the loser is cancelled — the `AsyncStream` child ends on
            // cancellation, which is what lets `locationTracking.stop()` in the caller be the last word.
            let fix = await group.next() ?? nil
            group.cancelAll()
            return fix
        }
    }

    /// Files one fix, stamped with the session's current reading.
    ///
    /// **The stamping happens here and not in the location service**, because the division is by what
    /// each side knows: a position service has no heart rate, and this type is the only thing holding
    /// the accumulator. `heartRate: 0` then means exactly what `WorkoutRoutePointRecord`'s doc comment
    /// says it means — *"the strap had no reading then, not a pulse"* — so a fix that arrives before
    /// the session's first sample carries the sentinel honestly, and every fix after it carries the
    /// reading in force.
    private func appendRoutePoint(_ point: WorkoutRoutePoint) {
        guard point.isPlausible else { return }
        routePoints.append(WorkoutRoutePoint(
            id: point.id,
            latitude: point.latitude,
            longitude: point.longitude,
            timestamp: point.timestamp,
            heartRate: accumulator?.snapshot.latestHeartRate ?? 0
        ))
    }

    // MARK: - The fast

    /// Seeds `activeFast` from the store — the relaunch, made to happen on an already-running process.
    ///
    /// **This is a method rather than something `init` does, and the reason is a language rule rather
    /// than a preference.** `init` is `nonisolated`, because `DIContainer` is not `@MainActor` and
    /// builds this type from its own plain `init`; and a `nonisolated init` may not assign
    /// main-actor-isolated stored state — `@Observable` rewrites stored properties into computed ones
    /// whose setter is an ordinary isolated mutation, so even a non-optional, un-defaulted property is
    /// refused. So the restore is the first thing the **main actor** does with this object instead,
    /// called from `MainContainerView`'s `init`: still before any of Home has been laid out, so the bar
    /// is already correct on the first body evaluation and no frame is drawn showing no bar over a
    /// fast that is in fact running.
    ///
    /// **It is idempotent, and it cannot resurrect an ended fast.** It returns immediately when one is
    /// already running, and `endFast()` clears the store as well as the slot — so a later call after a
    /// fast has ended reads an empty store and does nothing.
    public func restoreFast() {
        guard activeFast == nil, let stored = activeFastRepository.load() else { return }
        fastSlot = .running(stored)
    }

    /// Starts a fast, or does nothing when one is already running.
    ///
    /// **Idempotent on `start()`'s pattern**, and here it matters more: a fast has exactly one piece of
    /// state, so a second call that overwrote `startedAt` would silently restart a three-day fast from
    /// zero with nothing on screen to say so.
    ///
    /// **There is deliberately no guard against a live activity here, because the route that reaches
    /// this is already closed while one records.** A fast is started by picking `Fast` in
    /// `ActivityPickerView`, and that picker is reachable only through `START ACTIVITY` — which
    /// `ActivityMenu` withholds for the whole of a recording. So the two cannot be started in the wrong
    /// order, and a check here would be a second copy of a rule the menu already states, free to
    /// disagree with it.
    ///
    /// **The slot is filled before the store is written, not after.** The bar has to appear on the tap
    /// rather than a disk write later, and the persisted copy exists for the *restart* — it is not what
    /// this session reads. The window between the two statements is one in-memory write, and a kill
    /// inside it costs the fast at the next launch rather than misreporting this one.
    public func startFast() async {
        guard activeFast == nil else { return }
        let fast = ActiveFast(startedAt: Date())
        fastSlot = .running(fast)
        activeFastRepository.save(fast)
    }

    /// Ends the fast, writes its row, and hands that row back.
    ///
    /// Returns `nil` — writing nothing — when no fast is running, and when the fast is being ended in
    /// the same instant it started: a row whose `startedAt` and `endedAt` are the same instant is a
    /// fast of zero length, which is not a fast that happened.
    ///
    /// **Both clears are above the first `await`, one statement apart**, which is `end()`'s ordering
    /// above and for `end()`'s reason. There, `isRunning` is cleared at the top so a bar keyed on the
    /// state cannot go on drawing through a database round trip; here it is `activeFast`, and clearing
    /// it below the save would leave the bar counting past the END FAST press for the length of a
    /// SQLite write — and would leave a second END FAST callable in that window.
    ///
    /// **The window that opens is real, and it is the lesser of the two failures.** A kill between
    /// `clear()` and the save loses the fast outright. Clearing *after* a successful save is worse: a
    /// kill in that window leaves a stored fast whose row is already on disk, so a relaunch restores it
    /// and the next END FAST writes a second row for one fast under a fresh `UUID`. Losing a fast is a
    /// loss; duplicating one is a corruption, and the storage has no key that could collapse the two.
    ///
    /// **The row is `projectedSession(now:)` and not a second construction**, which is what makes the
    /// page the user was just looking at and the row they end with one definition rather than two that
    /// agree today. `Summary.calories` is `nil` here and stays `nil`: a fast burns nothing this app
    /// measured, and there is no accumulator behind it that could hold a figure.
    @discardableResult
    public func endFast() async -> Summary? {
        guard let fast = activeFast else { return nil }

        let now = Date()
        guard now > fast.startedAt else { return nil }

        fastSlot = .none
        activeFastRepository.clear()

        let workout = fast.projectedSession(now: now)
        do {
            try await saveWorkoutUseCase.execute(workout)
        } catch {
            AppLogger.database.error("Failed saving fast: \(error.localizedDescription)")
            return nil
        }

        return Summary(workout: workout, calories: nil)
    }

    // MARK: - Ending

    /// Ends the session, publishes it as an activity, and tears down the card.
    ///
    /// Returns `nil` — **and writes nothing** — when the session measured nothing, which is the repo's
    /// standing rule: *a writer may persist a row only when it produced a measurement, and the test it
    /// uses must be the same test its readers use*. A session with no samples has no strain, no average
    /// heart rate and no maximum, and `WorkoutSession` has no optional for any of the three — so writing
    /// one would mean inventing all three. A user who taps START and END with no strap connected gets
    /// no activity on Home, which is the honest answer rather than a 0.0-strain row.
    ///
    /// Three of the fields are set to `nil` deliberately, and a future editor will be tempted to fill
    /// them:
    ///
    /// - **`source: nil`** — documented on the entity as the value for a session this app recorded live.
    /// - **`hrZonePercents: nil`** — that column is WHOOP's own `HR Zone n %` block. Writing this app's
    ///   computed zones into it is precisely the two-producer defect the `source` column exists to
    ///   prevent, and the strain detail page will correctly draw dashes there.
    /// - **`steps`** — not a constant: `sessionStepCount` above, which is the session's own accumulated
    ///   count or `nil` when no motion batch arrived. It is the one field of the three that *does* have
    ///   a producer on this path, and it is `nil` rather than `0` for the sessions the strap was silent
    ///   through.
    ///
    /// **`activityName` comes from the picker, and a name is not a measurement.** This app records a
    /// session without classifying it, so the only name it can honestly write is the one the user
    /// chose — and when they were not asked, WHOOP's own answer to that case is a word rather than an
    /// absence: its classifier abstains rather than guessing, and writes the literal `Activity` for a
    /// session it did not categorise, which 197 rows of the bundled export read exactly. So the
    /// fallback is that same word for that same reason, in place of a NULL that only
    /// `HomeDashboardView`'s `??` turned back into it, and the row's shape matches the export's.
    /// **`ActivityGlyph` holds no entry for the string on purpose**, so the row takes the
    /// `figure.run` fallback exactly as `nil` did and no screen moves. Do not add one: it would give
    /// the one label that means "not categorised" a glyph of its own, which is a claim this app cannot
    /// make.
    @discardableResult
    public func end() async -> Summary? {
        guard isRunning, let startedAt, let accumulator else { return nil }

        consumer?.cancel()
        consumer = nil
        stepConsumer?.cancel()
        stepConsumer = nil
        // The GPS is released here rather than in `reset()` so it stops before the save is awaited: a
        // `CLLocationManager` left running keeps the blue indicator up, and a database round trip is
        // long enough to notice. `reset()` calls it again, which the protocol documents as safe.
        stopRoute()
        isRunning = false

        let snapshot = accumulator.snapshot

        // The card is ended whatever else happens, so a refusal or an empty session cannot strand it.
        // `isRunning: false` is load-bearing: `Activity.content` cannot be replaced after `end`, so this
        // state is what the card shows for its whole dismissal window.
        await controller.end(
            state: activityState(snapshot, startedAt: startedAt, isRunning: false))
        isLiveActivityActive = false

        defer { reset() }

        // **All four are policy, and none of them is the type talking.** Since `v18` the three figures
        // are optional on `WorkoutSession`, so this guard could be deleted and the session would still
        // build — writing a row of `nil`s. It is kept because a session with no samples is not a
        // workout: the zero-sample case writes nothing at all, and a session that measured too little
        // to score a strain writes nothing either. This is the absence rule at the write, and it is
        // the only thing standing between a mis-tapped toggle and a `workouts` row claiming a session
        // that never happened. Deleting it is the change that would look like a tidy-up.
        guard
            snapshot.sampleCount > 0,
            let strain = snapshot.strain,
            let averageHeartRate = snapshot.averageHeartRate,
            let maxHeartRate = snapshot.maxHeartRate
        else {
            return nil
        }

        let workout = WorkoutSession(
            startedAt: startedAt,
            endedAt: Date(),
            strain: strain,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            route: routePoints,
            splits: [],
            source: nil,
            activityName: activityName ?? WhoopActivityCatalog.abstentionName,
            hrZonePercents: nil,
            steps: sessionStepCount,
            // **Read before `reset()` runs, which is what makes the row honest.** The `defer` below
            // clears this field, so the value written here is the one the user left the switch on with —
            // and a session whose switch was off writes `nil`, which `RouteMapRenderer.resolve` reads as
            // *this session asked for no region* and draws on the iOS map.
            //
            // A download still in flight is deliberately **not** cancelled here. The row already names
            // its region, the tiles keep arriving, and the detail page — which is opened after the
            // session ends — asks the store what it found. Cancelling would leave a row claiming a region
            // the store does not have.
            offlineRegionID: offlineRegionID
        )

        do {
            try await saveWorkoutUseCase.execute(workout)
        } catch {
            AppLogger.database.error("Failed saving live session: \(error.localizedDescription)")
            return nil
        }

        return Summary(workout: workout, calories: snapshot.calories)
    }

    /// What the session's motion amounts to, as a value to store — or `nil` when there was none.
    ///
    /// **`measuredSeconds > 0` and not `stepCount > 0`**, which is the same test `StepCount` makes and
    /// the test `TrackStepsUseCase.write` gates on: a session of no walking is a measured `0` and must
    /// be stored as one, while a session the strap sent no motion during is an absence. The two
    /// answers are different on the page — a figure against a dash — and a `?? 0` at the write site is
    /// what would collapse them, which is why the conversion lives here rather than at the call.
    private var sessionStepCount: Int? {
        guard let stepAccumulator, stepAccumulator.measuredSeconds > 0 else { return nil }
        return stepAccumulator.stepCount
    }

    /// Ends the card, running or not, and clears the session's state.
    ///
    /// Called by `end()`'s `defer` so a session that produced no row still drops its accumulator — a
    /// second `start()` must not inherit the first one's samples.
    private func reset() {
        accumulator = nil
        snapshot = nil
        // Cancelled here as well as in `end()`, which is the only caller: an accumulator dropped while
        // its consumer is still attached would leave a continuation registered on the multicast motion
        // stream for the life of the process, and a leaked subscriber fails silently. A second
        // `cancel()` on a finished task is a no-op.
        stepConsumer?.cancel()
        stepConsumer = nil
        stepAccumulator = nil
        self.startedAt = nil
        lastPushedAt = nil
        // Cleared with `startedAt` and not before it, because the two describe one session: a name
        // beside no start instant is a name with no row to belong to.
        activityName = nil
        // A second `start()` must inherit neither the first session's samples nor its route.
        stopRoute()
        routePoints = []
        routeError = nil
        // Nor its offline region. Cleared here rather than left standing so the two fields cannot
        // disagree: `isOfflineMapRequested` and `offlineRegionID` are set and cleared together, which is
        // what makes the row `end()` writes name a region **exactly when the user left the switch on**.
        //
        // **The task is deliberately not cancelled**, and this is the one place that is true of a task
        // this type owns. A download that outlives the session is the desired behaviour: the row already
        // names the region and the tiles keep landing in Mapbox's store, which is what the detail page
        // reads. The task's own `self.offlineRegionID == regionID` guard is what stops it writing a
        // stale state back into a session that has moved on — so clearing the id here is also what
        // retires the task's ability to touch this object, without depriving the store of its tiles.
        isOfflineMapRequested = false
        offlineRegionID = nil
        offlineMapState = .absent
        offlineMapError = nil
        offlineMapTask = nil
    }

    /// Ends any card a process that died mid-session left behind.
    ///
    /// A card has no tie to a process lifetime: killing the app leaves the lock screen counting up from
    /// `startedAt` indefinitely. Because this build has **no BLE state restoration and no in-flight
    /// persistence**, a relaunch cannot adopt one — the only honest option is to end it. Called once
    /// from `MainContainerView`'s root task, and a no-op while a session is running.
    public func endOrphanedLiveActivities() async {
        guard !isRunning else { return }
        let ended = await controller.endOrphans()
        if ended > 0 {
            AppLogger.ui.info("Ended \(ended) live activity card(s) left by a previous process.")
        }
    }

    // MARK: - The card

    private func requestLiveActivity(state: LiveSessionActivityState) {
        guard controller.isSupported else { return }
        do {
            try controller.start(state: state)
            isLiveActivityActive = true
        } catch {
            // The session keeps recording — see `liveActivityError`.
            liveActivityError = error.localizedDescription
            AppLogger.ui.error("Live activity refused: \(error.localizedDescription)")
        }
    }

    private func pushCard(
        _ snapshot: LiveSessionAccumulator.Snapshot,
        startedAt: Date,
        isRunning: Bool
    ) {
        guard isLiveActivityActive else { return }
        let state = activityState(snapshot, startedAt: startedAt, isRunning: isRunning)
        Task { await controller.update(state: state) }
    }

    /// The one place a snapshot becomes a card's content.
    ///
    /// Every field comes off the snapshot, including `heartRate` — so the card and the screen cannot
    /// show two different beats, which a parameter carrying "the reading that just arrived" would
    /// eventually allow.
    private func activityState(
        _ snapshot: LiveSessionAccumulator.Snapshot,
        startedAt: Date,
        isRunning: Bool
    ) -> LiveSessionActivityState {
        LiveSessionActivityState(
            startedAt: startedAt,
            strain: snapshot.strain,
            heartRate: snapshot.latestHeartRate,
            calories: snapshot.calories,
            isRunning: isRunning
        )
    }
}
