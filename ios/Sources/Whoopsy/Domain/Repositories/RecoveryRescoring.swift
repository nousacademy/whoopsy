import Foundation

/// A type that can recompute the current day's recovery row on demand.
///
/// **It exists for one caller: the day purge.** `RefreshRecoveryUseCase` normally answers "is this row
/// owed?" from the night's watermark, and deleting *other* days moves neither the night nor the
/// watermark — but it does change the scoring window, because the baseline is a mean and a spread over
/// the trailing 30 days **that have rows**. A purge therefore leaves today's score computed against a
/// window that no longer exists, and nothing in the row's own audit fields can notice.
///
/// A protocol rather than the concrete actor so the purge can be driven in the suite without a
/// database, on the rule the rest of this folder follows.
public protocol RecoveryRescoring: Sendable {
    /// Recompute the current day's row, bypassing the gate that would otherwise skip it.
    ///
    /// `force` is the whole point: without it the call is a no-op for a row the night has not moved,
    /// which is every row after a purge.
    @discardableResult
    func refreshToday(now: Date, force: Bool) async -> RecoveryMetric?
}

extension RecoveryRescoring {
    /// The ordinary call, without the override.
    @discardableResult
    public func refreshToday() async -> RecoveryMetric? {
        await refreshToday(now: Date(), force: false)
    }
}
