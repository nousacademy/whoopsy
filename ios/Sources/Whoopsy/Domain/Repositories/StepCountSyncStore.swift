import Foundation

/// Range reads and range writes of `stepCounts`, expressed in the shape the sync moves — records, not
/// entities.
///
/// **The plainest protocol in this family, and the plainness is the resource.** `RecoverySyncStore`'s
/// arguments carry over verbatim — its own protocol rather than two methods on `LocalDatabaseManager`, a
/// second door into a table because `StepCountRepository` speaks `StepCount` while a sync moves the
/// stored row, and half-open `[from, to)` bounds so two chunks abut without sharing an instant.
///
/// **What it has no counterpart for is everything the other tables need.** There are no children, so
/// the save is a plain upsert rather than a replacement and there is no order to recover or preserve.
/// There is no `String`/`UUID` boundary: the identity is the day, a `Date` on both sides. There is no
/// second producer, so there is no provenance column to carry — and `stepCounts` deliberately has none,
/// because a per-row label could not be written honestly on a table only the strap feeds.
///
/// **The one rule this resource owns is that its absence is a column rather than a missing row.** Every
/// other day-keyed table here says *nothing was measured* by holding no row; steps say it with
/// `measuredSeconds == 0`, and `StepCount.hasMeasurement` is that exact test, applied on both sides of
/// the write. So a read must hand back a zero-length day as a row rather than skipping it — the caller
/// needs to see it to know it exists — and a save must store it rather than refusing it, because
/// refusing would make the two sides of a sync disagree about whether the day is on disk at all. Which
/// of those rows travel to the server is a different question, and it is `StepCountWireMapper.isSendable`'s.
public protocol StepCountSyncStore: Sendable {

    /// Every day filed in `[from, to)`, **half-open**, ascending.
    ///
    /// Ascending is load-bearing rather than a convenience, on this family's rule: an upload chunks this
    /// array and advances its boundary to each chunk's last row, so a shuffled read would move the
    /// boundary across days it had not sent. A day holds at most one row, so the day alone is the order.
    func syncStepCountRows(from: Date, to: Date) async throws -> [StepCountSyncRow]

    /// Insert or replace every day given, in **one** transaction.
    ///
    /// One transaction rather than a loop, on the recoveries' argument: a chunk that fails halfway
    /// leaves a range the sync cannot describe, so the next run can neither skip nor rewrite the
    /// remainder honestly. The day key is snapped to `startOfDay` by the implementation, centrally, for
    /// the reason every other writer in this app snaps it there: GRDB's `save` is INSERT-or-UPDATE *by
    /// primary key*, and a row written at a raw timestamp is inserted rather than updated and no keyed
    /// read finds it again.
    func saveSyncStepCountRows(_ rows: [StepCountSyncRow]) async throws
}
