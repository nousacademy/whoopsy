import Foundation
import Whoopsy

/// The Health Monitor page's five cards: the band each figure is read against, and the chip it earns.
///
/// The page has no renderer, so what is asserted is everything a screenshot cannot check — where the
/// band comes from, what the floor is, and that a chip cannot claim `within` over an out-of-range value.
enum HealthMonitorReadingsTests {
    static func run() async throws {
        let calendar = Calendar.current
        let night = calendar.startOfDay(for: Date())

        func day(_ offset: Int) -> RecoveryMetric {
            RecoveryMetric(
                date: calendar.date(byAdding: .day, value: offset, to: night)!,
                score: 70,
                hrvValueMs: 60,
                hrvMetric: .rmssd,
                restingHeartRate: 50)
        }

        func prior(_ hrv: [Double], rhr: [Int] = [], resp: [Double] = [], temp: [Double] = [])
            -> [RecoveryMetric]
        {
            let count = max(hrv.count, max(rhr.count, max(resp.count, temp.count)))
            return (0..<count).map { index in
                RecoveryMetric(
                    date: calendar.date(byAdding: .day, value: index - count, to: night)!,
                    score: 70,
                    hrvValueMs: hrv.indices.contains(index) ? hrv[index] : 0,
                    hrvMetric: .rmssd,
                    restingHeartRate: rhr.indices.contains(index) ? rhr[index] : 0,
                    skinTemperatureCelsius: temp.indices.contains(index) ? temp[index] : nil,
                    spO2Percentage: nil,
                    respiratoryRate: resp.indices.contains(index) ? resp[index] : nil)
            }
        }

        /// One night with every field the page can draw.
        func tonight(
            hrv: Double = 60,
            rhr: Int = 50,
            resp: Double? = 16,
            spo2: Double? = 97,
            temp: Double? = 34.0
        ) -> RecoveryMetric {
            RecoveryMetric(
                date: night,
                score: 70,
                hrvValueMs: hrv,
                hrvMetric: .rmssd,
                restingHeartRate: rhr,
                skinTemperatureCelsius: temp,
                spO2Percentage: spo2,
                respiratoryRate: resp)
        }

        // ── The floor, and what "no band" says ───────────────────────────────────────────────────────
        let thin = HealthMonitorReadings(
            recovery: tonight(), prior: prior([50, 60]), calendar: calendar)
        assertTest(
            thin.readings.contains { $0.vital == .heartRateVariability && $0.chipText == "no typical range yet" },
            "Two prior nights are below `minimumBaselineDays`, so the HRV card says there is no band "
                + "rather than drawing one off two points")
        assertTest(
            thin.readings.filter { $0.vital != .bloodOxygen }.allSatisfy { !$0.isWithin },
            "…and an unbanded reading is not 'within' — the tick follows the band, never the absence of one")

        // ── A band, and the three chips it can earn ─────────────────────────────────────────────────
        let history = prior([50, 55, 60, 65, 70], rhr: [48, 49, 50, 51, 52], resp: [15, 15, 15, 15, 15])
        let centred = HealthMonitorReadings(
            recovery: tonight(hrv: 60, rhr: 50), prior: history, calendar: calendar)
        if let hrv = centred.readings.first(where: { $0.vital == .heartRateVariability }) {
            // The spread is the sample standard deviation (n − 1) of 50…70, which is 7.9 — so the
            // band is 52.1…67.9 and prints as whole milliseconds at both ends.
            assertTest(
                hrv.isWithin && hrv.chipText == "within 52 – 68",
                "A HRV of 60 against a mean of 60 ± 7.9 prints `within 52 – 68` "
                    + "(got \(hrv.chipText))")
        } else {
            assertTest(false, "The HRV card was not produced")
        }

        let elevated = HealthMonitorReadings(
            recovery: tonight(hrv: 90, rhr: 50, resp: 18), prior: history, calendar: calendar)
        if let hrv = elevated.readings.first(where: { $0.vital == .heartRateVariability }) {
            assertTest(
                !hrv.isWithin && hrv.chipText == "above 52 – 68",
                "…and 90 is `above` the same band rather than silently 'within'")
        } else {
            assertTest(false, "The HRV card was not produced")
        }
        if let resp = elevated.readings.first(where: { $0.vital == .respiratoryRate }) {
            assertTest(
                !resp.isWithin && resp.valueText == "18.0",
                "Respiratory rate prints to a tenth, because a week of breaths spans two units")
        } else {
            assertTest(false, "The respiratory-rate card was not produced")
        }

        // ── Blood oxygen is the clinical band, not a personal one ───────────────────────────────────
        let oxygen = HealthMonitorReadings(recovery: tonight(spo2: 97), prior: history, calendar: calendar)
        if let spo2 = oxygen.readings.first(where: { $0.vital == .bloodOxygen }) {
            assertTest(
                spo2.isWithin && spo2.chipText == "near 95% – 100%",
                "Blood oxygen is read against the clinical range, which is the one figure the "
                    + "reference quotes as fixed (got \(spo2.chipText))")
        } else {
            assertTest(false, "The blood-oxygen card was not produced")
        }
        let lowOxygen = HealthMonitorReadings(
            recovery: tonight(spo2: 92), prior: history, calendar: calendar)
        if let spo2 = lowOxygen.readings.first(where: { $0.vital == .bloodOxygen }) {
            assertTest(
                !spo2.isWithin && spo2.chipText == "below 95%",
                "…and a night at 92 % is below it")
        } else {
            assertTest(false, "The blood-oxygen card was not produced")
        }

        // ── Skin temperature is a delta from the personal mean ─────────────────────────────────────
        let temperatures = HealthMonitorReadings(
            recovery: tonight(temp: 34.0),
            prior: prior([], temp: [34.5, 34.5, 34.5, 34.5, 34.5]),
            calendar: calendar)
        if let skin = temperatures.readings.first(where: { $0.vital == .skinTemperature }) {
            assertTest(
                skin.valueText == "-0.5",
                "The card prints the night's **delta** from the mean, not the absolute temperature — "
                    + "the reference's `SKIN TEMP (FROM BASELINE)` (got \(skin.valueText))")
            assertTest(
                !skin.isWithin,
                "…and a half-degree fall against a flat history is outside the band, which that "
                    + "history's spread floor makes a real band rather than zero")
        } else {
            assertTest(false, "The skin-temperature card was not produced")
        }

        // ── Absences ────────────────────────────────────────────────────────────────────────────────
        let bare = HealthMonitorReadings(
            recovery: tonight(resp: nil, spo2: nil, temp: nil),
            prior: history, calendar: calendar)
        assertTest(
            bare.readings.map(\.vital) == [.heartRateVariability, .restingHeartRate],
            "A night with only HRV and resting rate produces only two cards — no card is drawn over a "
                + "value the row does not hold")

        let none = HealthMonitorReadings(recovery: nil, prior: history, calendar: calendar)
        assertTest(
            none.readings.isEmpty && none.baselineNights == 0,
            "A night with no row produces nothing at all, which the page draws as its empty sentence")

        // ── The night is never inside its own band ──────────────────────────────────────────────────
        let selfIncluding = prior([60], rhr: [50])
            + [RecoveryMetric(
                date: night, score: 70, hrvValueMs: 60, hrvMetric: .rmssd, restingHeartRate: 50)]
        assertTest(
            HealthMonitorReadings(
                recovery: tonight(), prior: selfIncluding, calendar: calendar
            ).readings.first { $0.vital == .heartRateVariability }?.chipText == "no typical range yet",
            "A prior list that happens to include the night contributes nothing: the band is a "
                + "statement about history and is filtered to days strictly before")
    }
}
