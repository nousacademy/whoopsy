import Foundation

/// The mortality-risk half of the longevity estimate: three published relative risks multiplied
/// together against a stated reference profile.
///
/// **This is not a biological age and it is not a life expectancy.** It says one thing — *your measured
/// profile carries about this multiple of the reference person's all-cause mortality risk* — and it
/// says it from **someone else's fit**, exactly as `docs/ALGORITHMS.md` treats Strain. Turning it into
/// years needs an age-specific life table, which the app does not yet bundle; until then the number is
/// a multiplier and the card says so.
///
/// **Three factors, not five.** Each coefficient below is a published hazard ratio with a stated
/// reference, and the product assumes the factors act independently — an assumption the card states
/// rather than hides. Two things the app measures are deliberately left out: **sleep**, because its
/// mortality curve is J-shaped and this app will not invent a slope for it, and **strength-activity
/// time**, whose published hazard ratio is per week of a self-reported activity class rather than per
/// minute the strap can count.
///
/// ## The coefficients
///
/// - **Cardiorespiratory fitness** — HR **0.85 per +1 MET** (3.5 mL·kg⁻¹·min⁻¹), against a reference of
///   30 mL·kg⁻¹·min⁻¹, and **credited to at most 44 mL·kg⁻¹·min⁻¹** (12.5 METs, the elite threshold the
///   cohort itself uses). Mandsager et al., *JAMA Network Open* 2018 (122,007 patients): each 1-MET
///   higher fitness carried roughly 15 % lower all-cause mortality, monotonic across quintiles. The cap
///   is there because the gradient was measured *within* that cohort's range: this app's fitness figure
///   is itself an estimate, and an uncapped exponent let a good estimate compound into the floor of the
///   clamp, where every fit profile read the same number.
/// - **Steps per day** — HR **0.90 per +1,000 steps**, against a reference of 5,000, and **capped at
///   10,000** because the association flattens there. Paluch et al., *Lancet Public Health* 2021
///   (meta-analysis, ~47,000 adults) and Saint-Maurice et al., *JAMA* 2020 (NHANES; 8,000 vs 4,000
///   steps ≈ HR 0.49) put the per-1,000 effect in the 10–15 % range.
/// - **Resting heart rate** — HR **1.15 per +10 bpm**, against a reference of 60. Nauman et al.,
///   *JAMA* 2011 (Copenhagen Male Study): 71–80 bpm vs under 60 carried roughly HR 1.5, and 81+ about
///   1.9, which is of that order per 10 bpm.
///
/// The product is **clamped to 0.2–2.0**: the floor is the elite-versus-low hazard ratio the fitness
/// cohort itself reports (0.20), so the best measurable profile can reach the best observed number and
/// no further, and the ceiling bounds a stack of extreme inputs at what the worst bands of these
/// cohorts multiply to. A tighter floor than the evidence allows would pin every fit profile at the
/// same number, which is information thrown away.
public struct MortalityRiskProfile: Equatable, Sendable {

    /// One factor's contribution.
    public struct Factor: Equatable, Sendable, Identifiable {
        /// Stable identity for the row list.
        public enum Kind: String, Sendable, CaseIterable {
            case fitness
            case steps
            case restingHeartRate
        }

        public let kind: Kind
        /// What the factor is called on the card.
        public let name: String
        /// The reading, already formatted with its unit.
        public let valueText: String
        /// What it is read against, in words.
        public let referenceText: String
        /// This factor's relative risk on its own, before the product.
        public let relativeRisk: Double

        public var id: Kind { kind }
    }

    public let factors: [Factor]

    /// The product of the factors' relative risks, clamped. `1.0` is the reference profile.
    public let multiplier: Double

    /// The clamp. Stated as a constant because the card's footnote quotes it.
    public static let multiplierRange: ClosedRange<Double> = 0.2...2.0

    /// The reference profile the coefficients are anchored to, as the footnote prints it.
    public static let referenceDescription =
        "30 mL/kg/min fitness, 5,000 steps and a 60 bpm resting rate"

    /// The factors this app measures and does not use, with the reason — printed, so an absence on the
    /// card reads as a decision rather than as an oversight.
    public static let unusedFactors = [
        "Sleep: its mortality curve is J-shaped, and this app will not invent a slope for it.",
        "Strength time: the published ratio is per week of a self-reported activity class, not per "
            + "minute the strap can count.",
    ]

    public init(factors: [Factor]) {
        self.factors = factors
        let product = factors.reduce(1.0) { $0 * $1.relativeRisk }
        self.multiplier = min(Self.multiplierRange.upperBound,
                              max(Self.multiplierRange.lowerBound, product))
    }

    /// The three factors the day's rows can supply, or `nil` when it supplies none of them.
    ///
    /// **A missing reading removes its factor rather than counting as 1.0.** A `1.0` would be a claim
    /// that the factor is exactly average, which is a different statement from "no measurement", and it
    /// would let an unmeasured day look like a complete profile.
    public static func make(
        vo2MaxMlKgMin: Double?,
        steps: Int?,
        restingHeartRate: Int?
    ) -> MortalityRiskProfile? {
        var factors: [Factor] = []

        if let vo2 = vo2MaxMlKgMin, vo2 > 0 {
            let credited = min(vo2, fitnessCreditCap)
            let metres = (credited - 30) / 3.5
            factors.append(
                Factor(
                    kind: .fitness,
                    name: "Cardiorespiratory fitness",
                    valueText: "\(Int(vo2.rounded())) mL/kg/min",
                    referenceText: "vs 30",
                    relativeRisk: pow(0.85, metres)))
        }

        if let steps, steps >= 0 {
            // The benefit is capped where the evidence flattens, and the cap is in steps rather than in
            // the exponent so the card's own value can still print what the strap counted.
            let credited = min(steps, stepCreditCap)
            factors.append(
                Factor(
                    kind: .steps,
                    name: "Steps per day",
                    valueText: "\(credited.formatted(.number.grouping(.automatic)))",
                    referenceText: "vs 5,000",
                    relativeRisk: pow(0.90, Double(credited - 5_000) / 1_000)))
        }

        if let restingHeartRate, restingHeartRate > 0 {
            factors.append(
                Factor(
                    kind: .restingHeartRate,
                    name: "Resting heart rate",
                    valueText: "\(restingHeartRate) bpm",
                    referenceText: "vs 60",
                    relativeRisk: pow(1.15, Double(restingHeartRate - 60) / 10)))
        }

        guard !factors.isEmpty else { return nil }
        return MortalityRiskProfile(factors: factors)
    }

    /// The step count beyond which the published association is flat.
    public static let stepCreditCap = 10_000

    /// The fitness beyond which the published gradient is not credited — 12.5 METs, the elite
    /// threshold the fitness cohort uses. See the type's comment.
    public static let fitnessCreditCap = 44.0
}
