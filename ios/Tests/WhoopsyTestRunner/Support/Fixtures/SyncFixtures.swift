import Foundation
import Whoopsy

/// The boundary a test asked for, held in memory for the length of one section.
///
/// **It exists because the real store cannot be used from here.** `UserDefaultsSyncSettingsRepository`
/// reads `UserDefaults.standard` under `org.whoopsy.sync`, which on a developer's machine is whatever
/// the last simulator run left there — so a section built on it would open a database and skip days
/// according to state the test did not set, and pass or fail by accident. This answers the same two
/// questions from a value the fixture owns.
///
/// **An `actor`, on `KeychainSyncKeyStore`'s and `SyncStatusLog`'s reasoning**: the destination is read
/// from whatever task is awaiting a call and written from another, and one `load`-then-`save` pair is the
/// shape an actor makes one uninterrupted turn rather than something the caller has to arrange. It is
/// also what makes the type `Sendable` honestly instead of by `@unchecked`, which is the one place these
/// fixtures are allowed to be strict.
///
/// The default is `SyncSettings()` — one destination, this phone, and no span drawn — which is the state
/// a fresh install is in and the one the pane opens on. That is what the other sections' blocks want:
/// they are about parsing, day keys and the walk's arithmetic, and a destination nobody chose should not
/// be a variable in any of them.
actor InMemorySyncSettingsRepository: SyncSettingsRepository {

    private var settings: SyncSettings

    /// How many times `save` has been called. Kept because the sync use case's contract is partly about
    /// *when* it writes — the boundary advances after each landed chunk, never before it — and a
    /// fixture that only holds the final value cannot see the difference between one write and five.
    private(set) var saveCount = 0

    init(_ settings: SyncSettings = SyncSettings()) {
        self.settings = settings
    }

    func load() async -> SyncSettings { settings }

    func save(_ settings: SyncSettings) async {
        self.settings = settings
        saveCount += 1
    }
}

