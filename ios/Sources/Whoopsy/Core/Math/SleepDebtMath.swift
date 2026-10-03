import Foundation

/// Sleep Debt: a running deficit accumulated across the nights **before** the one it is written on.
///
/// WHOOP publishes the *shape* of this term and none of its constants — its API shows
/// `need_from_sleep_debt_milli` as one additive component of `sleep_needed`, and patent
/// US20250288255A1 describes it as "scaled and capped at a maximum" — which is the same bargain
/// `SleepNeedMath`, `SleepConsistencyMath` and `StressMath` all document. Everything below is fitted
/// to the export this app ships with.
///
/// ## The lag is measured, and it is the whole design
///
/// WHOOP's own `Sleep debt (min)` column is **not a function of the night it is written beside**. On
/// the export's 910 labelled nights:
///
///     corr(debt_n, shortfall_n)     = 0.506
///     corr(debt_n, shortfall_{n−1}) = 0.891
///     debt_n = 15.85 + 0.068·shortfall_n + 0.352·shortfall_{n−1}
///
/// The prior night's coefficient is **5.2×** its own night's, and the shortfalls are only 0.42
/// autocorrelated, so this is not collinearity — it is what the quantity is. `docs/ALGORITHMS.md` §4 had
/// already read the column that way in prose ("lagged a night so it cannot contain the night being
/// predicted"); this is that sentence measured. The model is therefore **lagged**: a night's debt
/// accumulates the shortfalls strictly before it.
///
/// **That alignment is not a free parameter, and getting it wrong costs more than accuracy.** A
/// same-night model scores MAE 16.03 deployed; the lagged one scores **8.31** — but the larger point
/// is that a same-night model would put a differently-defined number on the column the importer
/// fills, which is the inconsistency this type exists to remove. A strap night and an imported night
/// have to mean the same thing by the same word.
///
/// ## The model
///
///     shortfall_k = max(0, need_k − asleep_k)                        minutes, each night its own need
///     D_n         = Σ over k = 1…priorNightCount of carryover^(k−1) · shortfall_{n−k}
///     debt_n      = min(maximumDebtMinutes, debtPerAccumulatedMinute · D_n)
///
/// The decay is the two-process model's recovery of the waking deficit; the additive ceiling is the
/// SAFTE reservoir's shape and WHOOP's own "scaled and capped".
///
/// **Written as a closed form over a sorted window, never as a walk.** A recurrence has loop-carried
/// state, so the order the history arrives in changes the answer — walking the export in its own file
/// order (newest-first) moves MAE from 8.31 to 22.69. Selecting the priors by an explicit sort and
/// summing makes that unrepresentable rather than merely documented.
///
/// ## The fit, measured on the bundled export's 910 labelled nights
///
///     model                                          MAE (min)   corr     R²
///     lagged, carryover 0.15 — shipped                   8.31     0.900   0.767
///     lagged, carryover 0.00 (prior night only)          8.72     0.891   0.705
///     same-night, carryover 0.70                        16.03     0.785   0.611
///     weighted mean, 14 nights (Oura's taper)           19.61     0.670   0.450
///     predicting the mean                               27.70      —       —
///
/// Three things about that table belong in the reader's head. The **carryover is a shallow argmin**:
/// 0.00 scores 8.72 and 0.30 scores 9.26, so the exponential beyond the single prior night is worth
/// about 0.4 minutes and the basin 0.10–0.25 sits within 0.08 of the minimum. It is shipped as the
/// reproducible argmin, the same doctrine that puts `SleepNeedMath` at 6.40 over a luckier 7.0. The
/// **window is exact**: truncation at 5 costs at most **0.02 minutes** against the export's largest
/// single-night shortfall (543 min), and W = 5, 7, 10, 14 and 20 all score 8.3046. And the ceiling
/// remains modest — **MAE 8.3 against a column whose own standard deviation is 33.9** — so this
/// reproduces the shape and scale of WHOOP's quantity, not its value.
///
/// ## The cap is load-bearing
///
/// `maximumDebtMinutes` is **127**, because the export's column maxes at exactly 127 with **105 of
/// 910 rows stacked on that single value** against 33 rows spread over 120–126 — a written ceiling,
/// not a tail. It is not decoration: **77 of 910 predictions (8.5%) exceed it** uncapped, reaching
/// 254. A strap night must not print a figure the import could never have stored for the same night.
///
/// ## `0` is a real answer here
///
/// Uniquely among the numbers this app computes, the model may legitimately return **zero** — WHOOP's
/// own column bottoms out at 0, and "no accumulated deficit" is a measurement rather than an absence.
/// `nil` is what means *not scored*, which is the distinction `sleeps.sleep_debt`'s nullable column
/// already draws and the reason the importer writes `map` and never `?? 0`.
///
/// ## A negative worth recording: there is no repayment term
///
/// `D ← carryover·D + shortfall − ρ·surplus` was measured, sweeping ρ from 0 to 1 — a full
/// minute-for-minute repayment of every surplus. Deployed MAE moves from 8.31 to 8.24, four seconds,
/// monotonically but flat. The export's column shows no evidence of repayment beyond the decay, so
/// the second constant is not justifiable. "Sleeping more pays the debt off" is the first thing a
/// reader will want to add; this is the measurement that says not to.
public enum SleepDebtMath {

