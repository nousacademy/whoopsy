import Foundation

// MARK: - One resource, as a value

/// A resource the engine can move without knowing which one it is holding.
///
/// **The resource is a value rather than a protocol or a generic, and that is the whole reason this
/// file is one file.** `SyncRecoveriesUseCase`, `SyncWorkoutsUseCase` and `SyncStrainsUseCase` were
/// three near-copies of one walk that differed in a method name per call and, for workouts, in how a
/// chunk is cut — so the walk was written three times and the third copy is where a fix goes missing.
/// Here the walk is written once, over a generic row, and a resource is the four facts the walk needs
/// plus one closure: *which resource this is*, *what one of its rows is called*, *the widest range the
/// server will answer for it*, and *how to send it*.
///
/// **The closure is `send` and there is deliberately no `read`.** The natural-looking second member —
/// a `(Date, Date) async throws -> Int` answering *how many rows are in this range* — has **no reader
/// anywhere**, and shipping it would be shipping a promise nothing keeps. The pane's `SYNCED RESOURCES`
/// list is a plain list of titles with no counts beside them (the per-resource note that used to draw
/// one is gone), and the one number a run actually reports is what the database said it wrote, which
/// comes back from `send` inside a `SyncSummary`. A count of what is *pending* before a run is the
/// figure this feature was explicitly arranged not to draw — a range's day count is not a row count,
/// and a row count cannot be honest about a resource whose rows the wire will refuse.
///
/// **The two Worker constants are stored here and `batchSize` is not, and the asymmetry is which one
/// has a reader.** `maximumLookbackDays` is read by `SyncEngine.run` as the bound on the range the
/// user drew, so it belongs to the value. `batchSize` has exactly one reader — the chunking closure
/// built at the same construction site that would store it — so storing it would be a second number
/// that could disagree with the one actually applied to the request. It is a literal at each site,
/// where the Worker's constant it mirrors is named.
public struct SyncResource: Sendable {

    /// The drawn title, and the contract's own name in the same value — `SyncedResource` is the
    /// mapping, and the pane's list and this engine's contents are both derived from its cases.
    public let name: SyncedResource

    /// What one of this resource's rows is called in a `SyncSummary`'s sentence.
    public let unit: SyncSummary.Unit

    /// The widest range the server will answer for this resource, **mirroring the Worker's own constant
    /// for it**. `nil` on the profile, which is a singleton and is not filed under a date.
    ///
    /// **Declared per resource rather than shared**, because the Worker declares it per resource: six
    /// of the seven ceilings are `4000` today and they are six constants on the far side, so an alias
    /// here would let one resource's ceiling change silently for another.
    public let maximumLookbackDays: Int?

    /// Send this resource over `range`, and report what moved.
    ///
    /// The profile ignores the range and is the only resource that can: it has no dates, so there is no
    /// span to narrow it to, and it rides along on every run.
    let send: @Sendable (SyncSettings.SyncRange) async throws -> SyncSummary

    init(
        name: SyncedResource,
        unit: SyncSummary.Unit,
        maximumLookbackDays: Int?,
        send: @escaping @Sendable (SyncSettings.SyncRange) async throws -> SyncSummary
    ) {
        self.name = name
        self.unit = unit
        self.maximumLookbackDays = maximumLookbackDays
        self.send = send
    }
}

// MARK: - What one resource did

/// One resource's answer, with the resource it came from.
///
/// The engine moves seven resources in one press and the pane prints one line per resource, so the
/// summary and its subject travel together rather than as two arrays a caller has to zip — and a
/// `SyncSummary` on its own does not say which resource it describes, because its sentence is written
/// over the direction and the unit and never over the name.
public struct SyncResult: Equatable, Sendable {
    public let resource: SyncedResource
    public let summary: SyncSummary

    public init(resource: SyncedResource, summary: SyncSummary) {
        self.resource = resource
        self.summary = summary
    }
}

