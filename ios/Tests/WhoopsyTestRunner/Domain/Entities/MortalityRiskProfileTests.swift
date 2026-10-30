import Foundation
import Whoopsy

/// The Health tab's risk multiplier: three published relative risks, a stated reference and a clamp.
///
/// What is asserted here is the arithmetic and the absences. **What cannot be asserted is whether the
/// coefficients are right** — they are other people's fits, cited in `MortalityRiskProfile`'s doc
/// comment — and this file is careful not to imply otherwise.
enum MortalityRiskProfileTests {
    static func run() async throws {
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0000001 }

        // ── The reference profile is exactly 1.0 ───────────────────────────────────────────────────
        if let reference = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 30, steps: 5_000, restingHeartRate: 60)
        {
            assertTest(
                close(reference.multiplier, 1.0),
                "The anchor the coefficients are stated against multiplies to exactly 1.0 — 30 mL/kg/min, "
                    + "5,000 steps and 60 bpm (got \(reference.multiplier))")
            assertTest(
                reference.factors.count == 3,
                "…and all three factors contribute a row")
        } else {
            assertTest(false, "The reference profile did not build")
        }

        // ── One factor at a time, against its own coefficient ───────────────────────────────────────
        if let fit = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 33.5, steps: 5_000, restingHeartRate: 60)
        {
            assertTest(
                close(fit.multiplier, 0.85),
                "One MET of fitness above the reference multiplies risk by 0.85 — Mandsager et al."
                    + " (got \(fit.multiplier))")
        } else {
            assertTest(false, "The fitness fixture did not build")
        }

        if let walking = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 30, steps: 6_000, restingHeartRate: 60)
        {
            assertTest(
                close(walking.multiplier, 0.90),
                "A thousand steps above the reference multiplies risk by 0.90 (got \(walking.multiplier))")
        } else {
            assertTest(false, "The steps fixture did not build")
        }

        if let elevated = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 30, steps: 5_000, restingHeartRate: 70)
        {
            assertTest(
                close(elevated.multiplier, 1.15),
                "Ten beats above the reference multiplies risk by 1.15 — Nauman et al. "
                    + "(got \(elevated.multiplier))")
        } else {
            assertTest(false, "The resting-rate fixture did not build")
        }

        // ── The step credit is capped where the evidence flattens ──────────────────────────────────
        let twelveThousand = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 30, steps: 12_000, restingHeartRate: 60)
        let tenThousand = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 30, steps: 10_000, restingHeartRate: 60)
        assertTest(
            twelveThousand?.multiplier == tenThousand?.multiplier,
            "Twelve thousand steps count the same as ten — the association flattens there, and the cap "
                + "is what stops a big walk from buying an unbounded discount")
        assertTest(
            twelveThousand?.factors.first { $0.kind == .steps }?.valueText != nil,
            "…while the row still prints what the strap counted")

        // ── The product, and the clamp that bounds it ───────────────────────────────────────────────
        if let healthy = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 44, steps: 9_000, restingHeartRate: 52)
        {
            let expected = pow(0.85, 4.0) * pow(0.90, 4.0) * pow(1.15, -0.8)
            assertTest(
                close(healthy.multiplier, expected),
                "Three good readings multiply: the factors are independent relative risks, not an "
                    + "average (got \(healthy.multiplier), expected \(expected))")
            assertTest(
                healthy.multiplier < 1.0,
                "…and a fit, active, low-rate profile lands below the reference")
        } else {
            assertTest(false, "The healthy fixture did not build")
        }

        // The floor is the fitness cohort's own elite-versus-low ratio, so a profile that good is
        // allowed all the way down to it.
        let elite = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 44, steps: 9_000, restingHeartRate: 52)
        assertTest(
            (elite?.multiplier ?? 1) < 0.5 && (elite?.multiplier ?? 1) >= MortalityRiskProfile.multiplierRange.lowerBound,
            "A very fit profile is not pinned at half the reference's risk — the floor sits at the "
                + "elite ratio the evidence reports (\(elite?.multiplier ?? -1))")

        // The fitness credit stops at the elite threshold, so a very high estimate cannot compound a
        // fit profile into the clamp floor.
        let capped = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 80, steps: 5_000, restingHeartRate: 60)
        let atCap = MortalityRiskProfile.make(
            vo2MaxMlKgMin: MortalityRiskProfile.fitnessCreditCap, steps: 5_000, restingHeartRate: 60)
        assertTest(
            capped?.multiplier == atCap?.multiplier,
            "Fitness above 44 mL/kg/min counts no further — the gradient is measured inside the "
                + "cohort's range and this app's own figure is an estimate")

        let best = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 80, steps: 20_000, restingHeartRate: 30)
        assertTest(
            (best?.multiplier ?? 0) >= MortalityRiskProfile.multiplierRange.lowerBound,
            "…and the best measurable profile still lands on or above the floor rather than being "
                + "pinned at it (\(best?.multiplier ?? -1))")
        let backwards = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 10, steps: 0, restingHeartRate: 120)
        assertTest(
            backwards?.multiplier == MortalityRiskProfile.multiplierRange.upperBound,
            "…at both ends of the range")

        // ── A missing reading drops its factor ─────────────────────────────────────────────────────
        if let withoutFitness = MortalityRiskProfile.make(
            vo2MaxMlKgMin: nil, steps: 5_000, restingHeartRate: 60)
        {
            assertTest(
                withoutFitness.factors.map(\.kind) == [.steps, .restingHeartRate],
                "A day with no fitness estimate contributes two factors, not a third at 1.0 — an "
                    + "unmeasured factor is not an average one")
            assertTest(
                close(withoutFitness.multiplier, 1.0),
                "…and the two it has are both at their reference, so the product is still 1.0")
        } else {
            assertTest(false, "The partial fixture did not build")
        }

        assertTest(
            MortalityRiskProfile.make(vo2MaxMlKgMin: nil, steps: nil, restingHeartRate: nil) == nil,
            "A day with none of the three has no profile at all, which the card draws as its sentence "
                + "rather than as a 1.0")
        assertTest(
            MortalityRiskProfile.make(vo2MaxMlKgMin: 0, steps: 5_000, restingHeartRate: 0)?.factors.count == 1,
            "A zero fitness estimate or a zero resting rate is an absence, not a reading — the app's "
                + "reserved-zero rule, applied to the two factors that could be filled with one")
    }
}
