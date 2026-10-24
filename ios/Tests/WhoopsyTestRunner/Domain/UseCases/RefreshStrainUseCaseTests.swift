import Foundation
import Whoopsy

/// The watermark, the backfill range and what the refresh refuses to touch.
enum RefreshStrainUseCaseTests {
    static func run() async throws {
        // ---- The tick scores today and leaves an unchanged day alone ----
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let biometrics = GRDBBiometricRepository(db: db)
            let strains = GRDBStrainRepository(db: db)
            let motion = GRDBMotionEpochRepository(db: db)
            let refresh = RefreshStrainUseCase(
                calculate: CalculateStrainUseCase(
                    biometricRepository: biometrics,
                    strainRepository: strains,
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    motionEpochRepository: motion),
                strainRepository: strains,
                biometricRepository: biometrics,
                motionEpochRepository: motion)

            let today = Date().startOfDay
            let samples = StrainTests.samples(
                from: today.addingTimeInterval(3600), count: 60, heartRate: 120)
            try await biometrics.saveSamples(samples)

            await refresh.tick()
            let todayRow = try await strains.getLocalStrain(for: today)
            assertTest(
                todayRow?.algorithm == .hrMotionV2 && todayRow?.hasMeasurement == true,
                "A tick scores today and stamps the algorithm")
            assertTest(
                todayRow?.scoredThrough == samples.last?.timestamp,
                "…with the watermark at the newest input it read")

            // A sentinel: overwrite the row directly, with the watermark the refresh would have
            // written. If a second tick recomputes, this 19.9 disappears.
            let inputEdge = samples.last?.timestamp ?? today
            try await db.saveStrain(StrainRecord(
                date: today, strainScore: 19.9, kilojoules: 0,
                averageHeartRate: 0, maxHeartRate: 0, hasMeasurement: true,
                source: StrainScore.deviceSource, motionLoad: 0, scoredThrough: inputEdge,
                algorithm: StrainAlgorithm.hrMotionV2.rawValue))

            await refresh.tick()
            assertTest(
                try await strains.getLocalStrain(for: today)?.score == 19.9,
                "A day whose input has not advanced is not rewritten")

            // New input is what reopens the day — not a timer.
            try await biometrics.saveSamples(StrainTests.samples(
                from: today.addingTimeInterval(4000), count: 60, heartRate: 170))
            await refresh.tick()
            assertTest(
                try await strains.getLocalStrain(for: today)?.score != 19.9,
                "…and a later sample does recompute it")
        }

        // ---- WHOOP's own figure is never replaced ----
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let biometrics = GRDBBiometricRepository(db: db)
            let strains = GRDBStrainRepository(db: db)
            let motion = GRDBMotionEpochRepository(db: db)
            let refresh = RefreshStrainUseCase(
                calculate: CalculateStrainUseCase(
                    biometricRepository: biometrics,
                    strainRepository: strains,
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    motionEpochRepository: motion),
                strainRepository: strains,
                biometricRepository: biometrics,
                motionEpochRepository: motion)

            let day = StrainTests.day
            try await biometrics.saveSamples(StrainTests.samples(
                from: day.addingTimeInterval(9 * 3600), count: 600, heartRate: 150))
            try await strains.saveStrain(
                StrainScore(
                    date: day, score: 17.7, hasMeasurement: true,
                    source: StrainScore.importSource, algorithm: .whoopExport),
                source: StrainScore.importSource)