// MARK: - The engine

/// The one thing that moves data between this phone and the database, over all seven resources.
///
/// **There is no direction here and no mode**, which is the largest single difference from the three
/// types this replaces. Those read a pair of cutoffs, worked out a sign from their disagreement and
/// walked one way or the other; the cutoffs are gone (Decision 2), so what is left is the *span the
/// user drew* and one verb over it. `SYNC` sends that span up. A day coming *down* is not a run at all
/// — it is the read path answering a screen that asked for a day the phone does not hold — and it is
/// `CloudRecoveryRepository`'s business rather than this type's.
///
/// **A run is seven independent sends and it stops at the first failure.** Nothing is transactional
/// across resources and nothing needs to be: every write on the far side is an INSERT-or-UPDATE on the
/// row's own key, so a run that died after four resources leaves four resources' rows written and
/// re-pressing the button re-sends all seven with the same values. What a stop costs is the sentence
/// about the resources that did finish — which is why the failure is thrown rather than folded into
/// the returned array, where a caller could not tell *this resource was refused* from *this resource
/// had nothing to send*.
public struct SyncEngine: Sendable {

    private let settingsStore: any SyncSettingsRepository

    /// The resources to move, in the order the pane lists them.
    private let resources: [SyncResource]

    public init(resources: [SyncResource], settingsStore: any SyncSettingsRepository) {
        self.resources = resources
        self.settingsStore = settingsStore
    }

    /// What the engine covers, for the assertion that it covers everything the pane draws.
    ///
    /// It exists because the two lists are derived from different places — the pane's from
    /// `SyncedResource.allCases`, this one's from the table in `SyncResources` — and a resource that
    /// the pane promises and the engine does not hold is a title on a screen over nothing. §22 asserts
    /// one against the other rather than either against a literal typed twice.
    public var resourceNames: [SyncedResource] { resources.map(\.name) }

    // MARK: - The pane's own reads and writes

    /// What the storage pane draws: which store is in use, and over what span.
    public func settings() async -> SyncSettings {
        await settingsStore.load()
    }

    /// Switch which store this install's days belong to.
    ///
    /// **It saves nothing anywhere else and it moves nothing**, which is the rule this whole pane is
    /// arranged around: turning it to `.cloud` sends no rows and turning it back to `.device` fetches
    /// none, because neither store was ever emptied. What it changes is where the *next* write goes and
    /// which store answers a read — and `SYNC` is the only control on this pane that transfers
    /// anything at all.
    @discardableResult
    public func setDestination(_ destination: SyncSettings.Destination) async -> SyncSettings {
        var current = await settingsStore.load()
        current.destination = destination
        await settingsStore.save(current)
        return current
    }

    /// Draw the span `SYNC` walks. `nil` clears it, which leaves the button with nothing to do.
    ///
    /// Saved on its own rather than as part of a run, because it is a decision the user makes *before*
    /// pressing the button and it has to survive a run that fails. The snap to `startOfDay` is
    /// `SyncSettings.SyncRange`'s own and is load-bearing rather than tidy: a `DatePicker` hands back an
    /// instant carrying the current clock time, and an unsnapped end would make the set of days the run
    /// covers depend on what time of day the user tapped.
    @discardableResult
    public func setRange(from: Date?, to: Date?) async -> SyncSettings {
        var current = await settingsStore.load()
        // Both ends or neither: a span with one end drawn is not a span, and a half-drawn pair saved
        // as-is would put the button in a state its own gate could not describe.
        current.range = if let from, let to { SyncSettings.SyncRange(from: from, to: to) } else { nil }
        await settingsStore.save(current)
        return current
    }

    // MARK: - The run

