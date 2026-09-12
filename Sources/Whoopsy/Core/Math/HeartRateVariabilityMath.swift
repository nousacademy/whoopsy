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
    public static func calculateRMSSD(from rrIntervalsMs: [Double]) -> Double {
        let cleaned = filterRRIntervals(rrIntervalsMs)
        guard cleaned.count >= 2 else { return 0.0 }

        var sumSquaredDiffs = 0.0
        let count = cleaned.count - 1

        for i in 0..<count {
            let diff = cleaned[i + 1] - cleaned[i]
            sumSquaredDiffs += diff * diff
        }

        let meanSquare = sumSquaredDiffs / Double(count)
        return sqrt(meanSquare)
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
