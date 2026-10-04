import CoreBluetooth
import Foundation
import SwiftUI
import Whoopsy

/// A `WhoopBLEDeviceRepository` whose live parts are the two streams a section here drives.
///
/// **Both streams are multicast, like the real ones.** `liveTelemetryStream` and `motionStream` each
/// hand every caller its own `AsyncStream`, registered in a lock-guarded dictionary, because an
/// `AsyncStream` can be iterated once while `StreamBiometricsUseCase.execute()` iterates whatever it is
/// handed. A fixture returning one stored stream would deliver to the first reader and silently starve
/// the second — which is the exact failure `CLAUDE.md` records against this protocol, so a fixture
/// reproducing it would be testing the defect rather than the session.
///
/// **Two readers on one motion stream is the arrangement §19 has to prove**, because the app really
/// does run two: `TrackStepsUseCase` fills the day's tile and `LiveSessionUseCase` counts the session's
/// own. One stored continuation would let the first reader take every batch and leave the second's
/// `for await` silent, which is indistinguishable from a strap that went quiet.
///
/// The `subscriberCount`s it exposes are what let a section assert the *release* half of that rule:
/// ending a session must drop its reader, or a stream accumulates consumers that nothing feeds.
///
/// Every other member is a no-op or an empty answer. `LiveSessionUseCase` reads `liveTelemetryStream`
/// and `motionStream` and nothing else from this protocol, so none of the rest is reached — they exist
/// to satisfy it.
final class ScriptedTelemetryRepository: WhoopBLEDeviceRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BiometricSample>.Continuation] = [:]
    private var motionContinuations: [UUID: AsyncStream<MotionBatch>.Continuation] = [:]

    /// Registers one telemetry continuation under a fresh `UUID` and arranges for its removal.
    ///
    /// `[weak self]` rather than a strong capture: the continuation is stored by `self` and holds this
    /// closure, so a strong one is a retain cycle that no session would ever break.
    ///
    /// The motion register below is this function's twin rather than a shared generic: the two
    /// registries hold different element types, and the argument that they must be pruned alike is
    /// carried by their being three lines apart and identically shaped.
    private func register(_ continuation: AsyncStream<BiometricSample>.Continuation) {
        let id = UUID()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
    }

    private func register(_ continuation: AsyncStream<MotionBatch>.Continuation) {
        let id = UUID()
        lock.lock()
        motionContinuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.motionContinuations[id] = nil
            self.lock.unlock()
        }
    }

    var liveTelemetryStream: AsyncStream<BiometricSample> {
        AsyncStream { continuation in register(continuation) }
    }

    var motionStream: AsyncStream<MotionBatch> {
        AsyncStream { continuation in register(continuation) }
    }

    /// How many readers are attached. `0` after a session ends is the assertion; `1` before the first
    /// sample is the barrier.
    var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }

    /// How many readers the motion stream has. **`2` while a session and the day's counter are both
    /// attached**, which is the count a single-continuation registry cannot reach.
    var motionSubscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return motionContinuations.count
    }

    /// Delivers one sample to every attached reader.
    func yield(_ sample: BiometricSample) {
        lock.lock()
        let readers = Array(continuations.values)
        lock.unlock()
        for reader in readers { reader.yield(sample) }
    }

    /// Delivers one motion batch to every attached reader.
    func yieldMotion(_ batch: MotionBatch) {
        lock.lock()
        let readers = Array(motionContinuations.values)
        lock.unlock()
        for reader in readers { reader.yield(batch) }
    }

    var deviceStream: AsyncStream<WhoopDevice> { AsyncStream { $0.finish() } }

    func startScanning() async throws {}
    func stopScanning() async {}
    func connect(to deviceId: String) async throws {}
    func disconnect() async {}
    func sendHapticAlert(durationSeconds: Int, pattern: Int) async throws {}
    func getCurrentDevice() async -> WhoopDevice? { nil }
    func refreshStrapModel() async {}

    /// Never reached: a session writes a `workouts` row and reads no flash. `aborted` rather than
    /// `strapReportedComplete`, because a fixture that claimed the strap confirmed a drain it never
    /// performed would be asserting the strap's buffer from a machine with no strap.
    func requestHistoricalSync(from startDate: Date, to endDate: Date) async throws
        -> HistoricalSyncOutcome
    {
        HistoricalSyncOutcome(recordCount: 0, batchCount: 0, ending: .aborted)
    }
}