    /// Send everything the drawn range covers, resource by resource, and report each one.
    ///
    /// **Throws `.nothingToDo` when no range is drawn or the one drawn is empty**, rather than
    /// returning an empty array. The pane withholds the button in that state, so reaching here means a
    /// caller asked for something that is not a thing — and seven summaries reading *nothing to send*
    /// would be an answer that looks like a success.
    ///
    /// The range is checked against each resource's own ceiling **before that resource is read**, so an
    /// over-wide span is refused by name instead of being half-honoured. It is the same ceiling the
    /// server applies to a window of the same span, and the same one the read path asks it for: a run
    /// that reported a span complete while the app could not read that span back would be reporting a
    /// transfer it cannot honour.
    public func run() async throws -> [SyncResult] {
        let settings = await settingsStore.load()
        guard let range = settings.range, !range.isEmpty else { throw SyncError.nothingToDo }

        var results: [SyncResult] = []
        for resource in resources {
            if let ceiling = resource.maximumLookbackDays, range.dayCount > ceiling {
                throw SyncError.rangeTooWide(days: ceiling)
            }
            results.append(SyncResult(resource: resource.name, summary: try await resource.send(range)))
        }
        return results
    }
}

// MARK: - The walk every ranged resource shares

/// Read a span, drop what the wire will refuse, cut it into requests, send them.
///
/// **The shape is the one `SyncStrainsUseCase.upload` had, kept verbatim**, because that file's
/// ordering argument
/// is the load-bearing part rather than its arithmetic: the unsendable rows are removed **before** the
/// chunking and never after it. `POST /batch` is one transaction and all-or-nothing, so a single row
/// the schema refuses refuses the other hundred and ninety-nine in its chunk and the user's run fails
/// with a message naming a day they never touched; and the schema requires at least one row, so
/// filtering *inside* the chunk loop could produce a chunk that is empty after filtering, which is a
/// guaranteed `400`. Filtering first makes every chunk non-empty by construction.
///
/// **The gate is the wire's and not the app's.** Each mapper's `isSendable` asks *will the database
/// take this*, where the row's own `hasMeasurement` asks *is this a reading*. The two disagree on
/// exactly one shape — an unmeasured row with a well-formed score — and the disagreement is the honest
/// one: the row is sent, both stores then hold it, and every reader on either side draws the same dash.
///
/// **What is reported for a dropped row is a count and not a silence.** A run that quietly discarded
/// part of a span it then reported as finished is the failure this arrangement exists to prevent, and
/// the port above has no way to report one — so the count comes back in `SyncSummary.skipped` and the
/// rows themselves stay on the phone. Nothing in this file deletes anything.
///
/// **`chunk` is a parameter rather than a `batchSize`**, because one resource is not cut on a row count
/// alone: a session carries a route and a split list that the server caps *in aggregate across a
/// request*, so `chunks(of:size:)` would build requests `workouts` refuses. Three of the seven are
/// cut by count and that is `chunks(of:size:)`; the fourth is `workoutChunks(of:)`, and the fact that
/// the difference is one argument here rather than a fourth copy of this function is the point.
private func walk<Row: Sendable>(
    _ range: SyncSettings.SyncRange,
    unit: SyncSummary.Unit,
    read: @Sendable (Date, Date) async throws -> [Row],
    isSendable: @Sendable (Row) -> Bool,
    chunk: @Sendable ([Row]) -> [[Row]],
    write: @Sendable ([Row]) async throws -> Int
) async throws -> SyncSummary {
    let rows = try await read(range.from, range.to)

    let sendable = rows.filter(isSendable)
    let skipped = rows.count - sendable.count

    // Nothing to send, and it is not an error. A span the user drew can cover only days this app never
    // measured — or, for the resources the import writes, days it has no rows for at all. The database
    // is not missing anything the phone has, and a run over such a span is a real run that moved zero.
    guard !sendable.isEmpty else {
        return SyncSummary(direction: .upload, unit: unit, rows: 0, skipped: skipped)
    }

    var written = 0
    for request in chunk(sendable) {
        written += try await write(request)
    }
    return SyncSummary(direction: .upload, unit: unit, rows: written, skipped: skipped)
}

