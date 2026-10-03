import Foundation

/// How a night's banded sleep figure reads: **Poor**, **Sufficient** or **Optimal**.
///
/// WHOOP publishes the shape of this scale — three bands, coloured orange, grey and green — and not
/// its boundaries, so the thresholds below are this app's own calibration. That is the same bargain
/// `SleepNeedMath` and `StressMath` already document, and it means this app's band and the WHOOP app's
/// can disagree about a night near an edge.
///
/// **The boundaries are anchored on WHOOP's own published numbers wherever there is one to anchor
/// on**, which is why the three rows do not share a threshold despite sharing a scale:
///
/// | Row | Poor | Sufficient | Optimal | Where the anchor comes from |
/// | :--- | :--- | :--- | :--- | :--- |
/// | Hours vs. Needed | < 70 | 70–94 | ≥ 95 | WHOOP: "95–100% fully met, below 70% significant deficits" |
/// | Sleep Consistency | < 60 | 60–89 | ≥ 90 | WHOOP: "90%+ highly consistent, below 60% significant drift" |
/// | Sleep Efficiency | < 80 | 80–89 | ≥ 90 | **no published anchor — this app's own** |
///
/// Efficiency's pair is the one row here with nothing to cite, and it is written down as a
/// calibration rather than presented as a measurement. It sits at 80/90 because those are the round
/// numbers between the two that *are* anchored, on a quantity whose observed range (the export's
/// nights sit mostly in the high eighties and nineties) leaves the optimal band reachable rather than
/// empty.
///
/// **Two things about the scale are worth knowing before reading a screen that draws it.** First, it
/// is heavily lopsided on real data: over the export's 892 scored nights the consistency anchors put
/// **62 nights in Poor, 805 in Sufficient and 25 in Optimal**. That is a property of WHOOP's own
/// "90%+ is highly consistent" — a genuinely rare night — and not a fault to tune away, but a rule
/// that files 90% of nights under one label discriminates weakly, and a reader comparing two
/// differently-coloured nights should know the grey band is wide. Second, the bands are a **colour
/// key and nothing else**: unlike `MetricChange`, which carries a direction as well as a verdict, a
/// band says only where a figure sits on its own scale. It makes no claim that a higher figure is
/// better than a lower one for a different quantity.
///
/// It cannot carry its own `Color`: this type is in `Domain`, which imports only `Foundation`, so the
/// one mapping from a band to a token is `SleepBand+Extensions.swift` in `Presentation` — the shape
/// `RecoveryState+Extensions.swift` establishes.
public enum SleepBand: String, CaseIterable, Identifiable, Sendable {
    case poor
    case sufficient
    case optimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .poor: return "Poor"
        case .sufficient: return "Sufficient"
        case .optimal: return "Optimal"
        }
    }

    /// Which banded figure a value is being read for. The scale is shared; the boundaries are not.
    public enum Metric: Sendable, CaseIterable {
        /// Asleep over need — the ring's figure and the reference's `HOURS VS. NEEDED` row.
        case hoursVsNeeded
        /// `SleepConsistencyMath`, imported or computed.
        case consistency
        /// Asleep over sleep period.
        case efficiency

        /// The bottom of the middle band. Below it is Poor.
        public var sufficientLowerBound: Double {
            switch self {
            case .hoursVsNeeded: return 70
            case .consistency: return 60
            case .efficiency: return 80
            }
        }

        /// The bottom of the top band. Below it, and at or above `sufficientLowerBound`, is Sufficient.
        public var optimalLowerBound: Double {
            switch self {
            case .hoursVsNeeded: return 95
            case .consistency: return 90
            case .efficiency: return 90
            }
        }
    }

    /// Where a figure sits on its own scale.
    ///
    /// Both bounds are inclusive at the bottom: a figure of exactly `optimalLowerBound` is Optimal and
    /// one of exactly `sufficientLowerBound` is Sufficient. Stated because the three rows' bounds are
    /// different numbers and an off-by-one at 95 or 90 is invisible on screen — the two colours either
    /// side of it are adjacent in meaning either way, which is the same reason `RecoveryState`'s
    /// boundaries have their own assertions.
    public static func band(for value: Double, metric: Metric) -> SleepBand {
        if value >= metric.optimalLowerBound { return .optimal }
        if value >= metric.sufficientLowerBound { return .sufficient }
        return .poor
    }
}