            await refresh.refresh(from: day, to: day)
            let after = try await strains.getLocalStrain(for: day)
            assertTest(
                after?.score == 17.7 && after?.source == StrainScore.importSource,
                "A WHOOP-imported day is never recomputed, however many samples the phone holds")
            assertTest(
                after?.isDeviceScored == false,
                "…because its provenance is what says the row is not this app's to rewrite")
        }

        // ---- A day before the newest import is not filled in ----
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let biometrics = GRDBBiometricRepository(db: db)
            let strains = GRDBStrainRepository(db: db)
            let motion = GRDBMotionEpochRepository(db: db)
            let refresh = RefreshStrainUseCase(
                calculate: CalculateStrainUseCase(
                    biometricRepository: biometrics,
                    strainRepository: strains,
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    motionEpochRepository: motion),
                strainRepository: strains,
                biometricRepository: biometrics,
                motionEpochRepository: motion)

            let importedDay = StrainTests.day
            let earlierDay = Calendar.current.date(byAdding: .day, value: -1, to: importedDay) ?? importedDay
            try await biometrics.saveSamples(StrainTests.samples(
                from: earlierDay.addingTimeInterval(9 * 3600), count: 600, heartRate: 150))
            try await strains.saveStrain(
                StrainScore(
                    date: importedDay, score: 11.2, hasMeasurement: true,
                    source: StrainScore.importSource, algorithm: .whoopExport),
                source: StrainScore.importSource)

            await refresh.refresh(from: earlierDay, to: importedDay)
            assertTest(
                try await strains.getLocalStrain(for: earlierDay) == nil,
                "The backfill stops at the newest imported day rather than filling the gap before it")
        }

        // ---- A drain that named no days is no evidence ----
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let biometrics = GRDBBiometricRepository(db: db)
            let strains = GRDBStrainRepository(db: db)
            let motion = GRDBMotionEpochRepository(db: db)
            let refresh = RefreshStrainUseCase(
                calculate: CalculateStrainUseCase(
                    biometricRepository: biometrics,
                    strainRepository: strains,
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    motionEpochRepository: motion),
                strainRepository: strains,
                biometricRepository: biometrics,
                motionEpochRepository: motion)

            try await biometrics.saveSamples(StrainTests.samples(
                from: StrainTests.day.addingTimeInterval(9 * 3600), count: 60, heartRate: 120))
            await refresh.refresh(from: nil, to: nil)
            await refresh.refresh(from: StrainTests.day, to: nil)
            assertTest(
                try await strains.getLocalStrain(for: StrainTests.day) == nil,
                "A drain with no record stamps scores nothing — an absence is not a day at today")
        }

        // ---- Newest first, capped at seven days ----
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let biometrics = GRDBBiometricRepository(db: db)
            let strains = GRDBStrainRepository(db: db)
            let motion = GRDBMotionEpochRepository(db: db)
            let refresh = RefreshStrainUseCase(
                calculate: CalculateStrainUseCase(
                    biometricRepository: biometrics,
                    strainRepository: strains,
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    motionEpochRepository: motion),
                strainRepository: strains,
                biometricRepository: biometrics,
                motionEpochRepository: motion)

            let newest = StrainTests.day
            let oldest = Calendar.current.date(byAdding: .day, value: -8, to: newest) ?? newest
            for offset in 0...8 {
                guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: newest) else { continue }
                try await biometrics.saveSamples(StrainTests.samples(
                    from: day.addingTimeInterval(9 * 3600), count: 600, heartRate: 120))
            }

            await refresh.refresh(from: oldest, to: newest)

            let newestRow = try await strains.getLocalStrain(for: newest)
            let seventh = Calendar.current.date(byAdding: .day, value: -6, to: newest) ?? newest
            let eighth = Calendar.current.date(byAdding: .day, value: -7, to: newest) ?? newest
            assertTest(newestRow != nil, "The backfill scores the newest day first")
            assertTest(
                try await strains.getLocalStrain(for: seventh) != nil,
                "…and reaches the seventh day back")
            assertTest(
                try await strains.getLocalStrain(for: eighth) == nil,
                "…and stops there, leaving older days for a later run")
        }

        // ---- A saved row is published after the save ----
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let biometrics = GRDBBiometricRepository(db: db)
            let strains = GRDBStrainRepository(db: db)
            let motion = GRDBMotionEpochRepository(db: db)
            let refresh = RefreshStrainUseCase(
                calculate: CalculateStrainUseCase(
                    biometricRepository: biometrics,
                    strainRepository: strains,
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    motionEpochRepository: motion),
                strainRepository: strains,
                biometricRepository: biometrics,
                motionEpochRepository: motion)

            let day = StrainTests.day
            try await biometrics.saveSamples(StrainTests.samples(
                from: day.addingTimeInterval(9 * 3600), count: 600, heartRate: 150))

            // The stream's continuation is registered when the property is read, and `AsyncStream`
            // buffers what arrives before the `for await` starts — so this cannot miss the yield.
            let stream = refresh.strainUpdates
            let collector = Task { () -> StrainScore? in
                for await score in stream { return score }
                return nil
            }
            await refresh.refresh(from: day, to: day)
            let published = await collector.value

            assertTest(
                published?.date.startOfDay == day,
                "The row the writer saved is published to a subscriber")
            assertTest(
                published?.score == (try await strains.getLocalStrain(for: day)?.score),
                "…and it is the stored figure rather than one computed for the screen")
        }
    }
}