/// Split rows into runs of at most `size`, in order.
///
/// Order is load-bearing rather than incidental: a chunk's rows go into one request, and the server
/// counts what it wrote, so a chunk whose rows were shuffled would still be legal but the count would
/// stop mapping onto any span a reader could name. Every store's read is ascending, so the caller has
/// nothing to sort.
private func chunks<Row>(of rows: [Row], size: Int) -> [[Row]] {
    guard size > 0 else { return rows.isEmpty ? [] : [rows] }
    return stride(from: 0, to: rows.count, by: size).map {
        Array(rows[$0 ..< Swift.min($0 + size, rows.count)])
    }
}

/// Split sessions into requests the server will accept, in order.
///
/// **Two dimensions, and the first session is taken unconditionally so the walk always advances.** The
/// count ceiling is the Worker's `MAX_BATCH_WORKOUTS`; the two aggregate ceilings are its
/// `MAX_BATCH_ROUTE_POINTS` and `MAX_BATCH_SPLITS`, which bound a request's children **across every
/// session in it** rather than per session — two hundred sessions with no routes fit easily, two
/// hundred long ones do not. The first row is never tested against the aggregate caps because
/// `WorkoutWireMapper.isSendable` has already bounded it at exactly those numbers, so it cannot fail
/// them; a loop that tested it too would, on a session over the cap, take nothing and spin forever on
/// the same index.
///
/// The three checks are ordered most-specific-first in the server's own order and the order is not
/// observable from here — this walk refuses a chunk that any of them would refuse, and the request it
/// builds is legal under all three.
private func workoutChunks(of rows: [WorkoutSyncRow]) -> [[WorkoutSyncRow]] {
    var requests: [[WorkoutSyncRow]] = []
    var index = 0

    while index < rows.count {
        var taken = 1
        var points = rows[index].route.count
        var splits = rows[index].splits.count

        while index + taken < rows.count, taken < maximumBatchWorkouts,
            points + rows[index + taken].route.count <= maximumBatchRoutePoints,
            splits + rows[index + taken].splits.count <= maximumBatchSplits
        {
            points += rows[index + taken].route.count
            splits += rows[index + taken].splits.count
            taken += 1
        }

        requests.append(Array(rows[index ..< index + taken]))
        index += taken
    }

    return requests
}

// Mirrors the Worker's `MAX_BATCH_WORKOUTS`, `MAX_BATCH_ROUTE_POINTS` and `MAX_BATCH_SPLITS`
// (`backend/src/services/workoutService.ts`). Kept file-private rather than public because their only
// reader is `workoutChunks` above; the number a caller needs to know is the one the descriptor carries.
private let maximumBatchWorkouts = 200
private let maximumBatchRoutePoints = 2000
private let maximumBatchSplits = 200

// MARK: - The table of resources

/// The seven resources, in the order the pane draws them, built from the seven stores and one port.
///
/// **The order is `SyncedResource.allCases`' and not a second list**, so a resource added to the enum
/// appears here the moment it is given a store — and the two orders cannot drift, because this array is
/// the enum's order written once and §22 asserts the pane's list against the contract's.
///
/// **Each closure quotes the Worker constant it mirrors at its own construction site**, which is what
/// keeps a ceiling from being an alias of its neighbour: the six ranged resources are all `200`/`4000`
/// today, and they are six separate constants on the server, so a shared `SyncLimits` here would be the
/// one change that turns a per-resource limit into a global one without anything saying so.
///
/// **Each is built per call rather than held as a `static let`**, because the descriptors capture the
/// stores they were handed: a cached table would pin the first `DIContainer`'s database into every
/// later one, and the suite builds many.
public enum SyncResources {

