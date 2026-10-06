import Foundation

/// Range reads and range writes of `workouts`, expressed in the shape the sync moves — records, not
/// entities.
///
/// **This is `RecoverySyncStore`'s protocol for the resource next door, and it has three things that
/// one has no equivalent for.** Everything that file argues applies here verbatim and is not restated:
/// why this is its own protocol rather than two methods on `LocalDatabaseManager` (a Domain use case
/// may not name a Data type), why it is a second door into a table `WorkoutRepository` already reads
/// (`WorkoutRepository` speaks `WorkoutSession`, whose `makeSessions` **drops a row whose id will not
/// parse and mints a fresh `UUID` for every child it keeps** — so a sync built on it could not round
/// trip an id at all), and why the bounds are half-open `[from, to)`: the chunks must abut without
/// overlapping, because a shared instant between two of them is a day written twice.
///
/// **The first difference is that a row here is an aggregate.** A recovery is one row keyed on its day;
/// a workout is three tables keyed on `(user_id, id)`. The children therefore ride *inside*
/// `WorkoutSyncRow` rather than beside it, and that is the whole reason `saveSyncWorkoutRows` below is a
/// replacement rather than an upsert: a parent written without its children would leave the stored
/// route exactly as it was, which is a session whose path and whose summary come from two different
/// writes. Both halves of this protocol therefore carry the children — the read attaches them and the
/// write removes and re-inserts them in the same transaction as the parent.
///
/// **The second is that the read half is where ordering becomes data.** The two child tables have no
/// `seq` column: `WorkoutRoutePointRecord` is `(id, workout_id, latitude, longitude, timestamp,
/// heart_rate)` and `WorkoutSplitRecord` is `(id, workout_id, elapsed, strain)`, and `getRoutePoints`
/// / `getSplits` recover an order by sorting on `timestamp` and `elapsed`. The wire has no `seq`
/// either, because a JSON array is already ordered — the server's `seq` column is bound from the
/// array's index. So the array this protocol hands out *is* the sequence, and an implementation must
/// return the manager's own sorted read rather than re-sorting it into a second ordering rule that
/// agrees with the first today and need not tomorrow.
///
/// **The third is the `String`/`UUID` boundary, and it is the one policy a reader has to know.** The
/// stored id is a `String` and `WorkoutSyncRow.id` is a `UUID`; the conversion happens here and
/// nowhere else, in both directions. It is not symmetric, and the asymmetry is not this file's
/// invention — it is `GRDBWorkoutRepository.makeSessions`' rule, applied one layer down so that a sync
/// row and a screen's session cannot disagree about which rows exist:
///
/// - **A session whose stored id will not parse is dropped from the read**, not given a fresh one. A
///   session's id *is* its address — it is what `/v1/workouts/{id}` names and what every keyed read
///   matches on — so inventing an identity for it would upload a session under an id that corresponds
///   to nothing stored and that no screen of this app would ever find again. `makeSessions` skips such
///   a row (`guard let id = UUID(uuidString: record.id) else { continue }`) for exactly this reason.
/// - **A route point or a split whose stored id will not parse keeps its place and takes a fresh
///   `UUID()`.** A fix is at a real place at a real moment and its id is part of no lookup, so
///   dropping it would leave a hole in a recorded path — a drawing of a route the user did not take.
///   `makeSessions` keeps these the same way (`UUID(uuidString: $0.id) ?? UUID()`), and its own
///   comment is the argument: *"its `id` is not part of any lookup, unlike the session's."*
///
/// A caller therefore cannot be handed a row for a session it could not address, and cannot lose a
/// GPS fix to a storage defect it had no part in.
///
/// **The two method names carry the resource and their sibling's do not, and Swift is why.**
/// `LocalDatabaseManager` implements several sync-store protocols, and `syncRows(from:to:)` differs
/// from the recoveries one in nothing at all — a method's signature is its name plus its argument
/// labels, and the row type appears in neither. Declaring it again is `invalid redeclaration`, so the
/// workouts half is spelled `syncWorkoutRows` / `saveSyncWorkoutRows`: the resource is the only thing
/// that can tell them apart, so it is the thing the name says. (`saveSyncRows(_:)` could have
/// overloaded on its array's element type, and deliberately does not — one protocol whose methods are
/// named two ways is worse than two protocols' worth of clarity.)
public protocol WorkoutSyncStore: Sendable {

    /// Every session filed on a day in `[from, to)`, **half-open**, oldest first, each with its route
    /// and its splits attached in their recorded order.
    ///
    /// The order is `date`, then `started_at`, then `id` — which is the order every store in this folder
    /// answers in, and it is the order a chunking upload wants: a day can hold several sessions, and the
    /// rows of one chunk go into one request whose result is the count the server reports. Ties on both
    /// a day and a start instant are broken by the id so the walk is deterministic rather than
    /// filesystem-dependent; the two orders agree on every session this app writes, because `startedAt`
    /// is a second-resolution instant at worst.
    func syncWorkoutRows(from: Date, to: Date) async throws -> [WorkoutSyncRow]

    /// Insert or replace every session given, **with its children**, in **one** transaction.
    ///
    /// One transaction rather than a loop, on the recoveries' argument: a chunk that fails halfway
    /// leaves a set of days nothing can describe — some written and some not — and the next run would
    /// rewrite the whole chunk by replacement without being able to tell which half had landed. The
    /// children are inside that same transaction, which is the difference from the flat resource — a
    /// parent that
    /// landed and a route that did not is a session whose path is from an older write, and nothing on
    /// disk records that.
    ///
    /// **It is a replacement and not a merge.** `WorkoutRepository.save` is INSERT-or-UPDATE by primary
    /// key, and for this resource that is not enough: a stored route and a stored split list are
    /// *removed and re-inserted* for each session written, so a row carrying an empty `route` states
    /// affirmatively that the session has none. `WorkoutSyncRow`'s two arrays are non-optional and
    /// never defaulted for that reason, and an implementation that only upserted the parent would leave
    /// a deleted path on disk forever.
    ///
    /// The day key is snapped to `startOfDay` here, centrally, for the reason every other writer in
    /// this app snaps it there: `saveWorkout` does it, GRDB's `save` is INSERT-or-UPDATE *by primary
    /// key*, and a row written at a raw timestamp is inserted rather than updated and no keyed read
    /// finds it again.
    func saveSyncWorkoutRows(_ rows: [WorkoutSyncRow]) async throws
}
