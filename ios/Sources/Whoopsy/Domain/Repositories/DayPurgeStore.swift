import Foundation

/// The door `PurgeDaysUseCase` removes days through.
///
/// **Its own protocol rather than a method on `RecoveryRepository` or on `LocalDatabaseManager`**, on
/// the rule the rest of this folder follows: the use case is a Domain type and may not name a Data one,
/// so what it depends on is this and what implements it is `LocalDatabaseManager` — the same
/// arrangement `RecoverySyncStore` and `LocalDatabaseSnapshotting` have.
///
/// **One method, and its subject is a span of days rather than a table.** A purge has to remove every
/// measured row for a day across seven tables in one transaction, and no single repository can: five
/// of them own one table each, and the samples and motion epochs have no repository that deletes at
/// all. Splitting this into `recoveries.deleteRange` + `sleeps.deleteRange` + … would make the purge
/// seven partial operations that a failure can strand halfway — which is exactly the state
/// (`steps but no recovery`) that no writer produces and no reader expects.
///
/// **It deletes measurements and not sessions.** `workouts` and `receptive_inactivities` are outside
/// this door on purpose: an activity or a fast is something the owner recorded, and the operation this
/// exists for is about days a model got wrong. The tally it answers with names the seven tables it did
/// touch, so what was removed is visible rather than inferred.
public protocol DayPurgeStore: Sendable {
    /// Remove every measured row filed in `from…to`, **inclusive at both ends**, in one transaction.
    ///
    /// The bounds are snapped to `startOfDay` here rather than at the call site, as they are on every
    /// day-keyed write — a purge run from a view model holding a raw `Date` must not remove a
    /// neighbouring day because the caller's instant was midday.
    func purgeMeasuredDays(from: Date, to: Date) async throws -> DayPurgeTally
}
