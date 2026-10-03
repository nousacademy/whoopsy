import Foundation

/// Maps a window of HealthKit readings onto local recovery rows.
///
/// Pure mapping plus orchestration. It never touches `HKHealthStore` — only `HealthStoreClient` and
/// the domain repositories — so the whole path runs against a fixture store and an in-memory
/// database with no device, no entitlement, and no authorization prompt.
///
/// **What it writes, and what it refuses to.** One `recoveries` row per day: Apple's overnight SDNN
/// and Apple's daily resting heart rate, nothing else. The remaining columns stay nil rather than
/// being filled with a plausible constant, because a fabricated value is indistinguishable
/// downstream from a measured one — a row carrying an invented `14.2` respiratory rate feeds the
/// same baseline as a row carrying a real one.
///
/// **Days with no SDNN reading produce no row at all.** A `hrv_value_ms` of 0 would enter the SDNN
/// baseline as a catastrophic day and pull every subsequent score up; absence has to stay absent.
public struct HealthKitImporter: Sendable {

    private let store: any HealthStoreClient
    private let recoveryRepository: any RecoveryRepository
    private let sleepRepository: any SleepRepository
    private let userProfileRepository: any UserProfileRepository
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    public init(
        store: any HealthStoreClient,
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        userProfileRepository: any UserProfileRepository,
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.userProfileRepository = userProfileRepository
        self.calendar = calendar
        self.clock = clock
    }

    /// Imports the last `days` calendar days, today included.
    public func importRecent(days: Int) async throws -> HealthImportSummary {
        let requested = max(1, days)
        guard store.isAvailable else {
            throw HealthStoreUnavailableError(
                reason: store.unavailableReason ?? "Health data is not available on this device.")
        }

        let now = clock()
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(requested - 1), to: today) else {
            return .empty(daysRequested: requested, metric: .sdnn)
        }

        // Two queries for the whole window instead of two per day: the HealthKit round trip is the
        // expensive part, and bucketing in memory is what makes the day boundary ours to define.
        // The HRV query reaches back half a day so the night *before* the first requested day can
        // still be attributed to it.
        let hrvSamples = try await store.quantitySamples(
            .heartRateVariabilitySDNN,
            from: calendar.date(byAdding: .hour, value: -12, to: firstDay) ?? firstDay,
            to: now)
        let restingHeartRateSamples = try await store.quantitySamples(
            .restingHeartRate, from: firstDay, to: now)

        let hrvByDay = Self.bucketByWakeDay(hrvSamples, calendar: calendar, within: firstDay...today)
        let restingHeartRateByDay = Self.bucketByCalendarDay(
            restingHeartRateSamples, calendar: calendar)

        let profile = try await userProfileRepository.getUserProfile()
        // Read once, then extended in memory as rows are written, so backfilling 30 days scores each
        // day against the days before it rather than against an empty baseline. Re-running the
        // import refines earlier scores as the baseline fills in; the set of days is stable.
        var history = try await recoveryRepository.getRecoveryHistory(days: 30)

        var imported = 0
        var withoutData = 0
        var alreadyRecorded = 0
        var carriedRestingHeartRate: Int?

        for offset in 0..<requested {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }

            guard let hrvValues = hrvByDay[day], !hrvValues.isEmpty else {
                withoutData += 1
                continue
            }

            // The strap is the primary source for any day it *measured*; this import only fills days
            // that have no measurement. Overwriting would replace a real RMSSD reading with an SDNN
            // one, changing both the day's value and which baseline it counts toward. A placeholder
            // row is not a measurement — the strap writes zeros for a day it had no data for, and
            // those days are exactly the ones an import should fill.
            let existing = try await recoveryRepository.getLocalRecovery(for: day)
            guard existing?.hasMeasurement != true else {
                alreadyRecorded += 1
                continue
            }

