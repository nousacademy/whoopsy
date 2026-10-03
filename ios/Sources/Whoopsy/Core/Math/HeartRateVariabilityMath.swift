import Foundation

/// Heart Rate Variability (HRV) calculation and artifact rejection algorithms.
public enum HeartRateVariabilityMath {
    /// Minimum valid R-R interval in ms (200 BPM)
    public static let minValidRRMs: Double = 300.0
    /// Maximum valid R-R interval in ms (30 BPM)
    public static let maxValidRRMs: Double = 2000.0
    /// Max allowable delta percentage for ectopic beat rejection (20%)
    public static let maxEctopicVariationRatio: Double = 0.20

    /// Cleans and filters raw R-R intervals using physiological limits and moving median filter.
    public static func filterRRIntervals(_ rawIntervals: [Double]) -> [Double] {
        guard rawIntervals.count >= 3 else {
            return rawIntervals.filter { $0 >= minValidRRMs && $0 <= maxValidRRMs }
        }

        var cleaned: [Double] = []
        for i in 0..<rawIntervals.count {
            let current = rawIntervals[i]
            // 1. Boundary check
            guard current >= minValidRRMs && current <= maxValidRRMs else { continue }

            // 2. Relative check with neighbors
            if i > 0 && i < rawIntervals.count - 1 {
                let prev = rawIntervals[i - 1]
                let next = rawIntervals[i + 1]
                let localMedian = [prev, current, next].sorted()[1]
                let diffRatio = abs(current - localMedian) / localMedian
                if diffRatio <= maxEctopicVariationRatio {
                    cleaned.append(current)
                }
            } else {
                cleaned.append(current)
            }
        }
        return cleaned
    }

    /// Root Mean Square of Successive Differences (RMSSD) in milliseconds.
    ///
    /// A forwarder to `calculateRMSSD(fromRuns:)` with the whole array as one run, so there is one
    /// definition of "successive" rather than two. A caller holding intervals from more than one
    /// source must use the runs form — see its doc comment for why.
    public static func calculateRMSSD(from rrIntervalsMs: [Double]) -> Double {
        calculateRMSSD(fromRuns: [rrIntervalsMs])
    }

    /// RMSSD over **several contiguous runs** of intervals, pooled.
    ///
    /// ## Why this exists, and what it prevents
    ///
    /// A successive *difference* is only defined between two beats that were actually adjacent, and
    /// the intervals this app stores do not arrive as one unbroken series. `BiometricSample
    /// .rrIntervalsMs` holds the beats of a single BLE notification: within one array they are adjacent
    /// in exact order, and **across two arrays they are not** — the gap between the last beat of one
    /// notification and the first beat of the next is however long the strap took to send it, and no
    /// column records it. Differencing across that seam subtracts two beats that were never
    /// neighbours, which is a number about the notification rate wearing the name of a heart-rate
    /// measurement.
    ///
    /// Handing the concatenation to `calculateRMSSD(from:)` is exactly that mistake, and this repo has
    /// shipped it twice: `CalculateRecoveryUseCase` and `AnalyzeStressUseCase` each flatten one
    /// interval per sample and difference the result, which `BiometricSample`'s own doc comment
    /// records.
    ///
    /// Pooling rather than stitching: each run is cleaned on its own, the squared differences are
    /// accumulated **within** each run, and the mean is taken over the total count. The denominator is
    /// therefore `Σ(count − 1)`, not `Σcount − 1`. That is the estimator's honest form — stitching the
    /// runs into one array and differencing at the seams would silently add one fabricated difference
    /// per seam, each of which is large (it spans the notification gap) and each of which inflates the
    /// result.
    ///
    /// Cleaning per run rather than up front matters for the same reason: `filterRRIntervals`' relative
    /// check compares each interval against its neighbours, so a run boundary is a position where the
    /// check has no neighbour to compare against. Cleaning the concatenation first would let the last
    /// interval of one notification vote on the first interval of the next.
    ///
    /// - Parameter runs: one array per contiguous stretch of beats. Empty runs are ignored.
    /// - Returns: RMSSD in milliseconds, or `0.0` when fewer than two intervals survive cleaning in
    ///   total — which callers must guard, because a zero here is a perfectly metronomic heart rather
    ///   than an absent reading. See `StressMath.minimumRRIntervals`.
    public static func calculateRMSSD(fromRuns runs: [[Double]]) -> Double {
        var sumSquaredDiffs = 0.0
        var differenceCount = 0

        for run in runs {
            let cleaned = filterRRIntervals(run)
            guard cleaned.count >= 2 else { continue }
            for i in 0..<(cleaned.count - 1) {
                let diff = cleaned[i + 1] - cleaned[i]
                sumSquaredDiffs += diff * diff
                differenceCount += 1
            }
        }

        guard differenceCount > 0 else { return 0.0 }
        return sqrt(sumSquaredDiffs / Double(differenceCount))
    }

    /// Standard Deviation of NN intervals (SDNN) in milliseconds.
    public static func calculateSDNN(from rrIntervalsMs: [Double]) -> Double {
        let cleaned = filterRRIntervals(rrIntervalsMs)
        guard cleaned.count >= 2 else { return 0.0 }

        let mean = cleaned.reduce(0.0, +) / Double(cleaned.count)
        let sumSquaredDeviations = cleaned.reduce(0.0) { $0 + pow($1 - mean, 2) }
        return sqrt(sumSquaredDeviations / Double(cleaned.count - 1))
    }

    /// Percentage of successive RR intervals that differ by more than 50ms (pNN50).
    public static func calculatePNN50(from rrIntervalsMs: [Double]) -> Double {
        let cleaned = filterRRIntervals(rrIntervalsMs)
        guard cleaned.count >= 2 else { return 0.0 }

        var countOver50 = 0
        let totalComparisons = cleaned.count - 1

        for i in 0..<totalComparisons {
            if abs(cleaned[i + 1] - cleaned[i]) > 50.0 {
                countOver50 += 1
            }
        }

        return (Double(countOver50) / Double(totalComparisons)) * 100.0
    }
}
