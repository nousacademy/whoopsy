import Foundation

/// The window's mean sleep efficiency — the figure the efficiency card prints under the night's own.
///
/// **Efficiency is `asleep ÷ sleep period`, and the sleep period is `asleep + awake`.** It is not
/// `asleep ÷ time in bed`: `SleepSession.sleepPeriodSeconds` documents the difference at length and
/// reproduces WHOOP's `In bed duration` column exactly, which is why the denominator is the entity's
/// own property rather than a subtraction written here.
///
/// **It is a different quantity from sleep performance, and the two cards are not redundant.**
/// Performance is `asleep ÷ need` — a statement about whether the night was long enough — while
/// efficiency is `asleep ÷ (asleep + awake)` — a statement about how much of the night spent in bed
/// was actually spent asleep, with no reference to the need at all. A short night slept through
/// without a single waking scores 100% efficiency and can score 60% performance; the two move
/// independently and the screen prints both.
///
/// **A night with no sleep period is filtered out before the count floor is applied**, on
/// `SleepStageRangeScoring.summary`'s rule and for its reason. `SleepSession
/// .sleepEfficiencyPercentage` guards `sleepPeriodSeconds > 0` by returning `100`, which is the
/// honest answer for a ring with nothing under it and a fabricated one in a window mean — a
/// zero-length night would enter this average as a perfect one. Filtering first and *then* testing
/// `minimumBaselineDays` is what makes a window of five nights with one empty still produce a mean
/// and a window of three with one empty decline to.
public enum SleepEfficiencyScoring {
    /// The mean efficiency over the window, or `nil` below `RecoveryScoring.minimumBaselineDays`.
    ///
    /// - Parameter window: The nights to average, already narrowed by
    ///   `RecoveryScoring.baselineWindow(before:in:)` at the caller. This type does not re-window, on
    ///   `SleepConsistencyScoring.typicalScore`'s reasoning: the card and the page's other "typical"
    ///   figures must not come to describe different histories.
    public static func typicalEfficiency(in window: [SleepSession]) -> Double? {
        let efficiencies = window
            .filter { $0.sleepPeriodSeconds > 0 }
            .map(\.sleepEfficiencyPercentage)

        guard efficiencies.count >= RecoveryScoring.minimumBaselineDays else { return nil }
        return Double(efficiencies.reduce(0, +)) / Double(efficiencies.count)
    }
}
