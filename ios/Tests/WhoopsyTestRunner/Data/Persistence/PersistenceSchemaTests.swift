import Foundation
import Whoopsy

// MARK: - 7. Persistence Schema, Round-Trip & Day-Key Integrity

/// Hermetic: an in-memory database needs no device, no HealthKit and no files on disk.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum PersistenceSchemaTests {
    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)

        // Every table the repositories query must exist. `strains`, `user_profiles` and
        // `biometric_samples` previously had no migration at all, so this is the regression guard.
        let tables = (try? await db.existingTableNames()) ?? []
        // **Two of the seven are id-keyed and five are `date`-keyed**, and the split is the day-key rule
        // rather than a preference: a day holds one recovery, one sleep and one strain, so those three
        // are primary-keyed on the snapped `date`; a day can hold several naps and several receptive
        // activities, so those two are keyed on an `id` with `date` an ordinary indexed column. `naps`
        // is `v11`'s table and `receptive_inactivities` is `v21`'s — see §14 and §20 for why.
        //
        // The sweep is a list rather than a count on purpose: it fails on a table that was *renamed*,
        // which is the shape a new migration takes here (`receptive_inactivities`, not
        // `receptive_activities` — the card's word, not the row type's).
        for expected in [
            "recoveries", "sleeps", "strains", "user_profiles", "biometric_samples", "naps",
            "receptive_inactivities",
        ] {
            assertTest(tables.contains(expected), "Migration created table '\(expected)'")
        }

        let day = Calendar.current.startOfDay(for: Date())
        let wallClock = day.addingTimeInterval(9 * 3600 + 37 * 60)  // 09:37 on that day

        // Writes must land on the day key the reads use, or the row is unreachable.
        let first = RecoveryRecord(
            date: wallClock, recoveryScore: 71, restingHeartRate: 52, hrvValueMs: 68.4)
        let second = RecoveryRecord(
            date: wallClock.addingTimeInterval(2 * 3600), recoveryScore: 73, restingHeartRate: 51,
            hrvValueMs: 70.1, hrvMetric: .rmssd)

        do {
            try await db.saveRecovery(first)
            try await db.saveRecovery(second)

            let fetched = try await db.getRecovery(for: wallClock)
            assertTest(fetched != nil, "A recovery written at 09:37 is readable for that day")
            assertTest(fetched?.recoveryScore == 73, "Same-day rewrite updated in place (no new row)")
            assertTest(fetched?.date == day, "Stored date is snapped to start of day")

            let history = try await db.getRecoveryHistory(days: 30)
            assertTest(history.count == 1, "Same-day writes collapse to 1 row, got \(history.count)")

            // Sleep and strain share the day-key convention.
            try await db.saveSleep(
                SleepRecord(
                    date: wallClock, startTime: wallClock, endTime: wallClock.addingTimeInterval(28800),
                    sleepPerformance: 0.9, totalSleepNeeded: 28800, lightSleep: 14400,
                    deepSleep: 7200, remSleep: 7200, awakeTime: 1800))
            assertTest(
                try await db.getSleep(for: wallClock) != nil, "A sleep written at 09:37 is readable")

            // `v4` added these two columns. Before it, the repository filled both in on read, so a night
            // with no respiratory reading came back claiming 14.0 rpm — a number no code had measured.
            let sleepRepository = GRDBSleepRepository(db: db)
            let readBack = try await sleepRepository.getSleepSession(for: wallClock)
            assertTest(
                readBack?.respiratoryRate == nil,
                "A night written without a respiratory rate reads back absent, not as a default")
            assertTest(
                readBack?.disturbanceCount == nil,
                "A night written without a disturbance count reads back absent, not as zero")
            // `v9` added this column. Like the two above it, the honest value for a row written without
            // one is NULL — and `0` is the one value it must not come back as, since a 0% consistency is
            // the claim that the night's schedule was as irregular as the scale allows.
            assertTest(
                readBack?.sleepConsistency == nil,
                "A night written without a consistency value reads back absent, not as zero")
            // `v10` added this column, and it is the one where the absent-vs-zero distinction is not
            // hypothetical: `Sleep debt (min)` is genuinely 0 on 20 of the export's 910 nights, so a
            // defaulted column would make "no debt yet" and "never measured" the same `0`.
            assertTest(
                readBack?.sleepDebtSeconds == nil,
                "A night written without a sleep debt reads back absent, not as zero")

            try await sleepRepository.saveSleepSession(
                SleepSession(
                    date: wallClock, startTime: wallClock, endTime: wallClock.addingTimeInterval(28800),
                    targetSleepNeedSeconds: 28800, lightSleepSeconds: 14400, deepSleepSeconds: 7200,
                    remSleepSeconds: 7200, awakeSeconds: 1800, disturbanceCount: 7,
                    respiratoryRate: 13.6, sleepConsistency: 88, sleepDebtSeconds: 4620))
            let measured = try await sleepRepository.getSleepSession(for: wallClock)
            assertTest(
                measured?.respiratoryRate == 13.6, "A measured respiratory rate survives the round trip")
            assertTest(
                measured?.disturbanceCount == 7, "A measured disturbance count survives the round trip")
            assertTest(
                measured?.sleepConsistency == 88,
                "A stored consistency value survives the round trip as an `Int?` "
                    + "(got \(measured?.sleepConsistency.map(String.init) ?? "nil"))")
            assertTest(
                measured?.sleepDebtSeconds == 4620,
                "A stored sleep debt survives the round trip as a `Double?` in seconds — 77 min, "
                    + "not 77 (got \(measured?.sleepDebtSeconds.map { String($0) } ?? "nil"))")

            // NULL and 0 are distinguishable on the same column, which is what makes the optional the
            // right shape: "this night was never scored" and "this night scored as badly as possible"
            // are different answers, and a non-optional column would have had to spell one of them some
            // other way.
            try await db.saveSleep(
                SleepRecord(
                    date: wallClock, startTime: wallClock, endTime: wallClock.addingTimeInterval(28800),
                    sleepPerformance: 0.9, totalSleepNeeded: 28800, lightSleep: 14400,
                    deepSleep: 7200, remSleep: 7200, awakeTime: 1800, sleepConsistency: 0,
                    sleepDebt: 0))
            assertTest(
                try await db.getSleep(for: wallClock)?.sleepConsistency == 0,
                "A stored 0 is a reading and reads back as one, distinct from the NULL above")
            // The same pair on `sleep_debt`, and here it is not a constructed edge case: WHOOP scores a
            // debt of exactly 0 on 20 nights of the export, so `0` is a value the column really carries.
            assertTest(
                try await db.getSleep(for: wallClock)?.sleepDebt == 0,
                "…and a stored 0 sleep debt is likewise a reading rather than the NULL above")

            try await db.saveStrain(
                StrainRecord(
                    date: wallClock, strainScore: 12.4, kilojoules: 1800, averageHeartRate: 62,
                    maxHeartRate: 158, hasMeasurement: true))
            assertTest(
                try await db.getStrain(for: wallClock) != nil, "A strain written at 09:37 is readable")
        } catch {
            assertTest(false, "Day-keyed write/read round-trip threw: \(error)")
        }

        // Every biometric channel must survive the round trip. Dropping R-R intervals here is what
        // made `CalculateRecoveryUseCase` fall back to a hardcoded RMSSD on every single run.
        let sample = BiometricSample(
            timestamp: wallClock, heartRate: 58, rrIntervalMs: 882.5,
            accelerometerX: 0.02, accelerometerY: -0.98, accelerometerZ: 0.11,
            skinTemperatureCelsius: 34.75, spO2Percentage: 97.0, isOnBody: false, isCharging: true,
            rawSequenceNumber: 4242)
        let noSkinTemp = BiometricSample(timestamp: wallClock.addingTimeInterval(1), heartRate: 59)

        do {
            try await db.saveSamples([
                BiometricSampleRecord(
                    timestamp: sample.timestamp, heartRate: sample.heartRate,
                    rrIntervalMs: sample.rrIntervalMs, accelX: sample.accelerometerX,
                    accelY: sample.accelerometerY, accelZ: sample.accelerometerZ,
                    skinTemp: sample.skinTemperatureCelsius, spo2Percentage: sample.spO2Percentage,
                    isOnBody: sample.isOnBody, isCharging: sample.isCharging,
                    rawSequenceNumber: sample.rawSequenceNumber),
                BiometricSampleRecord(timestamp: noSkinTemp.timestamp, heartRate: noSkinTemp.heartRate),
            ])

            let back = try await db.getSamples(
                from: wallClock.addingTimeInterval(-60), to: wallClock.addingTimeInterval(60))
            assertTest(back.count == 2, "Both samples persisted, got \(back.count)")

            let full = back.first
            assertTest(full?.rrIntervalMs == 882.5, "R-R interval round-trips (\(full?.rrIntervalMs ?? -1))")
            assertTest(full?.spo2Percentage == 97.0, "SpO2 round-trips")
            assertTest(full?.skinTemp == 34.75, "Skin temperature round-trips")
            assertTest(full?.accelY == -0.98, "Accelerometer Y round-trips")
            assertTest(full?.isCharging == true, "Charging flag round-trips")
            assertTest(full?.rawSequenceNumber == 4242, "Sequence number round-trips")

            // A missing reading must stay missing: a fabricated default is indistinguishable from a
            // real one downstream, and silently enters the recovery math.
            let absent = back.last
            assertTest(absent?.skinTemp == nil, "Absent skin temperature stays nil (not fabricated)")
            assertTest(absent?.spo2Percentage == nil, "Absent SpO2 stays nil")
            assertTest(absent?.rrIntervalMs == nil, "Absent R-R stays nil")
            // The accelerometer is the one absence with a *physical* meaning rather than a missing one:
            // the column is NULL because nothing measured motion, and the repository's mapper used to
            // read it back as `?? 0` — handing every downstream reader a strap reported as being in free
            // fall, which the sleep classifier and the stress model both read as motionless. The two
            // assertions below are the read path and the entity, in that order.
            assertTest(
                absent?.accelX == nil && absent?.accelY == nil && absent?.accelZ == nil,
                "Absent accelerometer stays nil in the column (a substituted 0 is a free-fall reading)")

            // Read through the repository rather than the manager, because the mapper is where the
            // fabrication actually was: `GRDBBiometricRepository.makeSample` is the only place a NULL
            // accel column became a number, and a round trip through `LocalDatabaseManager` alone would
            // not touch it. Own in-memory database, so this stays off the developer's file.
            let mapperRepo = GRDBBiometricRepository(db: LocalDatabaseManager(inMemory: true))
            try await mapperRepo.saveSamples([
                BiometricSample(timestamp: wallClock, heartRate: 59)
            ])
            let mappedBack = try await mapperRepo.getSamples(
                from: wallClock.addingTimeInterval(-60), to: wallClock.addingTimeInterval(60))
            assertTest(
                mappedBack.first?.accelerationMagnitude == nil,
                "…and the mapper returns it as a `nil` magnitude rather than a magnitude of zero, which "
                    + "is a claim that the strap was measured motionless (got "
                    + "\(mappedBack.first?.accelerationMagnitude.map { "\($0)" } ?? "nil"))")
        } catch {
            assertTest(false, "Biometric round-trip threw: \(error)")
        }

        // MARK: The full R-R series (`v8`)
        //
        // The strap sends several beat-to-beat intervals per Heart Rate notification and the BLE layer
        // kept only the first. These assert the series survives the write, the read, and the mapper —
        // through the repository, which is the path the app uses, rather than through `db.saveSamples`,
        // which the block above covers and which would hide a mapper that drops the column.

        do {
            // The column exists and is spelled the way the record spells it. `BiometricSampleRecord`
            // declares no `CodingKeys`, so its **property names are its column names** — this is the
            // assertion that fails if the migration and the record disagree, and on this database that
            // disagreement is `SQLite error 1: no such column` at launch, not a test failure in the app.
            let columns = (try? await db.columnNames(in: "biometric_samples")) ?? []
            assertTest(
                columns.contains("rrIntervalsMs"),
                "v8 added `rrIntervalsMs` to biometric_samples (camelCase — the record has no CodingKeys)")

            let repo = GRDBBiometricRepository(db: db)
            // A notification carrying four adjacent beats, at a fixed instant so the ordering assertion
            // below is about the series and not about the clock.
            let seriesInstant = day.addingTimeInterval(2 * 3600)
            let series: [Double] = [881.5, 869.0, 902.25, 874.75]
            try await repo.saveSamples([
                BiometricSample(timestamp: seriesInstant, heartRate: 68, rrIntervalsMs: series)
            ])

            let readBack = try await repo.getSamples(
                from: seriesInstant.addingTimeInterval(-1), to: seriesInstant.addingTimeInterval(1))
            let seriesSample = readBack.first
            assertTest(
                seriesSample?.rrIntervalsMs == series,
                "A 4-interval series round-trips in wire order, got \(seriesSample?.rrIntervalsMs ?? [])")

            // The invariant the entity's shape is supposed to make structural: the scalar is the first
            // interval of the series, never a second independently-written value.
            assertTest(
                seriesSample?.rrIntervalMs == series.first,
                "rrIntervalMs is the series' first interval (\(seriesSample?.rrIntervalMs ?? -1))")

            // A series of one is spelled the same as a scalar. Both of these are the pre-`v8` shape and
            // the proprietary-0x01 shape, and they must be indistinguishable to a reader.
            let scalarInstant = day.addingTimeInterval(3 * 3600)
            try await db.saveSamples([
                BiometricSampleRecord(timestamp: scalarInstant, heartRate: 61, rrIntervalMs: 915.0)
            ])
            let scalarRows = try await db.getSamples(
                from: scalarInstant.addingTimeInterval(-1), to: scalarInstant.addingTimeInterval(1))
            let scalarRow = scalarRows.first
            assertTest(
                scalarRow?.rrIntervalsMs == nil,
                "A pre-v8 row's scalar column leaves `rrIntervalsMs` NULL rather than an invented series")
            assertTest(scalarRow?.rrIntervalMs == 915.0, "Its scalar R-R is intact")
            assertTest(
                scalarRow?.rrSeries == [915.0],
                "`rrSeries` falls back to a one-element series, got \(scalarRow?.rrSeries ?? [])")
            assertTest(scalarRow?.rrSeries.first == scalarRow?.rrIntervalMs, "The fallback agrees with the scalar")

            // A row with neither column is an absence, and `rrSeries` must not turn it into `[0.0]`.
            let emptyInstant = day.addingTimeInterval(4 * 3600)
            try await db.saveSamples([BiometricSampleRecord(timestamp: emptyInstant, heartRate: 60)])
            let emptyRows = try await db.getSamples(
                from: emptyInstant.addingTimeInterval(-1), to: emptyInstant.addingTimeInterval(1))
            assertTest(emptyRows.first?.rrSeries.isEmpty == true, "No R-R at all yields an empty series")

            // `getSamples` orders by `timestamp` alone, which leaves ties undefined — and a batch decoded
            // from one packet is a batch of ties. `id` is the secondary key, so arrival order survives.
            let tieInstant = day.addingTimeInterval(5 * 3600)
            try await db.saveSamples([
                BiometricSampleRecord(timestamp: tieInstant, heartRate: 101, rrIntervalMs: 601.0),
                BiometricSampleRecord(timestamp: tieInstant, heartRate: 102, rrIntervalMs: 602.0),
                BiometricSampleRecord(timestamp: tieInstant, heartRate: 103, rrIntervalMs: 603.0),
            ])
            let tied = try await db.getSamples(
                from: tieInstant.addingTimeInterval(-1), to: tieInstant.addingTimeInterval(1))
            assertTest(
                tied.map(\.heartRate) == [101, 102, 103],
                "Rows sharing a timestamp come back in insertion order, got \(tied.map(\.heartRate))")
        } catch {
            assertTest(false, "R-R series round-trip threw: \(error)")
        }

        // The stream is multicast: two subscribers both receive, and neither orphans the other.
        //
        // This was a single stored continuation that each read of the stream *replaced*, so
        // `StreamBiometricsUseCase` driven from Home's heart-rate readout and from a second screen meant
        // the later subscriber was the only one still receiving. Nothing errored and nothing finished —
        // the first subscriber's loop simply stopped, which on this app is indistinguishable from a
        // strap that went quiet.
        //
        // The evidence is persistence, not receipt. Each `execute()` is given its **own** database, so a
        // row in one is proof that that particular subscriber was still being fed: had the first been
        // orphaned, its database would stay empty while the second filled. Asserting on the stream
        // directly would mean a `for await` that never returns on the regression, and this runner's
        // failure mode is a process that idles out the RunLoop and exits 0 — a hang would read as a pass.
        // Polling two databases to a deadline cannot hang.
        do {
            // One repository, therefore one mock: both `liveTelemetryStream` reads below reach the same
            // manager, which is exactly the "two readers of one strap" shape the bug needed.
            let bleRepo = WhoopBLEDeviceRepositoryImpl(useMock: true)
            let firstRepo = GRDBBiometricRepository(db: LocalDatabaseManager(inMemory: true))
            let secondRepo = GRDBBiometricRepository(db: LocalDatabaseManager(inMemory: true))

            // Both subscriptions are taken before either drains, which is the order that used to break:
            // the second `execute()` replaced the first's continuation before it received anything.
            let firstStream = StreamBiometricsUseCase(
                bleRepository: bleRepo, biometricRepository: firstRepo).execute()
            let secondStream = StreamBiometricsUseCase(
                bleRepository: bleRepo, biometricRepository: secondRepo).execute()

            // Held so the streams are not deallocated before their consumers run. The consumers are the
            // use cases' own inner tasks, which start as soon as each stream is built.
            let firstConsumer = Task { for await _ in firstStream {} }
            let secondConsumer = Task { for await _ in secondStream {} }

            // The mock emits at 1 Hz and the use case flushes at 10 samples or 5 seconds, so the first
            // row can take up to ~5s to land. The deadline is generous and the poll is cheap; the point
            // is that it terminates either way.
            func sampleCount(_ repo: GRDBBiometricRepository) async -> Int {
                (try? await repo.getSamples(from: .distantPast, to: .distantFuture).count) ?? 0
            }

            var firstCount = 0
            var secondCount = 0
            for _ in 0..<60 {  // up to ~15s
                firstCount = await sampleCount(firstRepo)
                secondCount = await sampleCount(secondRepo)
                if firstCount > 0 && secondCount > 0 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            assertTest(
                firstCount > 0,
                "The first subscriber of a shared telemetry stream is still receiving (rows: \(firstCount))")
            assertTest(
                secondCount > 0,
                "The second subscriber of a shared telemetry stream is still receiving (rows: \(secondCount))")

            firstConsumer.cancel()
            secondConsumer.cancel()
        }
    }
}