/// The card's transport, with counters instead of a lock screen.
///
/// `LiveActivityControlling`'s whole point is that it is a seam, and this is the other side of it:
/// what §18 asserts is **when** the use case pushes and **what** it pushes, neither of which the real
/// controller can be asked. It is `@MainActor` and `Sendable` because the protocol is — a `@MainActor`
/// class is `Sendable` without saying so, which is precisely why the protocol refines both.
///
/// `nonisolated init()` with every property carrying its own value, exactly as `LiveActivityController`
/// is built: a `@MainActor` class cannot assign an isolated stored property from a nonisolated
/// initialiser, and this one has to be constructible from the suite's nonisolated context.
@MainActor
final class SpyLiveActivityController: LiveActivityControlling {

    /// Thrown by `start` when `refusesStart` is set. The refusal is the one the real controller can
    /// produce — Live Activities switched off, too many, or `NSSupportsLiveActivities` missing — and
    /// the session must record through all three.
    struct Refused: Error {}

    private(set) var startCount = 0
    private(set) var updateCount = 0
    private(set) var endCount = 0
    private(set) var endOrphansCount = 0

    /// Every state pushed, in order, so a block can assert *what* went to the card and not only how
    /// often — the two figures on the card and on the screen come off one snapshot, and this is what
    /// proves they cannot disagree.
    private(set) var pushedStates: [LiveSessionActivityState] = []

    /// Set by the refusal block. A `var` on the main actor rather than an initialiser argument, for
    /// the isolation reason above.
    var refusesStart = false

    nonisolated init() {}

    var isSupported: Bool { true }

    func start(state: LiveSessionActivityState) throws {
        startCount += 1
        if refusesStart { throw Refused() }
    }

    func update(state: LiveSessionActivityState) async {
        updateCount += 1
        pushedStates.append(state)
    }

    func end(state: LiveSessionActivityState) async {
        endCount += 1
        pushedStates.append(state)
    }

    func endOrphans() async -> Int {
        endOrphansCount += 1
        return 1
    }
}

/// The GPS, with a continuation instead of a satellite.
///
/// §18 cannot construct a `CLLocationManager` — see the gotcha about `CBCentralManager` raising a
/// system prompt mid-run — and would not want to: the real service's whole value is that it talks to
/// the system, and none of what is asserted below is a fact about CoreLocation. What a spy can answer
/// is what this block is about: whether the session asked, what it asked, and whether the instance
/// that started the fixes is the one that stopped them.
///
/// Three properties are settable rather than initialiser arguments, and `nonisolated init()` with
/// every stored property carrying its own value, for the reason `SpyLiveActivityController` gives
/// above: a `@MainActor` class cannot assign an isolated stored property from a nonisolated
/// initialiser, and the suite builds these from a nonisolated context.
@MainActor
final class SpyLocationTracking: LocationTracking {

    /// The answer `permission` gives before anything is asked. `.undetermined` is the interesting
    /// one: it is what forces `requestPermission()` to be consulted at all.
    var permission: LocationPermission = .authorized

    /// What the request resolves to. Set apart from `permission` so a block can drive "the user was
    /// asked and said no", which is a different situation from "the user said no earlier" — the
    /// session takes the same branch, but only the first one proves the prompt path was entered.
    var permissionAfterRequest: LocationPermission = .authorized

    private(set) var requestPermissionCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// When set, `start()` hands back a stream that is **already finished**, so a caller waiting for a
    /// fix sees the wait end at once rather than at its own timeout.
    ///
    /// It exists for one branch and one only: the offline map's "no position fix" refusal. That wait is
    /// ten seconds by design (`offlineMapFixTimeoutSeconds`), so the alternative to this flag is a
    /// block that makes the suite ten seconds slower — and a suite that pays that for one sentence is a
    /// suite whose next author trims the block. Defaulted off, so no existing assertion moves: every
    /// other block wants a stream it can push fixes into.
    var finishesStreamImmediately = false

