import Foundation

/// The nineteen things this app can do to the database, and the reason the rest of the app never sees
/// the transport.
///
/// **This is the app's first network seam, and it is a port rather than a client.** Nothing above it
/// names `URLSession`, a URL, a status code or a JSON key: what the layers above see is *rows in and
/// rows out*, in the same `RecoverySyncRow`/`WorkoutSyncRow` shapes the local database uses. That is
/// what makes the decorator possible at all — a `RecoveryRepository` that answers from the cloud for
/// some days and from SQLite for the rest can be written without either of its two sources knowing
/// about the other.
///
/// **The seven resources share this one port rather than each having their own, and that is a decision
/// about the subject rather than about the API.** This protocol's subject is *the database* — the
/// remote one this app writes a copy of itself into — and not *a day* or *a session*. A sibling
/// `WorkoutCloudSync` would have to be implemented by `HTTPCloudSync` and `UnconfiguredCloudSync` and
/// faked by every spy, so there would be seven ports whose implementations must be kept in step, seven
/// unconfigured arms whose sentences must not drift, and six more conformances for every test double;
/// and a caller holding one of them could not be handed another without a seventh stored property.
/// The API's own surface is the same small operation set per resource for the same reason, and this
/// mirrors it.
///
/// **The seven are not symmetric in this protocol and the asymmetry is the API's.** Recoveries,
/// strains and workouts are read as well as written, because three routes read them and one consumer —
/// the read path — needs them. Sleeps, step counts and entries are **written here and nowhere read**,
/// and a profile is written and *never* read back into the database: `PUT /v1/profile` is the whole of
/// that resource's surface as far as this app is concerned. A read method with no caller is a promise
/// this port does not keep, so the seven methods added below are all writes.
///
/// What the resources do *not* share is any of their positions: a range is a position in one
/// resource's history, and two resources can be at different ones — a week of nights sent and a year
/// of recoveries sent are two answers to two questions, and a single marker advanced by whichever
/// resource moved last would lose the other's place. The port carries the calls; where the positions
/// are kept is `SyncSettings`'s business and not this protocol's.
///
/// **The read answers `nil` for a key the database holds no row for, and that is not an error.** This
/// app's whole absence rule is that an unmeasured day is an absent row rather than a zero-filled one,
/// and the cloud says the same thing with a `404`. Making that `nil` instead of a thrown
/// `not_found` is what lets both sources be merged by one comparison, rather than by a caller that has
/// to know which of its two sources spells absence which way.
///
/// **Both absence codes are read by name and they are different words**, because the two absences are
/// different shapes: a day either has a reading or it does not, while a session id is either known in
/// this partition or it is not. An implementation that matched one code for both would throw on the
/// ordinary case of asking about a key the database has never seen.
public protocol CloudSync: Sendable {

    // MARK: - Recoveries, keyed on the day

    /// One day's row, or `nil` when the database holds none for it.
    func recovery(on day: Date) async throws -> RecoverySyncRow?

    /// Every row the database holds in `[from, to)`, **half-open**, ascending.
    ///
    /// Half-open rather than inclusive, and on the app's own convention rather than the wire's:
    /// `Date.startOfNextDay` is what a range like this is built from and `Date.endOfDay` is the wrong
    /// end for it, because `23:59:59` is the last *instant* of a day and a bound that is one second
    /// short silently drops a row written at midnight. The same rule, and the same reason, as
    /// `WorkoutSession.covers(_:)`.
    func recoveries(from: Date, to: Date) async throws -> [RecoverySyncRow]

    /// Write one day, replacing whatever the database holds for it.
    ///
    /// Its own method rather than a one-row batch, because the two are different operations rather
    /// than the same one at two sizes: this is a save of a day that has a shape, and a batch is a
    /// chunk of a history whose whole point is that its size is not interesting. The single write is
    /// what the read path uses when a screen saves a day, and it is the operation whose failure has to
    /// name the day.
    func writeRecovery(_ row: RecoverySyncRow) async throws

