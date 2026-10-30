import Foundation
import Whoopsy

/// The bundled life table, and the arithmetic that turns it plus a risk multiplier into years.
///
/// **The assertion that matters most is that the app's own integration agrees with the published
/// `e_x`.** The table carries both columns precisely for that: a parser or an integration that dropped
/// a row would still produce a smooth, plausible curve, and a screenshot cannot tell. The rest pins
/// the direction of the adjustment and the shape of the bundle.
enum LifeTableTests {
    static func run() async throws {
        let url = packageRoot()
            .appendingPathComponent("Sources/Whoopsy/Data/Resources/LifeTables/lifeTables.json")
        guard let data = try? Data(contentsOf: url) else {
            assertTest(false, "The bundled life table is missing at \(url.path)")
            return
        }
        let store = LifeTableStore(jsonData: data)
        assertTest(
            store.countryCodes == ["USA"],
            "The bundle carries exactly the country the generator fetched — the US, from NCHS "
                + "(got \(store.countryCodes))")
        guard let table = store.table(for: "USA", sex: "total") else {
            assertTest(false, "The US total table did not decode")
            return
        }

        assertTest(
            table.source.contains("NCHS") && table.year == 2024,
            "A table names its publisher and its edition — a life expectancy without a citation is a "
                + "number with no owner (got \(table.source), \(table.year))")

        // ── The integration agrees with the publication ────────────────────────────────────────────
        for age in [0, 20, 40, 65, 85] {
            let published = table.ex[age]
            let computed = table.remainingYears(at: age) ?? -1
            assertTest(
                abs(computed - published) < 0.05,
                "Remaining years at \(age) recomputed from q_x agrees with the published e_x — "
                    + "\(String(format: "%.2f", published)) against \(String(format: "%.2f", computed))")
        }
        assertTest(
            abs((table.remainingYears(at: 0) ?? 0) - 78.97) < 0.05,
            "The US total population's life expectancy at birth in 2024 is 79.0 years")

        // ── The adjustment moves in the right direction, and 1.0 moves nothing ─────────────────────
        func years(_ multiplier: Double, at age: Int = 40) -> Double {
            table.adjusted(by: multiplier).remainingYears(at: age) ?? -1
        }
        assertTest(
            abs(years(1.0) - years(1.0)) < 1e-9 && abs(years(1.0) - (table.remainingYears(at: 40) ?? 0)) < 1e-9,
            "A multiplier of 1.0 is the table itself — the identity is what makes the adjusted figure "
                + "comparable with the baseline")
        assertTest(
            years(0.5) > years(1.0) && years(2.0) < years(1.0),
            "Halving the force of mortality lengthens life and doubling it shortens it — the "
                + "direction the discrete form `q' = 1 − (1 − q)^HR` has to give")
        assertTest(
            years(0.5) < years(1.0) * 2,
            "…but half the hazard is not twice the years: the adjustment acts on mortality, not on the "
                + "expectancy, and a card that claimed otherwise would be doing arithmetic in the "
                + "wrong space")

        // ── The inverse: an expectancy read back as an age ─────────────────────────────────────────
        for age in [10, 30, 45, 70] {
            let years = table.remainingYears(at: age) ?? -1
            let recovered = table.age(withRemainingYears: years) ?? -1
            assertTest(
                abs(recovered - Double(age)) < 0.05,
                "An expectancy read back through the inverse returns the age it came from — "
                    + "\(age) → \(String(format: "%.1f", years)) → \(String(format: "%.1f", recovered))")
        }
        assertTest(
            table.age(withRemainingYears: 200) == 0,
            "An expectancy longer than the table's own e_0 is age 0 rather than a negative age")
        assertTest(
            (table.age(withRemainingYears: 0) ?? 0) == Double(LifeTable.terminalAge),
            "…and one shorter than the terminal row answers the terminal age")

        // ── The estimate pairs the two figures ─────────────────────────────────────────────────────
        if let estimate = LongevityEstimate.make(
            table: table, multiplier: 0.8, age: 40, countryName: "United States", sexLabel: "total")
        {
            assertTest(
                estimate.baselineYears > 0 && estimate.adjustedYears > estimate.baselineYears,
                "A profile below the reference risk buys years, and the estimate carries both figures "
                    + "so the card can state the comparison rather than the total alone")
            assertTest(
                estimate.deltaYears > 0,
                "…and their difference is the number the card leads with")
            if let equivalent = estimate.equivalentAgeYears {
                assertTest(
                    equivalent < Double(estimate.age),
                    "…and a profile below the reference's risk has a risk-equivalent age younger than "
                        + "its own — \(String(format: "%.1f", equivalent)) against \(estimate.age)")
                assertTest(
                    abs((table.remainingYears(at: Int(equivalent.rounded())) ?? 0) - estimate.adjustedYears) < 1.5,
                    "…which is the age whose population expectancy matches the adjusted one, not an "
                        + "arbitrary shift")
            } else {
                assertTest(false, "The estimate did not carry an equivalent age")
            }
        } else {
            assertTest(false, "The estimate did not build at a real age")
        }

        assertTest(
            store.table(for: "GBR", sex: "total") == nil && !store.hasTable(for: "GBR"),
            "A country with no bundled table says so rather than falling back to another country's "
                + "mortality — that is the whole reason the table is keyed by country")
        assertTest(
            store.table(for: "USA", sex: "nonesuch") != nil,
            "An unknown sex falls back to the total row, which is what the reference's own tables do "
                + "for anyone whose sex is not recorded")
    }
}
