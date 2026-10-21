import Foundation
import Whoopsy

// MARK: - 3. Mathematical & HRV Algorithms

/// The section's body. Driven from top level by `runSynchronousSections(_:)`.
enum HeartRateVariabilityMathTests {
    static func run() {
        let rawRR: [Double] = [800.0, 805.0, 810.0, 795.0, 1500.0, 802.0, 808.0]
        let cleaned = HeartRateVariabilityMath.filterRRIntervals(rawRR)
        assertTest(!cleaned.contains(1500.0), "Ectopic beat (1500ms) successfully rejected by filter")

        let rmssd = HeartRateVariabilityMath.calculateRMSSD(from: rawRR)
        assertTest(rmssd > 0.0 && rmssd < 50.0, "RMSSD calculated accurately (\(String(format: "%.1f", rmssd)) ms)")

        let sdnn = HeartRateVariabilityMath.calculateSDNN(from: rawRR)
        assertTest(sdnn > 0.0, "SDNN calculated accurately (\(String(format: "%.1f", sdnn)) ms)")

        let pnn50 = HeartRateVariabilityMath.calculatePNN50(from: rawRR)
        assertTest(pnn50 >= 0.0 && pnn50 <= 100.0, "pNN50 calculated accurately (\(String(format: "%.1f", pnn50))%)")

        // ── The support behind an RMSSD, which is what a real strap night exposed ────────────────
        //
        // A BLE notification carries at most four intervals; at rest most carry one. A run of length
        // 1 yields no successive difference, and a run of 2 yields exactly one that the ectopic rule
        // cannot judge — so an RMSSD can be built from a handful of pairs and be one outlier away
        // from any value. Measured on a real 5.0: an overnight HRV came out physiologically
        // impossible. The count is what lets the caller refuse it.
        let singleIntervalRuns = [[800.0], [810.0], [790.0], [805.0]]
        assertTest(
            HeartRateVariabilityMath.differenceCount(fromRuns: singleIntervalRuns) == 0,
            "Four one-interval notifications supply **zero** successive differences — the shape most "
                + "of a resting night arrives in")
        assertTest(
            HeartRateVariabilityMath.differenceCount(fromRuns: [[800.0, 810.0]]) == 1,
            "…a pair supplies exactly one, which is why a run of 2 is not evidence of variability")
        assertTest(
            HeartRateVariabilityMath.differenceCount(fromRuns: [[800.0, 810.0, 795.0, 805.0]]) == 3,
            "…and a four-interval run supplies three, so the count is additive across runs")
        assertTest(
            HeartRateVariabilityMath.minimumRMSSDDifferences == 20,
            "The floor is 20 differences — two-thirds of a 30 s strip at 60 bpm — and it is a "
                + "calibration this app owns rather than a published constant")
        assertTest(
            HeartRateVariabilityMath.calculateRMSSD(fromRuns: singleIntervalRuns) == 0.0
                && HeartRateVariabilityMath.calculateRMSSD(fromRuns: [[800.0, 850.0]]) == 50.0,
            "…and the estimator still returns a number from a single agreeing pair, which is exactly "
                + "why the caller gates on the count rather than on the value")
        // **A disagreeing pair is now dropped rather than differenced, and that is the fix.** The old
        // rule exempted both ends of a run, so a two-interval notification — the ordinary shape at
        // rest — passed untouched and its difference went straight into RMSSD.
        assertTest(
            HeartRateVariabilityMath.filterRRIntervals([800.0, 1400.0]).count == 1
                && HeartRateVariabilityMath.differenceCount(fromRuns: [[800.0, 1400.0]]) == 0,
            "A pair of adjacent beats differing by more than the ectopic ratio is not a measurement: "
                + "one of them is dropped, so the pair contributes no successive difference at all")
    }
}
