import Foundation

/// Range reads and range writes of `recoveries`, expressed in the shape the sync moves — records, not
/// entities.
///
/// **Its own protocol rather than two methods on `LocalDatabaseManager`**, on the rule the rest of
/// this folder follows: `SyncEngine` is a Domain type and may not name a Data one, so what
/// it depends on is this and what implements it is `LocalDatabaseManager` — the same arrangement
/// `LocalDatabaseSnapshotting` has, and the same arrangement `GRDBRecoveryRepository` has with
/// `RecoveryRepository`. The conformance is declared as a bare extension at the foot of
/// `LocalDatabaseManager.swift`, beside the snapshotting one.
///
/// **Why this is a second way into a table `RecoveryRepository` already reads**, and why that is not
/// the duplication it looks like: `RecoveryRepository` speaks `RecoveryMetric`, which has no `source`
/// and carries three baseline deltas that have no column. A sync built on it would drop provenance on
/// every imported row and would have nothing to write into three of the columns on the way back —
/// silently, with a green build. So the sync gets a door that speaks the stored shape
/// (`RecoverySyncRow`), and the two doors answer different questions on purpose.
///
/// **The bounds are half-open `[from, to)`**, on this app's own convention rather than the wire's:
/// `Date.startOfNextDay` builds the upper bound and `Date.endOfDay` would be the wrong one, being the
/// last *instant* of a day rather than the first of the next. That differs from
/// `getRecoveryHistory(days:endingOn:)`'s inclusive-both-ends window, deliberately: a screen asks for
/// *the days up to and including this one*, while a sync chunks an arithmetic range and needs the
/// chunks to abut without overlapping — a shared instant between two chunks is a day written twice.
public protocol RecoverySyncStore: Sendable {
    /// Every row filed in `[from, to)`, ascending by day.
    func syncRows(from: Date, to: Date) async throws -> [RecoverySyncRow]

    /// Insert or replace every row given, in **one** transaction.
    ///
    /// One transaction rather than a loop of `saveRecovery` calls, because a chunk that fails halfway
    /// leaves a set of days nothing can describe: some written and some not, with no record on either
    /// side of which is which. Neither store removes a row, so the next run would rewrite the whole
    /// chunk by replacement anyway — and a run that reported a partly-landed chunk as done is the
    /// failure this arrangement exists to prevent.
    ///
    /// The day key is snapped to `startOfDay` here, centrally, for the reason every other writer in
    /// this app snaps it there: GRDB's `save` is INSERT-or-UPDATE *by primary key*, so a row written
    /// at a raw timestamp is inserted rather than updated and no keyed read can find it again.
    func saveSyncRows(_ rows: [RecoverySyncRow]) async throws
}