    /// Write many days at once, and report how many the database says it wrote.
    ///
    /// **Idempotent by construction**, which is what makes a retry safe after a timeout the client
    /// never saw the answer to: every row lands on the same key the single write uses, so a replayed
    /// chunk rewrites each row with the values it already holds. The count is returned rather than
    /// discarded because the database counts a matched row as changed, so a replayed chunk reports the
    /// same number as the first send instead of zero — a caller must not read `0` as "there was
    /// nothing to do", and the number being visible is what stops it.
    func writeRecoveries(_ rows: [RecoverySyncRow]) async throws -> Int

    // MARK: - Strains, keyed on the day

    /// One day's row, or `nil` when the database holds none for it.
    ///
    /// **The absence is the same word as the recoveries one and the row that is *not* absent is the
    /// difference.** The server answers `404` + `no_measurement_for_day` for a day it has no row for,
    /// exactly as its sibling does, and that is translated to `nil` here — two sources merged by one
    /// comparison rather than by a caller that knows which of them spells absence which way.
    ///
    /// **What differs is a `200` carrying `hasMeasurement: false`, and it must come back as a row.**
    /// `strains` holds that flag as a required column, so an unmeasured day is a row like any other and
    /// the server says so with a `200` — the `404` is reserved for a day with *no row at all*. A client
    /// that read the flag as an absence would report a day the database holds as a day it does not, and
    /// the two are different facts: the first is a row this app can draw a dash for, the second is a day
    /// it has never heard of. `kilojoules == 0` beside `hasMeasurement == true` is a measured reading of
    /// no work done, and it lands on the ordinary path for the same reason.
    func strain(on day: Date) async throws -> StrainSyncRow?

    /// Every row the database holds in `[from, to)`, **half-open**, ascending.
    ///
    /// Half-open on the app's own convention rather than the wire's, exactly as `recoveries(from:to:)`
    /// is and for the same reason: `Date.startOfNextDay` is what a range like this is built from, and
    /// `Date.endOfDay`'s `23:59:59` is the last *instant* of a day, so a bound built from it silently
    /// drops a row written at midnight.
    func strains(from: Date, to: Date) async throws -> [StrainSyncRow]

    /// Write one day, replacing whatever the database holds for it.
    ///
    /// Its own method rather than a one-row batch, on `writeRecovery(_:)`'s argument: this is a save of
    /// a day that has a shape, and a batch is a chunk of a history whose whole point is that its size is
    /// not interesting.
    func writeStrain(_ row: StrainSyncRow) async throws

    /// Write many days at once, and report how many the database says it wrote.
    ///
    /// **Idempotent by construction**, on `writeRecoveries(_:)`'s argument: every row lands on the same
    /// key the single write uses, so a replayed chunk rewrites each row with the values it already
    /// holds. The count comes back rather than being discarded because the database counts a matched row
    /// as changed — a replayed chunk reports the same number as the first send instead of zero, and a
    /// caller must not read `0` as *there was nothing to do*.
    func writeStrains(_ rows: [StrainSyncRow]) async throws -> Int

    // MARK: - Workouts, keyed on the session

    /// One session and everything filed under it, or `nil` when this database holds no such id.
    ///
    /// **A `UUID` and not a `Date`, which is the whole of what this resource is.** A day holds one
    /// recovery and can hold several workouts, so a session is addressed by its own id — `/v1/workouts/{id}`,
    /// never `{date}`, and the API's contract asserts no `{date}` path exists. `WorkoutSyncRow.id` is
    /// already a `UUID` on this side of the boundary, so a caller cannot ask about a key the wire
    /// would refuse to parse.
    ///
    /// **The children ride inside the row**, because a route has no identity outside the session that
    /// owns it: there is no `/v1/routes/{id}` to fetch, so a session read is one request and never
    /// three.
    func workout(id: UUID) async throws -> WorkoutSyncRow?

