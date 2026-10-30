import Foundation

/// One published life table: `q_x` and `e_x` per single year of age, from birth to 100-and-over.
///
/// **The numbers are somebody else's publication and the app only applies them.** `q_x` is what a
/// relative risk acts on; `e_x` is carried so the app's own integration can be checked against the
/// printed figure rather than trusted — a parser that dropped a row would still produce a smooth,
/// plausible curve, and the suite asserts the two agree at several ages.
///
/// **A risk multiplier acts on the force of mortality**: `q'_x = 1 − (1 − q_x)^HR`, which is the
/// discrete form of scaling `µ` by a constant. The tail above 100 is held at the published `e_100`,
/// and that is a stated assumption rather than a computed one — the table's terminal age is a single
/// row, so anything beyond it is a modelling choice either way.
public struct LifeTable: Equatable, Sendable {

    public let source: String
    public let year: Int

    /// `q_x` for ages 0…100, where index 100 is the 100-and-over row.
    public let qx: [Double]

    /// The published `e_x` for the same ages.
    public let ex: [Double]

    /// The last age the table describes — the 100-and-over row.
    public static let terminalAge = 100

    public init(source: String, year: Int, qx: [Double], ex: [Double]) {
        self.source = source
        self.year = year
        self.qx = qx
        self.ex = ex
    }

    /// Remaining life expectancy at an exact age, from this table's own `q_x`.
    ///
    /// Ages beyond the table answer with the terminal row rather than `nil`: a 101-year-old is
    /// described by the 100-and-over row, which is what that row is for.
    public func remainingYears(at age: Int) -> Double? {
        guard !qx.isEmpty, !ex.isEmpty else { return nil }
        let clamped = min(max(age, 0), Self.terminalAge)

        var survivors = 1.0
        var personYears = 0.0
        for index in 0..<Self.terminalAge {
            guard index + 1 < qx.count else { break }
            let next = survivors * (1 - qx[index])
            if index >= clamped {
                personYears += (survivors + next) / 2
            }
            survivors = next
        }
        // The open-ended row: the survivors at 100 each live the published expectancy at 100.
        let terminal = survivors * (ex.last ?? 0)
        if clamped <= Self.terminalAge {
            personYears += terminal
        }
        let atAge = clamped == 0 ? 1.0 : survivorsAt(clamped)
        guard atAge > 0 else { return nil }
        return personYears / atAge
    }

    /// Survivors to an exact age, on a cohort of 1.
    private func survivorsAt(_ age: Int) -> Double {
        var survivors = 1.0
        for index in 0..<min(age, Self.terminalAge) where index < qx.count {
            survivors *= (1 - qx[index])
        }
        return survivors
    }

    /// The age whose **population average** has this many years left — the inverse of
    /// `remainingYears(at:)`, interpolated between whole years.
    ///
    /// **This is what turns a mortality risk into an "effective age".** It is the standard
    /// construction: equate the risk-adjusted expectancy with the age-only curve and solve for the age.
    /// PhenoAge, GrimAge and CosinorAge all do exactly this; what differs between them is which inputs
    /// move the expectancy, not how the age is read back out.
    ///
    /// The curve is monotone, so a bisection is all it needs. An expectancy above the table's own `e_0`
    /// answers `0` and one below `e_100` answers the terminal age — a clamp at both ends rather than a
    /// number outside the table.
    public func age(withRemainingYears years: Double) -> Double? {
        guard let atBirth = remainingYears(at: 0) else { return nil }
        guard years < atBirth else { return 0 }
        guard let terminal = remainingYears(at: Self.terminalAge) else { return nil }
        guard years > terminal else { return Double(Self.terminalAge) }

        var low = 0.0
        var high = Double(Self.terminalAge)
        for _ in 0..<40 {
            let middle = (low + high) / 2
            let whole = Int(middle)
            let fraction = middle - Double(whole)
            guard
                let lower = remainingYears(at: whole),
                let upper = remainingYears(at: min(whole + 1, Self.terminalAge))
            else { return nil }
            let value = lower + (upper - lower) * fraction
            if value > years { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// The same table with its force of mortality scaled by a relative risk.
    ///
    /// `q' = 1 − (1 − q)^HR` is `µ' = HR · µ` in discrete form: the survival of one year at hazard
    /// ratio `HR` is the reference survival raised to `HR`. A multiplier below 1 flattens the curve; a
    /// multiplier above 1 steepens it, and both leave `q` inside 0…1 by construction.
    public func adjusted(by multiplier: Double) -> LifeTable {
        guard multiplier > 0 else { return self }
        let scaled = qx.map { 1 - pow(1 - $0, multiplier) }
        // The published `e_x` describes the unadjusted table, so the adjusted one carries it only as
        // the terminal tail — see the type's comment.
        return LifeTable(source: source, year: year, qx: scaled, ex: ex)
    }
}

/// What the app can say once a life table and a risk multiplier meet: remaining years for someone of
/// this age in this population, and the same figure with the measured profile applied.
///
/// **It is an estimate and the card says so.** The baseline is a period life table — the mortality of a
/// particular year applied to a hypothetical cohort — and the adjusted figure assumes the profile's
/// relative risk holds for the rest of a life, which no cohort has shown. Both caveats belong beside
/// the number, not in a drawer.
public struct LongevityEstimate: Equatable, Sendable {

    public let countryName: String
    public let source: String
    public let year: Int
    public let age: Int
    public let sexLabel: String

    /// Remaining years for the population average at this age.
    public let baselineYears: Double

    /// The same figure with `multiplier` applied to the force of mortality.
    public let adjustedYears: Double

    /// The risk multiplier that produced `adjustedYears`, so the card can name it.
    public let multiplier: Double

    /// The age whose population average has `adjustedYears` left — **the effective age**.
    ///
    /// `nil` only when the table cannot be inverted, which its monotone expectancy makes unreachable in
    /// practice. It is the figure the Healthspan card's dial draws, and it is a risk equivalent rather
    /// than a measurement of anything in the body.
    public let equivalentAgeYears: Double?

    public var deltaYears: Double { adjustedYears - baselineYears }

    public init(
        countryName: String,
        source: String,
        year: Int,
        age: Int,
        sexLabel: String,
        baselineYears: Double,
        adjustedYears: Double,
        multiplier: Double,
        equivalentAgeYears: Double? = nil
    ) {
        self.countryName = countryName
        self.source = source
        self.year = year
        self.age = age
        self.sexLabel = sexLabel
        self.baselineYears = baselineYears
        self.adjustedYears = adjustedYears
        self.multiplier = multiplier
        self.equivalentAgeYears = equivalentAgeYears
    }

    /// Builds the estimate, or `nil` when the table cannot describe this age.
    public static func make(
        table: LifeTable,
        multiplier: Double,
        age: Int,
        countryName: String,
        sexLabel: String
    ) -> LongevityEstimate? {
        guard let baseline = table.remainingYears(at: age) else { return nil }
        guard let adjusted = table.adjusted(by: multiplier).remainingYears(at: age) else { return nil }
        return LongevityEstimate(
            countryName: countryName,
            source: table.source,
            year: table.year,
            age: age,
            sexLabel: sexLabel,
            baselineYears: baseline,
            adjustedYears: adjusted,
            multiplier: multiplier,
            equivalentAgeYears: table.age(withRemainingYears: adjusted))
    }
}
