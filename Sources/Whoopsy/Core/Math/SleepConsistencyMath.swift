import Foundation

/// Sleep Consistency: how closely a night's onset and wake line up with the four nights before it.
///
/// WHOOP publishes the *shape* of this model and none of its constants — the same bargain
/// `SleepNeedMath` and `StressMath` document — so everything below is fitted to the export this app
/// ships with. The number this produces is a calibration that reproduces WHOOP's, not a recovery of
/// their function.
///
/// ## What the model is
///
/// WHOOP describes the metric as "the percentage of time you are in the same state (asleep vs. awake)
/// at specific clock times across consecutive nights", with comparisons further apart weighted less.
/// That description is exact, and it is also a boundary-shift model in disguise: a night with one
/// onset and one wake is a single asleep interval, so the fraction of the clock on which two such
/// nights agree is `1 − (|Δonset| + |Δwake|) / 1440` — those two boundaries are the whole of the
/// disagreement. The two formulations are the same quantity, which is why fitting boundaries
/// reproduces a score that is defined over timepoints.
///
/// ## The window is four prior nights, not three
///
/// Free per-lag coefficients on the twelve boundary features — onset and wake at each of six lags —
/// are all significant at lags 1–4 and collapse at lag 5 (t = +0.44). Refitting the whole model at
/// each window size peaks sharply at four:
///
///     prior nights      1       2       3       4       5       6
///     MAE            5.317   3.935   3.119   2.749   2.935   3.247
///
/// Below four priors the model is worse than saying nothing — at one prior its MAE is 6.547 — so
/// there is no partial rendering: `consistency(for:history:)` returns `nil` and the row draws a dash.
/// That is the same gate `SleepNeedMath` and `BaselineStatisticsMath` apply to thin history.
///
/// ## Recency weighting, and the link
///
/// 4:3:2:1 sits inside the noise of a fitted exponential decay, and flat 1:1:1:1 is measurably worse,
/// so the weighting is real but gentle. The score is **concave** in the mean boundary shift — a power
/// of 0.60 rather than a straight line — and that was the single biggest finding of the fit: under a
/// linear link the coefficients report a spurious 1.8:1 onset-to-wake asymmetry, because a straight
/// line absorbs the curve's slope into whichever feature moves furthest. It vanishes once the link is
/// right, which is how the concavity was confirmed rather than assumed.
///
/// ## Agreement, measured on the bundled export
///
/// On the 891 scorable nights, in sample: **R² 0.728, MAE 2.749, median error 1.379, 79.0% within ±3,
/// 86.6% within ±5.** A forward time split — fitted on 2023-07→2025-11, tested on 2025-11→2026-08 —
/// is better rather than worse: **MAE 1.978, 88.8% within ±3.**
///
/// **The error is period-dependent, and that is a caveat rather than a tuning target.** Every 60-night
/// window ending on or after 2025-05-23 sits at MAE 1.23–2.13 — 455 nights at **MAE 1.190, R² 0.927,
/// 91.0% within ±3** — while every window before 2024-12-08 sits at 2.25–5.42 (436 nights, MAE 4.238).
/// The discontinuity coincides exactly with a 137-day recording gap, and the lag structure is
/// *identical* on both sides of it, so this is not an algorithm change. The 2023–24 rows of the export
/// carry a consistency score that is scattered relative to the timestamps in the same file, and no
/// model reading those timestamps can reproduce it.
///
/// ## Three things the implementation must get right
///
/// Each is demonstrated by the export rather than assumed:
///
/// 1. **Order by the night's own `day` and take the last four records** — never subtract calendar days
///    from an onset. 297 of the 910 nights begin before midnight while the export keys a night on its
///    wake onset, so calendar arithmetic against `onset` puts those nights in the wrong order.
/// 2. **The history read is a date range, not a count.** On the export the range covering four prior
///    nights spans more than five calendar days on 17 of 891 nights, and up to 148. So the caller
///    widens the read to `historyLookbackDays` and this type truncates to four records — and returns
///    `nil` for the 8 nights whose fourth predecessor is further back than that, because a score built
///    across a five-month gap would be comparing a night to a different life.
/// 3. **All arithmetic is on night-clock minutes with a circular distance.** Naive minute-of-day
///    differences break across midnight for 613 of the 910 nights: a 23:50 onset against a 00:10 one
///    is twenty minutes apart, not 1420.
public enum SleepConsistencyMath {