    /// One night, as this model needs it: its day key, what was needed, and how long was slept.
    ///
    /// A plain value rather than a `SleepSession`, because `Core` holds the math and does not reach
    /// into `Domain`. The day is carried because the priors are **records**, not calendar arithmetic —
    /// an unmeasured night is an absent row, so consecutive records are not consecutive days.
    public struct Night: Sendable, Equatable {
        public let day: Date
        public let needSeconds: TimeInterval
        public let asleepSeconds: TimeInterval

        public init(day: Date, needSeconds: TimeInterval, asleepSeconds: TimeInterval) {
            self.day = day
            self.needSeconds = needSeconds
            self.asleepSeconds = asleepSeconds
        }
    }

    /// How much of each earlier night's shortfall survives into the next night.
    ///
    /// The argmin of a 0.00–1.00 sweep at 0.05 steps on the export's 910 labelled nights: 0.15 scores
    /// 8.31 where 0.00 scores 8.72 and 0.30 scores 9.26. Shallow on purpose — see the type's comment.
    public static let carryover: Double = 0.15

    /// The fitted scale: minutes of debt per minute of accumulated shortfall.
    ///
    /// Through-origin least squares, so zero accumulation is exactly zero debt — one constant fewer
    /// than a free intercept, which buys 0.02 minutes and would extrapolate into a region of the input
    /// the export never covers. The same reasoning as `SleepNeedMath`'s pinned intercept.
    public static let debtPerAccumulatedMinute: Double = 0.4293

    /// How many prior nights the accumulation reads.
    ///
    /// Five is exact rather than chosen: the truncation tail is `carryover^5 / (1 − carryover)`, worth
    /// at most 0.02 minutes against the export's largest shortfall, and the measured error is
    /// *identical* at 5, 7, 10, 14 and 20.
    public static let priorNightCount = 5

    /// The ceiling, in minutes: the largest value the scale can express.
    ///
    /// WHOOP's own column maxes at exactly 127, with 105 of 910 rows on that single value. Load-bearing
    /// rather than cosmetic — 8.5% of the model's own predictions exceed it before clamping.
    public static let maximumDebtMinutes: Double = 127.0

    /// How far back the caller reads `sleeps` to find the nights the accumulation needs.
    ///
    /// Generous rather than tight, because the window is **calendar days** and the model consumes
    /// **records**: a recording gap makes the calendar span far longer than the night count. On the
    /// export only 15 of 910 nights have fewer than five priors inside 30 days.
    public static let historyLookbackDays = 30

    /// The night's accumulated sleep debt in seconds, or `nil` when there is no earlier night to
    /// accumulate from.
    ///
    /// **The gate is one prior record, not a fixed count, and that follows from the lagged form.** The
    /// accumulation is a strictly-earlier-only quantity, so a night with one predecessor has a
    /// complete — if short-memoried — answer, and the terms it cannot see are worth at most 0.02
    /// minutes. `SleepConsistencyMath` gates at four because its quantity *is* a mean over four and
    /// has no partial rendering; this one has a base case. With nothing before it there is genuinely
    /// nothing to accumulate, and the row draws a dash.
    ///
    /// - Parameters:
    ///   - night: The night being scored. Its own shortfall is **never** part of its own debt.
    ///   - history: Other nights, in any order. Nights on or after `night.day` are ignored.
    ///   - calendar: Unused by the model — the ordering is by `day`, not by elapsed days — and taken
    ///     only so a caller reading days in another zone has somewhere to say so.
    public static func sleepDebtSeconds(
        for night: Night, history: [Night], calendar: Calendar = .current
    ) -> TimeInterval? {
        let priors = history
            .filter { $0.day < night.day }
            .sorted { $0.day > $1.day }
            .prefix(priorNightCount)

        guard !priors.isEmpty else { return nil }

        var accumulated = 0.0
        var weight = 1.0
        for prior in priors {
            accumulated += weight * shortfallMinutes(of: prior)
            weight *= carryover
        }

        let minutes = min(maximumDebtMinutes, debtPerAccumulatedMinute * accumulated)
        return (minutes * 60).rounded()
    }

    /// One night's shortfall in minutes: how far it fell short of its own need, never negative.
    ///
    /// Each night is measured against **its own** need, which matters across the import boundary —
    /// an imported night carries WHOOP's own need and a strap night carries the computed one, and
    /// using either for both would misstate the deficit on every night from the other path.
    public static func shortfallMinutes(of night: Night) -> Double {
        max(0, (night.needSeconds - night.asleepSeconds) / 60.0)
    }
}