    /// **The stores are named `<entity>Store` rather than for the resource**, because a parameter
    /// called `recoveries` shadows the `recoveries(cloud:store:)` below it and the call reads as an
    /// attempt to invoke a store. The factories are named for what the pane draws; these are named for
    /// what they are.
    public static func all(
        cloud: any CloudSync,
        profileStore: any UserProfileSyncStore,
        inactivityStore: any ReceptiveInactivitySyncStore,
        recoveryStore: any RecoverySyncStore,
        sleepStore: any SleepSyncStore,
        stepCountStore: any StepCountSyncStore,
        strainStore: any StrainSyncStore,
        workoutStore: any WorkoutSyncStore
    ) -> [SyncResource] {
        [
            profile(cloud: cloud, store: profileStore),
            receptiveInactivities(cloud: cloud, store: inactivityStore),
            recoveries(cloud: cloud, store: recoveryStore),
            sleeps(cloud: cloud, store: sleepStore),
            stepCounts(cloud: cloud, store: stepCountStore),
            strains(cloud: cloud, store: strainStore),
            workouts(cloud: cloud, store: workoutStore),
        ]
    }

    // MARK: - The singleton

    /// The profile, and the one resource whose send does not walk anything.
    ///
    /// **It ignores the range it is handed, deliberately.** A profile is not filed under a date — its
    /// only date-valued field is a birthday, which is a fact about a person rather than a position in a
    /// history — so a span has nothing to narrow it to and *did the user's span cover my profile* is a
    /// question with no meaning. It therefore goes on every run, and its `maximumLookbackDays` is `nil`
    /// for the same reason: there is no window for the server to bound.
    ///
    /// **`isSendable` is applied here by hand rather than by the walk**, and the shape of the answer is
    /// what makes that right. A singleton cannot be *partially* sent: a row the schema refuses would
    /// otherwise be skipped and reported as `1 profile could not be sent`, which is the honest sentence
    /// — but the row is the whole resource, so sending nothing and saying so is exactly what the walked
    /// resources do one row at a time. The count is one because there is one row.
    private static func profile(
        cloud: any CloudSync,
        store: any UserProfileSyncStore
    ) -> SyncResource {
        SyncResource(name: .profile, unit: .profile, maximumLookbackDays: nil) { _ in
            guard let row = try await store.syncProfileRow() else {
                // No row at all, which is a user who has never filled the form in. Not an error and
                // not a skip: there is nothing on this phone to send, exactly as an unmeasured day is
                // an absent row rather than a zero. The app's own 190/60 cold-start pair is applied by
                // the client when it draws the form and has never been a stored row.
                return SyncSummary(direction: .upload, unit: .profile, rows: 0, skipped: 0)
            }
            guard UserProfileWireMapper.isSendable(row) else {
                return SyncSummary(direction: .upload, unit: .profile, rows: 0, skipped: 1)
            }
            try await cloud.writeProfile(row)
            // One, not a count the server returned: `writeProfile` answers with nothing, because the
            // route's whole job is the one row and there is no chunk whose parts could be counted.
            return SyncSummary(direction: .upload, unit: .profile, rows: 1, skipped: 0)
        }
    }

    // MARK: - The six that walk a span

    private static func receptiveInactivities(
        cloud: any CloudSync,
        store: any ReceptiveInactivitySyncStore
    ) -> SyncResource {
        // `MAX_BATCH_RECEPTIVE_INACTIVITIES`, and the window it imports: this resource is the one that
        // deliberately does **not** declare a sixth window constant on the server, reading the
        // recoveries one instead, so the number here mirrors `MAX_WINDOW_DAYS`.
        SyncResource(name: .receptiveInactivities, unit: .entry, maximumLookbackDays: 4000) { range in
            try await walk(
                range,
                unit: .entry,
                read: { try await store.syncReceptiveInactivityRows(from: $0, to: $1) },
                isSendable: ReceptiveInactivityWireMapper.isSendable,
                chunk: { chunks(of: $0, size: 200) },
                write: { try await cloud.writeReceptiveInactivities($0) }
            )
        }
    }

