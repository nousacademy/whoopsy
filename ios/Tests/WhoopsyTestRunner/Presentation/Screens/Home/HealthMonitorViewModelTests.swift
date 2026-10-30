import Foundation
import Whoopsy

/// The day the healthspan inputs are read from.
///
/// **The rule this pins is the one that made the dial empty on a real phone.** The tab asks the view
/// model to load *today*, and a day with no measurement has no `recoveries` row — that is this app's
/// whole absence rule, not an edge case — so an estimate taken only from the day on screen dashes for
/// anyone who has not slept with the strap since the last import. The fallback makes the estimate
/// describe the person rather than the calendar, and these assertions hold it to the most recent
/// measured day rather than any measured day.
enum HealthMonitorViewModelTests {
    static func run() async throws {
        let calendar = Calendar.current
        func day(_ daysAgo: Int) -> Date {
            calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        }

        func row(_ daysAgo: Int, hrv: Double) -> RecoveryMetric {
            RecoveryMetric(
                date: day(daysAgo),
                score: 60,
                hrvValueMs: hrv,
                hrvMetric: .rmssd,
                restingHeartRate: 52)
        }

        // ── The pick is the last measured row, in the order the repository promises ─────────────────
        let ordered = [row(30, hrv: 40), row(20, hrv: 0), row(10, hrv: 45)]
        assertTest(
            HealthMonitorViewModel.mostRecentMeasured(in: ordered)?.date == day(10),
            "The most recent measured row wins — the last qualifying entry of a read the repository "
                + "promises oldest-first")

        assertTest(
            HealthMonitorViewModel.mostRecentMeasured(in: [row(5, hrv: 0), row(3, hrv: 0)]) == nil,
            "A window holding only absence rows yields no measurement — `hasMeasurement` is the gate, "
                + "and a placeholder row must never stand in for a night")

        assertTest(
            HealthMonitorViewModel.mostRecentMeasured(in: []) == nil,
            "An empty history yields no measurement rather than crashing or inventing one")

        // **The one that would otherwise pass while being wrong.** If the read came back newest-first,
        // taking `.last` would pick the *oldest* night in the window — a plausible-looking profile from
        // the wrong end of the year. The order is asserted rather than assumed.
        let reversed = Array(ordered.reversed())
        assertTest(
            HealthMonitorViewModel.mostRecentMeasured(in: reversed)?.date == day(30),
            "The pick follows the array's own order, so the repository's ascending contract is what "
                + "makes it the newest — stated here because a reversed read would still look plausible")

        // ── Absence is named, and the three reasons are different ──────────────────────────────────
        assertTest(
            HealthMonitorViewModel.LongevityAbsence.noBirthDate
                != HealthMonitorViewModel.LongevityAbsence.noLifeTable,
            "No date of birth and no life table are different absences — one is a field the reader can "
                + "fill in and the other is a table this app has not bundled")

        // ── A measured day turns into an age ───────────────────────────────────────────────────────
        let url = packageRoot()
            .appendingPathComponent("Sources/Whoopsy/Data/Resources/LifeTables/lifeTables.json")
        guard let data = try? Data(contentsOf: url) else {
            assertTest(false, "The bundled life table is missing at \(url.path)")
            return
        }
        let store = LifeTableStore(jsonData: data)

        // A profile whose measured fitness and resting rate put it below the reference carries a
        // multiplier under 1, and the age it reads back as must therefore be below the age it started
        // from. This is the dial's arithmetic end to end, minus the database.
        let strong = MortalityRiskProfile.make(
            vo2MaxMlKgMin: 57, steps: 9_000, restingHeartRate: 48)
        let profile = UserProfile(
            birthDate: calendar.date(byAdding: .year, value: -40, to: Date()),
            maxHeartRate: 190,
            restingHeartRate: 55)
        assertTest(profile.age == 40, "The profile's age comes from its birth date (got \(String(describing: profile.age)))")

        let estimate = HealthMonitorViewModel.longevity(
            riskProfile: strong,
            profile: profile,
            regionCode: "US",
            store: store)
        if let estimate {
            assertTest(
                estimate.multiplier < 1.0,
                "A measured profile this fit carries less than the reference profile's risk "
                    + "(got \(estimate.multiplier))")
            if let equivalent = estimate.equivalentAgeYears {
                assertTest(
                    equivalent < Double(estimate.age),
                    "A risk below the reference reads back as a younger age — the direction the dial "
                        + "and its 'years younger' line both state "
                        + "(got \(String(format: "%.1f", equivalent)) against \(estimate.age))")
            } else {
                assertTest(false, "The inverted age should exist for a monotone life table")
            }
        } else {
            assertTest(false, "A complete profile and a bundled table should produce an estimate")
        }

        // ── The three absences, each from one missing input ────────────────────────────────────────
        assertTest(
            HealthMonitorViewModel.longevity(
                riskProfile: nil, profile: profile, regionCode: "US", store: store) == nil,
            "No risk profile yields no estimate — the multiplier is the only measured half")
        assertTest(
            HealthMonitorViewModel.longevity(
                riskProfile: strong,
                profile: UserProfile(maxHeartRate: 190, restingHeartRate: 55),
                regionCode: "US",
                store: store) == nil,
            "No birth date yields no estimate — there would be no age to compare the risk with")
        assertTest(
            HealthMonitorViewModel.longevity(
                riskProfile: strong, profile: profile, regionCode: "GB", store: store) == nil,
            "A region with no bundled table yields no estimate rather than borrowing another country's "
                + "mortality")

        // ── The sex row ────────────────────────────────────────────────────────────────────────────
        assertTest(
            HealthMonitorViewModel.sexKey(for: .man) == "male"
                && HealthMonitorViewModel.sexKey(for: .woman) == "female",
            "A man and a woman take the table's own sex-specific rows")
        assertTest(
            HealthMonitorViewModel.sexKey(for: .nonBinary) == "total"
                && HealthMonitorViewModel.sexKey(for: .preferNotToSay) == "total",
            "The two other options take the population row — inferring an anatomical category from a "
                + "gender answer is the substitution this app does not make")
    }
}
