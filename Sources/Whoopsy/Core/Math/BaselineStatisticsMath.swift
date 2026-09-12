import Foundation

/// A baseline mean and standard deviation for one metric, with every degenerate-input guard
/// already applied. Build these with `BaselineStatisticsMath.baseline(_:fallbackMean:fallbackStdDev:)`
/// rather than assembling the two numbers by hand.
public struct BaselineStatistics: Equatable, Sendable {
    public let mean: Double
    public let stdDev: Double

    public init(mean: Double, stdDev: Double) {
        self.mean = mean
        self.stdDev = stdDev
    }
}

/// Rolling statistical window and z-score mathematics for Recovery model.
public enum BaselineStatisticsMath {
    /// Smallest standard deviation a baseline may report, as a fraction of its own mean.
    ///
    /// Without this floor a near-constant history collapses the denominator and every difference
    /// becomes infinitely many sigma. Real data reaches this state easily: a mock/synthetic series
    /// with one repeated value, an early baseline of two near-identical days, or a device that
    /// reports a rounded constant. The score then silently pins to a clamp while still looking like
    /// a perfectly valid number.
    public static let minimumCoefficientOfVariation = 0.05

    /// Largest z-score any single metric may contribute. Four sigma is already an extreme
    /// observation; beyond that the input is far more likely to be an artifact than physiology.
    public static let maximumAbsoluteZScore = 4.0

    /// The sleep performance at which the sleep term contributes nothing to the score.
    ///
    /// Exposed because a caller with **no** sleep data needs a value for the term, and the only
    /// honest one is the one that shifts the score by zero. Substituting a plausible night — the
    /// `85` this used to fall back to — turns "we do not know how you slept" into a real adjustment.
    public static let sleepPerformancePivot = 0.70

    /// Calculates mean (average) of an array.
    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        return values.reduce(0.0, +) / Double(values.count)
    }

    /// Calculates sample standard deviation.
    public static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 1.0 } // Avoid division by zero
        let avg = mean(values)
        let sumSquaredDevs = values.reduce(0.0) { $0 + pow($1 - avg, 2) }
        let variance = sumSquaredDevs / Double(values.count - 1)
        return max(0.001, sqrt(variance))
    }

    /// Standard normal z-score: (value - mean) / stdDev, clamped to ±`maximumAbsoluteZScore`.
    public static func zScore(value: Double, mean: Double, stdDev: Double) -> Double {
        let safeStd = max(0.001, stdDev)
        let raw = (value - mean) / safeStd
        guard raw.isFinite else { return 0.0 }
        return max(-maximumAbsoluteZScore, min(maximumAbsoluteZScore, raw))
    }

    /// Builds a baseline from observations, falling back to supplied defaults when there is no
    /// history to learn from. Both guards that keep a z-score meaningful are applied here, so callers
    /// never hold a bare `mean`/`stdDev` pair that has skipped them.
    ///
    /// - Parameters:
    ///   - values: history for one metric, already filtered to exclude other metrics.
    ///   - fallbackMean: cold-start mean, used only when `values` is empty.
    ///   - fallbackStdDev: cold-start spread, used only when `values` is empty.
    public static func baseline(
        _ values: [Double], fallbackMean: Double, fallbackStdDev: Double
    ) -> BaselineStatistics {
        guard !values.isEmpty else {
            return BaselineStatistics(mean: fallbackMean, stdDev: fallbackStdDev)
        }
        let avg = mean(values)
        let observed = standardDeviation(values)
        let floor = abs(avg) * minimumCoefficientOfVariation
        return BaselineStatistics(mean: avg, stdDev: max(observed, floor))
    }

    /// Computes multi-factor Recovery Score.
    ///
    /// The weights below are the specification — `ALGORITHMS.md` §3 restates them, and the two must
    /// agree. They previously did not, which is why they are named constants here.
    ///
    /// - Parameters:
    ///   - todayHrv: Overnight HRV (ms), in the *same metric* as the baseline.
    ///   - baselineHrvMean: Rolling mean HRV over the history window.
    ///   - baselineHrvStd: Rolling stdDev HRV over the history window.
    ///   - todayRhr: Resting Heart Rate (bpm)
    ///   - baselineRhrMean: Rolling mean RHR
    ///   - baselineRhrStd: Rolling stdDev RHR
    ///   - sleepPerformance: 0.0 to 1.0+ (actual / needed)
    /// - Returns: Score clamped to `1...99`, never 0 or 100 — the score is an estimate from a
    ///   statistical window, so a perfect reading is not claimable.
    public static func computeRecoveryScore(
        todayHrv: Double,
        baselineHrvMean: Double,
        baselineHrvStd: Double,
        todayRhr: Double,
        baselineRhrMean: Double,
        baselineRhrStd: Double,
        sleepPerformance: Double
    ) -> Int {
        let hrvWeight = 24.0
        let rhrWeight = 18.0
        let sleepWeight = 20.0
        let sleepPivot = sleepPerformancePivot
        let sleepPerformanceRange = 0.4...1.2

        let zHRV = zScore(value: todayHrv, mean: baselineHrvMean, stdDev: baselineHrvStd)
        let zRHR = zScore(value: todayRhr, mean: baselineRhrMean, stdDev: baselineRhrStd)

        // Anchor at 50%, then move by the two z-scores and the sleep term. Higher RHR means
        // fatigue/stress and subtracts; the sleep term is centred on 70% performance.
        let boundedSleep = min(sleepPerformanceRange.upperBound,
                               max(sleepPerformanceRange.lowerBound, sleepPerformance))
        let sleepFactor = (boundedSleep - sleepPivot) * sleepWeight

        var rawRecovery = 50.0 + (zHRV * hrvWeight) - (zRHR * rhrWeight) + sleepFactor
        rawRecovery = max(1.0, min(99.0, rawRecovery))
        return Int(rawRecovery.rounded())
    }
}