    /// Every session filed on a day in `[from, to)`, **half-open**, oldest first, each with its
    /// children.
    ///
    /// Half-open on the app's own convention, exactly as `recoveries(from:to:)` is and for the same
    /// reason. The order is `date`, then the session's own start, then its id — the order the upload
    /// walk reads in, and the reason it has nothing to sort, since a chunk's rows go into one request
    /// whose result is the count the server reports.
    ///
    /// **An empty array is a real answer and not an error**, and here it answers two different
    /// situations this port cannot tell apart: a window whose days hold no session, and one whose days
    /// hold no *reading*. A day inside the window with no session is simply absent, because nothing
    /// pads it — a caller wanting to know which days were covered has to ask the calendar rather than
    /// the length.
    func workouts(from: Date, to: Date) async throws -> [WorkoutSyncRow]

    /// Write one session, replacing it **and both of its child tables**.
    ///
    /// **A replacement rather than a merge, and the children are what that costs.** The server deletes
    /// a stored route and a stored split list and re-inserts whatever this row carried, so an empty
    /// `route` is an affirmative claim that the session has none — which is why `WorkoutSyncRow`'s two
    /// arrays are non-optional and never defaulted. A row that could leave them out would delete a
    /// path the user recorded rather than leaving it alone.
    func writeWorkout(_ row: WorkoutSyncRow) async throws

    /// Write many sessions at once, and report how many the database says it wrote.
    ///
    /// **The count is sessions, not rows.** A session with a two-thousand-point route touches two
    /// thousand and three rows in the server's batch, and the server sums only the parent upserts — so
    /// the number that comes back is a function of how many sessions were written and not of how much
    /// GPS a run collected. Idempotent on `writeRecoveries(_:)`'s argument, and the count must not be
    /// read as "there was nothing to do" for the same reason.
    ///
    /// **A chunk has two size constraints and not one.** The batch's row ceiling is on the session
    /// count, but the child arrays are capped *in aggregate across the chunk* as well as per session —
    /// two hundred sessions with no routes fit easily, two hundred long ones do not — so a caller
    /// chunking on `rows.count` alone can build a request the server refuses. That rule lives in
    /// `SyncEngine`, which is the only thing that chunks.
    func writeWorkouts(_ rows: [WorkoutSyncRow]) async throws -> Int

    // MARK: - Sleeps, keyed on the wake day

    /// Write one night, replacing whatever the database holds for its day.
    ///
    /// **The day is the night's *wake* day and the row is authoritative over it.** `/v1/sleeps/{date}`
    /// keys on the morning the night ended, and the schema says in as many words that the day is not
    /// derived from `startTime` — so a caller must send the day the app stored rather than recomputing
    /// one, or a night that began before midnight lands on a different key on the two sides of this
    /// call.
    ///
    /// Its own method rather than a one-row batch, on `writeRecovery(_:)`'s argument: this is the save a
    /// screen makes when a night is scored, and a batch is a chunk of a history whose size is not
    /// interesting.
    func writeSleep(_ row: SleepSyncRow) async throws

    /// Write many nights at once, and report how many the database says it wrote.
    ///
    /// **Idempotent by construction**, on `writeRecoveries(_:)`'s argument: a night lands on the same
    /// key the single write uses, so a replayed chunk rewrites each night with the values it already
    /// holds, and a replayed chunk reports the same count as the first send rather than zero because
    /// the database counts a matched row as changed.
    ///
    /// **A chunk must name each day exactly once**, which the server enforces. That is free here rather
    /// than something a caller has to arrange: `sleeps` is keyed on `date`, so the app's own read of a
    /// window cannot return the same day twice.
    func writeSleeps(_ rows: [SleepSyncRow]) async throws -> Int

    // MARK: - Step counts, keyed on the day

    /// Write one day's steps, replacing whatever the database holds for it.
    ///
    /// **The only write here whose caller must decide something the row cannot say.** A `measuredSeconds`
    /// of zero is this app's word for *no measurement*, and the wire has no equivalent — its `0` is a
    /// legal reading of zero steps — so a caller that sent an unmeasured day would create a measurement
    /// on the far side that this app reports as absent. `StepCountWireMapper.isSendable` is that
    /// decision, and it belongs to the caller to apply before the call rather than to this method.
    func writeStepCount(_ row: StepCountSyncRow) async throws