    private static func recoveries(
        cloud: any CloudSync,
        store: any RecoverySyncStore
    ) -> SyncResource {
        // `MAX_BATCH_ROWS` and `MAX_WINDOW_DAYS`.
        SyncResource(name: .recoveries, unit: .day, maximumLookbackDays: 4000) { range in
            try await walk(
                range,
                unit: .day,
                read: { try await store.syncRows(from: $0, to: $1) },
                isSendable: RecoveryWireMapper.isSendable,
                chunk: { chunks(of: $0, size: 200) },
                write: { try await cloud.writeRecoveries($0) }
            )
        }
    }

    private static func sleeps(
        cloud: any CloudSync,
        store: any SleepSyncStore
    ) -> SyncResource {
        // `MAX_BATCH_SLEEPS` and `MAX_SLEEP_WINDOW_DAYS`. A row here is keyed on the night's **wake**
        // day, which is the store's business and not this walk's: the rows arrive already keyed, and a
        // walk that recomputed a day from `startTime` would file every night that began before midnight
        // one day early on this side of the call.
        SyncResource(name: .sleeps, unit: .day, maximumLookbackDays: 4000) { range in
            try await walk(
                range,
                unit: .day,
                read: { try await store.syncSleepRows(from: $0, to: $1) },
                isSendable: SleepWireMapper.isSendable,
                chunk: { chunks(of: $0, size: 200) },
                write: { try await cloud.writeSleeps($0) }
            )
        }
    }

    private static func stepCounts(
        cloud: any CloudSync,
        store: any StepCountSyncStore
    ) -> SyncResource {
        // `MAX_BATCH_STEP_COUNTS` and `MAX_STEP_COUNT_WINDOW_DAYS`. This is the resource whose gate is
        // doing real work rather than tidying: `measuredSeconds == 0` is this app's word for *no
        // measurement* and the wire has no equivalent — its `0` is a legal reading of zero steps — so an
        // unmeasured day sent anyway would create a measurement on the far side that this app reports as
        // absent.
        SyncResource(name: .stepCounts, unit: .day, maximumLookbackDays: 4000) { range in
            try await walk(
                range,
                unit: .day,
                read: { try await store.syncStepCountRows(from: $0, to: $1) },
                isSendable: StepCountWireMapper.isSendable,
                chunk: { chunks(of: $0, size: 200) },
                write: { try await cloud.writeStepCounts($0) }
            )
        }
    }

    private static func strains(
        cloud: any CloudSync,
        store: any StrainSyncStore
    ) -> SyncResource {
        // `MAX_BATCH_STRAINS` and `MAX_STRAIN_WINDOW_DAYS` — a separate pair on the server rather than
        // an alias of the recoveries one, which is why the two numbers are written twice here.
        SyncResource(name: .strains, unit: .day, maximumLookbackDays: 4000) { range in
            try await walk(
                range,
                unit: .day,
                read: { try await store.syncStrainRows(from: $0, to: $1) },
                isSendable: StrainWireMapper.isSendable,
                chunk: { chunks(of: $0, size: 200) },
                write: { try await cloud.writeStrains($0) }
            )
        }
    }

    private static func workouts(
        cloud: any CloudSync,
        store: any WorkoutSyncStore
    ) -> SyncResource {
        // `MAX_BATCH_WORKOUTS`, `MAX_BATCH_ROUTE_POINTS` and `MAX_BATCH_SPLITS` — the only resource
        // here whose request is bounded in two dimensions, which is why it is the one that does not use
        // `chunks(of:size:)`. Its window is `MAX_WINDOW_DAYS`.
        SyncResource(name: .workouts, unit: .session, maximumLookbackDays: 4000) { range in
            try await walk(
                range,
                unit: .session,
                read: { try await store.syncWorkoutRows(from: $0, to: $1) },
                isSendable: WorkoutWireMapper.isSendable,
                chunk: workoutChunks(of:),
                write: { try await cloud.writeWorkouts($0) }
            )
        }
    }
}

