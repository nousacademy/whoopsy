import Foundation
import Whoopsy

enum TypicalRangeBarTests {
    static func run() async throws {
        // ── 3. The bar's layout ──────────────────────────────────────────────────────────────────────
        let banded = TypicalRangeBarLayout(
            percent: 50,
            typical: SleepStageRangeScoring.Typical(lowPercent: 20, highPercent: 80))
        assertTest(
            TypicalRangeTests.near(banded.filledFraction, 0.5) && TypicalRangeTests.near(banded.unfilledFraction, 0.5),
            "Half the night fills half the track, and the remainder is its complement")
        assertTest(
            TypicalRangeTests.near(banded.lowFraction ?? .nan, 0.2) && TypicalRangeTests.near(banded.highFraction ?? .nan, 0.8),
            "A band in percentage points lands on the track's own 0–100% scale at 0.2 and 0.8")
        assertTest(
            TypicalRangeTests.near(TypicalRangeBarLayout(percent: 0, typical: nil).filledFraction, 0)
                && TypicalRangeTests.near(TypicalRangeBarLayout(percent: 100, typical: nil).unfilledFraction, 0),
            "A stage that took none of the night fills none of the track, and one that took all of it "
                + "leaves no remainder to hatch")

        // The clamps, which are a guard rather than a rule — see the type's doc comment — but a guard
        // that has to hold for a mark not to be drawn off the end of the scale.
        assertTest(
            TypicalRangeBarLayout(
                percent: 50, typical: SleepStageRangeScoring.Typical(lowPercent: -10, highPercent: 250)
            ).lowFraction == 0
                && TypicalRangeBarLayout(
                    percent: 50,
                    typical: SleepStageRangeScoring.Typical(lowPercent: -10, highPercent: 250)
                ).highFraction == 1,
            "A bound outside the scale is clamped to the track rather than drawn past it")
        assertTest(
            TypicalRangeBarLayout(
                percent: 50, typical: SleepStageRangeScoring.Typical(lowPercent: .nan, highPercent: .nan)
            ).lowFraction == 0,
            "A non-finite bound collapses to zero instead of taking the whole bar with it — every "
                + "comparison against a NaN is false, so a clamp cannot catch one")
        assertTest(
            TypicalRangeBarLayout(percent: 50, typical: nil).lowFraction == nil
                && TypicalRangeBarLayout(percent: 50, typical: nil).highFraction == nil,
            "**No band, no markers** — `nil` and not a pair of zeros, which would put two dashed bounds "
                + "at the left edge of every row on a thin window")

    }
}