    /// Write many days at once, and report how many the database says it wrote.
    ///
    /// Idempotent and count-reporting on `writeRecoveries(_:)`'s argument, and a chunk of the app's
    /// whole step history is a handful of these — the same order as its recoveries.
    func writeStepCounts(_ rows: [StepCountSyncRow]) async throws -> Int

    // MARK: - Receptive inactivities, keyed on the entry

    /// Write one entry, replacing whatever the database holds under its id.
    ///
    /// **Keyed on the entry and not on the day, although the row carries a day** — which is what makes
    /// this the one resource here whose identity is a `String` the *import* derived. A re-import
    /// rewrites an entry rather than appending a second one precisely because
    /// `InactivityParser.identifier(date:type:note:)` is deterministic, so the id is not a label: it is
    /// the mechanism. A caller that minted a fresh one would append.
    func writeReceptiveInactivity(_ row: ReceptiveInactivitySyncRow) async throws

    /// Write many entries at once, and report how many the database says it wrote.
    ///
    /// **The chunk cap is the whole bound on a request's work**, because an entry is one row with no
    /// children — where a chunk of sessions is bounded twice over, here it is bounded once. Idempotent
    /// on `writeRecoveries(_:)`'s argument, and each id must appear exactly once in a chunk, which the
    /// app's own read satisfies because the table's primary key *is* the id.
    func writeReceptiveInactivities(_ rows: [ReceptiveInactivitySyncRow]) async throws -> Int

    // MARK: - The profile, a singleton

    /// Write the caller's profile, replacing the whole row.
    ///
    /// **The one resource with no batch and no window, and both absences are the table's.** A profile is
    /// a singleton keyed on the local `"primary"`, so there is no chunk to split and no range to walk —
    /// this is the whole of what syncing a profile is, and the engine sends it in a single call.
    ///
    /// **A whole-row upsert rather than a patch, and `nil` is a value.** Every field goes on the wire
    /// every time, because the route answers `400` for an omitted one and because a field sent as `null`
    /// is *cleared* — so `nil` here means the user has not supplied that fact, and a caller must not
    /// read it as *leave what is there alone*. That is the same rule the app's own `saveUserProfile`
    /// follows, which is why the two agree without either deferring to the other.
    func writeProfile(_ row: UserProfileSyncRow) async throws
}

/// Why a cloud call failed, split by **what the caller should do about it** rather than by status code.
///
/// Three cases, because there are three behaviours and one of them is a trap. The decorator degrades
/// to the local copy on exactly the first, and propagates the other two:
///
/// - `.unreachable` — the request never got an answer. Airplane mode, no route, a timeout, a server
///   that is down. There is a local copy for some days and this is the case where drawing it is
///   right; a day the phone holds *nothing* for is marked in `SyncStatus` saying a connection is
///   needed, which is the only sentence left to say now that nothing is ever deleted.
/// - `.rejected` — the server answered and refused. The API's own envelope, carrying its own code.
///   The local copy is *not* a substitute: the server knows something this app does not, and hiding
///   that behind a cached figure is how a bug becomes a wrong number on a screen.
/// - `.malformed` — the server answered with something this client cannot read. **Its own case rather
///   than folded into `.unreachable`, and that is the one worth arguing for**: a contract mismatch
///   looks exactly like a connectivity problem if you only ask "did I get data", and degrading over it
///   would silently paper over a client and a server that disagree about the shape of a day. It is a
///   bug, so it surfaces as one.
public enum CloudSyncError: Error, Equatable, Sendable {
    /// No answer at all. The only case a caller may degrade to local storage over.
    case unreachable(message: String)

    /// An answer that refused — the API's `{ error: { code, message } }` envelope, or a status this
    /// client has no reading for.
    case rejected(code: String, message: String)

    /// An answer this client could not read.
    case malformed(message: String)
}