/// A database, in a dictionary and a list of calls.
///
/// **`CloudSync` is the app's only network seam and this is the other side of it**, so a block can
/// answer as the server would, refuse as it would, and — the part no real client can offer — say
/// afterwards exactly what it was asked. Three of §22's blocks are about *whether* and *with what*, not
/// about the answer: the decorator must not call the cloud for `getLocalRecovery` at all, the history
/// split must ask for the head range and only the head range, and the upload must advance the boundary
/// after a chunk lands rather than before it.
///
/// **It is deliberately not `HTTPCloudSync` with a stubbed `URLSession`.** That would put the wire's
/// exact spelling — a `YYYY-MM-DD` body, a JSON envelope, a status code — between the assertion and the
/// claim, so a block about the *decorator's* routing would fail when a header changed. The mapper has
/// its own file and its own block for the wire's shape; this one answers in `RecoverySyncRow`, which is
/// the same currency the local database deals in.
///
/// **Its rows are keyed by `startOfDay`,** because every other day-keyed thing in this app is, and a
/// fixture that keyed them on the raw instant would let a caller that forgot to snap pass here and fail
/// on a real database — the `LocalDatabaseManager` day-key rule, restated in the one fixture that could
/// silently disagree with it.
///
/// An `actor`, for `InMemorySyncSettingsRepository`'s reason and one more: `SyncEngine`
/// reads it from one task while another may be awaiting a write, and the record of calls has to be one
/// uninterrupted list rather than something two tasks append to concurrently.
actor SpyCloudSync: CloudSync {

    /// One call, as a value the suite can compare.
    ///
    /// A `switch` over these is how a block says *this happened and that did not* — most importantly the
    /// decorator's discipline, where the assertion is that the list is empty. A bare counter could not
    /// distinguish "the cloud was asked for the right range" from "the cloud was asked twice".
    ///
    /// **The last seven cases are all writes, and that asymmetry is the port's rather than this
    /// fixture's.** `recoveries`, `strains` and `workouts` are read *and* written; `sleeps`,
    /// `stepCounts`, `receptiveInactivities` and the profile are written only, because the app has no
    /// reader for a night, a step count, an entry or a profile that came from the server — the local
    /// database is the one source for all four. So there is no `.sleep(day:)` here to leave out, and a
    /// block that wanted one would be asking for a method `CloudSync` does not have.
    enum Call: Equatable, Sendable {
        case recovery(day: Date)
        case recoveries(from: Date, to: Date)
        case writeRecovery(RecoverySyncRow)
        case writeRecoveries([RecoverySyncRow])
        case strain(day: Date)
        case strains(from: Date, to: Date)
        case writeStrain(StrainSyncRow)
        case writeStrains([StrainSyncRow])
        case workout(id: UUID)
        case workouts(from: Date, to: Date)
        case writeWorkout(WorkoutSyncRow)
        case writeWorkouts([WorkoutSyncRow])
        case writeSleep(SleepSyncRow)
        case writeSleeps([SleepSyncRow])
        case writeStepCount(StepCountSyncRow)
        case writeStepCounts([StepCountSyncRow])
        case writeReceptiveInactivity(ReceptiveInactivitySyncRow)
        case writeReceptiveInactivities([ReceptiveInactivitySyncRow])
        case writeProfile(UserProfileSyncRow)
    }

    /// Every call, in order. **Empty is the assertion for `getLocalRecovery`**, and it is asserted
    /// rather than enforced here: a fixture that tripped the runner's own `assertTest` from inside a
    /// helper would report a failure against this file's line rather than the block's, and would kill
    /// the section before the block could say which call it saw.
    private(set) var calls: [Call] = []

    /// What the database holds, by snapped day.
    private var stored: [Date: RecoverySyncRow]

    /// What the database holds of the third resource, **by snapped day like the first**.
    ///
    /// **A `[Date: …]` here where the aggregate next door needs an id, and the difference is the table's.**
    /// A day holds exactly one strain, so the day *is* the key — `strains` is primary-keyed on `date` in
    /// this app and in D1 alike, and there is no second session on a day that a keyed dictionary would
    /// silently overwrite. A fixture that keyed these on anything else would be an implementation of a
    /// different table.
    private var storedStrains: [Date: StrainSyncRow]

    /// What the database holds of the other resource, **by session id**.
    ///
    /// **Keyed on the id and not on a day, which is the whole of what this resource is**: a day holds
    /// one recovery and can hold several sessions, so a `[Date: …]` here would make the second session
    /// on a day overwrite the first — the defect `workouts`' `id` primary key exists to prevent,
    /// restated in the fixture that would otherwise hide it. A block asserting that a two-session day
    /// round-trips would pass against a day-keyed fixture and fail on the real database.
    private var storedWorkouts: [UUID: WorkoutSyncRow]

    /// What the database holds of the nights, **by snapped wake day, like the flat resources**.
    ///
    /// Keyed on the day the row carries rather than recomputed from `startTime` — the one keying rule
    /// this resource adds, and the reason the fixture must not derive it: a night that began before
    /// midnight would land one day early here and the write would look correct against a fixture that
    /// made the same mistake. `SleepSyncRow.date` is *given*, so this is a copy of it and nothing more.
    private var storedSleeps: [Date: SleepSyncRow]

    /// What the database holds of the step counts, by snapped day — one row a day, like a recovery.
    ///
    /// **A zero-length day is a row here and not an absence**, which on this table is the whole
    /// difference: steps say *nothing was measured* with `measuredSeconds == 0` rather than with no row,
    /// so a fixture that skipped such a row would make the two sides of a sync disagree about whether
    /// the day is on disk at all.
    private var storedStepCounts: [Date: StepCountSyncRow]

    /// What the database holds of the entries, **by id** — the second keyed dictionary here, for
    /// `storedWorkouts`' reason and not the flat resources': a day holds several entries, so a
    /// `[Date: …]` would make the second one on a day overwrite the first. The id is the row's own and
    /// is deliberately not reminted, because its determinism is what makes a re-import idempotent.
    private var storedInactivities: [String: ReceptiveInactivitySyncRow]

    /// The one profile the database holds, or `nil` — a singleton, so this is an optional and not a
    /// dictionary. `nil` here means the user has never filled the form in, which is a different thing
    /// from a row of blanks and is the same absence every day-keyed table spells with no row.
    private var storedProfile: UserProfileSyncRow?

    /// What every call throws instead of answering. `nil` — the default — is a database that answers.
    private var failure: CloudSyncError?

    /// What a batch write reports back, when a block wants to pin the wire's own count rather than this
    /// fixture's arithmetic. The real client returns the number the *server* counted, and its doc
    /// comment says a replayed chunk reports the same number rather than zero — so a block that wants to
    /// prove a caller does not read `0` as "nothing to do" has to be able to produce a figure the rows
    /// alone would not give.
    ///
    /// **One knob for every batch write**, on the five resources that have one, because it arms one
    /// *behaviour* rather than one method: a block that set it and then called another resource's write
    /// would expect the same answer, and five fields would be five places to look for it. The profile
    /// has no batch and so cannot consult it — the port gives it a single write that returns nothing.
    private var reportedWriteCount: Int?

    /// - Parameters:
    ///   - rows: what the database holds to begin with, of the flat resource.
    ///   - workouts: what it holds of the aggregate one. A second parameter rather than one array of an
    ///     enum, because the two resources are two dictionaries in here as well as two methods out
    ///     there, and a block that seeded both would otherwise have to say which kind each row was.
    ///   - strains: what it holds of the third, keyed by day as the first is. A third parameter for the
    ///     same reason: one array of an enum would make a block say which resource each row was, and the
    ///     three row types share no protocol to be erased to.
    ///   - sleeps: what it holds of the nights, keyed by wake day.
    ///   - stepCounts: what it holds of the step counts, keyed by day.
    ///   - inactivities: what it holds of the entries, keyed by id.
    ///   - profile: the one profile it holds, or `nil` for a database whose user has never filled the
    ///     form in. An optional rather than an array of zero or one, because that is what the table is.
    ///   - failure: armed from the start, for a block whose very first call must fail.
    ///
    /// **Four more parameters rather than one array of an enum**, which is the argument the first three
    /// already make: the row types share no protocol to be erased to, so a single list would make every
    /// caller say which resource each element was. The defaults are what keep this a single-argument
    /// initialiser at the one call site that only seeds recoveries.
    init(
        rows: [RecoverySyncRow] = [],
        workouts: [WorkoutSyncRow] = [],
        strains: [StrainSyncRow] = [],
        sleeps: [SleepSyncRow] = [],
        stepCounts: [StepCountSyncRow] = [],
        inactivities: [ReceptiveInactivitySyncRow] = [],
        profile: UserProfileSyncRow? = nil,
        failure: CloudSyncError? = nil
    ) {
        var seeded: [Date: RecoverySyncRow] = [:]
        for row in rows { seeded[row.date.startOfDay] = row }
        self.stored = seeded
        var seededWorkouts: [UUID: WorkoutSyncRow] = [:]
        for row in workouts { seededWorkouts[row.id] = row }
        self.storedWorkouts = seededWorkouts
        var seededStrains: [Date: StrainSyncRow] = [:]
        for row in strains { seededStrains[row.date.startOfDay] = row }
        self.storedStrains = seededStrains
        var seededSleeps: [Date: SleepSyncRow] = [:]
        for row in sleeps { seededSleeps[row.date.startOfDay] = row }
        self.storedSleeps = seededSleeps
        var seededStepCounts: [Date: StepCountSyncRow] = [:]
        for row in stepCounts { seededStepCounts[row.date.startOfDay] = row }
        self.storedStepCounts = seededStepCounts
        var seededInactivities: [String: ReceptiveInactivitySyncRow] = [:]
        for row in inactivities { seededInactivities[row.id] = row }
        self.storedInactivities = seededInactivities
        self.storedProfile = profile
        self.failure = failure
    }

    // MARK: - Arming

    /// Refuse every call from here on, with this error.
    ///
    /// A setter rather than an initialiser argument alone, because the interesting degradation cases are
    /// *sequences*: the same day read successfully and then read with the server down, so a block can
    /// show that a stale mark is cleared by a good answer and set by a bad one rather than only that the
    /// bad one sets it.
    func fail(with error: CloudSyncError?) { failure = error }

    /// Report this count from either batch write, whatever was actually written. `nil` restores the
    /// fixture's own `rows.count`.
    func reportWriteCount(_ count: Int?) { reportedWriteCount = count }

    // MARK: - What a block reads back

    /// The days the database holds, so a block can assert what an upload actually landed.
    var storedDays: Set<Date> { Set(stored.keys) }

    /// The row the database holds for a day, or `nil`.
    func storedRow(on day: Date) -> RecoverySyncRow? { stored[day.startOfDay] }

    /// Every row handed to any write, in order, across both write methods.
    ///
    /// **The workouts cases return nothing here** rather than being folded in under a common protocol:
    /// the two resources' rows are two types, so a single flat-mapped list of "everything written" would
    /// have to be a list of `Any`. `writtenWorkouts` below is this property's counterpart.
    var writtenRows: [RecoverySyncRow] {
        calls.flatMap { call -> [RecoverySyncRow] in
            switch call {
            case .writeRecovery(let row): return [row]
            case .writeRecoveries(let rows): return rows
            case .recovery, .recoveries, .strain, .strains, .writeStrain, .writeStrains,
                 .workout, .workouts, .writeWorkout, .writeWorkouts,
                 .writeSleep, .writeSleeps, .writeStepCount, .writeStepCounts,
                 .writeReceptiveInactivity, .writeReceptiveInactivities, .writeProfile: return []
            }
        }
    }

    /// Every day handed to any strain write, in order, across both of that resource's write methods.
    var writtenStrains: [StrainSyncRow] {
        calls.flatMap { call -> [StrainSyncRow] in
            switch call {
            case .writeStrain(let row): return [row]
            case .writeStrains(let rows): return rows
            case .recovery, .recoveries, .strain, .strains,
                 .writeRecovery, .writeRecoveries,
                 .workout, .workouts, .writeWorkout, .writeWorkouts,
                 .writeSleep, .writeSleeps, .writeStepCount, .writeStepCounts,
                 .writeReceptiveInactivity, .writeReceptiveInactivities, .writeProfile: return []
            }
        }
    }

    /// Every session handed to any write, in order, across both of the aggregate's write methods.
    var writtenWorkouts: [WorkoutSyncRow] {
        calls.flatMap { call -> [WorkoutSyncRow] in
            switch call {
            case .writeWorkout(let row): return [row]
            case .writeWorkouts(let rows): return rows
            case .recovery, .recoveries, .strain, .strains, .writeStrain, .writeStrains,
                 .workout, .workouts, .writeRecovery, .writeRecoveries,
                 .writeSleep, .writeSleeps, .writeStepCount, .writeStepCounts,
                 .writeReceptiveInactivity, .writeReceptiveInactivities, .writeProfile: return []
            }
        }
    }

    /// The ranges `recoveries(from:to:)` was asked for, in order — the history split's evidence.
    var readRanges: [(from: Date, to: Date)] {
        calls.compactMap { call in
            guard case let .recoveries(from, to) = call else { return nil }
            return (from, to)
        }
    }

    /// The days `recovery(on:)` was asked for, in order.
    var readDays: [Date] {
        calls.compactMap { call in
            guard case let .recovery(day) = call else { return nil }
            return day
        }
    }

    /// The session ids the database holds, so a block can assert what an upload actually landed.
    var storedWorkoutIds: Set<UUID> { Set(storedWorkouts.keys) }

    /// The row the database holds for a session id, or `nil`.
    func storedWorkout(id: UUID) -> WorkoutSyncRow? { storedWorkouts[id] }

    /// The ranges `workouts(from:to:)` was asked for, in order — the chunk walk's evidence.
    var readWorkoutRanges: [(from: Date, to: Date)] {
        calls.compactMap { call in
            guard case let .workouts(from, to) = call else { return nil }
            return (from, to)
        }
    }

    /// The ids `workout(id:)` was asked for, in order.
    var readWorkoutIds: [UUID] {
        calls.compactMap { call in
            guard case let .workout(id) = call else { return nil }
            return id
        }
    }

    /// The days the database holds of the third resource — the flat read-back, beside `storedDays`.
    var storedStrainDays: Set<Date> { Set(storedStrains.keys) }

    /// The row the database holds for a strain day, or `nil`.
    ///
    /// Snap the argument here for `storedRow(on:)`'s reason: this is the read a block uses to check that
    /// an upload landed on the day it claimed, and a raw instant would look up a key no writer ever set.
    func storedStrain(on day: Date) -> StrainSyncRow? { storedStrains[day.startOfDay] }

    /// The ranges `strains(from:to:)` was asked for, in order.
    var readStrainRanges: [(from: Date, to: Date)] {
        calls.compactMap { call in
            guard case let .strains(from, to) = call else { return nil }
            return (from, to)
        }
    }

    /// The days `strain(on:)` was asked for, in order.
    var readStrainDays: [Date] {
        calls.compactMap { call in
            guard case let .strain(day) = call else { return nil }
            return day
        }
    }

    // MARK: - What a block reads back, the write-only resources

    /// The nights the database holds, so a block can assert what an upload actually landed.
    var storedSleepDays: Set<Date> { Set(storedSleeps.keys) }

    /// The night the database holds for a wake day, or `nil`. Snapped, for `storedRow(on:)`'s reason.
    func storedSleep(on day: Date) -> SleepSyncRow? { storedSleeps[day.startOfDay] }

    /// Every night handed to either sleep write, in order.
    ///
    /// **Exhaustive rather than `default`-armed, on the three collectors above.** A `default` arm would
    /// make a *new* `CloudSync` case silently invisible to every read-back in this file, which is the
    /// opposite of what these switches are for: the compiler is what makes a block author decide
    /// whether the new call is one this property should collect.
    var writtenSleeps: [SleepSyncRow] {
        calls.flatMap { call -> [SleepSyncRow] in
            switch call {
            case .writeSleep(let row): return [row]
            case .writeSleeps(let rows): return rows
            case .recovery, .recoveries, .writeRecovery, .writeRecoveries,
                 .strain, .strains, .writeStrain, .writeStrains,
                 .workout, .workouts, .writeWorkout, .writeWorkouts,
                 .writeStepCount, .writeStepCounts,
                 .writeReceptiveInactivity, .writeReceptiveInactivities,
                 .writeProfile: return []
            }
        }
    }

    /// The days the database holds step counts for — including a zero-length day, which is a row here.
    var storedStepCountDays: Set<Date> { Set(storedStepCounts.keys) }

    /// The step count the database holds for a day, or `nil`.
    func storedStepCount(on day: Date) -> StepCountSyncRow? { storedStepCounts[day.startOfDay] }

    /// Every day handed to either step-count write, in order.
    var writtenStepCounts: [StepCountSyncRow] {
        calls.flatMap { call -> [StepCountSyncRow] in
            switch call {
            case .writeStepCount(let row): return [row]
            case .writeStepCounts(let rows): return rows
            case .recovery, .recoveries, .writeRecovery, .writeRecoveries,
                 .strain, .strains, .writeStrain, .writeStrains,
                 .workout, .workouts, .writeWorkout, .writeWorkouts,
                 .writeSleep, .writeSleeps,
                 .writeReceptiveInactivity, .writeReceptiveInactivities,
                 .writeProfile: return []
            }
        }
    }

    /// The entry ids the database holds, so a block can assert that a replayed chunk replaced rather
    /// than appended — the property the import's derived ids exist to give.
    var storedInactivityIds: Set<String> { Set(storedInactivities.keys) }

    /// The entry the database holds for an id, or `nil`.
    func storedInactivity(id: String) -> ReceptiveInactivitySyncRow? { storedInactivities[id] }

    /// Every entry handed to either inactivity write, in order.
    var writtenInactivities: [ReceptiveInactivitySyncRow] {
        calls.flatMap { call -> [ReceptiveInactivitySyncRow] in
            switch call {
            case .writeReceptiveInactivity(let row): return [row]
            case .writeReceptiveInactivities(let rows): return rows
            case .recovery, .recoveries, .writeRecovery, .writeRecoveries,
                 .strain, .strains, .writeStrain, .writeStrains,
                 .workout, .workouts, .writeWorkout, .writeWorkouts,
                 .writeSleep, .writeSleeps,
                 .writeStepCount, .writeStepCounts,
                 .writeProfile: return []
            }
        }
    }

    /// The profile the database holds, or `nil` for one it has never been given.
    var storedProfileRow: UserProfileSyncRow? { storedProfile }

    /// Every profile handed to the write. A list rather than the last value, because the port has one
    /// single-row write and a block's question is usually *how many times* it was called.
    var writtenProfiles: [UserProfileSyncRow] {
        calls.compactMap { call in
            guard case let .writeProfile(row) = call else { return nil }
            return row
        }
    }

    // MARK: - CloudSync

    func recovery(on day: Date) async throws -> RecoverySyncRow? {
        calls.append(.recovery(day: day.startOfDay))
        try refuseIfArmed()
        return stored[day.startOfDay]
    }

    /// Half-open `[from, to)`, ascending — the protocol's own convention rather than the wire's.
    func recoveries(from: Date, to: Date) async throws -> [RecoverySyncRow] {
        calls.append(.recoveries(from: from, to: to))
        try refuseIfArmed()
        let lower = from.startOfDay
        let upper = to.startOfDay
        return stored.values
            .filter { $0.date.startOfDay >= lower && $0.date.startOfDay < upper }
            .sorted { $0.date < $1.date }
    }

    func writeRecovery(_ row: RecoverySyncRow) async throws {
        calls.append(.writeRecovery(row))
        try refuseIfArmed()
        stored[row.date.startOfDay] = row
    }

    func writeRecoveries(_ rows: [RecoverySyncRow]) async throws -> Int {
        calls.append(.writeRecoveries(rows))
        try refuseIfArmed()
        for row in rows { stored[row.date.startOfDay] = row }
        return reportedWriteCount ?? rows.count
    }

    // MARK: - CloudSync, the second flat resource

    /// The day's row, or `nil` for a day the database holds nothing for.
    ///
    /// **This fixture answers `nil` for an *absent* day and a row for an unmeasured one, and that
    /// distinction is the whole of what the strains wire carries.** Unlike `stored[day]`, which is a
    /// dictionary lookup that could not tell the two apart, this method is where a block proves the
    /// download path treats a `hasMeasurement: false` row as a row — the server's `404` is the only
    /// thing that becomes a `nil` on the real client, not the flag.
    func strain(on day: Date) async throws -> StrainSyncRow? {
        calls.append(.strain(day: day.startOfDay))
        try refuseIfArmed()
        return storedStrains[day.startOfDay]
    }

    /// Half-open `[from, to)`, ascending — `recoveries(from:to:)`'s convention rather than the wire's.
    func strains(from: Date, to: Date) async throws -> [StrainSyncRow] {
        calls.append(.strains(from: from, to: to))
        try refuseIfArmed()
        let lower = from.startOfDay
        let upper = to.startOfDay
        return storedStrains.values
            .filter { $0.date.startOfDay >= lower && $0.date.startOfDay < upper }
            .sorted { $0.date < $1.date }
    }

    func writeStrain(_ row: StrainSyncRow) async throws {
        calls.append(.writeStrain(row))
        try refuseIfArmed()
        storedStrains[row.date.startOfDay] = row
    }

    /// A plain upsert per day, with no children to replace — the store's own contract, restated: a
    /// strain has no route and no splits, so there is nothing here that a second write could leave
    /// behind the way a session's stale route would be left behind by a merge.
    func writeStrains(_ rows: [StrainSyncRow]) async throws -> Int {
        calls.append(.writeStrains(rows))
        try refuseIfArmed()
        for row in rows { storedStrains[row.date.startOfDay] = row }
        return reportedWriteCount ?? rows.count
    }

    // MARK: - CloudSync, the aggregate resource

    func workout(id: UUID) async throws -> WorkoutSyncRow? {
        calls.append(.workout(id: id))
        try refuseIfArmed()
        return storedWorkouts[id]
    }

    /// Half-open `[from, to)`, matching the protocol — and ordered by **day, then start, then id**,
    /// which is the protocol's own order and not this fixture's choice.
    ///
    /// **The filter is on the snapped day and not on the instant**, exactly as `recoveries(from:to:)`
    /// filters: a row stored with a raw `date` therefore still lands in the right window, which is what
    /// keeps this fixture from being the place a caller that failed to snap passes.
    func workouts(from: Date, to: Date) async throws -> [WorkoutSyncRow] {
        calls.append(.workouts(from: from, to: to))
        try refuseIfArmed()
        let lower = from.startOfDay
        let upper = to.startOfDay
        return storedWorkouts.values
            .filter { $0.date.startOfDay >= lower && $0.date.startOfDay < upper }
            .sorted(by: Self.oldestFirst)
    }

    func writeWorkout(_ row: WorkoutSyncRow) async throws {
        calls.append(.writeWorkout(row))
        try refuseIfArmed()
        storedWorkouts[row.id] = row
    }

    /// Replaces each session wholesale, children included — the replacement semantics the protocol
    /// carries, so a row written with an empty `route` really does leave the session with none here as
    /// well as on the server.
    func writeWorkouts(_ rows: [WorkoutSyncRow]) async throws -> Int {
        calls.append(.writeWorkouts(rows))
        try refuseIfArmed()
        for row in rows { storedWorkouts[row.id] = row }
        return reportedWriteCount ?? rows.count
    }

    // MARK: - CloudSync, the write-only resources

    /// The four resources the app only ever sends.
    ///
    /// **Their writes are upserts on the same keys the flat resources use**, and each is here rather
    /// than in a second spy because `CloudSync` is one port: a block proving that the engine sends
    /// sleeps and does *not* send steps needs both on one call list, and two doubles would be two lists
    /// with no order between them.
    ///
    /// **`writeProfile` returns nothing**, because the port's profile write is a single row with no
    /// batch — so there is no count to report and `reportedWriteCount`, which arms a *batch*'s answer,
    /// is deliberately not consulted here.

    func writeSleep(_ row: SleepSyncRow) async throws {
        calls.append(.writeSleep(row))
        try refuseIfArmed()
        storedSleeps[row.date.startOfDay] = row
    }

    /// A plain upsert per night, keyed on the row's own wake day — the day is *given* and is not
    /// recomputed from `startTime`, which is the one thing this resource's writer must not do.
    func writeSleeps(_ rows: [SleepSyncRow]) async throws -> Int {
        calls.append(.writeSleeps(rows))
        try refuseIfArmed()
        for row in rows { storedSleeps[row.date.startOfDay] = row }
        return reportedWriteCount ?? rows.count
    }

    func writeStepCount(_ row: StepCountSyncRow) async throws {
        calls.append(.writeStepCount(row))
        try refuseIfArmed()
        storedStepCounts[row.date.startOfDay] = row
    }

    /// A zero-length day is stored like any other here. Unlike `StepCountWireMapper.isSendable`, which
    /// refuses to *send* one, the write itself accepts it — those are two different questions and the
    /// fixture answers the storage one.
    func writeStepCounts(_ rows: [StepCountSyncRow]) async throws -> Int {
        calls.append(.writeStepCounts(rows))
        try refuseIfArmed()
        for row in rows { storedStepCounts[row.date.startOfDay] = row }
        return reportedWriteCount ?? rows.count
    }

    func writeReceptiveInactivity(_ row: ReceptiveInactivitySyncRow) async throws {
        calls.append(.writeReceptiveInactivity(row))
        try refuseIfArmed()
        storedInactivities[row.id] = row
    }

    /// Keyed on the row's own id, which is **not** reminted — the determinism a re-import depends on.
    func writeReceptiveInactivities(_ rows: [ReceptiveInactivitySyncRow]) async throws -> Int {
        calls.append(.writeReceptiveInactivities(rows))
        try refuseIfArmed()
        for row in rows { storedInactivities[row.id] = row }
        return reportedWriteCount ?? rows.count
    }

    /// Replaces the one profile, or stores the first one. A whole-row write rather than a patch, which
    /// is what the table's contract is: the second call's row *is* the profile, `nil` fields included.
    func writeProfile(_ row: UserProfileSyncRow) async throws {
        calls.append(.writeProfile(row))
        try refuseIfArmed()
        storedProfile = row
    }

    /// `date`, then the session's own start, then its id — ascending, on the protocol's own rule.
    private static func oldestFirst(_ a: WorkoutSyncRow, _ b: WorkoutSyncRow) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        return a.id.uuidString < b.id.uuidString
    }

    private func refuseIfArmed() throws {
        if let failure { throw failure }
    }
}