    /// The live stream's continuation, held so `yield` can push a fix through it the way
    /// `locationManager(_:didUpdateLocations:)` does. `= nil` is required by the `nonisolated init`
    /// below, exactly as it is on `LiveActivityController`.
    private var continuation: AsyncStream<WorkoutRoutePoint>.Continuation? = nil

    nonisolated init() {}

    func requestPermission() async -> LocationPermission {
        requestPermissionCount += 1
        permission = permissionAfterRequest
        return permission
    }

    func start() -> AsyncStream<WorkoutRoutePoint> {
        startCount += 1
        // See the flag's own comment: a stream that ends the moment it is read is how a block reaches
        // the caller's "the fix never arrived" branch without sleeping through its timeout.
        if finishesStreamImmediately { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    /// Pushes one fix through the stream the session is reading, and reports whether anyone was
    /// attached to receive it. `false` is not a failure — it is how a block asserts that a fix was
    /// *not* delivered, because the GPS was never started or had already been released.
    @discardableResult
    func yield(latitude: Double, longitude: Double, timestamp: Date = Date()) -> Bool {
        guard let continuation else { return false }
        continuation.yield(WorkoutRoutePoint(
            latitude: latitude, longitude: longitude, timestamp: timestamp, heartRate: 0))
        return true
    }
}

/// The offline map, in a build that has none — the runner's stand-in for Mapbox.
///
/// **The suite must not construct a Mapbox type, and in this build it cannot**: the SDK lives in
/// `App/Map/`, which only the Xcode app target compiles, so `MapboxOfflineMaps` is not a symbol this
/// file could name whatever it was handed. That makes the spy *necessary* rather than merely
/// convenient — but the reason it must be a spy and not a real implementation is the one the runner
/// already applies to `CLLocationManager` and `CBCentralManager`: a real one downloads over the
/// network through a `TileStore` and needs a secret token merely to build, so a block that drove one
/// would pass or fail on this machine's connection and on whether a credential file happens to exist.
/// Neither is a fact about this app.
///
/// **Its answers are not placeholders.** `isSupported` is `false`, which is what the runner's build
/// actually is, and `state(for:)` reads back whatever a block put there — so the type's whole purpose
/// is that a block can place a region in `.ready` and assert that a session naming it resolves to
/// `.offline`, the one branch that draws Mapbox, without a tile ever being fetched.
///
/// `nonisolated init()` for `SpyLocationTracking`'s reason: it is constructed in the argument list of
/// a `nonisolated` initialiser, and every stored property below has a default so there is nothing for
/// the main actor to protect at that moment.
@MainActor
final class SpyOfflineMaps: OfflineMapRendering {

    /// What the build is. `false` by default because that is the truth here, and a block that wants the
    /// supported path says so explicitly rather than the other way round — a default of `true` would
    /// make every existing fixture silently claim a capability this build does not have.
    var isSupported = false

    /// The store, keyed by region id. Absent means `.absent`, which is the real service's own fallback
    /// rather than something a block has to seed.
    var states: [String: OfflineMapState] = [:]

    /// The fractions a download reports, in order, through `onProgress` before it returns. Left empty
    /// by default: a real download may report nothing at all, and a block that wants the `.downloading`
    /// card to move has to say which values it moved through.
    var progressValues: [Double] = []

    /// When set, a download reports its progress and then waits instead of finishing, leaving the region
    /// in `.downloading`.
    ///
    /// That is the state `LiveSessionUseCase` is documented to call `cancelDownload()` in and no other,
    /// so a block has to be able to hold a download open to reach it — the switch is turned off while
    /// the download is genuinely in flight rather than a moment after it landed. `Task.sleep` rather
    /// than a continuation because **cancellation is the release**: the use case cancels its own task,
    /// the sleep throws, and the download returns with nothing for the block to signal. Thirty seconds
    /// is a bound on a hung case, not a wait anybody performs.
    var holdsDownloadOpen = false

    private(set) var downloadCount = 0
    private(set) var cancelledCount = 0
    private(set) var deletedRegionIDs: [String] = []

    /// The centre the last download was asked for, so a block can assert that the switch asked about
    /// the user's actual position rather than about a constant. Two separate fields rather than a
    /// labelled tuple, because an optional tuple is not `Equatable` and the comparison would have to be
    /// taken apart at the call site anyway.
    private(set) var lastLatitude: Double?
    private(set) var lastLongitude: Double?

    nonisolated init() {}

    func state(for regionID: String) -> OfflineMapState { states[regionID] ?? .absent }

    /// Records the call, reports the configured progress, and lands the region in `.ready` — the only
    /// state `RouteMapRenderer.resolve` will draw, so the state a block cares about is the one a
    /// successful download actually produces.
    func download(
        regionID: String,
        latitude: Double,
        longitude: Double,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async {
        downloadCount += 1
        lastLatitude = latitude
        lastLongitude = longitude
        for value in progressValues { onProgress(value) }
        if holdsDownloadOpen {
            try? await Task.sleep(for: .seconds(30))
            return
        }
        states[regionID] = .ready
    }

    func cancelDownload() { cancelledCount += 1 }

    func delete(regionID: String) async {
        deletedRegionIDs.append(regionID)
        states[regionID] = nil
    }

    /// The same card `UnavailableOfflineMaps` draws, and it is never called by the suite: the runner
    /// has no renderer, so nothing here evaluates a `body`. Returning the MapKit view rather than an
    /// `EmptyView` keeps the spy honest about what the branch it stands for draws.
    func map(route: ActivityRoute, unit: ActivityRoute.Unit, regionID: String) -> AnyView {
        AnyView(ActivityRouteMapView(route: route, unit: unit))
    }
}

/// The stored fast, in a field instead of `UserDefaults`.
///
/// **The suite must not be handed `UserDefaultsActiveFastRepository`**, and the reason is the same one
/// that keeps §6 off the real database: `LiveSessionUseCase` restores from this store in its
/// initialiser, so a session built over `.standard` would read — and, on `startFast()`, overwrite — the
/// fast belonging to whoever is running the suite on this machine. That is a mutation of real state,
/// and it is invisible, because a stray fast would surface as a bar over a recording nobody started.
///
/// **It counts as well as stores**, which is what makes persistence assertable at all: "the fast came
/// back after a relaunch" is otherwise a claim only a human with a phone can check, while
/// `saves == 1` and `saves == 0` are the two halves of `startFast()` and `endFast()` writing and
/// clearing exactly once. `NSLock` rather than `@MainActor` because `load()` is called from the use
/// case's `nonisolated init`, which the protocol requires to be synchronous.
final class SpyActiveFastRepository: ActiveFastRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ActiveFast?
    private var saveCount = 0
    private var clearCount = 0

    init(seed: ActiveFast? = nil) { self.stored = seed }

    var saved: ActiveFast? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var saves: Int {
        lock.lock(); defer { lock.unlock() }
        return saveCount
    }

    var clears: Int {
        lock.lock(); defer { lock.unlock() }
        return clearCount
    }

    func load() -> ActiveFast? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ fast: ActiveFast) {
        lock.lock(); defer { lock.unlock() }
        saveCount += 1
        stored = fast
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        clearCount += 1
        stored = nil
    }
}

/// A `WorkoutRepository` whose `save` **parks until it is let go**.
///
/// **This exists to make one ordering observable, and it is the only way that ordering is observable
/// at all.** `endFast()` clears the live fast and the stored copy *above* its first `await`, so that a
/// bar drawn from `activeFast` stops the instant END FAST is pressed rather than a SQLite write later.
/// Against any real repository that window is invisible: the save returns before an assertion can run,
/// so a build that cleared the state *below* the save would pass every other assertion in §18 while
/// leaving the bar counting over Home through the write — and leaving a second END FAST callable in
/// that window, which writes a duplicate row under a fresh `UUID`.
///
/// So the save blocks. `awaitSaveEntered()` waits until the write has been *reached*, and the
/// assertions run at exactly that moment — the state a user would be looking at mid-write.
///
/// **An actor and not a lock-guarded class**, because the parking is `async`: the flag and the
/// continuation are assigned in one actor-isolated region with no intervening `await`, so by the time
/// `awaitSaveEntered()` observes the flag the continuation is certainly set and `open()` cannot
/// resume `nil` and hang the suite. An `NSLock` around an `await` would be a data race rather than a
/// guard.
actor GatedWorkoutRepository: WorkoutRepository {
    private(set) var saved: [WorkoutSession] = []
    private var release: CheckedContinuation<Void, Never>?
    private var didEnterSave = false

    func save(_ workout: WorkoutSession) async throws {
        saved.append(workout)
        didEnterSave = true
        await withCheckedContinuation { self.release = $0 }
    }

    /// Spins until `save` has been entered and is parked.
    ///
    /// `Task.yield()` rather than a sleep: the work being waited on is this process's own, so yielding
    /// hands it the executor directly instead of guessing how long it needs.
    func awaitSaveEntered() async {
        while !didEnterSave { await Task.yield() }
    }

    /// Lets the parked save return.
    func open() {
        release?.resume()
        release = nil
    }

    // The reads answer from what was written rather than from a database, because the only thing this
    // fixture is used for is the write path — a `nil` here is "no row" and not a missing feature.
    func latest() async throws -> WorkoutSession? { saved.last }
    func getWorkouts(for date: Date) async throws -> [WorkoutSession] { [] }
    func getWorkouts(covering date: Date) async throws -> [WorkoutSession] { [] }
    func getWorkoutHistory(days: Int, endingOn: Date) async throws -> [WorkoutSession] { [] }
    func delete(_ id: UUID) async throws -> Bool { false }
}

/// Spins until `condition` holds, or gives up after `timeout`.
///
/// The suite is a linear script and the work it waits on runs in a `Task` the use case owns, so there
/// is nothing to `await` directly — this side can only observe the result. A bounded spin is the
/// honest instrument: an unbounded one turns a regression into a hang, and a fixed `sleep` turns a
/// slow machine into a failure.
func waitUntil(timeout: TimeInterval = 5.0, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if await condition() { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// One `MotionBatch` carrying `bumps` acceleration transients on the x axis.
///
/// **A bump train rather than a sine, and the count is why** — §16's reasoning, restated because the
/// waveform is what makes the number `12` an assertion rather than an artefact: `|sin|` at 2 Hz peaks
/// four times a second and the 1/3 s refractory rejects every other one, so a sine's count is a
/// property of that interaction. Isolated Gaussian bumps 0.5 s apart at σ = 4 samples never merge.
///
/// **The two-second lead-in is not decoration either.** `StepDetectionMath.Detector` judges a peak
/// against a threshold window that *includes the sample under test*, so a bump arriving into an empty
/// window faces a level near its own peak and passes whatever the rule is; two seconds of still wrist
/// fills the window first and drops the level to the 0.05 g floor.
///
/// `sampleIntervalSeconds` is `0.01`, so the batch is 100 Hz and `StepAccumulator` builds its detector
/// at that rate — which is the whole reason `LiveSessionUseCase` reads the rate off the batch it was
/// handed rather than declaring one.
func motionBatch(startingAt start: Date, bumps: Int) -> MotionBatch {
    let interval = 0.01
    let leadInSeconds = 2.0
    let periodSeconds = 0.5
    let amplitudeG = 0.3
    let sigma = 0.04
    let total = leadInSeconds + Double(max(bumps - 1, 0)) * periodSeconds + 0.4
    let count = Int((total / interval).rounded()) + 1

    let x = (0..<count).map { index -> Double in
        let seconds = Double(index) * interval
        var value = 1.0
        for bump in 0..<bumps {
            let distance = seconds - (leadInSeconds + Double(bump) * periodSeconds)
            value += amplitudeG * exp(-(distance * distance) / (2 * sigma * sigma))
        }
        return value
    }
    let still = [Double](repeating: 0, count: count)

    return MotionBatch(
        generation: .whoop4,
        start: start,
        // A live batch, not a banked one: the strap's own absolute time is a property of a flash
        // record, and this is the shape a session receives while it is recording.
        timestampIsFromStrap: false,
        sampleIntervalSeconds: interval,
        accelerometerG: MotionAxes(x: x, y: still, z: still),
        gyroscopeDps: nil)
}