            let measuredRestingHeartRate = restingHeartRateByDay[day].map(Self.meanRounded)
            // Apple does not publish a daily resting heart rate for every day, and the column is
            // NOT NULL. Carry the most recent real measurement forward rather than inventing one;
            // only a window with no measurement at all falls back to the profile.
            let restingHeartRate = measuredRestingHeartRate
                ?? carriedRestingHeartRate
                ?? profile.restingHeartRate
            if let measuredRestingHeartRate { carriedRestingHeartRate = measuredRestingHeartRate }

            let hrvValueMs = BaselineStatisticsMath.mean(hrvValues).rounded(toPlaces: 1)

            let scoring = RecoveryScoring.score(
                RecoveryScoring.Input(
                    history: history,
                    todayHrvValueMs: hrvValueMs,
                    todayHrvMetric: .sdnn,
                    todayRestingHeartRate: restingHeartRate,
                    sleepPerformance: await sleepPerformance(for: day),
                    fallbackRestingHeartRateBaseline: profile.baselineRhr))

            let recovery = RecoveryMetric(
                date: day,
                score: scoring.score,
                hrvValueMs: hrvValueMs,
                hrvMetric: .sdnn,
                restingHeartRate: restingHeartRate,
                hrvBaselineDeltaMs: scoring.hrvBaselineDeltaMs,
                rhrBaselineDeltaBpm: scoring.rhrBaselineDeltaBpm)

            try await recoveryRepository.saveRecovery(recovery)
            history.append(recovery)
            imported += 1
        }

        return HealthImportSummary(
            daysRequested: requested,
            daysImported: imported,
            daysWithoutData: withoutData,
            daysAlreadyRecorded: alreadyRecorded,
            metric: .sdnn)
    }

    // MARK: - Bucketing

    /// Attributes each reading to the day whose sleep it belongs to.
    ///
    /// A reading taken after noon belongs to the **following** day: an SDNN sample at 03:00 on the
    /// 5th and one at 23:00 on the 4th are the same night, and Apple's overnight HRV readings
    /// cluster in exactly that pre-dawn band. Noon is the cut because no plausible sleep window
    /// straddles it, which makes it the one boundary that cannot split a night in half.
    private static func bucketByWakeDay(
        _ samples: [HealthQuantitySample], calendar: Calendar, within range: ClosedRange<Date>
    ) -> [Date: [Double]] {
        var byDay: [Date: [Double]] = [:]
        for sample in samples {
            var day = calendar.startOfDay(for: sample.start)
            if calendar.component(.hour, from: sample.start) >= 12,
                let next = calendar.date(byAdding: .day, value: 1, to: day)
            {
                day = next
            }
            // A reading taken this evening belongs to tomorrow's sleep, which is outside the window.
            guard range.contains(day) else { continue }
            byDay[day, default: []].append(sample.value)
        }
        return byDay
    }

    /// Attributes each reading to the calendar day it was recorded on. Unlike HRV, Apple's resting
    /// heart rate is a daytime figure for the day it is published against, so it does not shift.
    private static func bucketByCalendarDay(
        _ samples: [HealthQuantitySample], calendar: Calendar
    ) -> [Date: [Double]] {
        var byDay: [Date: [Double]] = [:]
        for sample in samples {
            byDay[calendar.startOfDay(for: sample.start), default: []].append(sample.value)
        }
        return byDay
    }

    private static func meanRounded(_ values: [Double]) -> Int {
        Int(BaselineStatisticsMath.mean(values).rounded())
    }

    /// The value this contributes when a day has no sleep session, taken from
    /// `BaselineStatisticsMath` rather than redeclared here: the importer and
    /// `CalculateRecoveryUseCase` score the same day against the same formula, so they must not hold
    /// two opinions about what a missing input contributes.
    private func sleepPerformance(for day: Date) async -> Double {
        guard let session = try? await sleepRepository.getSleepSession(for: day) else {
            return BaselineStatisticsMath.sleepPerformancePivot
        }
        return Double(session.sleepPerformancePercentage) / 100.0
    }
}
