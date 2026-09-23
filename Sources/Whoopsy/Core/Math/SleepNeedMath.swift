import Foundation

/// Sleep Need: how much sleep a night actually required, as opposed to a nightly target.
///
/// WHOOP publishes the *shape* of this model and none of its constants. Its developer API exposes
/// `sleep_needed` as an additive breakdown — `baseline_milli` + `need_from_sleep_debt_milli` +
/// `need_from_recent_strain_milli` − `need_from_recent_nap_milli` — so a baseline with a positive
/// strain term is WHOOP's published structure rather than an invention of this app's. The constant
/// below is **fitted to the export this app ships with**, because there is nothing to cite.
///
/// ## The fit
///
/// Least squares of WHOOP's own `Sleep need (min)` on its own `Day Strain`, taken from the *previous*
/// day, with the intercept pinned to the 8-hour baseline: **6.40 minutes of additional need per strain
/// point** over the 909 nights that carry a preceding strain day. Leaving the intercept free moves it
/// to 478 minutes — within two minutes of the profile's 8 hours — which is why pinning it costs
/// nothing and keeps `UserProfile.targetSleepHours` as the one knob for the baseline.
///
/// Scored by 5-fold cross-validation — the model fitted on four fifths of the series, its error
/// measured on the held-out fifth, five times over — against the sleep performance WHOOP's *own* need
/// implies (`asleep / their need`), so the number isolates error in the need rather than in the
/// four-component performance composite this app does not reproduce:
///
///     480 flat, no strain term                   10.06   ← what this replaced
///     480 + 4.5 × strain                          4.64
///     480 + 6.40 × strain (this)                  3.77
///     refitting the coefficient on each fold      3.87
///     … plus a fitted 7-night deficit term        3.41
///     docs/ALGORITHMS.md §4's old formula, written out 18.44
///
/// The curve is flat between 6.4 and 7.0 (3.77, 3.76, 3.78), so the fitted value is shipped rather
/// than the marginally luckier one: a constant anyone can reproduce from the export in one line is
/// worth more than 0.01 of a percentage point.
///
/// ## What is deliberately left out
///
/// - **Accumulated Sleep Debt**, one of WHOOP's four named inputs. A fitted 7-night deficit term does
///   help — 3.77 → 3.41 — and WHOOP's own `Sleep debt (min)` column, lagged a night so it cannot
///   contain the night being predicted, does no better (3.43). So the gain is real but small, and a
///   reconstruction of the debt series has no hidden headroom to find. It is left out as a judgement:
///   0.35 of a point, on a 0–100 scale, for a second fitted constant and seven nights of history to
///   read. The strain coefficient absorbs what the debt term would have carried — it falls from 6.40
///   to about 2.9 when the term is present, so the two are near-substitutes rather than independent
///   inputs.
/// - **The `0.20` carryover of `docs/ALGORITHMS.md` §4's old formula.** Written out as specified, with a
///   7-night deficit, it scores **18.44** — nearly twice the flat 480 it would have replaced. A
///   7-night deficit averages about 1000 minutes there, so a fifth of it swamps the baseline instead
///   of adjusting it. That formula was never implemented, and it should not be.
/// - **Naps.** WHOOP's API shows naps *subtract* from need. The export's `Nap` column lives only in
///   the unbundled `sleeps.csv`, and all 8 nap rows collide with a night on the same day key that
///   `sleeps` is primary-keyed on.
/// - **Sleep Stress.** WHOOP's fourth input, quantified in prose only — in no export column and no
///   API field. Unobtainable from this data.
///
/// ## The lag, and what the constant is
///
/// The *previous* day's strain, not the same day's: across those 909 nights the previous day's fits
/// need at R² = 0.366 against the same day's 0.161, and WHOOP's own wording names the previous day.
/// The app reads it from the row that precedes the night — `strains` is keyed on
/// `startOfDay(wakeOnset)`, so the cycle preceding the night ending on morning D is keyed D.
///
/// The constant is *effective*, not WHOOP's own `f(strain)`. It is fitted against a fixed baseline, so
/// it also absorbs whatever drift in WHOOP's learned baseline correlates with strain, and WHOOP's own
/// API example shows its strain term contributing single-digit minutes where this implies more. It is
/// a calibration that reproduces WHOOP's need — which is the point — not a recovery of their function.
/// The model under-disperses accordingly: predicted need spans 491–613 min against WHOOP's actual
/// 321–650 (σ 26.0 against 42.5).
public enum SleepNeedMath {
    /// Minutes of extra sleep a night requires per point of the previous day's Strain.
    ///
    /// Fitted, not assumed — the type's doc comment carries the fit, the cross-validation and the
    /// alternatives rejected. 6.40 is the pinned-intercept least-squares slope over the 909 export
    /// nights that carry a preceding strain day.
    public static let strainMinutesPerPoint = 6.40

    /// The documented Strain scale, used to bound the *input* rather than the output.
    ///
    /// Strain is defined on 0–21, so a value outside it is a corrupt row rather than a hard day.
    /// Clamping at the input keeps the adjustment inside the range the coefficient was fitted over;
    /// at the maximum it is worth 134 minutes, which leaves the need inside the 321–650 min band
    /// WHOOP's own need occupies.
    public static let maximumStrain = 21.0

    /// The sleep a night required.
    ///
    /// - Parameters:
    ///   - baselineSeconds: The personal baseline need, from `UserProfile.targetSleepHours`.
    ///   - previousDayStrain: The Strain of the cycle that preceded the night, or `nil` when no such
    ///     row is stored.
    /// - Returns: The baseline plus the strain adjustment. A `nil` strain returns the baseline
    ///   **exactly**: an absent strain row means the day is unmeasured, and substituting a plausible
    ///   strain would turn "we do not know how hard yesterday was" into a real change in tonight's
    ///   target. That is the rule that keeps a placeholder recovery row out of the scoring baselines,
    ///   applied to an input instead of an output.
    public static func sleepNeedSeconds(
        baselineSeconds: TimeInterval,
        previousDayStrain: Double?
    ) -> TimeInterval {
        guard let previousDayStrain else { return baselineSeconds }
        let bounded = max(0.0, min(maximumStrain, previousDayStrain))
        return baselineSeconds + bounded * strainMinutesPerPoint * 60.0
    }
}
