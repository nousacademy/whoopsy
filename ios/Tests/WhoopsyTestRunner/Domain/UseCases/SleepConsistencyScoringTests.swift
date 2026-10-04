import Foundation
import Whoopsy

enum SleepConsistencyScoringTests {
    static func run() async throws {
        // ── 9. The window mean ───────────────────────────────────────────────────────────────────────
        //
        // The figure's comparison, resolved night by night with the stored value taking precedence. The
        // assertion that matters is the second: a night neither path can score is **left out** of the
        // mean rather than counted as a zero, and a window of two scored nights and three unscored ones
        // is a mean over two rather than over five.
        do {
            let calendar = Calendar.current
            let base = calendar.startOfDay(for: Date())

            func scoredNight(_ dayOffset: Int, _ score: Int?) -> SleepSession {
                let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
                return SleepSession(
                    date: day,
                    startTime: calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!,
                    endTime: calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day)!,
                    sleepConsistency: score)
            }

            let threeStored = [scoredNight(1, 90), scoredNight(2, 92), scoredNight(3, 94)]
            assertTest(
                SleepConsistencyScoring.typicalScore(in: threeStored, history: threeStored)
                    .map { TypicalRangeTests.near($0, 92) } == true,
                "Three stored figures average at face value — 90, 92, 94 is 92, and no model is run over "
                    + "a night that already carries WHOOP's own answer")

            // Two nights with no stored figure and nothing to compute one from: fewer than four priors
            // each, so `SleepConsistencyMath` returns `nil` for both.
            let unscored = [scoredNight(4, nil), scoredNight(5, nil)]
            assertTest(
                SleepConsistencyScoring.typicalScore(in: unscored, history: unscored) == nil,
                "Two nights that cannot be scored are no mean at all — below `minimumBaselineDays` there "
                    + "is no mean to take over two nights, and the card's spoken description says so "
                    + "rather than naming a typical figure")

            assertTest(
                SleepConsistencyScoring.typicalScore(
                    in: threeStored + unscored, history: threeStored + unscored)
                    .map { TypicalRangeTests.near($0, 92) } == true,
                "…and adding two unscoreable nights to a window of three leaves the mean at 92. Counting "
                    + "them as zeroes would make it 55.2 — a `0%` consistency is a claim about a night, and "
                    + "no night was measured there")

            assertTest(
                SleepConsistencyScoring.typicalScore(
                    in: [scoredNight(1, 90), scoredNight(2, nil)], history: [scoredNight(2, nil)])
                    == nil,
                "One scored night and one that cannot be is still below the floor: the count is of the "
                    + "nights in the mean, not of the nights in the window")
        }

    }
}