// MARK: - The answer the pane prints

/// What a completed transfer of one resource did, in the shape a screen can turn into a sentence.
///
/// `message` is the engine's own words about what it moved, on `WhoopImportSummary.message`'s
/// precedent: the alternative is seven call sites composing the same sentence from the same three
/// fields, and one of them saying *uploaded* over a download.
///
/// **`skipped` is a second count rather than a subtraction from `rows`, and it is only ever non-zero on
/// an upload.** `rows` is what the database said it wrote; `skipped` is what this app declined to send
/// because the wire would have refused it. Folding them into one number would make a run that sent nine
/// hundred days and left two behind read exactly like one that sent nine hundred and two — the state
/// this field exists to make visible. It has no default on the initialiser for the reason
/// `StrainScore.hasMeasurement` has none: a default of `0` would let a construction site report a clean
/// run without having counted.
///
/// **`unit` is what one of those counts is called, and the resources do not call it the same thing.**
/// A recovery row is a *day* — one row per day, which is why `recoveries`, `sleeps`, `strains` and
/// `stepCounts` all share that case. A workout row is a *session* and an entry is an *entry*: both are
/// tables where a day holds several, so "Uploaded 12 days" over twelve basketball games or twelve
/// journal entries would be false. A profile is a *profile* and there is exactly one of it. The unit is
/// therefore carried rather than assumed, and `message` is still composed in exactly one place — which
/// is the whole point of sharing this type rather than giving each resource a summary of its own whose
/// sentences could drift from these.
///
/// **`unit` has no default, on the same rule as `skipped`.** A default of `.day` would let the workouts
/// construction site silently inherit the recoveries vocabulary, and the failure would be a message
/// naming the wrong noun over a run that did everything right — invisible to the compiler and to every
/// test that does not read the string.
public struct SyncSummary: Equatable, Sendable {

    /// Which way the rows went.
    ///
    /// **It lives here rather than on `SyncSettings` because the report is its only consumer.** It used
    /// to be the settings' own type, because a run read a pair of boundaries and *which one is ahead*
    /// **was** the direction — `Set` or `Restore` was the button's title and the user never chose it.
    /// The boundaries are gone with the delete that created them, so the direction is now what a
    /// finished run says about itself and nothing else reads it.
    ///
    /// **`.upload` is the only case a run in this pass constructs**, and the other two are kept rather
    /// than pruned because `message` is written as a switch over this and because both name a real
    /// state of the report: `.download` is what a restore of a range would say — the read path answers a
    /// *day* rather than a range, so no run produces one today — and `.none` is the arm a run with
    /// nothing to do would have used, which is now `SyncError.nothingToDo` thrown before any summary
    /// exists because a summary saying *0 moved* reads like a success.
    public enum Direction: Sendable {
        case upload
        case download
        case none
    }

    /// What one `rows`/`skipped` unit is called on the resource this summary describes.
    ///
    /// One case per shape of row and not per resource: four cases cover the seven, because four
    /// resources key one row to a day and the remaining three are a singleton, a table where a day holds
    /// several sessions, and a table where a day holds several entries. `message`'s own switch is over
    /// the *direction* rather than over this, so a new unit needs no new arm — only the two strings
    /// below.
    public enum Unit: Sendable {
        /// One row keyed on a day: `recoveries`, `sleeps`, `strains`, `stepCounts`.
        case day

        /// One row of `workouts`: a recorded session, several of which can share a day.
        case session

        /// One row of `receptive_inactivities`: a named entry, several of which can share a day.
        case entry

        /// The one row of `user_profiles`. There is never a second.
        case profile

        var singular: String {
            switch self {
            case .day: return "day"
            case .session: return "session"
            case .entry: return "entry"
            case .profile: return "profile"
            }
        }

