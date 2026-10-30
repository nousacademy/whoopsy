import Foundation
import Whoopsy

/// Fat-free mass from height, weight and sex: three published regressions, a median and a range.
///
/// **The assertion that matters is that the three disagree and the answer says so.** A single formula
/// printed bare would claim a precision none of these has; the range is the honest form of the
/// disagreement, and these fixtures pin it at a body both a formula and a reader can check.
enum LeanBodyMassMathTests {
    static func run() async throws {
        // 80 kg at 180 cm: Boer 61.4, Hume 57.8, James 62.7 — the worked example the type documents.
        if let man = LeanBodyMassMath.estimate(weightKg: 80, heightCm: 180, sex: .male) {
            assertTest(
                abs(man.medianKg - 61.4) < 0.1,
                "The median of the three regressions for 80 kg at 180 cm is 61.4 kg "
                    + "(got \(String(format: "%.2f", man.medianKg)))")
            assertTest(
                abs(man.lowKg - 57.8) < 0.1 && abs(man.highKg - 62.7) < 0.1,
                "…and its range is Hume's 57.8 to James's 62.7 — the spread that stops the figure being "
                    + "printed bare")
            assertTest(
                man.formulaCount == 3,
                "All three formulas are usable at an ordinary body size")
            assertTest(
                man.spreadKg > 4 && man.spreadKg < 6,
                "…and they disagree by about five kilograms, which is the estimate's real error bar")
        } else {
            assertTest(false, "The male fixture did not build")
        }

        if let woman = LeanBodyMassMath.estimate(weightKg: 65, heightCm: 165, sex: .female) {
            assertTest(
                abs(woman.medianKg - 46.1) < 0.1,
                "65 kg at 165 cm on the female regressions lands at 46.1 kg "
                    + "(got \(String(format: "%.2f", woman.medianKg)))")
            assertTest(
                abs(woman.lowKg - 44.9) < 0.1 && abs(woman.highKg - 46.6) < 0.1,
                "…with its own range, because the female coefficients are different fits rather than "
                    + "a shift of the male ones")
        } else {
            assertTest(false, "The female fixture did not build")
        }

        // ── Absences ────────────────────────────────────────────────────────────────────────────────
        assertTest(
            LeanBodyMassMath.estimate(weightKg: 80, heightCm: 180, sex: nil) == nil,
            "No sex, no estimate: the regressions are fitted on two categories and this app will not "
                + "infer one from a gender answer that says neither")
        assertTest(
            LeanBodyMassMath.estimate(weightKg: nil, heightCm: 180, sex: .male) == nil
                && LeanBodyMassMath.estimate(weightKg: 80, heightCm: nil, sex: .male) == nil,
            "…and no weight or no height is the same absence")
        assertTest(
            LeanBodyMassMath.estimate(weightKg: 300, heightCm: 180, sex: .male) == nil,
            "A weight outside the plausible range is refused rather than extrapolated — 300 kg is "
                + "past anything these regressions were fitted on")
        assertTest(
            LeanBodyMassMath.estimate(weightKg: 25, heightCm: 220, sex: .male) == nil,
            "…and so is a body whose every formula lands outside 30–85 % of its weight: each is "
                + "filtered by that gate, and none survives it here")
    }
}
