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

        // Recovery's sleep term is the sufficiency ratio, not the ring's composite. Two nights with
        // the same asleep-over-need and very different quality terms must leave Recovery identical,
        // which is what keeps the calibrated 0.70 pivot meaningful after the ring changes.
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        func night(light: TimeInterval, deep: TimeInterval, rem: TimeInterval, awake: TimeInterval,
                   consistency: Int) -> SleepSession {
            SleepSession(
                date: day,
                startTime: day.addingTimeInterval(-4 * 3600),
                endTime: day.addingTimeInterval(4 * 3600),
                targetSleepNeedSeconds: 8 * 3600,
                lightSleepSeconds: light,
                deepSleepSeconds: deep,
                remSleepSeconds: rem,
                awakeSeconds: awake,
                sleepConsistency: consistency)
        }
        let strong = night(light: 4 * 3600, deep: 2 * 3600, rem: 2 * 3600, awake: 0, consistency: 100)
        let weak = night(light: 6 * 3600, deep: 1 * 3600, rem: 1 * 3600, awake: 2 * 3600, consistency: 20)
        let strongComposite = SleepScoreScoring.score(
            for: strong, consistency: strong.sleepConsistency, age: nil)?.value
        let weakComposite = SleepScoreScoring.score(
            for: weak, consistency: weak.sleepConsistency, age: nil)?.value
        assertTest(
            strong.sleepSufficiencyPercentage == weak.sleepSufficiencyPercentage,
            "The two nights have the same sufficiency ratio")
        assertTest(
            strongComposite != weakComposite,
            "…but different composites, because their efficiency, restorative share and timing differ "
                + "(\(strongComposite.map { "\($0)" } ?? "nil") vs \(weakComposite.map { "\($0)" } ?? "nil"))")
        let strongRecovery = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: 65, baselineHrvMean: 65, baselineHrvStd: 10,
            todayRhr: 54, baselineRhrMean: 54, baselineRhrStd: 3,
            sleepPerformance: Double(strong.sleepSufficiencyPercentage) / 100)
        let weakRecovery = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: 65, baselineHrvMean: 65, baselineHrvStd: 10,
            todayRhr: 54, baselineRhrMean: 54, baselineRhrStd: 3,
            sleepPerformance: Double(weak.sleepSufficiencyPercentage) / 100)
        assertTest(
            strongRecovery == weakRecovery,
            "Recovery is identical on both nights, because it reads the ratio and not the composite")
    }
}
