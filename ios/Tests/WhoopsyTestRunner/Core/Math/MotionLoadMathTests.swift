import Foundation
import Whoopsy

/// The translation from wrist motion to weighted seconds.
enum MotionLoadMathTests {
    static func run() async throws {
        // ---- ENMO ----
        assertTest(
            MotionLoadMath.enmo(meanMagnitudeG: 1.0) == 0,
            "A motionless strap reads exactly gravity, so its ENMO is 0")
        assertTest(
            MotionLoadMath.enmo(meanMagnitudeG: 1.23) - 0.23 < 1e-9,
            "ENMO is the mean magnitude minus gravity")
        assertTest(
            MotionLoadMath.enmo(meanMagnitudeG: 0.94) == 0,
            "Sensor noise below gravity clamps to 0 rather than going negative — a negative weight "
                + "would subtract load from the day")

        // ---- The weight table ----
        // Half-open at the bottom, so exactly 0.02 is already light movement rather than stillness.
        let weights: [(Double, Double, String)] = [
            (0.0199, 0, "below 0.02 g is still"),
            (0.02, 1, "exactly 0.02 g is weight 1"),
            (0.0499, 1, "just under 0.05 g is still weight 1"),
            (0.05, 2, "0.05 g is walking/manual-work weight"),
            (0.0999, 2, "just under 0.10 g is still weight 2"),
            (0.10, 3, "0.10 g is brisk-walk weight"),
            (0.1999, 3, "just under 0.20 g is still weight 3"),
            (0.20, 4, "0.20 g is running weight"),
            (1.50, 4, "above the top threshold stays at 4"),
        ]
        for (enmo, expected, description) in weights {
            assertTest(
                MotionLoadMath.weight(forENMO: enmo) == expected,
                "Weight for ENMO \(enmo) is \(expected) — \(description)")
        }

        // ---- Covered seconds ----
        assertTest(
            MotionLoadMath.coveredSeconds(sampleCount: 0) == 0
                && MotionLoadMath.coveredSeconds(sampleCount: -5) == 0,
            "No samples (or a negated count) covers no time")
        assertTest(
            MotionLoadMath.coveredSeconds(sampleCount: 2_999) - 29.99 < 1e-9,
            "2,999 samples at 100 Hz cover 29.99 s")
        assertTest(
            MotionLoadMath.coveredSeconds(sampleCount: 3_000) == 30,
            "A full window is 30 s")
        assertTest(
            MotionLoadMath.coveredSeconds(sampleCount: 6_000) == 30,
            "An overlapping double delivery is clamped to the window rather than credited twice")

        // ---- The product ----
        assertTest(
            MotionLoadMath.motionLoad(meanMagnitudeG: 1.0, sampleCount: 3_000) == 0,
            "A still window contributes nothing")
        assertTest(
            MotionLoadMath.motionLoad(meanMagnitudeG: 1.07, sampleCount: 3_000) == 60,
            "A full walking-weight window is 2 × 30 = 60 weighted seconds, got "
                + "\(MotionLoadMath.motionLoad(meanMagnitudeG: 1.07, sampleCount: 3_000))")
        assertTest(
            MotionLoadMath.motionLoad(meanMagnitudeG: 1.30, sampleCount: 1_500) == 60,
            "A half-filled running-weight window is 4 × 15 = 60 — a window grows as its batches arrive")
    }
}
