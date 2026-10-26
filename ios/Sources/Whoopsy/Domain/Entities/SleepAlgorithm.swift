import Foundation

/// Which rule produced a stored night's classification.
///
/// **A night is not a measurement the way a heart rate is; it is a decision this app made** — where
/// onset was, which epochs were asleep, what the need was. Two rows classified by different rules are
/// therefore not the same claim, and before this type the table could not tell them apart. That is
/// what forced the sleep page to re-run the classifier on every open: with no version on the row, the
/// only way to be sure a night met the current rule was to recompute it, and a recompute over a night
/// whose drain had not finished could answer "no night" and take a real row with it.
///
/// **A change to any staging rule, onset threshold or need form is a new case.** The values
/// themselves are `docs/ALGORITHMS.md` §4's, and a rule that moves without a new string here leaves
/// two rows that disagree looking identical — the failure `StrainAlgorithm` exists to prevent on the
/// other table.
public enum SleepAlgorithm: String, CaseIterable, Sendable {

    /// The actigraphy stager as `AnalyzeSleepUseCase` applies it today: motion onset, epoch staging,
    /// the measured-rate ceiling and the fitted sleep-need form.
    case stagerV1 = "stager-v1"

    /// WHOOP's own night, read from the bundled export and stored verbatim. Never this app's decision,
    /// and never reclassified.
    case whoopExport = "whoop-export"

    /// The version a night written now records.
    public static let current: SleepAlgorithm = .stagerV1

    /// The version a stored string names, or `nil` when the row predates the column.
    public init?(stored: String?) {
        guard let stored else { return nil }
        self.init(rawValue: stored)
    }
}
