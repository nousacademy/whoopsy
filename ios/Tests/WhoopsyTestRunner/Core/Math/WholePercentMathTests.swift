import Foundation
import Whoopsy

enum WholePercentMathTests {
    static func run() async throws {
        // ── 2. The percent column ────────────────────────────────────────────────────────────────────
        //
        // The rule the card's four figures are drawn from, and the reason it is largest-remainder rather
        // than rounding: the card prints `DURATION` above the column, so a column summing to 99 or 101
        // contradicts the total printed at the top of its own card.
        let halves = SleepStageRangeScoring.wholePercents(
            ofSeconds: [10800, 10800, 3600, 3600])
        assertTest(
            halves == [38, 38, 12, 12],
            "3h/3h/1h/1h is 37.5/37.5/12.5/12.5 — floors sum to 98 and the two spare seats go to the "
                + "largest remainders, giving [38, 38, 12, 12] "
                + "(got \((halves ?? []).map { "\($0)" }.joined(separator: ", ")))")
        assertTest(
            halves?.reduce(0, +) == 100,
            "…and the column sums to exactly 100, which naive rounding does not: it gives "
                + "38 + 38 + 13 + 13 = 102")

        // A three-way tie on the remainder, broken by position so the answer is reproducible rather than
        // dependent on how a sort happened to order equal keys.
        assertTest(
            SleepStageRangeScoring.wholePercents(ofSeconds: [1, 1, 1, 0]) == [34, 33, 33, 0],
            "Three equal thirds tie on their remainder and the spare seat goes to the first row — the "
                + "tie-break that makes this column reproducible")

        assertTest(
            SleepStageRangeScoring.wholePercents(ofSeconds: [1, 1, 1, 1]) == [25, 25, 25, 25],
            "Four equal stages need no seat at all — the floors already sum to 100")

        // No total to divide by, in every form one can arrive. Each of these is a `nil` and not a
        // four-zero column, which is the difference between "we could not describe this night" and "this
        // night was 0% awake".
        assertTest(
            SleepStageRangeScoring.wholePercents(ofSeconds: []) == nil
                && SleepStageRangeScoring.wholePercents(ofSeconds: [0, 0, 0, 0]) == nil,
            "An empty list and an all-zero night both have no column — `nil`, not four zeros")
        assertTest(
            SleepStageRangeScoring.wholePercents(ofSeconds: [-1, 2, 3, 4]) == nil
                && SleepStageRangeScoring.wholePercents(ofSeconds: [.nan, 1, 1, 1]) == nil
                && SleepStageRangeScoring.wholePercents(ofSeconds: [.infinity, 1, 1, 1]) == nil,
            "A negative, a NaN and an infinity each make the column `nil` rather than a silent wrong answer")

        // The property, over every fixture above rather than only the ones with a pinned answer: each
        // percent is within one of its exact share. That is the guarantee largest-remainder actually
        // makes, and it holds for any input.
        let fixtures: [[TimeInterval]] = [
            [10800, 10800, 3600, 3600], [15120, 6480, 5760, 1440], [3600, 14400, 5400, 5400],
            [1, 2, 3, 7], [1, 1, 1, 0],
        ]
        let farOff = fixtures.filter { durations in
            guard let percents = SleepStageRangeScoring.wholePercents(ofSeconds: durations) else {
                return true
            }
            let total = durations.reduce(0, +)
            return zip(percents, durations).contains { percent, seconds in
                abs(Double(percent) - seconds / total * 100) > 1
            }
        }
        assertTest(
            farOff.isEmpty,
            "Every percent in every fixture is within one of its exact share (\(farOff.count) fixtures "
                + "are not)")

    }
}
