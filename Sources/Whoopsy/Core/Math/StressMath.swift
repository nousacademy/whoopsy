import Foundation

/// Daytime physiological activation — WHOOP's "Stress Monitor".
///
/// ## Provenance, and what this is not
///
/// WHOOP publishes this model's *shape* and none of its constants. The shape: stress is estimated
/// from heart rate variability, heart rate and motion; it is compared against a personal baseline
/// built from the previous 14 days; the comparison is what separates physical exertion from mental
/// or emotional stress; and the output is a 0–3 scale, banded 0–1 low, 1–2 medium, 2–3 high, with
/// high stress inviting a guided breathwork protocol.
///
/// Nothing beyond that is published — not the window length, not the weights, not the band edges.
/// Every constant below is therefore **this app's**, calibrated to reproduce that described
/// behaviour, and this app's number will not agree with the WHOOP app's. That is the same bargain
/// `SleepNeedMath` documents: a calibration that reproduces their output, not a recovery of their
/// function.
///
/// ## The model
///
/// A window is eligible only if the strap was still, because motion is the discriminator WHOOP names
/// for telling exertion from stress, and it is the right one: a raised heart rate while the arm is
/// moving is work, and while the arm is still is activation. Each eligible window then contributes
/// two z-scores against the personal baseline — RMSSD **negated**, because HRV falls under stress,
/// and heart rate as-is, because it rises — and their mean is the window's activation.
///
/// ## What it cannot do
///
/// The motion gate is the only exertion filter, so a still-armed activity with a raised heart rate —
/// cycling, a rowing machine, carrying something heavy — reads as activation. From HRV, heart rate
/// and motion alone it is not distinguishable from it.
public enum StressMath {
    /// Days of history the personal baseline is drawn from. WHOOP names a 14-day window.
    ///
    /// Deliberately not `RecoveryScoring`'s 30: these are separate models with separate baselines, and
    /// a shared constant would invite one to be tuned for the other's reasons.
    public static let baselineDays = 14

    /// The fewest baseline days that can produce a score at all.
    ///
    /// Three is the smallest number a sample standard deviation exists for. It sits below the 14-day
    /// window on purpose: the window is what the baseline is *drawn from*, and demanding fourteen
    /// consecutive days of strap data before showing anything would leave the tile blank for a
    /// fortnight. Below this there is no personal baseline, and since this model is defined *relative*
    /// to one, the honest answer is no score rather than a score against a default.
    public static let minimumBaselineDays = 3

    /// Length of one scored window.
    public static let windowSeconds: TimeInterval = 300

    /// R-R intervals a window needs before its RMSSD is used.
    ///
    /// This guard is load-bearing rather than tidy: `HeartRateVariabilityMath.calculateRMSSD` returns
    /// **0.0** when it has fewer than two usable intervals, and a zero RMSSD is not "no reading" — it
    /// describes a perfectly metronomic heart, which this model would score as maximum stress. A
    /// window without enough beats must never reach the scorer.
    public static let minimumRRIntervals = 20

    /// Mean acceleration magnitude at or below which the strap counts as still.
    ///
    /// Gravity is inside that magnitude, so a motionless strap reads ~1.0 G rather than 0. That is why
    /// this sits just above 1 instead of near zero — and it is the same line `AnalyzeSleepUseCase`
    /// already draws between an awake and a sleeping epoch, reused rather than re-derived.
    public static let motionCeiling = 1.25

    /// The score at zero activation — which is the low/medium band boundary.
    ///
    /// What makes it meaningful is the pairing with one score point per standard deviation: sitting at
    /// your own baseline puts you exactly on the low/medium edge, one sigma above it on medium/high,
    /// and anything below is calm.
    public static let activationOffset = 1.0

    /// The top of WHOOP's published 0–3 scale.
    public static let maximumScore = 3.0

    /// The low/medium band boundary on that scale.
    ///
    /// Named rather than written as a literal because it is read in three places that must agree: the
    /// band lookup below, and the chart's colour gradient, whose stops are the band edges. The chart
    /// cannot type `1.0` itself without becoming a second definition of where medium starts.
    public static let lowMediumBandEdge = 1.0

    /// The medium/high band boundary on that scale. See `lowMediumBandEdge`.
    public static let mediumHighBandEdge = 2.0

    /// The first hour of the waking window, in local time.
    ///
    /// A convention, not a measurement. The Stress Monitor is a *daytime* metric, and scoring the
    /// whole day would fold sleep in — where HRV is high and heart rate low, correctly scoring as
    /// calm — and pull the day's average down with it. Bounding the window keeps the number about the
    /// waking day. A night-shift wearer gets a window that does not match their day.
    public static let wakingWindowStartHour = 6

    /// The last hour of the waking window, in local time. See `wakingWindowStartHour`.
    public static let wakingWindowEndHour = 22

    /// WHOOP's three published bands.
    public enum Band: String, Sendable, CaseIterable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
    }

    /// Whether a window is still enough to be scored at all.
    public static func isResting(motionMagnitude: Double) -> Bool {
        motionMagnitude <= motionCeiling
    }

    /// A window's activation, in standard deviations of the personal baseline.
    ///
    /// HRV is negated so that both terms point the same way — up means more activated — which is what
    /// makes averaging them meaningful instead of a cancellation.
    public static func activation(
        rmssdMs: Double,
        meanHeartRate: Double,
        rmssdBaseline: BaselineStatistics,
        heartRateBaseline: BaselineStatistics
    ) -> Double {
        let hrvZ = -BaselineStatisticsMath.zScore(
            value: rmssdMs, mean: rmssdBaseline.mean, stdDev: rmssdBaseline.stdDev)
        let hrZ = BaselineStatisticsMath.zScore(
            value: meanHeartRate, mean: heartRateBaseline.mean, stdDev: heartRateBaseline.stdDev)
        return (hrvZ + hrZ) / 2.0
    }

    /// An activation on WHOOP's 0–3 scale.
    ///
    /// Clamped at both ends: `BaselineStatisticsMath.zScore` caps each term at ±4, so an extreme
    /// window would otherwise run past 3.
    public static func score(fromActivation activation: Double) -> Double {
        max(0.0, min(maximumScore, activationOffset + activation))
    }

    /// The band a score falls in, on WHOOP's published edges.
    ///
    /// Edges are exclusive at the bottom: exactly 1.0 is medium and exactly 2.0 is high, which is how
    /// WHOOP's 0–1 / 1–2 / 2–3 description reads.
    public static func band(forScore score: Double) -> Band {
        if score < lowMediumBandEdge { return .low }
        if score < mediumHighBandEdge { return .medium }
        return .high
    }

    /// The daytime span this model scores on one day, in local time.
    ///
    /// Lives here rather than inside `AnalyzeStressUseCase` because it is no longer one consumer's
    /// private detail: the chart has to know which hours the model *can* score, so it can say so
    /// instead of drawing an unscored hour as a calm one. Two definitions of the waking window would
    /// let the plot and the number describe different days.
    ///
    /// See `wakingWindowStartHour` for why the window is bounded rather than the whole day. Returns
    /// `nil` only when the calendar cannot build the bounds — an hour offset from a day start always
    /// can, so the practical return is never `nil`.
    public static func wakingWindow(on dayStart: Date, calendar: Calendar = .current) -> Range<Date>? {
        guard
            let start = calendar.date(byAdding: .hour, value: wakingWindowStartHour, to: dayStart),
            let end = calendar.date(byAdding: .hour, value: wakingWindowEndHour, to: dayStart),
            end > start
        else { return nil }
        return start..<end
    }
}
