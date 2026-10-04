import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The VO₂ MAX estimate, derived on read

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeMetricSourceTests {
    static func run() async throws {
        // Re-declared per file rather than threaded: `Calendar.current` is a pure value,
        // so a fresh one here is the same value the section's other files hold.
        let calendar = Calendar.current

        // ---- HealthKit steps are gone ----
        //
        // The block that stood here drove `FixtureHealthStore` → `HealthKitBridge.stepCount(on:)` and
        // asserted a day with no samples was `nil` rather than `0`. Steps are the strap's now — see §16,
        // which owns the same absence pair against `stepCounts` and the repository that reads it — and
        // the whole HealthKit read-through went with the case: `HealthQuantityMetric` no longer has a
        // `stepCount`, `HealthStoreClient` no longer has a `dailyTotal`, and the consent prompt's
        // `readTypes` is one quantity shorter for it.

        // ---- The VO₂ MAX estimate: derived on read, and `nil` rather than 0 ----
        //
        // Replaced the HealthKit read-through this app used to render. The panel now prints an estimate
        // this app computes, so the guards below are the ones that keep a derivation from becoming a
        // fabrication: the arithmetic itself, the two zero-input cases that a reserved marker can reach
        // it through, and the fact that a day with no measured resting heart rate has no estimate.
        do {
            let day = calendar.startOfDay(for: Date())

            // A measured row and a placeholder differ only in `hrvValueMs`, because that is what
            // `RecoveryMetric.hasMeasurement` reads — it is a derived property, not an initialiser
            // parameter, so a row cannot be *labelled* unmeasured while carrying a measurement.
            func recoveryRow(_ dayOffset: Int, restingHeartRate: Int, measured: Bool = true)
                -> RecoveryMetric
            {
                RecoveryMetric(
                    date: calendar.date(byAdding: .day, value: dayOffset, to: day)!,
                    score: 70, hrvValueMs: measured ? 60 : 0, hrvMetric: .rmssd,
                    restingHeartRate: restingHeartRate)
            }

            // The arithmetic, pinned to the published constant. Written out as a literal and compared
            // with a tolerance rather than recomputed from `heartRateRatioCoefficient`, so a changed
            // constant fails here instead of agreeing with itself — and so a last-bit difference in the
            // double does not read as a broken model.
            let estimated = Vo2MaxMath.heartRateRatioEstimate(maxHeartRate: 190, restingHeartRate: 50)
            assertTest(
                abs((estimated ?? 0) - 58.14) < 0.0001,
                "The Heart Rate Ratio Method evaluates 15.3 × 190/50 at 58.14 mL/(kg·min) (got "
                    + "\(estimated.map { "\($0)" } ?? "nil"))")

            // The two reserved-marker cases. Both columns are non-optional in storage, so both reach
            // here as `0` rather than `nil` on a placeholder row or an importer's `?? 0` — and a `0`
            // anchor must be an absence, not a division or a confident `0.0`.
            assertTest(
                Vo2MaxMath.heartRateRatioEstimate(maxHeartRate: 190, restingHeartRate: 0) == nil,
                "A resting heart rate of 0 is the reserved marker, not a bpm, so the estimate is `nil` "
                    + "rather than a division by zero or an infinite reading")
            assertTest(
                Vo2MaxMath.heartRateRatioEstimate(maxHeartRate: 0, restingHeartRate: 50) == nil,
                "…and a maximal heart rate of 0 gives `nil` rather than the inverse error — the same "
                    + "`?? 0` importer path writes both columns")
            assertTest(
                Vo2MaxMath.heartRateRatioEstimate(maxHeartRate: nil, restingHeartRate: 50) == nil
                    && Vo2MaxMath.heartRateRatioEstimate(maxHeartRate: 190, restingHeartRate: nil) == nil,
                "…and a missing anchor on either side is the same absence — a week with no profile "
                    + "cannot print an estimate on any day")

            // The week the panel actually reads, through the real `MetricWeek` join. This is the
            // assertion that fails if anyone re-derives the resting-heart-rate gate for the estimate
            // instead of reading the slot's own already-gated value.
            let week = MetricWeek(
                endingOn: day,
                recovery: [
                    recoveryRow(0, restingHeartRate: 50),
                    // A measured day with no rate reported. It is a bpm-less `0`, and the estimate must
                    // fall away with it rather than be computed from the marker.
                    recoveryRow(-1, restingHeartRate: 0),
                    // An **unmeasured row that still carries a real-looking rate**. `hasMeasurement` is
                    // `hrvValueMs > 0`, so a row can hold `hrvValueMs: 0` beside a genuine `55` — and
                    // that is the case that discriminates: reading the raw row would produce a
                    // confident 52.85 on a day this app calls unmeasured, while the math's own `> 0`
                    // guard would not catch it. Only the slot's gated value does.
                    recoveryRow(-2, restingHeartRate: 55, measured: false),
                    // Two more measured days, to carry the baseline over `minimumBaselineDays`.
                    recoveryRow(-3, restingHeartRate: 52),
                    recoveryRow(-5, restingHeartRate: 55),
                ],
                maxHeartRate: 190)

            assertTest(
                abs((week.days.last?.vo2MaxMlKgMin ?? 0) - 58.14) < 0.0001,
                "A measured day's estimate is computed on read from its own stored resting heart rate "
                    + "(got \(week.days.last?.vo2MaxMlKgMin.map { "\($0)" } ?? "nil"))")
            assertTest(
                week.days.last?.vo2MaxMlKgMin != nil
                    && week.days.last?.restingHeartRate == 50,
                "…and it is computed from the very rate the RHR panel prints beside it, "
                    + "so the two panels cannot describe different days")
            assertTest(
                week.days[5].vo2MaxMlKgMin == nil && week.days[5].restingHeartRate == nil,
                "A day that is measured but reports no rate has no estimate — the `> 0` guard on the "
                    + "rate is what the estimate inherits, so a `0` bpm never becomes a denominator")
            assertTest(
                week.days[4].vo2MaxMlKgMin == nil && week.days[4].restingHeartRate == nil,
                "…and an unmeasured row holding a plausible `55` bpm yields no estimate and no rate, "
                    + "because the estimate reads the slot's gated value rather than the raw row — a "
                    + "row this app calls unmeasured must not produce a reading")
            assertTest(
                week.vo2MaxBaselineMlKgMin != nil,
                "Three estimable days in the week clear `minimumBaselineDays`, so the panel prints a "
                    + "mean beneath the day's estimate")

            // The anchor is the app's *one* definition of a maximal heart rate, so a week built without
            // one — no profile could be read — carries no estimate anywhere, rather than defaulting.
            let noAnchor = MetricWeek(
                endingOn: day, recovery: [recoveryRow(0, restingHeartRate: 50)])
            assertTest(
                noAnchor.days.last?.vo2MaxMlKgMin == nil
                    && noAnchor.days.last?.restingHeartRate == 50,
                "A week with no `maxHeartRate` prints no estimate on any day, while the resting heart "
                    + "rate it does have still renders — the assumption is missing, not the measurement")
        }
    }
}
