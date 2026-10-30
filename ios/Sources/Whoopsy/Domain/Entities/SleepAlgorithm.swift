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
    ///
    /// **`v2` changed one thing and it is not the staging: the night's data-edge verdict.** A night
    /// used to record *ended at the data edge* only when no epoch at all followed it, so a run that
    /// happened while a drain was still delivering could see a few live epochs past the end, stamp
    /// *trimmed at a wake*, and freeze the row at a fragment — the reclassification gate then treats
    /// everything after that end as wake time for the rest of the night's life. `v2` asks whether the
    /// evidence **resumes** within `SleepReclassification.extensionGraceSeconds` instead, so a hole
    /// means the night may still grow and a continuous run means it really ended. The staging, the
    /// staging bands and the sleep-need form are untouched.
    ///
    /// **It is a version bump rather than an edit for the reason every one is**: a stored row carries
    /// the verdict its own rule produced, and no row written by `v1` can be asked whether it would
    /// still be frozen under `v2`. Bumping re-classifies each strap night once — which is also how a
    /// night already frozen at a fragment gets its second look.
    case stagerV1 = "stager-v1"

    /// The same staging with the data-edge verdict repaired. See `stagerV1`.
    case stagerV2 = "stager-v2"

    /// WHOOP's own night, read from the bundled export and stored verbatim. Never this app's decision,
    /// and never reclassified.
    case whoopExport = "whoop-export"

    /// The version a night written now records.
    public static let current: SleepAlgorithm = .stagerV2

    /// The version a stored string names, or `nil` when the row predates the column.
    public init?(stored: String?) {
        guard let stored else { return nil }
        self.init(rawValue: stored)
    }
}
