import Foundation

/// Which heart-rate-variability quantity a reading represents.
///
/// The two are **not interchangeable**. SDNN is the standard deviation of all N-N intervals; RMSSD
/// is the root mean square of successive differences. They measure different things, have different
/// ranges, and are systematically offset — Apple Watch overnight SDNN commonly lands near 20–60 ms
/// where the strap's RMSSD baseline is 65 ms.
///
/// Every series therefore carries the metric it was measured with, and `RecoveryScoring` filters
/// history to the matching metric before computing a baseline. Mixing them would compute a z-score
/// across two different quantities and pin the Recovery score to a clamp — the failure is silent,
/// because a wrong z-score still produces a number in range.
public enum HRVMetric: String, Codable, CaseIterable, Sendable {
    /// Root mean square of successive differences. Derived from the strap's R-R intervals.
    case rmssd
    /// Standard deviation of N-N intervals. The only HRV quantity Apple HealthKit exposes.
    case sdnn

    public var displayName: String {
        switch self {
        case .rmssd: return "RMSSD"
        case .sdnn: return "SDNN"
        }
    }

    /// Cold-start baseline mean, used until enough history accumulates to compute a real one.
    public var coldStartMeanMs: Double {
        switch self {
        case .rmssd: return 65.0
        // PLACEHOLDER. Not yet validated against real Apple Watch data — revise once the HealthKit
        // import has run on a device for a few weeks. Until then it is a plausible guess, and a
        // wrong cold start is what makes the first scores misleading.
        case .sdnn: return 40.0
        }
    }

    /// Cold-start baseline standard deviation, paired with `coldStartMeanMs`.
    public var coldStartStdDevMs: Double {
        switch self {
        case .rmssd: return 12.0
        // PLACEHOLDER, as above.
        case .sdnn: return 10.0
        }
    }
}