    /// One night, as this model needs it: the day it is keyed on, and its two boundaries.
    ///
    /// A plain value rather than a `SleepSession`, because `Core` holds the math and does not reach
    /// into `Domain` — `StressMath` takes a `Double` and hands back a `Band` for the same reason. The
    /// day is carried because the window is *records*, not calendar arithmetic: see rule 1 above.
    public struct Night: Sendable, Equatable {
        public let day: Date
        public let onset: Date
        public let wake: Date

        public init(day: Date, onset: Date, wake: Date) {
            self.day = day
            self.onset = onset
            self.wake = wake
        }
    }

    /// How many prior nights the score is read over — four, not the three the prose suggests.
    ///
    /// Pinned as a constant because it is the model's shape rather than a tuned parameter: the fit
    /// peaks here and the fifth lag's coefficient is indistinguishable from zero.
    public static let priorNightCount = 4

    /// The recency weights, newest prior first, summing to `recencyWeightTotal`.
    public static let recencyWeights: [Double] = [4, 3, 2, 1]

    public static var recencyWeightTotal: Double { recencyWeights.reduce(0, +) }

    /// The fitted intercept, in percentage points: the score a night scores when its boundaries sit
    /// exactly on all four predecessors'. Above 100 on purpose — it is clipped, and pinning it at 100
    /// would bend the curve near perfect consistency, which is where a reader is most likely to look.
    public static let shiftInterceptPercent = 107.4883

    /// The fitted multiplier, in percentage points per `shiftExponent`-th power of a minute.
    public static let shiftCoefficient = 1.81848

    /// The fitted exponent: the link is concave, not linear. See the type's doc comment.
    public static let shiftExponent = 0.60

    /// How far back the caller reads `sleeps` to find four prior records.
    ///
    /// Wide enough that the range is almost never the reason a score is missing: on the bundled export
    /// this covers 880 of the 888 scorable nights, and every window from 10 to 21 days covers the same
    /// 880 — the eight it does not reach are nights whose fourth predecessor is 13 to 148 days earlier,
    /// which is a recording gap rather than a history this model should score across.
    public static let historyLookbackDays = 12

    /// A night's consistency, or `nil` when there are not four prior nights to read it against.
    ///
    /// - Parameters:
    ///   - night: The night being scored.
    ///   - history: Other nights, in any order. Nights on or after `night.day` are ignored, whichever
    ///     day they were keyed on; the four most recent survivors are used.
    ///   - calendar: The calendar the wall-clock times are read in. Passed rather than assumed so a
    ///     caller reading a day in another zone gets that zone's clock times.
    public static func consistency(
        for night: Night, history: [Night], calendar: Calendar = .current
    ) -> Int? {
        let priors = history
            .filter { $0.day < night.day }
            .sorted { $0.day > $1.day }
            .prefix(priorNightCount)

        // Four priors or nothing. The model's error at one, two or three of them is larger than the
        // spread of the scores it would be predicting — at one prior its MAE is 6.547 — so a partial
        // render would put a confident-looking percentage on the screen that carries no information.
        guard priors.count == priorNightCount else { return nil }

        let targetOnset = nightClockMinutes(night.onset, calendar: calendar)
        let targetWake = nightClockMinutes(night.wake, calendar: calendar)

        var weightedShift = 0.0
        for (weight, prior) in zip(recencyWeights, priors) {
            weightedShift += weight * (
                circularMinuteDistance(targetOnset, nightClockMinutes(prior.onset, calendar: calendar))
                    + circularMinuteDistance(
                        targetWake, nightClockMinutes(prior.wake, calendar: calendar)))
        }
        let meanShift = weightedShift / recencyWeightTotal

        let raw = shiftInterceptPercent - shiftCoefficient * pow(meanShift, shiftExponent)
        return max(0, min(100, Int(raw.rounded())))
    }

    /// Minutes past a **noon-shifted** midnight, so that a whole night is one contiguous run.
    ///
    /// Noon is the pivot rather than midnight because midnight falls in the middle of the night: a
    /// 23:50 onset is ten minutes before a 00:10 one, and on a midnight clock they are 1420 minutes
    /// apart, which is the wraparound this shift exists to remove.
    public static func nightClockMinutes(_ date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutesOfDay = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        let shifted = (minutesOfDay - 720).truncatingRemainder(dividingBy: 1440)
        return shifted < 0 ? shifted + 1440 : shifted
    }

    /// How far apart two night-clock minutes are, the short way round the clock.
    public static func circularMinuteDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 1440)
        return min(difference, 1440 - difference)
    }
}