/// The one failure the local store fixture can be armed with.
///
/// A type of its own rather than a case on an app error, because what it stands in for is a **SQLite**
/// failure — the class of error a real `LocalDatabaseManager` produces and that nothing here can ask for
/// on demand. A block driving the use case's error path needs *a* throw and needs it to be
/// distinguishable from the cloud's; what the block then asserts is the use case's own behaviour, not
/// this value.
enum WorkoutSyncStoreFixtureError: Error, Equatable {
    /// The store refused the call, as a full disk or a locked database would.
    case refused
}

/// The local half of the aggregate resource's sync, in a dictionary and a list of calls.
///
/// **`LocalDatabaseManager` implements the real thing and is not what a use-case block should use**,
/// even though it would genuinely work — it has an in-memory mode. A block built on it would be
/// asserting GRDB's behaviour alongside the use case's, so a failure could not be attributed to either,
/// and two of this protocol's rules are *contracts an implementation must meet* rather than anything a
/// caller can check:
///
/// - the read is ordered `date`, then `started_at`, then `id`, and it is the returned array's own order
///   that carries a route's sequence — the child tables have no `seq` column, so the real implementation
///   recovers it by sorting on `timestamp` / `elapsed`;
/// - the write snaps the day key centrally, so a row handed in at a raw instant is found by the keyed
///   read afterwards.
///
/// **The fixture meets both by storing the row with its day snapped and by answering in the sorted
/// order**, and it keeps the children's order by simply holding the array it was handed — the one thing
/// an in-memory double cannot get wrong and a real implementation has to work for. §22's ordering
/// assertion is therefore written against the real manager rather than against this, because these
/// lines are the only place the order could not be lost.
///
/// **It is deliberately not the same object as `SpyCloudSync`.** A sync block is about a *transfer*, so
/// it needs a local store and a cloud that can each be inspected separately: an upload's assertion is
/// that the rows left one and arrived at the other, and a single double holding both ends would make
/// that one statement said twice.
///
/// An `actor`, for `InMemorySyncSettingsRepository`'s reason: the use case reads from one task while
/// another awaits a write, and the call list has to be one uninterrupted list rather than something two
/// tasks append to concurrently.
actor InMemoryWorkoutSyncStore: WorkoutSyncStore {

    /// One call, as a value the suite can compare — `SpyCloudSync.Call`'s shape and its reason.
    ///
    /// **There is no `delete` case, and its absence is the whole of Decision 3.** Switching the
    /// destination moves where data is stored and purges nothing, so `WorkoutSyncStore` has no delete
    /// and neither does this double — a fixture keeping one would be an implementation of a protocol
    /// that no longer exists, and its `deletedRanges` accessor would assert against a policy the app
    /// deliberately does not have.
    enum Call: Equatable, Sendable {
        case read(from: Date, to: Date)
        case save([WorkoutSyncRow])
    }

    /// Every call, in order.
    private(set) var calls: [Call] = []

    /// How many saves actually landed.
    ///
    /// Kept for `InMemorySyncSettingsRepository.saveCount`'s reason one layer up: the contract is partly
    /// about *when* the store is written — once per chunk, never once per row — and a fixture holding
    /// only the final contents could not tell one write of two hundred rows from two hundred writes of
    /// one. It counts the calls that were not refused, so a block comparing it against `calls` can see
    /// the difference an armed failure makes.
    private(set) var saveCount = 0

    private var stored: [UUID: WorkoutSyncRow]

    /// What every call throws instead of answering. `nil` — the default — is a store that works.
    private var failure: Error?

    /// - Parameters:
    ///   - rows: what the table holds to begin with.
    ///   - failure: armed from the start, for a block whose very first call must fail.
    init(rows: [WorkoutSyncRow] = [], failure: Error? = nil) {
        var seeded: [UUID: WorkoutSyncRow] = [:]
        for row in rows { seeded[row.id] = row }
        self.stored = seeded
        self.failure = failure
    }

    // MARK: - Arming

    /// Refuse every call from here on, with this error — or stop refusing, with `nil`.
    func fail(with error: Error?) { failure = error }

    // MARK: - What a block reads back

    /// The ids the table holds, so a block can assert what a chunk actually landed.
    var storedIds: Set<UUID> { Set(stored.keys) }

    /// Every session the table holds, in the order its own read answers in.
    var storedRows: [WorkoutSyncRow] { stored.values.sorted(by: Self.oldestFirst) }

    /// The row the table holds for a session id, or `nil`.
    func storedRow(id: UUID) -> WorkoutSyncRow? { stored[id] }

    /// The ranges `syncWorkoutRows` was asked for, in order.
    var readRanges: [(from: Date, to: Date)] {
        calls.compactMap { call in
            guard case let .read(from, to) = call else { return nil }
            return (from, to)
        }
    }

    // MARK: - WorkoutSyncStore

    /// Half-open `[from, to)`, oldest first — the protocol's convention, restated here because this is
    /// the second implementation of it and the two must agree.
    func syncWorkoutRows(from: Date, to: Date) async throws -> [WorkoutSyncRow] {
        calls.append(.read(from: from, to: to))
        try refuseIfArmed()
        let lower = from.startOfDay
        let upper = to.startOfDay
        return stored.values
            .filter { $0.date.startOfDay >= lower && $0.date.startOfDay < upper }
            .sorted(by: Self.oldestFirst)
    }

    /// Replaces every session given, children and all, snapping each row's day on the way in.
    ///
    /// **The snap is the store's and not this fixture's invention** — it is what `saveWorkout` does and
    /// what the protocol's doc comment says an implementation must do, so a fixture that skipped it
    /// would be an implementation of a different contract.
    func saveSyncWorkoutRows(_ rows: [WorkoutSyncRow]) async throws {
        calls.append(.save(rows))
        try refuseIfArmed()
        for row in rows { stored[row.id] = Self.snapped(row) }
        saveCount += 1
    }

    /// The row as the table would hold it — the day snapped, everything else copied.
    ///
    /// **A replacement value rather than a mutation**, because every field on `WorkoutSyncRow` is a
    /// `let` and that is deliberate on the real record too: a sync row is a value handed across a
    /// boundary, and a mutable one would let a caller snap a day in place and leave two chunks
    /// describing the same day under two keys.
    private static func snapped(_ row: WorkoutSyncRow) -> WorkoutSyncRow {
        WorkoutSyncRow(
            id: row.id,
            date: row.date.startOfDay,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            strain: row.strain,
            averageHeartRate: row.averageHeartRate,
            maxHeartRate: row.maxHeartRate,
            source: row.source,
            activityName: row.activityName,
            hrZonePercents: row.hrZonePercents,
            steps: row.steps,
            offlineRegionID: row.offlineRegionID,
            route: row.route,
            splits: row.splits)
    }

    /// `date`, then the session's own start, then its id — the protocol's order, and the order the
    /// chunking upload depends on rather than a convenience.
    private static func oldestFirst(_ a: WorkoutSyncRow, _ b: WorkoutSyncRow) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        return a.id.uuidString < b.id.uuidString
    }

    private func refuseIfArmed() throws {
        if let failure { throw failure }
    }
}
