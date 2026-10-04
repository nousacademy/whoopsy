import Foundation
import Whoopsy

// MARK: - 9. HealthKit Import (hermetic: fixture store + in-memory database)

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum HealthKitImportTests {
    static func run() async throws {
        // Fixed UTC calendar and clock: day attribution must not depend on the machine's time zone or
        // on the hour the suite happens to run.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = 30
        let today = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 12, to: today)!

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset - (days - 1), to: today)!
        }
        func sample(_ value: Double, on date: Date, atHour hour: Int) -> HealthQuantitySample {
            let start = calendar.date(byAdding: .hour, value: hour, to: date)!
            return HealthQuantitySample(value: value, start: start, end: start.addingTimeInterval(60))
        }

        var hrv: [HealthQuantitySample] = []
        var resting: [HealthQuantitySample] = []
        for offset in 0..<days {
            // Offset 15 has a resting heart rate but no overnight HRV. That is a real shape — the watch
            // publishes resting HR far more reliably than SDNN — and it is what the skip rule is for.
            if offset != 15 { hrv.append(sample(40.0 + Double(offset), on: day(offset), atHour: 3)) }
            resting.append(sample(52.0 + Double(offset % 5), on: day(offset), atHour: 8))
        }
        // Two readings on the first night, so a mean is distinguished from a first or last value.
        hrv.append(sample(60.0, on: day(0), atHour: 4))
        // 23:00 on the first night is the following night's sleep by the importer's noon cut, so this
        // belongs to day 1. It is also the assertion that fails if the cut is missing.
        hrv.append(sample(43.0, on: day(0), atHour: 23))

        let db = LocalDatabaseManager(inMemory: true)
        let recoveryRepository = GRDBRecoveryRepository(db: db)
        let importer = HealthKitImporter(
            store: FixtureHealthStore(hrv: hrv, restingHeartRate: resting),
            recoveryRepository: recoveryRepository,
            sleepRepository: NoSleepSource(),
            userProfileRepository: GRDBUserProfileRepository(db: db),
            calendar: calendar,
            clock: { now })

        do {
            let summary = try await importer.importRecent(days: days)
            assertTest(summary.daysImported == days - 1, "Imported \(summary.daysImported) of \(days) days (one has no HRV)")
            assertTest(summary.daysWithoutData == 1, "The HRV-less day is counted as having no reading")
            assertTest(summary.daysAlreadyRecorded == 0, "An empty database reports nothing already recorded")
            assertTest(summary.metric == .sdnn, "The import reports SDNN as the metric it wrote")

            let history = try await recoveryRepository.getRecoveryHistory(days: 60)
            assertTest(history.count == days - 1, "\(history.count) rows stored, one per day with a reading")
            assertTest(history.allSatisfy { $0.hrvMetric == .sdnn }, "Every imported row is tagged SDNN, never RMSSD")
            assertTest(history.allSatisfy { $0.score >= 1 && $0.score <= 99 }, "Imported scores stay inside the clamp")
            assertTest(
                history.allSatisfy { $0.restingHeartRate > 30 && $0.restingHeartRate < 100 },
                "Resting heart rate carries a real reading, never a placeholder zero")

            // A day with no SDNN reading must store no row. A row with hrvValueMs 0 would enter the SDNN
            // baseline as a catastrophic day and lift every later score.
            let missing = try await recoveryRepository.getLocalRecovery(for: day(15))
            assertTest(missing == nil, "A day with no overnight HRV produced no row at all")

            let firstDay = try await recoveryRepository.getRecovery(for: day(0))
            assertTest(firstDay?.hrvValueMs == 50.0, "Two readings on one night average to 50.0 ms (got \(firstDay?.hrvValueMs ?? -1))")
            let secondDay = try await recoveryRepository.getRecovery(for: day(1))
            assertTest(secondDay?.hrvValueMs == 42.0, "A 23:00 reading belongs to the next day's sleep (got \(secondDay?.hrvValueMs ?? -1))")

            // Idempotency — the highest-value assertion here. `save` is INSERT-or-UPDATE *by primary
            // key*, so a row written at a raw timestamp rather than `startOfDay` is invisible to every
            // keyed read and a second import appends a duplicate. Only the count catches that.
            let second = try await importer.importRecent(days: days)
            assertTest(second.daysImported == 0, "A second import writes nothing")
            assertTest(second.daysAlreadyRecorded == days - 1, "A second import recognises every day it already stored")
            let after = try await recoveryRepository.getRecoveryHistory(days: 60)
            assertTest(after.count == days - 1, "Re-running the import does not duplicate rows (got \(after.count), expected \(days - 1))")
        } catch {
            assertTest(false, "HealthKit import threw: \(error)")
        }

        // Availability is a runtime question, not a compile-time one. HealthKit is present in the macOS
        // SDK, so `#if canImport(HealthKit)` is true here while no health store exists — the check that
        // was replaced. Both of these fail if anyone reintroduces it.
        assertTest(HealthKitStoreClient().isAvailable == false, "The real client reports unavailable on the macOS host")
        assertTest(PreviewHealthStoreClient().isAvailable == false, "The preview client reports unavailable")

        let unavailable = HealthKitImporter(
            store: PreviewHealthStoreClient(),
            recoveryRepository: recoveryRepository,
            sleepRepository: NoSleepSource(),
            userProfileRepository: GRDBUserProfileRepository(db: db),
            calendar: calendar,
            clock: { now })
        do {
            _ = try await unavailable.importRecent(days: 7)
            assertTest(false, "An unavailable store must throw rather than report an empty import")
        } catch {
            assertTest(true, "An unavailable store throws instead of returning a misleading empty summary")
        }
    }
}
