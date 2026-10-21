import Foundation

/// Heart Rate Variability (HRV) calculation and artifact rejection algorithms.
public enum HeartRateVariabilityMath {
    /// Minimum valid R-R interval in ms (200 BPM)
    public static let minValidRRMs: Double = 300.0
    /// Maximum valid R-R interval in ms (30 BPM)
    public static let maxValidRRMs: Double = 2000.0
    /// Max allowable delta percentage for ectopic beat rejection (20%)
    public static let maxEctopicVariationRatio: Double = 0.20

    /// Cleans and filters raw R-R intervals using physiological limits and a neighbour rule.
    ///
    /// **Every interval is judged, including the first and the last of a run — and that is the fix a
    /// real strap night forced.** The rule used to check only the *middle* of a run of three or more
    /// and exempt both ends, so a run of two was pure ends and passed untouched, and a run of three
    /// judged one interval while admitting two. A BLE notification carries at most four intervals and
    /// at rest usually one, which makes short runs the ordinary case rather than the edge: measured on
    /// a real 5.0, an overnight RMSSD came out at **301 ms** from 195 differences, because the pairs
    /// the filter never inspected were exactly the pairs RMSSD is built from. A pair of adjacent beats
    /// differing by more than `maxEctopicVariationRatio` is an ectopic pair, not a measurement, so both
    /// are dropped and a run of two that disagrees contributes nothing.
    ///
    /// A single interval has no neighbour to disagree with and is kept once it is inside the
    /// physiological bounds; it contributes no successive difference either way, so keeping it is
    /// harmless and dropping it would make a run of one indistinguishable from no run.
    public static func filterRRIntervals(
        _ rawIntervals: [Double], ratio: Double = maxEctopicVariationRatio
    ) -> [Double] {
        let bounded = rawIntervals.filter { $0 >= minValidRRMs && $0 <= maxValidRRMs }
        guard bounded.count >= 2 else { return bounded }

        var cleaned: [Double] = []
        for index in bounded.indices {
            let current = bounded[index]
            // The local comparison set: every immediate neighbour the run actually has, so an end is
            // judged against its one neighbour rather than exempted.
            var neighbours: [Double] = []
            if index > 0 { neighbours.append(bounded[index - 1]) }
            if index < bounded.count - 1 { neighbours.append(bounded[index + 1]) }

            let localMedian = (neighbours + [current]).sorted()[
                (neighbours.count + 1) / 2]
            let diffRatio = abs(current - localMedian) / localMedian
            if diffRatio <= ratio {
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
    public static func calculateRMSSD(
        fromRuns runs: [[Double]], ratio: Double = maxEctopicVariationRatio
    ) -> Double {
        var sumSquaredDiffs = 0.0
        var differenceCount = 0

        for run in runs {
            let cleaned = filterRRIntervals(run, ratio: ratio)
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
    /// How many successive differences the runs actually supply after cleaning.
    ///
    /// **RMSSD's denominator, returned rather than inferred, because it is the number that separates a
    /// measurement from an accident.** A strap notification carries at most four intervals, and at rest
    /// most carry one — a run of length 1 yields no difference at all, and a run of 2 yields exactly
    /// one, which the ectopic rule cannot judge because its relative check needs both neighbours. So an
    /// RMSSD built from a handful of pairs is one bad pair away from any value at all, and a
    /// physiologically impossible figure can reach a score. Callers gate on this before using the
    /// result; see `minimumRMSSDDifferences`.
    public static func differenceCount(fromRuns runs: [[Double]]) -> Int {
        runs.reduce(0) { total, run in
            let cleaned = filterRRIntervals(run)
            return total + max(0, cleaned.count - 1)
        }
    }

    /// The fewest successive differences an RMSSD may be computed from.
    ///
    /// **A calibration, not a published constant**, in the same bargain `StressMath` documents: 30
    /// seconds of beats at a resting 60 bpm is 30 intervals and 29 differences, so 20 is two-thirds of
    /// a conventional short-term HRV strip. Below it the estimator is not reporting the heart's
    /// variability, it is reporting how many beats happened to share a notification.
    public static let minimumRMSSDDifferences = 20

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
