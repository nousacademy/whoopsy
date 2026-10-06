import Foundation

/// Range reads and range writes of `strains`, expressed in the shape the sync moves — records, not
/// entities.
///
/// **This is `RecoverySyncStore`'s protocol for the resource that is most like it, and it is short
/// because the two tables have the same shape.** Why this is its own protocol rather than two
/// methods on `LocalDatabaseManager` (a Domain use case may not name a Data type), why it is a second
/// door into a table `StrainRepository` already reads (`StrainRepository` speaks `StrainScore`, whose
/// `zones` array is computed and has no column, so a sync built on the entity would carry a field the
/// database cannot store), and why the bounds are half-open `[from, to)` (the chunks must abut without
/// overlapping, because a shared instant between two of them is a day written twice) all carry over
/// verbatim and are not restated.
///
/// **What has no counterpart here is the aggregate half.** There are no children, so `saveSyncStrainRows`
/// is a plain upsert rather than a replacement, and there is no order to recover or preserve. The
/// `String`/`UUID` boundary does not exist either: a strain's identity *is* its day, which is a `Date`
/// on both sides.
///
/// **The two method names carry the resource and their siblings' do not, and Swift is why.**
/// `LocalDatabaseManager` implements several sync-store protocols now, and `syncRows(from:to:)` differs
/// from the recoveries one in nothing at all — a method's signature is its name plus its argument
/// labels, and the row type appears in neither. Declaring it again is `invalid redeclaration`, so this
/// half is spelled `syncStrainRows` / `saveSyncStrainRows`, on `WorkoutSyncStore`'s rule. **The
/// resource is the only thing that can tell them apart, so it is the thing every name says** — and the
/// temptation to shorten this one to `syncStrainRows`/`saveSyncRows` would leave two protocols'
/// conformance looking like one.
public protocol StrainSyncStore: Sendable {

    /// Every day filed in `[from, to)`, **half-open**, ascending.
    ///
    /// Ascending is the store's contract rather than a convenience, on the rule every store in this
    /// folder keeps: a chunk's rows go into one request and the server counts what it wrote, so a
    /// shuffled read would make the count stop mapping onto any span a reader could name. A day holds
    /// at most one strain, so unlike `workouts` there is no second ordering key — the day alone is the
    /// order.
    func syncStrainRows(from: Date, to: Date) async throws -> [StrainSyncRow]

    /// Insert or replace every row given, in **one** transaction.
    ///
    /// One transaction rather than a loop, on the recoveries' argument: a chunk that fails halfway
    /// leaves a set of days nothing can describe — some written and some not — and the next run would
    /// rewrite the whole chunk by replacement without being able to tell which half had landed.
    ///
    /// The day key is snapped to `startOfDay` by the implementation, centrally, for the reason every
    /// other writer in this app snaps it there: GRDB's `save` is INSERT-or-UPDATE *by primary key*, and a
    /// row written at a raw timestamp is inserted rather than updated and no keyed read finds it again.
    func saveSyncStrainRows(_ rows: [StrainSyncRow]) async throws
}
