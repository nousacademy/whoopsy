import Foundation

/// The formula that produced a `recoveries` row.
///
/// **Every computed metric row has to record what computed it**, and recovery was the last one that
/// did not: `strains.algorithm` and `sleeps.algorithm` were added for exactly this reason, and a
/// recovery row could only say *when* it was written rather than *by what*. The consequence is the one
/// the repo has already paid for twice — a corrected estimator leaves its predecessor's numbers on
/// disk, and nothing can tell an old row from a current one, so a migration has to guess which days to
/// clear. With the version stored, the day is simply re-scored when the version is not this one.
///
/// It is a `String` raw value because it is a column, and the raw value is what is written — an index
/// would silently re-point every stored row at a different formula the moment a case is inserted.
///
/// **A parameter change is a version bump.** The calibration constants live in `RecoveryScoring`; the
/// day a weight or a boundary moves, this enum gains a case and `current` moves with it, which is what
/// makes every stored row re-scoreable rather than silently stale.
public enum RecoveryAlgorithm: String, CaseIterable, Sendable {

    /// The z-score model in `RecoveryScoring`, over the last thirty days that have measurements.
    case scorerV1 = "scorer-v1"

    /// The version a row written now records.
    public static let current: RecoveryAlgorithm = .scorerV1

    /// The version a stored string names, or `nil` when the row predates the column.
    public init?(stored: String?) {
        guard let stored else { return nil }
        self.init(rawValue: stored)
    }
}
