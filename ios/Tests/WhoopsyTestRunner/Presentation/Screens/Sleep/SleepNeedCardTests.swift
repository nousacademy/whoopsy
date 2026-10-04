import Foundation
import Whoopsy

enum SleepNeedCardTests {
    static func run() async throws {
        // ── The window's mean performance ────────────────────────────────────────────────────────────
        //
        // The comparison the card heads itself with. Its three priors carry **different needs** — 8h, 9h
        // and 10h against the same 7h of sleep — so the mean is not a mean of three identical figures,
        // and the entity's own rounding is visible in it: 88, 78 and 70 average to 78.67, where averaging
        // the exact ratios (87.5, 77.78, 70) gives 78.43. The two are 0.24 apart and the assertion tells
        // them apart, which is what pins the mean as one *of the printed night figures* rather than of
        // the underlying seconds.
        func shortNight(dayOffset: Int, need: TimeInterval) -> SleepSession {
            TypicalRangeTests.night(dayOffset: dayOffset, light: 25200, deep: 0, rem: 0, awake: 0, need: need)
        }
        let needlessPriors = [
            shortNight(dayOffset: 30, need: 8 * 3600),
            shortNight(dayOffset: 20, need: 9 * 3600),
            shortNight(dayOffset: 10, need: 10 * 3600),
        ]
        let needTarget = shortNight(dayOffset: 0, need: 8 * 3600)

        if let performanceSummary = SleepStageRangeScoring.summary(
            for: needTarget, priorNights: needlessPriors) {
            assertTest(
                performanceSummary.typicalPerformancePercent.map { abs($0 - 236.0 / 3.0) < 0.0001 }
                    == true,
                "The window's mean performance is the mean of the nights' own rounded figures — 88, 78 "
                    + "and 70 — which is 78.67, and not the 78.43 an average of the exact ratios gives "
                    + "(got \(performanceSummary.typicalPerformancePercent.map { String(format: "%.2f", $0) } ?? "nil"))")

            assertTest(
                performanceSummary.typicalPerformancePercent.map {
                    abs($0 - 78.4259) > 0.1
                } == true,
                "…asserted against the wrong answer too, so the assertion above cannot pass by agreeing "
                    + "with a re-derivation of the same thing")
        } else {
            assertTest(false, "A three-night window produced no summary at all")
        }

        // The empty night is dropped from the **performance** mean as well, and this is the case where
        // including it would be invisible on the card: it carries a need and no sleep, so its performance
        // is a real-looking `0`, and a mean over five nights where one is that zero is 80 against the 100
        // the four real nights give.
        if let withEmptyPerformance = SleepStageRangeScoring.summary(
            for: TypicalRangeTests.target, priorNights: TypicalRangeTests.priors + [TypicalRangeTests.empty]) {
            assertTest(
                withEmptyPerformance.typicalPerformancePercent.map { abs($0 - 100) < 0.0001 } == true,
                "A stored night with no sleep period contributes no performance either — its `0` is a "
                    + "night that was not slept rather than a night that scored nothing, and an "
                    + "unfiltered mean over the same five nights reads 80")
        } else {
            assertTest(false, "Five nights, one of them empty, still produced no summary")
        }

        // The fifth carrier of the one condition. `Summary`'s doc comment lists five equivalents of
        // `nightCount == 0`, and this is the assertion that holds the newest of them to it.
        if let twoPriorsPerformance = SleepStageRangeScoring.summary(
            for: TypicalRangeTests.target, priorNights: Array(TypicalRangeTests.priors.suffix(2))) {
            assertTest(
                twoPriorsPerformance.typicalPerformancePercent == nil
                    && twoPriorsPerformance.typicalAsleepSeconds == nil
                    && twoPriorsPerformance.typicalRestorativeSeconds == nil
                    && twoPriorsPerformance.nightCount == 0
                    && twoPriorsPerformance.rows.allSatisfy({ $0.typical == nil }),
                "Below `minimumBaselineDays` the mean performance is withheld along with the other four "
                    + "carriers of the same fact — the card then prints its figure alone rather than "
                    + "against a mean taken over two nights")
        } else {
            assertTest(false, "A thin window returned no summary at all; it must still describe the night")
        }

    }
}