        var plural: String {
            switch self {
            case .day: return "days"
            case .session: return "sessions"
            case .entry: return "entries"
            case .profile: return "profiles"
            }
        }

        /// `3 days`, `1 session` — the noun agrees with the number, so a one-row run cannot read
        /// `1 sessions`.
        func count(_ value: Int) -> String {
            value == 1 ? "1 \(singular)" : "\(value) \(plural)"
        }
    }

    public let direction: Direction

    /// What the noun for `rows` and `skipped` is on this resource.
    public let unit: Unit

    /// What the database reported it wrote. A replayed chunk reports its full count, not zero.
    public let rows: Int

    /// Rows this run could not send at all. Always `0` for a download.
    public let skipped: Int

    public init(direction: Direction, unit: Unit, rows: Int, skipped: Int) {
        self.direction = direction
        self.unit = unit
        self.rows = rows
        self.skipped = skipped
    }

    public var message: String {
        switch direction {
        case .upload:
            return uploadMessage
        case .download:
            guard rows > 0 else { return "There was nothing left to restore from the database." }
            // No skip clause: nothing is filtered on the way down. Every row the database hands over is
            // one this app can store — the mappers' refusals are all about what the *wire* will accept.
            return "Restored \(unit.count(rows)) from the database."
        case .none:
            // Unreachable: a run with nothing to do throws `.nothingToDo` before it can build a summary.
            // The arm exists because the direction is a three-case enum and an exhaustive switch is what
            // keeps a fourth from arriving silently.
            return "There was nothing to send."
        }
    }

    /// The upload's sentence, which has four shapes rather than one.
    ///
    /// The skip clause is appended only when there is something to skip, so an ordinary run reads as one
    /// short line. The two degenerate arms are separate sentences rather than one, because *nothing was
    /// in the span* and *nothing in it could be sent* are different facts about the range and only the
    /// first is the benign one.
    ///
    /// **It no longer says "and moved the boundary",** because there is no boundary to move: the
    /// sentence belonged to a model in which a run advanced a marker past what it had sent, and the
    /// marker went with the delete. What a run leaves behind now is the rows on the far side, and the
    /// sentence says only what went.
    private var uploadMessage: String {
        let moved = rows > 0 ? "Uploaded \(unit.count(rows))." : nil
        let left = skipped > 0
            ? "\(unit.count(skipped)) could not be sent and \(skipped == 1 ? "is" : "are") still on this phone."
            : nil

        switch (moved, left) {
        case let (moved?, left?):
            return moved + " " + left
        case let (moved?, nil):
            return moved
        case let (nil, left?):
            return "Nothing could be sent. " + left
        case (nil, nil):
            return "There was nothing to send."
        }
    }
}

/// Why a sync could not run.
///
/// Two cases, and neither wraps `CloudSyncError`: a failure of the transport is that type's own answer
/// and the pane switches on it directly, so folding it in here would mean one error presented two ways
/// and a caller that has to unwrap to find out which of them it is holding.
public enum SyncError: Error, Equatable, Sendable {
    /// No span is drawn, or the one drawn covers no days.
    ///
    /// **It no longer means *the boundaries agree*.** There are no boundaries: the pane withholds the
    /// button until a span exists, so reaching here means a caller asked for a run over nothing — and a
    /// result list of seven summaries reading *nothing to send* would be an answer that reads like a
    /// success.
    case nothingToDo

    /// The span is wider than the server will answer for the resource being sent.
    ///
    /// **Not a clamp, deliberately.** Truncating the span would send a partial range and then report the
    /// transfer as complete — the pane would say it had moved a range the app cannot read back, and
    /// nothing downstream could tell. The associated value is the resource's own ceiling, so the
    /// sentence can name it, and it is the same number the Worker applies to a window of that width.
    case rangeTooWide(days: Int)
}
