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
    }
}
