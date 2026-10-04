import Foundation
import Whoopsy

// MARK: - 10. Days with no data

/// A day with no data must be recorded as one, and must never be counted as an observation.
///
/// Three separate places can get this wrong, and each is asserted below: the strap path can invent a
/// value from the profile, the scoring window can average a placeholder in as if it were a real
/// 0 ms reading, and the importer can mistake a placeholder for a day already recorded and skip it.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum NoDataDayTests {
    static func run() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: Date())

        let db = LocalDatabaseManager(inMemory: true)
        let recoveryRepository = GRDBRecoveryRepository(db: db)
        let profileRepository = GRDBUserProfileRepository(db: db)
        // Kept separate from the `NoSleepSource()` the recovery use case takes below: that stub answers
        // "no night exists" without touching storage, which is what the sleep-pivot assertion needs,
        // while the sleep check needs the real repository to prove nothing was written.
        let sleepRepository = GRDBSleepRepository(db: db)
        // Empty, like every other store here — and unreachable for this section's night anyway, since the
        // use case returns at its sample-count guard before it ever reads a strain.
        let strainRepository = GRDBStrainRepository(db: db)

        let useCase = CalculateRecoveryUseCase(
            biometricRepository: EmptyBiometricStore(),
            recoveryRepository: recoveryRepository,
            sleepRepository: NoSleepSource(),
            userProfileRepository: profileRepository)

        do {
            // ── A day with nothing measured must not become a row ────────────────────────────────────
            //
            // It used to be stored as a placeholder of zeros, so that a reader could tell "measured zero"
            // from "nothing at all". Nothing needed telling — every reader already tested
            // `hasMeasurement` — while the row was what let a placeholder be averaged into a baseline and
            // what made an import count the day as already recorded.
            let result = try await useCase.execute(for: today)
            assertTest(result == nil, "A day with no biometrics returns nil rather than a row of zeros")

            let stored = try await recoveryRepository.getLocalRecovery(for: today)
            assertTest(stored == nil, "…and writes no row at all: the day is absent, not reserved")
            assertTest(
                try await recoveryRepository.getRecovery(for: today) == nil,
                "…on the day key the whole app reads on, not merely on the writer's own lookup")

            // The profile's cold-start HRV must not stand in for a measurement. There is now no row for it
            // to hide in, which is the strongest form of that guarantee — the check is kept because a
            // substitution would have to show up here to be invisible everywhere else.
            let profile = try await profileRepository.getUserProfile()
            assertTest(
                profile.baselineHrvRmssd > 0,
                "The profile holds a \(profile.baselineHrvRmssd) ms cold-start HRV, so this is not vacuous")
            assertTest(
                try await recoveryRepository.getRecoveryHistory(days: 30, endingOn: today).isEmpty,
                "…and no row anywhere in the window carries it, because the day has no row at all")

            // ── The counterpart: a day that WAS measured still stores, and reads back measured ────────
            //
            // Without this, "writes nothing" would be satisfied by a use case that never writes anything.
            // Ten days back, deliberately outside the four-day window the HealthKit import below walks —
            // a measured row inside it would be counted into `daysAlreadyRecorded` and break that check's
            // premise rather than this one's.
            let measuredDay = calendar.date(byAdding: .day, value: -10, to: today)!
            let nightWithRR = OvernightBiometricStore(samples: (0..<12).map { index in
                BiometricSample(
                    timestamp: measuredDay.addingTimeInterval(-3600 + Double(index) * 60),
                    heartRate: 52,
                    rrIntervalMs: index.isMultiple(of: 2) ? 800.0 : 850.0)
            })
            let measuredResult = try await CalculateRecoveryUseCase(
                biometricRepository: nightWithRR,
                recoveryRepository: recoveryRepository,
                sleepRepository: NoSleepSource(),
                userProfileRepository: profileRepository
            ).execute(for: measuredDay)
            assertTest(
                measuredResult != nil, "…while a night with real R-R intervals still produces a recovery")
            assertTest(
                measuredResult?.hasMeasurement == true,
                "…which reads back measured, so the flag still separates a reading from an absence")
            assertTest(
                try await recoveryRepository.getRecovery(for: measuredDay) != nil,
                "…and it is stored under its own day key")

            // ── A night that yields no scorable HRV must not become a row either ─────────────────────
            //
            // The hole this closes: the guard used to test `!rrIntervals.isEmpty`, which is not the test
            // this type's readers use. `HeartRateVariabilityMath.calculateRMSSD` returns exactly `0.0` when
            // `filterRRIntervals` leaves fewer than two beats, while `RecoveryMetric.hasMeasurement` is
            // `hrvValueMs > 0` — so a night holding a single captured interval produced a row with a
            // plausible resting heart rate and a 0 ms HRV that every reader called unmeasured, and
            // `RecoveryViewModel.shouldCompute` then re-scored and rewrote it on every load. The samples
            // below are otherwise ordinary: only the R-R channel is nearly empty, which is what a strap
            // worn loose actually records.
            let sparseDay = calendar.date(byAdding: .day, value: -12, to: today)!
            let oneInterval = OvernightBiometricStore(samples: (0..<12).map { index in
                BiometricSample(
                    timestamp: sparseDay.addingTimeInterval(-3600 + Double(index) * 60),
                    heartRate: 52,
                    rrIntervalMs: index == 0 ? 800.0 : nil)
            })
            let sparseResult = try await CalculateRecoveryUseCase(
                biometricRepository: oneInterval,
                recoveryRepository: recoveryRepository,
                sleepRepository: NoSleepSource(),
                userProfileRepository: profileRepository
            ).execute(for: sparseDay)
            assertTest(
                sparseResult == nil,
                "One R-R interval is not a measurement — RMSSD needs two, so the row would store a 0 ms "
                    + "HRV that its own readers call unmeasured")
            assertTest(
                try await recoveryRepository.getRecovery(for: sparseDay) == nil,
                "…and that night writes no row either, which is why the guard tests the measured value "
                    + "and not the interval count")

            // ── A placeholder must not enter a baseline ──────────────────────────────────────────────
            // Ten measured days at ~65 ms, with and without a no-data day alongside them. Averaging the
            // placeholder in as a 0 ms reading would drop the mean to ~59 ms and make today's ordinary
            // 65 ms look like a large positive delta.
            let measured: [RecoveryMetric] = (0..<10).map { offset in
                RecoveryMetric(
                    date: calendar.date(byAdding: .day, value: -(offset + 2), to: today)!,
                    score: 50, hrvValueMs: 65.0, hrvMetric: .rmssd, restingHeartRate: 54)
            }
            let placeholder = RecoveryMetric(
                date: calendar.date(byAdding: .day, value: -(1), to: today)!,
                score: 0, hrvValueMs: 0, hrvMetric: .rmssd, restingHeartRate: 0)

            func scored(_ history: [RecoveryMetric]) -> RecoveryScoring.Output {
                RecoveryScoring.score(
                    RecoveryScoring.Input(
                        history: history, todayHrvValueMs: 65.0, todayHrvMetric: .rmssd,
                        todayRestingHeartRate: 54, sleepPerformance: 0.9,
                        fallbackRestingHeartRateBaseline: 54.0))
            }
            let withoutPlaceholder = scored(measured)
            let withPlaceholder = scored(measured + [placeholder])
            assertTest(
                withPlaceholder.hrvBaselineMeanMs == withoutPlaceholder.hrvBaselineMeanMs,
                "A placeholder day does not move the HRV baseline (mean "
                    + "\(String(format: "%.2f", withPlaceholder.hrvBaselineMeanMs)) ms)")
            assertTest(
                withPlaceholder.rhrBaselineMean == withoutPlaceholder.rhrBaselineMean,
                "A placeholder day does not move the resting-heart-rate baseline")
            assertTest(
                withPlaceholder.score == withoutPlaceholder.score,
                "A placeholder day leaves today's score untouched (got \(withPlaceholder.score))")

            // ── And an import must still be able to fill one ─────────────────────────────────────────
            // A row like this is what an older build wrote for a day it had no data for, and those are
            // exactly the days HealthKit can supply. Counting the row as "already recorded" would leave
            // the day empty even though a real SDNN reading exists for it.
            let emptyDay = calendar.date(byAdding: .day, value: -3, to: today)!
            try await recoveryRepository.saveRecovery(
                RecoveryMetric(
                    date: emptyDay, score: 0, hrvValueMs: 0, hrvMetric: .rmssd, restingHeartRate: 0))

            let readingAt3am = calendar.date(byAdding: .hour, value: 3, to: emptyDay)!
            // Captured as a constant: a closure reading the mutable `calendar` would be a data race
            // under strict concurrency.
            let noon = calendar.date(byAdding: .hour, value: 12, to: today)!
            let importer = HealthKitImporter(
                store: FixtureHealthStore(
                    hrv: [
                        HealthQuantitySample(
                            value: 44.0, start: readingAt3am,
                            end: readingAt3am.addingTimeInterval(60))
                    ],
                    restingHeartRate: [
                        HealthQuantitySample(
                            value: 51.0, start: calendar.date(byAdding: .hour, value: 8, to: emptyDay)!,
                            end: calendar.date(byAdding: .hour, value: 8, to: emptyDay)!
                                .addingTimeInterval(60))
                    ]),
                recoveryRepository: recoveryRepository,
                sleepRepository: NoSleepSource(),
                userProfileRepository: profileRepository,
                calendar: calendar,
                clock: { noon })

            let summary = try await importer.importRecent(days: 4)
            assertTest(summary.daysImported == 1, "An import fills a day that held only a placeholder")
            assertTest(
                summary.daysAlreadyRecorded == 0,
                "A placeholder day is not reported as already recorded (got \(summary.daysAlreadyRecorded))")

            let filled = try await recoveryRepository.getLocalRecovery(for: emptyDay)
            assertTest(filled?.hasMeasurement == true, "The day now holds a measurement")
            assertTest(filled?.hrvValueMs == 44.0, "HealthKit's SDNN replaced the placeholder value")
            assertTest(filled?.hrvMetric == .sdnn, "The filled row is tagged SDNN, not left as RMSSD")

            // ── And a night that cannot be classified is not a night ─────────────────────────────────
            // `AnalyzeSleepUseCase` used to build an eight-hour session out of literals and save it
            // whenever the window held too few samples, so "the strap spent the night on the charger"
            // was recorded as a full night's sleep and then scored as one. It has to answer with nothing
            // *and* write nothing — a returned nil next to a stored row would be the worst of both.
            let sleepUseCase = AnalyzeSleepUseCase(
                biometricRepository: EmptyBiometricStore(),
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                userProfileRepository: profileRepository)
            let session = try await sleepUseCase.execute(for: today)
            assertTest(
                session == nil,
                "A night with no samples yields no session rather than a synthetic eight-hour one")
            let storedNight = try await sleepRepository.getSleepSession(for: today)
            assertTest(storedNight == nil, "The unclassifiable night was not written to the database")
        } catch {
            assertTest(false, "No-data-day handling threw: \(error)")
        }
    }
}
