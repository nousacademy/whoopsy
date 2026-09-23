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

    public nonisolated init(
        controller: any LiveActivityControlling,
        locationTracking: any LocationTracking,
        streamBiometricsUseCase: StreamBiometricsUseCase,
        saveWorkoutUseCase: SaveWorkoutUseCase,
        userProfileRepository: any UserProfileRepository,
        bleRepository: any WhoopBLEDeviceRepository
    ) {
        self.controller = controller
        self.locationTracking = locationTracking
        self.streamBiometricsUseCase = streamBiometricsUseCase
        self.saveWorkoutUseCase = saveWorkoutUseCase
        self.userProfileRepository = userProfileRepository
        self.bleRepository = bleRepository
    }

    // MARK: - Starting

    /// Begins a session. Idempotent: a second call while one is running returns immediately.
    ///
    /// The zone table is built **once, here**, from the profile as it stands at the start, and never
    /// recomputed per sample. The profile cannot change mid-session in a way that should retroactively
    /// re-score the minutes already recorded, and re-reading it per sample would be a SQLite round trip
    /// per heartbeat.
    public func start() async {
        guard !isRunning else { return }

        guard let profile = try? await userProfileRepository.getUserProfile() else {
            // Unreachable in practice — `GRDBUserProfileRepository` falls back to a cold-start pair
            // rather than throwing when there is no row, so this needs a broken database. Recorded
            // rather than swallowed, because the symptom is a START button that does nothing.
            AppLogger.database.error("Live session not started: the user profile could not be read.")
            return
        }

        let now = Date()
        startedAt = now
        isRunning = true
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
    /// **`activityName` is set, and a name is not a measurement.** This app records a session without
    /// classifying it, and WHOOP's own answer to that case is a word rather than an absence: its
    /// classifier abstains rather than guessing, and writes the literal `Activity` for a session it did
    /// not categorise — 197 rows of the bundled export read exactly that. So this writer stores the same
    /// word for the same reason, in place of a NULL that only `HomeDashboardView`'s `??` turned back
    /// into it, and the row's shape matches the export's. **`ActivityGlyph` holds no entry for the
    /// string on purpose**, so the row takes the `figure.run` fallback exactly as `nil` did and no screen
    /// moves. Do not add one: it would give the one label that means "not categorised" a glyph of its
    /// own, which is a claim this app cannot make.
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
            activityName: "Activity",
            hrZonePercents: nil,
            steps: sessionStepCount
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
        // A second `start()` must inherit neither the first session's samples nor its route.
        stopRoute()
        routePoints = []
        routeError = nil
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
