import Foundation

/// Range reads and range writes of `sleeps`, expressed in the shape the sync moves — records, not
/// entities.
///
/// **This is `RecoverySyncStore`'s protocol for the resource that is shaped most like it**, and the
/// arguments that file makes carry over verbatim rather than being restated: why it is its own protocol
/// rather than two methods on `LocalDatabaseManager` (a Domain use case may not name a Data type), why
/// it is a second door into a table `SleepRepository` already reads (`SleepRepository` speaks
/// `SleepSession`, whose `id` is a `UUID` the record does not have and whose stage timeline is a parsed
/// `[SleepStageSegment]` rather than the stored string — so a sync built on the entity could not round
/// trip a night at all), and why the bounds are half-open `[from, to)` (the chunks must abut without
/// overlapping, and a shared instant between two of them is a night written twice).
///
/// **What this resource adds is a day key nobody may recompute.** A night's `date` is its **wake** day
/// — the morning it ended — and the API's schema says in as many words that it is not derived from
/// `startTime`. That makes this the one table where the *reader* must not do arithmetic: a caller that
/// keyed a night on `startOfDay(startTime)` would file every night that began before midnight one day
/// early, and the two sides of a sync would disagree about a key neither of them prints.
///
/// **The four optional columns ride through in both directions and none of them is normalised.** An
/// imported night stores WHOOP's own `respiratoryRate` and `sleepDebt` verbatim while a strap night has
/// the first computed and the second absent, and `sleepConsistency` and `disturbanceCount` are `nil` on
/// every imported night — so a read that dropped a `nil`, or a save that turned one into a `0`, would
/// make two different kinds of absence into one and a real reading into a fabricated one. The one
/// exception is deliberate and lives a layer up: `SleepWireMapper` sends an empty stage array as
/// `null`, because the schema has no spelling for *staged and empty*.
public protocol SleepSyncStore: Sendable {

    /// Every night filed on a day in `[from, to)`, **half-open**, ascending by wake day.
    ///
    /// Ascending is load-bearing rather than a convenience: an upload chunks this array and advances its
    /// boundary to each chunk's last row, so a shuffled read would move the boundary across days it had
    /// not sent. A day holds at most one night, so unlike `workouts` there is no second ordering key —
    /// the day alone is the order.
    func syncSleepRows(from: Date, to: Date) async throws -> [SleepSyncRow]

    /// Insert or replace every night given, in **one** transaction.
    ///
    /// One transaction rather than a loop, on the recoveries' argument: a chunk that fails halfway
    /// leaves a range the sync cannot describe, so the next run can neither skip nor rewrite the
    /// remainder honestly. Each night lands on its own day, so a replayed chunk rewrites what it
    /// already wrote rather than appending.
    ///
    /// The day key is snapped to `startOfDay` by the implementation, centrally, for the reason every
    /// other writer in this app snaps it there: GRDB's `save` is INSERT-or-UPDATE *by primary key*, and
    /// a row written at a raw timestamp is inserted rather than updated and no keyed read finds it
    /// again.
    func saveSyncSleepRows(_ rows: [SleepSyncRow]) async throws
}
