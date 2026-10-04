import Foundation
import Whoopsy

// MARK: - 5. Recovery Baseline Model

/// The section's body. Driven from top level by `runSynchronousSections(_:)`.
enum RecoveryScoringTests {
    static func run() {
        let greenRecovery = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: 85.0,
            baselineHrvMean: 65.0,
            baselineHrvStd: 10.0,
            todayRhr: 48.0,
            baselineRhrMean: 54.0,
            baselineRhrStd: 3.0,
            sleepPerformance: 0.95
        )
        assertTest(greenRecovery >= 67, "High HRV + Low RHR yields Green Recovery (\(greenRecovery)%)")

        let redRecovery = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: 35.0,
            baselineHrvMean: 65.0,
            baselineHrvStd: 10.0,
            todayRhr: 64.0,
            baselineRhrMean: 54.0,
            baselineRhrStd: 3.0,
            sleepPerformance: 0.60
        )
        assertTest(redRecovery <= 35, "Low HRV + High RHR yields Red Recovery (\(redRecovery)%)")
    }
}
