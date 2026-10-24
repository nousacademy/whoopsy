import Foundation

/// Turns the strap's wrist motion into load in the same weighted-seconds unit the heart-rate zones
/// use, so the two can be compared window by window.
///
/// ## Why this exists
///
/// A day of manual work done below the heart-rate bands used to score nothing: `StrainAccumulatorMath`
/// integrates heart rate against a resting and maximum rate, and carrying boxes or standing at a bench
/// can keep a rate under zone 1's floor for eight hours. The wrist is already measuring that work —
/// the strap's accelerometer is what `RecordMotionUseCase` reduces to one epoch per 30 seconds — so the
/// missing term is a translation, not a sensor.
///
/// ## The weights are this app's calibration, not WHOOP's
///
/// WHOOP publishes neither its all-day motion weighting nor its non-exercise strain term. The scale
/// below is chosen so that a hard eight-hour manual day — roughly `8 × 3600 / 30 = 960` windows at
/// `0.05–0.10 g`, weight 2, 30 s each — adds about `57,600` weighted seconds. On the day curve that is
/// `21·(1 − e^(−1.085e-5 × 57,600)) ≈ +10.9` of *load*, and because the day's own quiet baseline is
/// already near 9.8 the ring moves about **+3 points**. That is the target the moderate scale was
/// chosen against, and it is recorded in `docs/ALGORITHMS.md` §2 with the table.
///
/// **A weight above 1 is the whole point.** A scale that mapped every moving epoch to 1 could never
/// beat the heart-rate low band's `1 × duration`, so the motion term would be a no-op on any window it
/// was combined with. The non-linear steps are what let vigorous work out-rank a resting heart rate.
///
/// ## Units
///
/// `ENMO` is the mean magnitude minus gravity, clamped at zero — a still strap reads ≈1.0 g because
/// gravity is inside `|a|`, and a worn strap cannot read below it by more than sensor noise. Both
/// motion layouts sample at 100 Hz (`MotionPayloadDecoder.samplesPerAxis`), so a full window is 3,000
/// samples and a partial one is credited only for the seconds it actually covers. A window saved
/// several times as its batches arrive therefore gains load as it fills, which is what makes the day's
/// total rise through the day rather than jump at the window boundary.
public enum MotionLoadMath {
    /// Gravity, in the same Gs `|a|` is measured in. Subtracted to get ENMO and clamped at zero.
    public static let referenceGravityG: Double = 1.0

    /// The axes' rate on both motion layouts, from `MotionPayloadDecoder.samplesPerAxis`'s premise.
    public static let samplesPerSecond: Double = 100.0

    /// The most weighted seconds one window can contribute, on any curve.
    public static let maximumWeightedSecondsPerWindow: Double = MotionEpochGrid.epochSeconds

    /// `max(0, meanMagnitudeG − 1)` — the Euclidean-norm-minus-one estimate of dynamic acceleration.
    public static func enmo(meanMagnitudeG: Double) -> Double {
        max(0, meanMagnitudeG - referenceGravityG)
    }

    /// The weight table. Boundaries are half-open at the bottom, so exactly `0.02 g` is weight 1.
    ///
    /// | ENMO | weight | typical |
    /// | :--- | ---: | :--- |
    /// | `< 0.02` | 0 | still |
    /// | `0.02 ..< 0.05` | 1 | fidgeting, light movement |
    /// | `0.05 ..< 0.10` | 2 | walking, manual work |
    /// | `0.10 ..< 0.20` | 3 | brisk walk, lifting |
    /// | `>= 0.20` | 4 | running, vigorous work |
    public static func weight(forENMO enmo: Double) -> Double {
        switch enmo {
        case ..<0.02: return 0
        case ..<0.05: return 1
        case ..<0.10: return 2
        case ..<0.20: return 3
        default: return 4
        }
    }

    /// How much of a 30-second window a partial epoch actually measured.
    ///
    /// Clamped at the window's own length: two overlapping batches can deliver more than 3,000
    /// samples for one window, and crediting the overlap would let a writer that re-sends a batch
    /// inflate the day. A negative count is the same zero as no samples at all.
    public static func coveredSeconds(sampleCount: Int) -> Double {
        min(maximumWeightedSecondsPerWindow, Double(max(0, sampleCount)) / samplesPerSecond)
    }

    /// One epoch's contribution: the weight for its ENMO multiplied by the seconds it covers.
    public static func motionLoad(meanMagnitudeG: Double, sampleCount: Int) -> Double {
        weight(forENMO: enmo(meanMagnitudeG: meanMagnitudeG)) * coveredSeconds(sampleCount: sampleCount)
    }
}
