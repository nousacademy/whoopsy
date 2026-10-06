import Foundation

/// The sync status, in memory, for the life of the process.
///
/// **Deliberately not persisted, and that is a decision rather than an omission.** This records what the
/// *last read* found, and a read is a thing that happens on a screen. A relaunch is followed by a read
/// before anything is drawn — `HomeViewModel.load(for:)` is the screen's own `.task` — so a stored copy
/// would be re-derived a moment later, and the only thing persistence could add is a stale note surviving
/// a launch to describe a connection that has since come back.
///
/// **It holds one set where it used to hold two.** `SyncStatus` lost `markStale(_:)` and `staleDays()`
/// with the delete that justified them, so the read-modify-write that used to keep the two sets disjoint
/// — and the ordering bug that lived in it — has nothing left to keep apart. What survives is a single
/// set of days the database holds and this phone cannot show.
///
/// **It is an `actor` rather than a class behind a lock, on `KeychainSyncKeyStore`'s reasoning made
/// structural.** The decorator writes this set from whatever task happened to be awaiting a request, and
/// a screen may read it from another; an actor makes each mark and each clear one uninterrupted turn
/// rather than something the caller has to arrange.
public actor SyncStatusLog: SyncStatus {

    private var unavailable: Set<Date> = []

    public init() {}

    public func markUnavailable(_ day: Date) async {
        unavailable.insert(day.startOfDay)
    }

    public func clear(_ day: Date) async {
        unavailable.remove(day.startOfDay)
    }

    public func unavailableDays() async -> Set<Date> { unavailable }
}
