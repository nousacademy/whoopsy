import Foundation
import Whoopsy

/// The Home row's count: which of WHOOP's five vitals this app holds a reading for.
///
/// **The assertion that matters is the one about what it does *not* say.** The row is a count of
/// readings, not a verdict about them — there is no per-metric band for blood oxygen or respiratory
/// rate in this app — so a day with all five present is `ALL MEASURED`, never `WITHIN RANGE`.
enum HealthMonitorSummaryTests {
    static func run() async throws {
        let day = Calendar.current.startOfDay(for: Date())

        func recovery(
            hrv: Double = 60,
            rhr: Int = 52,
            respiratory: Double? = 15.2,
            spo2: Double? = 97,
            skinTemp: Double? = 34.1
        ) -> RecoveryMetric {
            RecoveryMetric(
                date: day,
                score: 70,
                hrvValueMs: hrv,
                hrvMetric: .rmssd,
                restingHeartRate: rhr,
                skinTemperatureCelsius: skinTemp,
                spO2Percentage: spo2,
                respiratoryRate: respiratory)
        }

        assertTest(
            HealthMonitorSummary.total == 5,
            "The denominator is the enum's own count — WHOOP's five vitals — not a literal at the call "
                + "site (got \(HealthMonitorSummary.total))")

        let complete = HealthMonitorSummary(recovery: recovery())
        assertTest(
            complete.measuredCount == 5 && complete.isComplete && complete.missing.isEmpty,
            "A day carrying all five readings is complete")

        let partial = HealthMonitorSummary(
            recovery: recovery(respiratory: nil, spo2: nil, skinTemp: nil))
        assertTest(
            partial.measuredCount == 2 && !partial.isComplete,
            "…and a strap-classified day, which carries only HRV and resting heart rate, counts two")
        assertTest(
            partial.missing.map(\.displayName) == ["Respiratory rate", "Blood oxygen", "Skin temperature"],
            "…and names the three it is missing, in the monitor's own order, which is what the row says "
                + "to a listener who cannot see the count")

        assertTest(
            HealthMonitorSummary(recovery: recovery(hrv: 0)).measuredCount == 4,
            "An HRV of `0` is not a reading — `RecoveryMetric.hasMeasurement`'s rule, and the same "
                + "one a heart rate of `0` takes")
        assertTest(
            HealthMonitorSummary(recovery: recovery(rhr: 0)).measuredCount == 4,
            "…and neither is a resting heart rate of `0`")

        let empty = HealthMonitorSummary(recovery: nil)
        assertTest(
            empty.measuredCount == 0 && empty.missing.count == 5,
            "A day with no `recoveries` row is `0` of 5 rather than a crash or a missing card — the "
                + "card draws on every day")
    }
}
