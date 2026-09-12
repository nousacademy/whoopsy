import Foundation

/// VO₂ max from the ratio of maximal to resting heart rate — the **Heart Rate Ratio Method**.
///
/// This is the only model in `Core/Math` that produces a quantity neither the strap nor the export
/// gives this app a way to read, so the whole of its basis is recorded here rather than summarised.
/// It is an *estimate*, and every surface that prints it must say so.
///
/// ## The model
///
///     VO₂max (mL·kg⁻¹·min⁻¹) = 15.3 × HRmax / HRrest
///
/// Uth, Sørensen, Overgaard & Pedersen (2004), *Estimation of V̇O₂max from the ratio between HRmax
/// and HRrest — the Heart Rate Ratio Method*, Eur J Appl Physiol 91(1):111–115,
/// [doi:10.1007/s00421-003-0988-y](https://doi.org/10.1007/s00421-003-0988-y).
///
/// The coefficient is not fitted to anything this app can see. The paper derives it from the Fick
/// equation as the product of the maximal-to-rest ratios of stroke volume (≈1.3) and of the
/// arterio-venous O₂ difference (≈3.4) — 1.3 × 3.4 × 3.4 ≈ 15 — and then measures it in a subgroup
/// of 10 of its 46 subjects as **15.26 (0.72)**, which is where `15.3` comes from.
///
/// ## What the constant costs
///
/// The paper's own standard error of estimate, which is the number that belongs next to any figure
/// this function produces:
///
///     with a *measured* HRmax        2.7 mL·kg⁻¹·min⁻¹   (~4.5%)   ← not this app's case
///     with an age-predicted HRmax    4.7 mL·kg⁻¹·min⁻¹   (~7.8%)   ← this app's case
///
/// The second row is the one that applies here, and it is roughly **twice** the error of the first.
/// Nothing in this app performs a maximal exercise test, so the anchor handed in is never a measured
/// HRmax — it is `UserProfile.maxHeartRate`, a stored constant. Every estimate this function returns
/// therefore sits in the age-predicted row, and a decimal place on screen would claim a precision
/// below an error bar quoted in whole mL·kg⁻¹·min⁻¹.
///
/// The study's population was **46 well-trained men aged 21–51**, and its authors state that
/// applicability to other groups requires direct validation. That validation has not been done here.
///
/// ## Why `HRmax` is never the day's observed peak
///
/// The obvious per-day anchor — the `Max HR (bpm)` the strap or the export recorded for that day —
/// is rejected, and this is a measurement rather than a preference. Over the bundled export's **909
/// days carrying both a Max HR and a resting heart rate**, the per-day estimate spans **25.9 to 62.2
/// mL·kg⁻¹·min⁻¹** — a 2.4× spread — and correlates **+0.49 with that day's Day Strain**.
///
/// That correlation is the disqualifier. A day's peak heart rate is a record of how hard the day
/// was, not of the heart's ceiling, so a model anchored on it reports effort and calls it fitness.
/// `ALGORITHMS.md` §6 already argues the panel must not carry a day-to-day arrow because VO₂ max
/// moves on a scale of years; an anchor that swings it 2.4× with the day's training contradicts the
/// quantity's own definition. Anchoring on a stable `HRmax` instead leaves a day's estimate varying
/// only with its resting heart rate, which *is* the genuine fitness signal in this ratio.
public enum Vo2MaxMath {
    /// The proportionality constant of the Heart Rate Ratio Method: 15.3 mL·kg⁻¹·min⁻¹, measured at
    /// 15.26 (0.72) in the study's 10-subject subgroup and not significantly different from the
    /// theoretical ≈15.
    public static let heartRateRatioCoefficient = 15.3

    /// Estimates VO₂ max in mL·kg⁻¹·min⁻¹ from a maximal and a resting heart rate, or `nil` when
    /// either anchor is missing.
    ///
    /// Both arguments are optional and both a missing and a **non-positive** one return `nil`, because
    /// the two are the same absence in this app's storage: `strains.maxHeartRate` and the resting
    /// heart rate on a `recoveries` row are non-optional columns that a placeholder row or an
    /// importer's `?? 0` fills with a literal zero. A zero is a reserved marker here, not a
    /// measurement — `HRmax` of 0 bpm and a resting rate of 0 bpm are not readings any sensor could
    /// take. Feeding one in would divide by zero or return a confident `0.0`, which is the exact
    /// fabrication this app's dash convention exists to prevent.
    ///
    /// The result is deliberately **not rounded**. Rounding belongs where the number is rendered, and
    /// a rounded value stored in an entity is a precision claim the entity cannot take back.
    public static func heartRateRatioEstimate(
        maxHeartRate: Int?,
        restingHeartRate: Int?
    ) -> Double? {
        guard
            let maxHeartRate, maxHeartRate > 0,
            let restingHeartRate, restingHeartRate > 0
        else { return nil }

        let estimate = heartRateRatioCoefficient * Double(maxHeartRate) / Double(restingHeartRate)
        // Unreachable while both guards hold — two positives cannot produce a non-positive quotient —
        // but returned as an absence rather than trusted, because the alternative is a `0.0` that
        // reads as a measurement of zero aerobic capacity.
        return estimate > 0 ? estimate : nil
    }
}
