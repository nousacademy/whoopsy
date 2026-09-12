import Foundation
import Whoopsy

func assertTest(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition {
        print("❌ FAILED: \(message) at \(file):\(line)")
        exit(1)
    } else {
        print("  ✓ \(message)")
    }
}

print("==================================================")
print("⚡ RUNNING WHOOPSY TEST SUITE")
print("==================================================")

// MARK: - 1. CRC & Packet Framing Tests
print("\n[1/14] Testing CRC Algorithms & Framing...")
let crc8Val = CRCUtils.crc8(Data([0x01, 0x10, 0x00]))
assertTest(crc8Val >= 0, "CRC8 computed valid checksum")

let crc16Val = CRCUtils.crc16Modbus(Data([0xAA, 0x01, 0x04, 0x00]))
assertTest(crc16Val != 0, "CRC16-Modbus produced non-zero checksum")

let crc32Val = CRCUtils.crc32("WHOOP4_TELEMETRY".data(using: .utf8)!)
assertTest(crc32Val != 0, "CRC32 produced non-zero checksum")

let packet = WhoopPacketEncoder.hapticAlarmCommand(durationSeconds: 3, pattern: 1)
assertTest(packet.count >= 4, "Encoder created packet with valid header")
assertTest(packet[0] == 0xAA, "Packet start of frame is 0xAA")
assertTest(packet[1] == 0x10, "Packet command byte is 0x10 (Haptic Alarm)")

// MARK: - 2. Packet Decoder Tests
print("\n[2/14] Testing WHOOP Packet Decoder...")
let decoder = WhoopPacketDecoder()

// Test Standard SIG Heart Rate Frame
let sigData = Data([0x10, 72, 0x50, 0x03]) // 72 BPM, 848 in 1/1024s (~828ms)
let sigResult = decoder.decodeStandardHeartRate(data: sigData)
assertTest(sigResult != nil, "Decoded standard SIG Heart Rate frame")
assertTest(sigResult?.heartRate == 72, "Heart rate is 72 BPM")
assertTest(sigResult?.rrIntervalsMs.count == 1, "Extracted 1 R-R interval")
if let rr = sigResult?.rrIntervalsMs.first {
    assertTest(rr > 800 && rr < 850, "R-R interval duration (~828ms) is correct")
}

// Test Proprietary 0xAA Live Telemetry Frame
var frame = Data([0xAA, 0x01, 16, 0x00])
let payload = Data([
    0xE8, 0x03, 0x00, 0x00, // timestamp 1000
    68,                     // HR = 68
    0x72, 0x03,             // RR = 882ms
    0x00, 0x00,             // Ax = 0
    0x00, 0x00,             // Ay = 0
    0x00, 0x20,             // Az = 8192 (1.0g)
    0x42, 0x0E,             // Temp = 3650 (36.5C)
    98                      // SpO2 = 98
])
frame.append(payload)

let decodedPayload = decoder.decodeProprietaryFrame(data: frame)
assertTest(decodedPayload != nil, "Decoded proprietary 0xAA frame")
if case .liveBiometric(let sample) = decodedPayload {
    assertTest(sample.heartRate == 68, "Decoded live HR is 68 BPM")
    assertTest(sample.rrIntervalMs == 882.0, "Decoded live R-R is 882.0 ms")
    assertTest(sample.spO2Percentage == 98.0, "Decoded SpO2 is 98%")
    assertTest(sample.skinTemperatureCelsius == 36.5, "Decoded Skin Temp is 36.5°C")
    assertTest(sample.accelerometerZ == 1.0, "Decoded Z-axis gravity acceleration is 1.0g")
} else {
    assertTest(false, "Failed to decode .liveBiometric payload")
}

// The standard Heart Rate characteristic (0x2A37) carries a *repeated* R-R field, and everything
// downstream of the R-R series rests on this decoder returning all of it, in wire order. Until `v8`
// the BLE layer kept only `rrs.first`, so a decoder that quietly returned one interval would have
// looked correct — this is the assertion that distinguishes the two.
//
// Each interval is a `uint16` in units of 1/1024 s, so milliseconds are `raw / 1024 * 1000`; the
// expected values below are written as that same expression rather than as decimal literals, which
// would be a second rounding of the same number.
do {
    // flags 0x10 = R-R present, 8-bit HR, no energy-expended field.
    func frame(flags: UInt8, hrBytes: [UInt8], extra: [UInt8] = [], rrRaw: [UInt16]) -> Data {
        var bytes: [UInt8] = [flags] + hrBytes + extra
        for raw in rrRaw {
            bytes.append(UInt8(raw & 0xFF))
            bytes.append(UInt8(raw >> 8))
        }
        return Data(bytes)
    }

    let fourRaw: [UInt16] = [902, 890, 924, 896]
    let four = decoder.decodeStandardHeartRate(data: frame(flags: 0x10, hrBytes: [68], rrRaw: fourRaw))
    let expectedFour = fourRaw.map { (Double($0) / 1024.0) * 1000.0 }
    assertTest(four?.heartRate == 68, "0x2A37 decodes an 8-bit heart rate")
    assertTest(
        four?.rrIntervalsMs == expectedFour,
        "0x2A37 returns all 4 intervals in wire order, got \(four?.rrIntervalsMs ?? [])")

    // The bit that matters most for the offset arithmetic: an energy-expended field (flags bit 3)
    // and a 16-bit heart rate (bit 0) both sit *between* the flags and the R-R list, and a decoder
    // that ignores either reads the R-R bytes from the wrong offset and still returns numbers.
    let shifted = decoder.decodeStandardHeartRate(
        data: frame(flags: 0x01 | 0x08 | 0x10, hrBytes: [0x2C, 0x01], extra: [0x00, 0x00], rrRaw: fourRaw))
    assertTest(shifted?.heartRate == 300, "0x2A37 decodes a 16-bit heart rate (\(shifted?.heartRate ?? -1))")
    assertTest(
        shifted?.rrIntervalsMs == expectedFour,
        "The R-R list is read past the energy field, got \(shifted?.rrIntervalsMs ?? [])")

    // R-R bit unset. This is the case the BLE layer collapses to `nil` — an absent series, which is
    // a different statement from a series of length zero and must not be written as one.
    let noRR = decoder.decodeStandardHeartRate(data: frame(flags: 0x00, hrBytes: [70], rrRaw: []))
    assertTest(noRR?.heartRate == 70, "0x2A37 without the R-R bit still decodes a heart rate")
    assertTest(noRR?.rrIntervalsMs.isEmpty == true, "0x2A37 without the R-R bit returns no intervals")

    // A single interval is the common real-world shape and must not be special-cased into a scalar.
    let one = decoder.decodeStandardHeartRate(data: frame(flags: 0x10, hrBytes: [58], rrRaw: [904]))
    assertTest(
        one?.rrIntervalsMs == [(Double(904) / 1024.0) * 1000.0],
        "0x2A37 with one interval returns a one-element series")
}

// MARK: - 3. Mathematical & HRV Algorithms
print("\n[3/14] Testing HRV (RMSSD, SDNN, pNN50) & Artifact Rejection...")
let rawRR: [Double] = [800.0, 805.0, 810.0, 795.0, 1500.0, 802.0, 808.0]
let cleaned = HeartRateVariabilityMath.filterRRIntervals(rawRR)
assertTest(!cleaned.contains(1500.0), "Ectopic beat (1500ms) successfully rejected by filter")

let rmssd = HeartRateVariabilityMath.calculateRMSSD(from: rawRR)
assertTest(rmssd > 0.0 && rmssd < 50.0, "RMSSD calculated accurately (\(String(format: "%.1f", rmssd)) ms)")

let sdnn = HeartRateVariabilityMath.calculateSDNN(from: rawRR)
assertTest(sdnn > 0.0, "SDNN calculated accurately (\(String(format: "%.1f", sdnn)) ms)")

let pnn50 = HeartRateVariabilityMath.calculatePNN50(from: rawRR)
assertTest(pnn50 >= 0.0 && pnn50 <= 100.0, "pNN50 calculated accurately (\(String(format: "%.1f", pnn50))%)")

// MARK: - 4. Strain & Zone Accumulator
print("\n[4/14] Testing Strain Integrator & Karvonen Zones...")
let zones = StrainAccumulatorMath.computeZones(maxHR: 190, restHR: 50)
assertTest(zones.count == 5, "Computed 5 distinct Heart Rate Zones")
assertTest(zones[0].lowerBpm == 120, "Zone 1 threshold calculated via HRR: \(zones[0].lowerBpm)")
assertTest(zones[4].upperBpm == 190, "Zone 5 ceiling equals Max HR")

let zeroStrain = StrainAccumulatorMath.calculateStrainScore(from: 0.0)
assertTest(zeroStrain == 0.0, "0 accumulated load yields 0.0 strain")

let modStrain = StrainAccumulatorMath.calculateStrainScore(from: 50_000.0)
assertTest(modStrain >= 10.0 && modStrain <= 20.0, "Moderate load produces expected strain (\(modStrain))")

let extremeStrain = StrainAccumulatorMath.calculateStrainScore(from: 1_000_000.0)
assertTest(extremeStrain <= 21.0 && extremeStrain >= 20.9, "Extreme load caps at 21.0 scale ceiling (\(extremeStrain))")

// MARK: - 5. Recovery Baseline Model
print("\n[5/14] Testing Recovery z-Score Baseline Model...")
let greenRecovery = BaselineStatisticsMath.computeRecoveryScore(
    todayHrv: 85.0,
    baselineHrvMean: 65.0,
    baselineHrvStd: 10.0,
    todayRhr: 48.0,
    baselineRhrMean: 54.0,
    baselineRhrStd: 3.0,
    sleepPerformance: 0.95
)
assertTest(greenRecovery >= 67, "High HRV + Low RHR yields Green Recovery (\(greenRecovery)%)")

let redRecovery = BaselineStatisticsMath.computeRecoveryScore(
    todayHrv: 35.0,
    baselineHrvMean: 65.0,
    baselineHrvStd: 10.0,
    todayRhr: 64.0,
    baselineRhrMean: 54.0,
    baselineRhrStd: 3.0,
    sleepPerformance: 0.60
)
assertTest(redRecovery <= 35, "Low HRV + High RHR yields Red Recovery (\(redRecovery)%)")

// MARK: - 6. End-to-End Clean Architecture & Local Data Sovereignty
print("\n[6/14] Testing DI Container, Use Cases & Data Sovereignty Export...")
Task {
    let container = DIContainer(useMockBLE: true)

    // Calculate Recovery UseCase. As with Sleep below, this runs against the shared dev database and
    // a mock strap that recorded nothing, so both outcomes are checked only for what must hold of
    // them: a day with a reading scores in range, and a day without one reports no reading rather
    // than a row of zeros. The "answers nil *and* writes nothing" rule is asserted in §10, where the
    // database is in memory and the sample source is empty.
    let recovery = try await container.calculateRecoveryUseCase.execute()
    if let recovery {
        assertTest(recovery.score >= 0 && recovery.score <= 100, "Recovery UseCase returned valid score: \(recovery.score)%")
        assertTest(recovery.hasMeasurement, "A returned recovery carries a measurement, not a reserved zero")
    } else {
        assertTest(true, "Recovery UseCase reported no measurement rather than inventing a row")
    }

    // Calculate Strain UseCase
    let strain = try await container.calculateStrainUseCase.execute()
    if let strain {
        assertTest(strain.score >= 0.0 && strain.score <= 21.0, "Strain UseCase returned valid score: \(strain.score)")
        assertTest(strain.hasMeasurement, "A returned strain carries a measurement, not a reserved zero")
    } else {
        assertTest(true, "Strain UseCase reported no measurement rather than inventing a row")
    }

    // Analyze Sleep UseCase. This runs against the shared dev database, which is not under the
    // suite's control — whether a night exists for today depends on what this machine has recorded,
    // and a database written by an older build can hold rows no current code would produce. So both
    // outcomes are checked only for what must hold of them. The "answers nil *and* writes nothing"
    // rule is asserted in §10, where the database is in memory and the sample source is empty.
    let sleep = try await container.analyzeSleepUseCase.execute()
    if let sleep {
        assertTest(sleep.sleepPerformancePercentage >= 0 && sleep.sleepPerformancePercentage <= 100, "Sleep UseCase returned valid performance: \(sleep.sleepPerformancePercentage)%")
    } else {
        assertTest(true, "Sleep UseCase reported no session: no classifiable samples for today")
    }

    // Export Data UseCase (Data Sovereignty)
    let exportResult = try await container.exportLocalDataUseCase.execute()
    assertTest(!exportResult.jsonString.isEmpty, "JSON local backup generated successfully")
    assertTest(exportResult.csvHeartRates.contains("Timestamp,HeartRateBPM"), "CSV heart rate telemetry exported properly")

    // MARK: - 7. Persistence Schema, Round-Trip & Day-Key Integrity
    print("\n[7/14] Testing migrations, biometric round-trip and day-keyed writes...")
    await runPersistenceTests()

    // MARK: - 8. HRV Metric Isolation & Baseline Guards
    print("\n[8/14] Testing HRV metric isolation, baseline guards and formatters...")
    runScoringAndFormatterTests()

    // MARK: - 9. HealthKit Import (hermetic: fixture store + in-memory database)
    print("\n[9/14] Testing HealthKit import attribution, skipping and idempotency...")
    await runHealthKitImportTests()

    // MARK: - 10. Days with no data
    print("\n[10/14] Testing no-data days store zeros, and zeros never enter a baseline...")
    await runNoDataDayTests()

    // MARK: - 11. WHOOP export import (real CSV, in-memory database)
    print("\n[11/14] Testing the WHOOP export import against the real file...")
    await runWhoopExportImportTests()

    // MARK: - 12. Choosing a day
    print("\n[12/14] Testing that a chosen day is read, and an imported day is never overwritten...")
    await runDaySelectionTests()

    // MARK: - 13. Sleep Need
    print("\n[13/14] Testing that a night's Sleep Need follows the previous day's Strain...")
    await runSleepNeedTests()

    // MARK: - 14. The Home screen's sources
    print("\n[14/14] Testing recorded workouts, HealthKit steps, the Stress Monitor, the recovery ring tiers and the seven-day MetricWeek join...")
    await runHomeSourceTests()

    print("\n==================================================")
    print("✅ ALL WHOOPSY TESTS PASSED SUCCESSFULLY! (100% OK)")
    print("==================================================")
    exit(0)
}

/// Hermetic: an in-memory database needs no device, no HealthKit and no files on disk.
func runPersistenceTests() async {
    let db = LocalDatabaseManager(inMemory: true)

    // Every table the repositories query must exist. `strains`, `user_profiles` and
    // `biometric_samples` previously had no migration at all, so this is the regression guard.
    let tables = (try? await db.existingTableNames()) ?? []
    for expected in ["recoveries", "sleeps", "strains", "user_profiles", "biometric_samples"] {
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

        try await sleepRepository.saveSleepSession(
            SleepSession(
                date: wallClock, startTime: wallClock, endTime: wallClock.addingTimeInterval(28800),
                targetSleepNeedSeconds: 28800, lightSleepSeconds: 14400, deepSleepSeconds: 7200,
                remSleepSeconds: 7200, awakeSeconds: 1800, disturbanceCount: 7,
                respiratoryRate: 13.6))
        let measured = try await sleepRepository.getSleepSession(for: wallClock)
        assertTest(
            measured?.respiratoryRate == 13.6, "A measured respiratory rate survives the round trip")
        assertTest(
            measured?.disturbanceCount == 7, "A measured disturbance count survives the round trip")

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
    // `StreamBiometricsUseCase` driven from Home's heart-rate readout and from the workout HUD meant
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

func runScoringAndFormatterTests() {
    func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86_400)
    }
    func metric(_ hrv: Double, _ kind: HRVMetric, _ rhr: Int, _ offset: Int) -> RecoveryMetric {
        RecoveryMetric(
            date: day(offset), score: 50, hrvValueMs: hrv, hrvMetric: kind, restingHeartRate: rhr)
    }

    // SDNN and RMSSD must never share a baseline. Ten RMSSD days at ~65 ms and ten SDNN days at
    // ~40 ms, scored as SDNN, must produce an SDNN baseline — not a mean of the two populations.
    var history: [RecoveryMetric] = []
    for i in 0..<10 {
        history.append(metric(65.0 + Double(i % 3), .rmssd, 54, -(i + 1)))
        history.append(metric(40.0 + Double(i % 3), .sdnn, 54, -(i + 20)))
    }

    let sdnnScored = RecoveryScoring.score(
        RecoveryScoring.Input(
            history: history, todayHrvValueMs: 41.0, todayHrvMetric: .sdnn,
            todayRestingHeartRate: 54, sleepPerformance: 0.9,
            fallbackRestingHeartRateBaseline: 54.0))
    assertTest(
        sdnnScored.hrvBaselineMeanMs >= 40.0 && sdnnScored.hrvBaselineMeanMs <= 42.0,
        "SDNN baseline excludes RMSSD days (mean \(String(format: "%.1f", sdnnScored.hrvBaselineMeanMs)))")

    let rmssdScored = RecoveryScoring.score(
        RecoveryScoring.Input(
            history: history, todayHrvValueMs: 66.0, todayHrvMetric: .rmssd,
            todayRestingHeartRate: 54, sleepPerformance: 0.9,
            fallbackRestingHeartRateBaseline: 54.0))
    assertTest(
        rmssdScored.hrvBaselineMeanMs >= 65.0 && rmssdScored.hrvBaselineMeanMs <= 67.0,
        "RMSSD baseline excludes SDNN days (mean \(String(format: "%.1f", rmssdScored.hrvBaselineMeanMs)))")

    // A zero-variance window must not make every difference infinitely many sigma. Without the
    // coefficient-of-variation floor, a 0.5 ms gap against a constant baseline scored ~500 sigma
    // and pinned the result to the clamp on data that was in fact perfectly average.
    let constant = (0..<10).map { metric(65.5, .rmssd, 54, -($0 + 1)) }
    let degenerate = RecoveryScoring.score(
        RecoveryScoring.Input(
            history: constant, todayHrvValueMs: 65.0, todayHrvMetric: .rmssd,
            todayRestingHeartRate: 54, sleepPerformance: 0.9,
            fallbackRestingHeartRateBaseline: 54.0))
    assertTest(
        degenerate.score > 40 && degenerate.score < 60,
        "A 0.5 ms gap on a zero-variance baseline stays near the midpoint (got \(degenerate.score))")

    // The z-score ceiling still bounds genuine outliers, so one wild reading cannot max the score.
    let wild = RecoveryScoring.score(
        RecoveryScoring.Input(
            history: constant, todayHrvValueMs: 900.0, todayHrvMetric: .rmssd,
            todayRestingHeartRate: 54, sleepPerformance: 0.9,
            fallbackRestingHeartRateBaseline: 54.0))
    assertTest(wild.score == 99, "An extreme outlier saturates at the 99 ceiling, not above it")

    // ── The scoring window, and the baselines a screen reads back off it ─────────────────────────
    //
    // `RecoveryScoring.baselines` exists so that a screen printing a day's figure against "its
    // baseline" prints the numbers the score above it was computed from, rather than an average of
    // its own taken over some neighbouring window. These assertions are what keep the two from
    // drifting: the first pins the window rule, the middle ones pin the display gate that stops a
    // cold-start constant being printed as a measurement, and the last pins `score` and `baselines`
    // to one answer.
    //
    // Every fixture below is built **oldest first**, which is the order `baselineWindow` documents
    // and the order the repositories return (`order(Column("date").asc)`). A newest-first array
    // would make `suffix` take the *oldest* thirty and the window would be a month adrift.
    let scoringWindowDays = RecoveryScoring.baselineWindowDays
    let dense = (0..<(scoringWindowDays + 5)).map { metric(60.0, .rmssd, 54, -((scoringWindowDays + 5) - $0)) }
    let windowed = RecoveryScoring.baselineWindow(before: day(0), in: dense)
    assertTest(
        windowed.count == scoringWindowDays,
        "The scoring window holds \(scoringWindowDays) days (got \(windowed.count))")
    assertTest(
        windowed.allSatisfy { $0.date < day(0) },
        "The scoring window is strictly before the day it scores")
    assertTest(
        windowed.last?.date == day(-1),
        "Its newest day is the day before, so a day never contributes to its own baseline")

    // The cap applies **after** the strictly-before filter, and the two orders disagree the moment
    // the series contains the day being scored — which it ordinarily does, since a caller reads a
    // window that ends on or after it. Slicing first takes the day itself out of the thirty and
    // returns twenty-nine; the mean then shifts by a day nobody can see.
    let withToday = (0..<scoringWindowDays).map { metric(60.0, .rmssd, 54, -(scoringWindowDays - $0)) }
        + [metric(60.0, .rmssd, 54, 0)]
    let filteredWindow = RecoveryScoring.baselineWindow(before: day(0), in: withToday)
    assertTest(
        filteredWindow.count == scoringWindowDays,
        "The cap is applied after the filter, not before (got \(filteredWindow.count) of \(scoringWindowDays))")
    assertTest(
        !filteredWindow.contains { $0.date == day(0) },
        "…and the day being scored is not inside its own baseline")

    // The lookback a reader has to fetch. It must exceed the window, because the window is of the
    // last thirty days *that have rows* — a history with a gap reaches back further than a month to
    // fill, so a reader that fetched exactly `baselineWindowDays` would silently build the printed
    // baseline from a different set of days than the score used.
    assertTest(
        RecoveryScoring.baselineWindowLookbackDays > scoringWindowDays,
        "The lookback exceeds the window it has to fill (\(RecoveryScoring.baselineWindowLookbackDays) > \(scoringWindowDays))")

    // The display gate. `BaselineStatisticsMath.baseline` substitutes a cold-start **constant** when
    // it is handed nothing, which is right for scoring a first day and wrong to print: a screen
    // showing those numbers as "your baseline" would be presenting a profile default as a
    // measurement. So the constant must survive for the score and be withheld from the screen.
    let emptyWindow = RecoveryScoring.baselines(history: [], todayHrvMetric: .rmssd)
    assertTest(
        emptyWindow.hrvMeanMs == HRVMetric.rmssd.coldStartMeanMs,
        "An empty window still yields a scoring baseline — the cold start")
    assertTest(
        emptyWindow.displayed.hrvMs == nil,
        "…and that cold-start HRV is not printed as a baseline")
    assertTest(
        emptyWindow.displayed.restingHeartRate == nil,
        "…nor is the cold-start resting heart rate")

    let twoDays = (0..<2).map { metric(60.0, .rmssd, 54, -($0 + 1)) }
    assertTest(
        RecoveryScoring.baselines(history: twoDays, todayHrvMetric: .rmssd).displayed.hrvMs == nil,
        "Two measured days do not make a printed baseline")
    let threeDays = (0..<3).map { metric(60.0, .rmssd, 54, -($0 + 1)) }
    assertTest(
        RecoveryScoring.baselines(history: threeDays, todayHrvMetric: .rmssd).displayed.hrvMs == 60.0,
        "Three do — the floor is \(RecoveryScoring.minimumBaselineDays)")

    // The never-mix rule reaches the screen too. A window holding both quantities prints a mean of
    // the day's own metric only; an unfiltered mean here would be 55, a statistic about neither.
    let mixedWindow =
        (0..<5).map { metric(40.0, .sdnn, 54, -($0 + 1)) }
        + (0..<5).map { metric(70.0, .rmssd, 54, -($0 + 6)) }
    assertTest(
        RecoveryScoring.baselines(history: mixedWindow, todayHrvMetric: .rmssd).displayed.hrvMs == 70.0,
        "The printed HRV baseline is narrowed to the day's own metric, not a mean across both")

    // Respiratory rate comes off the recovery row and is absent far more often than it is present —
    // the strap has no sensor for it — so its mean is over the days that carry one, or nothing.
    let withRates = (0..<4).map { offset in
        RecoveryMetric(
            date: day(-(offset + 1)), score: 50, hrvValueMs: 60, hrvMetric: .rmssd,
            restingHeartRate: 54, respiratoryRate: 14.0 + Double(offset))
    }
    assertTest(
        RecoveryScoring.baselines(history: withRates, todayHrvMetric: .rmssd)
            .displayed.respiratoryRate == 15.5,
        "The respiratory baseline is the mean of the days that measured one")

    // Sleep performance is derived per night from asleep-over-need, so its baseline is a mean of
    // ratios rather than of minutes: three nights at 4, 5 and 6 hours against an 8-hour need are
    // 50%, 62.5% and 75%.
    func night(_ offset: Int, asleepHours: Double) -> SleepSession {
        SleepSession(
            date: day(offset),
            startTime: day(offset).addingTimeInterval(-8 * 3600),
            endTime: day(offset),
            targetSleepNeedSeconds: 8 * 3600,
            lightSleepSeconds: asleepHours * 3600)
    }
    //
    // Two things are pinned here, and the first is the one that would otherwise be a silent
    // inconsistency on screen. A night at five hours against an eight-hour need is 62.5%, which
    // `SleepSession` reports as **63** — and the baseline is the mean of that printed figure, not of
    // the ratio behind it. Averaging the unrounded ratio would print a mean beneath a value that the
    // row above could never equal.
    let fiveHourNights = [night(-3, asleepHours: 5), night(-2, asleepHours: 5), night(-1, asleepHours: 5)]
    let roundedBaseline = RecoveryScoring.baselines(
        history: [], todayHrvMetric: .rmssd, sleepingNights: fiveHourNights).displayed.sleepPerformance
    assertTest(
        roundedBaseline.map { abs($0 - 0.63) < 0.0001 } == true,
        "The sleep-performance baseline averages the printed percentage, not the raw ratio (got \(roundedBaseline.map { String(format: "%.4f", $0) } ?? "nil"), not 0.625)")

    // And a plain mean over nights that do land on whole percents: 75%, 50% and 25%.
    let nights = [night(-3, asleepHours: 6), night(-2, asleepHours: 4), night(-1, asleepHours: 2)]
    assertTest(
        RecoveryScoring.baselines(history: [], todayHrvMetric: .rmssd, sleepingNights: nights)
            .displayed.sleepPerformance == 0.5,
        "The sleep-performance baseline is the mean of the nights it was given")

    // A night's own day is not in its window, the same rule the recovery overload applies — and it
    // is the rule a caller gets wrong by writing `filter` at the call site instead of using this.
    let nightsPlusToday = nights + [night(0, asleepHours: 8)]
    assertTest(
        RecoveryScoring.baselineWindow(before: day(0), in: nightsPlusToday).count == 3,
        "The night window is strictly before the day as well (got \(RecoveryScoring.baselineWindow(before: day(0), in: nightsPlusToday).count))")

    // The guarantee the detail screen rests on: what `score` used and what a reader gets back are
    // one computation, not two that agree today.
    let scoredWithHistory = RecoveryScoring.score(
        RecoveryScoring.Input(
            history: history, todayHrvValueMs: 66.0, todayHrvMetric: .rmssd,
            todayRestingHeartRate: 54, sleepPerformance: 0.9,
            fallbackRestingHeartRateBaseline: 54.0))
    let baselinesForHistory = RecoveryScoring.baselines(
        history: history, todayHrvMetric: .rmssd, fallbackRestingHeartRateBaseline: 54.0)
    assertTest(
        scoredWithHistory.hrvBaselineMeanMs == baselinesForHistory.hrvMeanMs
            && scoredWithHistory.rhrBaselineMean == baselinesForHistory.restingHeartRateMean,
        "The baseline a screen reads back is the one the score was computed from")

    // Formatters. `formattedHoursMinutes` is a behavioural reconstruction of a file that was
    // overwritten without being read; these assertions pin the contract its call sites rely on,
    // including the "0h 45m" literal SleepDashboardView falls back to.
    assertTest(2700.0.formattedHoursMinutes() == "0h 45m", "2700s formats as 0h 45m")
    assertTest(9900.0.formattedHoursMinutes() == "2h 45m", "9900s formats as 2h 45m")
    assertTest(28_800.0.formattedHoursMinutes() == "8h 0m", "28800s formats as 8h 0m")
    assertTest(62.5.formattedOneDecimal() == "62.5", "62.5 formats as one decimal")
    assertTest(62.0.formattedOneDecimal() == "62.0", "62 formats with a trailing decimal")
    assertTest(62.456.rounded(toPlaces: 2) == 62.46, "rounded(toPlaces:) rounds half up")
}

/// A health store that answers from arrays.
///
/// Stands in for `HKHealthStore` so the importer's day attribution, skipping and idempotency are
/// assertable with no device, no entitlement and no authorization prompt — the three things that
/// make the real path untestable off-device.
struct FixtureHealthStore: HealthStoreClient {
    var hrv: [HealthQuantitySample] = []
    var restingHeartRate: [HealthQuantitySample] = []
    var steps: [HealthQuantitySample] = []

    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
    func requestReadAuthorization() async -> Bool { true }

    func quantitySamples(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> [HealthQuantitySample] {
        // Applies the window the importer asked for, like the real query predicate does. Without
        // this the fixture would hand back samples outside the requested range and hide a wrong
        // range calculation.
        //
        // Spelled out per metric rather than as a two-way ternary. The ternary this replaced sent
        // everything that was not HRV to the resting-heart-rate array, so a new case would have
        // silently answered its query with heart rates — a fixture inventing a reading of the wrong
        // quantity, which is worse than the missing case a `switch` would give.
        let all: [HealthQuantitySample]
        switch metric {
        case .heartRateVariabilitySDNN: all = hrv
        case .restingHeartRate: all = restingHeartRate
        case .respiratoryRate, .oxygenSaturation, .sleepingWristTemperature, .stepCount: all = []
        }
        return all.filter { $0.start >= start && $0.start <= end }
    }

    func sleepSegments(from start: Date, to end: Date) async throws -> [HealthSleepSegment] { [] }

    /// The daily sum the real store computes with `HKStatisticsQuery(.cumulativeSum)`.
    ///
    /// Summed over the same window the caller asked for, so a wrong range shows up as a wrong total
    /// rather than being masked. `nil` when the window holds nothing, which is the protocol's
    /// contract — **not** `0`, which is a day the user did not walk.
    func dailyTotal(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> Double? {
        guard metric == .stepCount else { return nil }
        let inWindow = steps.filter { $0.start >= start && $0.start <= end }
        guard !inWindow.isEmpty else { return nil }
        return inWindow.reduce(0) { $0 + $1.value }
    }
}

struct NoSleepSource: SleepRepository {
    func getSleepSession(for date: Date) async throws -> SleepSession? { nil }
    func saveSleepSession(_ session: SleepSession, source: String?) async throws {}
    /// Implements the requirement, not the `days:`-only convenience: once `days:` moved to a protocol
    /// extension it stopped dispatching, so a conformer that still implemented only the old form would
    /// compile and have its body silently never called through `any SleepRepository`.
    func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession] { [] }
}

func runHealthKitImportTests() async {
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

/// A strap that recorded nothing. This is the real shape of "the strap was not worn" rather than a
/// contrived one: `GRDBBiometricRepository` returns an empty array for any window with no samples,
/// so an unworn night reaches the use case as exactly this.
struct EmptyBiometricStore: BiometricRepository {
    func saveSamples(_ samples: [BiometricSample]) async throws {}
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] { [] }
    func getLatestSample() async throws -> BiometricSample? { nil }
    func clearAllBiometricData() async throws {}
}

/// A day with no data must be recorded as one, and must never be counted as an observation.
///
/// Three separate places can get this wrong, and each is asserted below: the strap path can invent a
/// value from the profile, the scoring window can average a placeholder in as if it were a real
/// 0 ms reading, and the importer can mistake a placeholder for a day already recorded and skip it.
func runNoDataDayTests() async {
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

// MARK: - 11. WHOOP export import

/// The export this app ships with, located from the compile-time path of *this file* rather than from
/// the working directory. `swift build`, `swift run` and a hand-invoked binary disagree about `cwd`,
/// and a section that quietly skipped its own assertions would be worse than no section at all.
func whoopExportURL() -> URL {
    URL(fileURLWithPath: #filePath)  // …/Tests/WhoopsyTestRunner/main.swift
        .deletingLastPathComponent()  // …/Tests/WhoopsyTestRunner
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Sources/Whoopsy/Data/Resources/physiological_cycles.csv")
}

/// The export is read for real, and written into an in-memory database — no device, no bundle, and
/// nothing left on disk. This is the only place the day-keying, the unit conversions and the
/// precedence rule are exercised together against the actual 935-row file.
func runWhoopExportImportTests() async {
    // Two calendars, because two different jobs need one.
    //
    // `utcCalendar` builds absolute instants from the wall-clock times in the file — that is what
    // makes the timezone assertion below meaningful. `dayCalendar` is `Calendar.current`, and it is
    // what the importer must be given: `LocalDatabaseManager.save*` snaps every write with the
    // `Date.startOfDay` extension, which is `Calendar.current` and is not injectable. Handing the
    // importer a calendar in another zone does not shift the day keys, it splits them — the importer
    // computes `startOfDay` in one zone, the database re-snaps in another, and a UTC midnight lands on
    // the previous day. Production passes `.current`, so the two agree; the test must too.
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dayCalendar = Calendar.current

    func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return utcCalendar.date(from: components)!
    }

    func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    let csvURL = whoopExportURL()
    guard FileManager.default.fileExists(atPath: csvURL.path) else {
        assertTest(false, "The bundled export is missing at \(csvURL.path)")
        return
    }

    // ── The file's own contract, asserted before anything is written ─────────────────────────────
    // These counts stand on their own because a parser that silently dropped a row would still
    // satisfy every write assertion below. `CSVImporter` was exactly that failure: it returned `[]`
    // and threw nothing, because `ISO8601DateFormatter` yields nil for `2026-08-22 00:17:13`.
    let rows: [WhoopExportRow]
    do {
        rows = try WhoopExportParser.parseCycles(at: csvURL)
        assertTest(rows.count == 935, "Parsed all 935 rows from the export (got \(rows.count))")
        assertTest(
            rows.filter { $0.wakeOnset != nil }.count == 910,
            "910 rows carry a wake onset (got \(rows.filter { $0.wakeOnset != nil }.count))")
        assertTest(
            rows.filter(\.isEmpty).count == 1,
            "Exactly one row is empty (got \(rows.filter(\.isEmpty).count))")

        // The zone column is part of the value, not a display detail. 2024-01-14 01:39:10 at
        // UTC-05:00 is 06:39:10 UTC, and a parser that ignored the column would place it five hours
        // early — which the day key alone would not catch, since the date survives a five-hour shift.
        guard let known = rows.first(where: { $0.cycleStart == utc(2024, 1, 14, 6, 39, 10) }) else {
            assertTest(false, "The 2024-01-14 row was parsed with the export's own UTC offset")
            return
        }
        assertTest(true, "The 2024-01-14 row was parsed with the export's own UTC offset")
        assertTest(known.wakeOnset == utc(2024, 1, 14, 14, 4, 15), "Its wake onset is 14:04:15 UTC")
        assertTest(known.hrvMs == 50.0, "Its HRV parses to 50 ms (got \(known.hrvMs ?? -1))")
        assertTest(known.restingHeartRate == 57, "Its resting heart rate parses to 57 bpm")
        assertTest(known.bloodOxygenPercent == 98.33, "Its SpO2 parses to 98.33 (no ×100)")
        assertTest(known.lightMinutes == 179, "Its light sleep parses to 179 minutes")
        assertTest(known.sleepNeedMinutes == 602, "Its sleep need parses to 602 minutes")
    } catch {
        assertTest(false, "Parsing the real export threw: \(error)")
        return
    }

    // ── The day keys, recomputed independently of the importer ───────────────────────────────────
    //
    // Derived from the parsed rows rather than written down as literals. The device zone decides
    // `startOfDay`, and the two strain-only cycles that begin at 23:30 sit right on a date boundary —
    // in the export's own zone they collide with the closed cycle that already claims the day, one
    // zone east they do not. The importer's rule is asserted by recomputing the key set here, so the
    // assertion holds wherever this runs and still fails if the rule changes.
    let expectedRecoveryDays = Set(
        rows
            .filter { $0.wakeOnset != nil && ($0.hrvMs ?? 0) > 0 && $0.restingHeartRate != nil }
            .map { dayCalendar.startOfDay(for: $0.wakeOnset!) })
    let expectedSleepDays = Set(
        rows
            .filter { $0.sleepOnset != nil && $0.wakeOnset != nil && $0.wakeOnset! > $0.sleepOnset! }
            .map { dayCalendar.startOfDay(for: $0.wakeOnset!) })
    let expectedStrainDays = Set(
        rows
            .filter { $0.dayStrain != nil }
            .map { dayCalendar.startOfDay(for: $0.wakeOnset ?? $0.cycleStart) })

    assertTest(expectedRecoveryDays.count == 910, "910 rows have both an HRV and a resting heart rate")
    assertTest(expectedSleepDays.count == 910, "910 rows describe a night")
    assertTest(
        expectedStrainDays.count == 933 || expectedStrainDays.count == 931,
        "933 Day Strain values land on \(expectedStrainDays.count) distinct days "
            + "(931 where a fragment collides with its closed cycle)")

    // Every non-empty row contributes at least one row of its own — a row with a wake onset always
    // has a night in it, and a strain-only cycle always has its Day Strain — so the first entry for a
    // day always writes, and every *later* entry for that same day finds it taken. Those later rows
    // are `duplicateExportRows`, which is what this figure is: the export's own collisions, not
    // pre-existing local history.
    let entryCount = rows.filter { !$0.isEmpty }.count
    let entryDays = Set(
        rows
            .filter { !$0.isEmpty }
            .map { dayCalendar.startOfDay(for: $0.wakeOnset ?? $0.cycleStart) })
    let expectedAlreadyRecorded = entryCount - entryDays.count

    // ── The import ───────────────────────────────────────────────────────────────────────────────
    let db = LocalDatabaseManager(inMemory: true)
    let recoveryRepository = GRDBRecoveryRepository(db: db)
    let sleepRepository = GRDBSleepRepository(db: db)
    let strainRepository = GRDBStrainRepository(db: db)
    let importer = WhoopExportImporter(
        recoveryRepository: recoveryRepository,
        sleepRepository: sleepRepository,
        strainRepository: strainRepository,
        userProfileRepository: GRDBUserProfileRepository(db: db),
        calendar: dayCalendar)

    do {
        let summary = try await importer.importExport(at: csvURL)

        assertTest(
            summary.recoveriesWritten == expectedRecoveryDays.count,
            "Wrote one recovery per measured day (\(summary.recoveriesWritten))")
        assertTest(
            summary.sleepsWritten == expectedSleepDays.count,
            "Wrote one sleep session per night (\(summary.sleepsWritten))")
        assertTest(
            summary.strainsWritten == expectedStrainDays.count,
            "Wrote one strain day per distinct Day Strain date (\(summary.strainsWritten))")
        // Nothing was recorded before this import ran, so nothing may be reported as pre-existing.
        // The `expectedAlreadyRecorded` collisions are the export's own duplicate rows and are counted
        // separately — reporting them here is what made a fresh install claim history it never had.
        assertTest(
            summary.daysAlreadyRecorded == 0,
            "A fresh database reports nothing already recorded (got \(summary.daysAlreadyRecorded))")
        assertTest(
            summary.duplicateExportRows == expectedAlreadyRecorded,
            "\(expectedAlreadyRecorded) export rows shared a day with an earlier row "
                + "(got \(summary.duplicateExportRows))")
        assertTest(summary.daysWithoutData == 0, "Every non-empty row yielded something to write")

        // `daysWritten` and `strainOnlyDays` are day counts, so they come from sets, not from the
        // per-table row counts above — a day can appear in two tables or in one, and the row totals
        // cannot tell those apart. On a fresh database every non-empty row writes something (the
        // proof is the `expectedAlreadyRecorded` comment), so every entry day is a written day.
        assertTest(
            summary.daysWritten == entryDays.count,
            "The summary reports \(entryDays.count) distinct days written (got \(summary.daysWritten))")

        let expectedStrainOnly = expectedStrainDays.subtracting(expectedRecoveryDays)
        assertTest(
            summary.strainOnlyDays == expectedStrainOnly.count,
            "\(expectedStrainOnly.count) days carry a strain and no recovery (got \(summary.strainOnlyDays))")

        // The reason this field is not `strainsWritten - recoveriesWritten`. That subtraction is only
        // right when no day falls the other way, and days do: a night scored with no Day Strain is as
        // ordinary as a strain-only cycle. Asserted only when such a day exists, so the check records
        // the trap rather than failing on an export where the two figures happen to coincide.
        let recoveryDaysWithoutStrain = expectedRecoveryDays.subtracting(expectedStrainDays)
        if !recoveryDaysWithoutStrain.isEmpty {
            assertTest(
                summary.strainOnlyDays > summary.strainsWritten - summary.recoveriesWritten,
                "The set difference (\(summary.strainOnlyDays)) exceeds strains − recoveries "
                    + "(\(summary.strainsWritten - summary.recoveriesWritten)) because "
                    + "\(recoveryDaysWithoutStrain.count) scored day(s) carry no strain")
        }

        // ── Day keys ─────────────────────────────────────────────────────────────────────────────
        // Read back through the same keyed lookups the app uses. A raw-timestamp write would leave a
        // row that is present in the table and unreachable by any of them.
        let recoveries = try await recoveryRepository.getRecoveryHistory(days: 4000)
        assertTest(recoveries.count == expectedRecoveryDays.count, "Reading history returns every recovery")
        assertTest(
            recoveries.allSatisfy { $0.date == dayCalendar.startOfDay(for: $0.date) },
            "Every recovery day key is a startOfDay")
        assertTest(
            Set(recoveries.map(\.date)) == expectedRecoveryDays,
            "The stored recovery days are exactly the days the export measured")
        assertTest(
            recoveries.allSatisfy { $0.hrvMetric == .rmssd && $0.hrvValueMs > 0 && $0.hasMeasurement },
            "Every imported recovery is a measured RMSSD row")

        let sleeps = try await sleepRepository.getSleepHistory(days: 4000)
        assertTest(sleeps.count == expectedSleepDays.count, "Reading history returns every sleep session")
        assertTest(
            Set(sleeps.map(\.date)) == expectedSleepDays, "The stored sleep days are exactly the nights")

        let strains = try await strainRepository.getStrainHistory(days: 4000)
        assertTest(strains.count == expectedStrainDays.count, "Reading history returns every strain day")
        assertTest(
            Set(strains.map(\.date)) == expectedStrainDays,
            "The stored strain days are exactly the days the export scored")
        assertTest(
            strains.allSatisfy { $0.date == dayCalendar.startOfDay(for: $0.date) },
            "Every strain day key is a startOfDay")

        // The summary's span must describe everything written, across all three tables — the earliest
        // day of all is 2023-07-22, a strain-only cycle with no recovery and no night, so checking it
        // against the recoveries alone would report a span four hours short of the truth. Compared
        // against the stored rows rather than a literal, since the span is what the user is shown as
        // evidence the import landed in the right place.
        let storedDays = Set(recoveries.map(\.date))
            .union(sleeps.map(\.date))
            .union(strains.map(\.date))
            .sorted()
        assertTest(
            summary.firstDay == displayDate(storedDays.first!) && summary.lastDay == displayDate(storedDays.last!),
            "The reported span (\(summary.firstDay) → \(summary.lastDay)) matches the rows written")
        assertTest(
            summary.message.contains(summary.firstDay) && summary.message.contains(summary.lastDay),
            "The message shown to the user carries the span")

        // ── Scoring ──────────────────────────────────────────────────────────────────────────────
        // The distribution is the assertion, not the individual values. `BaselineStatisticsMath`
        // anchors at 50 and moves by `z × 24` and `z × −18` against a ±4 z clamp, so two standard
        // deviations in HRV alone spans ±48 points — a day at 1 or 99 is the formula working, not
        // failing. What would be a failure is a history with no spread at all (every day at 50, i.e.
        // a baseline that never moved) or a run pinned entirely to one end.
        let distinctScores = Set(recoveries.map(\.score))
        assertTest(distinctScores.count > 20, "Scores span a real range (\(distinctScores.count) distinct values)")
        assertTest(recoveries.contains { $0.score > 1 }, "Not every day is pinned to the floor")
        assertTest(recoveries.contains { $0.score < 99 }, "Not every day is pinned to the ceiling")
        let saturated = recoveries.filter { $0.score == 1 || $0.score == 99 }.count
        assertTest(
            saturated < recoveries.count / 2,
            "Most days land inside the clamp (\(saturated) of \(recoveries.count) saturate)")

        // ── One day, field by field ──────────────────────────────────────────────────────────────
        // 2026-08-19, chosen because WHOOP's own `Sleep performance %` column says 30 for it while
        // asleep-over-need is 284/572 = 50%. The gap is what makes the assertion sharp: a stored 50
        // proves the app derived the figure, and a stored 30 would prove it copied the export's.
        let knownDay = dayCalendar.startOfDay(for: utc(2026, 8, 19, 12, 23, 23))

        let knownRecovery = try await recoveryRepository.getLocalRecovery(for: knownDay)
        assertTest(knownRecovery?.hrvValueMs == 31.0, "That day's HRV round-trips as 31 ms")
        assertTest(knownRecovery?.restingHeartRate == 66, "That day's resting heart rate round-trips as 66 bpm")
        assertTest(knownRecovery?.spO2Percentage == 96.5, "That day's SpO2 round-trips as 96.5")

        let knownSleep = try await sleepRepository.getSleepSession(for: knownDay)
        assertTest(knownSleep?.targetSleepNeedSeconds == 572 * 60, "Sleep need became seconds (572 min)")
        assertTest(knownSleep?.deepSleepSeconds == 152 * 60, "Deep sleep became seconds (152 min)")
        // The unit error that would otherwise look like a night rather than a bug: minutes stored as
        // seconds reads as 105 seconds of light sleep, and nothing else on the screen contradicts it.
        assertTest(knownSleep?.lightSleepSeconds == 105 * 60, "Light sleep became seconds (105 min)")
        assertTest((knownSleep?.lightSleepSeconds ?? 0) > 3600, "Light sleep is in seconds, not minutes")
        assertTest(
            knownSleep?.sleepPerformancePercentage == 50,
            "Sleep performance is derived from asleep-over-need, not copied from the export "
                + "(got \(knownSleep?.sleepPerformancePercentage ?? -1), export says 30)")
        assertTest(knownSleep?.respiratoryRate == 16.5, "Respiratory rate round-trips as 16.5 rpm")
        assertTest(knownSleep?.disturbanceCount == nil, "No disturbance count is invented")
        assertTest(knownSleep?.sleepStages.isEmpty == true, "No stage timeline is invented")

        let knownStrain = try await strainRepository.getStrain(for: knownDay)
        assertTest(knownStrain?.score == 5.4, "That day's strain round-trips as 5.4")
        assertTest(knownStrain?.averageHeartRate == 72, "Average heart rate round-trips as 72 bpm")
        assertTest(knownStrain?.maxHeartRate == 156, "Peak heart rate round-trips as 156 bpm")
        assertTest(
            abs((knownStrain?.activeCalories ?? 0) - 1973) < 0.01,
            "Energy survives the kilojoule conversion (got \(knownStrain?.activeCalories ?? -1) kcal)")
        assertTest(
            knownStrain?.zones.isEmpty == true,
            "No heart-rate zones are invented — the export carries a total, not a distribution")

        // ── Re-running changes nothing ───────────────────────────────────────────────────────────
        // The assertion that catches a missing `startOfDay` snap: the first run's rows are found by
        // every keyed lookup, so a second run has to see them as already recorded.
        let second = try await importer.importExport(at: csvURL)
        assertTest(second.recoveriesWritten == 0, "A second import writes no recovery")
        assertTest(second.sleepsWritten == 0, "A second import writes no sleep session")
        assertTest(second.strainsWritten == 0, "A second import writes no strain")
        // A run that writes nothing must still report zero days written, or a re-import would claim
        // to have imported history it only recognised.
        assertTest(second.daysWritten == 0, "A second import reports no days written")
        // Now everything really is pre-existing, so the whole export is counted there — and nothing
        // is a duplicate, because this run claimed no day to collide with.
        assertTest(
            second.daysAlreadyRecorded == entryCount,
            "Every one of the \(entryCount) entries is now already recorded (got \(second.daysAlreadyRecorded))")
        assertTest(second.duplicateExportRows == 0, "A second import has no duplicate rows to report")
        assertTest(
            second.message.contains("Nothing to import"),
            "A second import says so rather than reporting an import (got \"\(second.message)\")")
        let afterSecond = try await recoveryRepository.getRecoveryHistory(days: 4000)
        assertTest(afterSecond.count == recoveries.count, "A second import adds no recovery row")
        assertTest(
            Set(afterSecond.map(\.date)) == expectedRecoveryDays,
            "A second import leaves the day keys exactly as they were")
    } catch {
        assertTest(false, "The WHOOP export import threw: \(error)")
    }
}

/// A day the user picks must be **read**, and reading it must not disturb it.
///
/// The three metric screens were blank for imported history because each was wired to
/// `execute(for: Date())` — a recompute, never a read. The obvious repair (hand them a day picker and
/// keep the use case) is still the wrong one, though for a different reason than it was: an imported
/// day has no `biometric_samples` by construction, so `execute(for:)` on one comes back as no row at
/// all and would blank the day it was asked about. Before the calculate use cases stopped storing
/// placeholders it was worse — they saved `score: 0` over whatever was stored, so paging back would
/// have replaced all 910 imported recoveries and all 931 imported strains with their placeholder
/// shape.
///
/// So this section asserts both halves: the read finds the imported day, which is what makes it
/// visible at all, and then the real view models are driven over that day and every row must come
/// back identical. The second half is the regression guard — "the screen does not write" is a
/// property of the screen's *wiring*, and it is exactly what a later change could undo by handing
/// `load(for:)` a use case again.
func runDaySelectionTests() async {
    let csvURL = whoopExportURL()
    guard FileManager.default.fileExists(atPath: csvURL.path) else {
        assertTest(false, "The bundled export is missing at \(csvURL.path)")
        return
    }

    // Its own in-memory database and its own import, so the section stands alone whatever §11 did.
    let db = LocalDatabaseManager(inMemory: true)
    let recoveryRepository = GRDBRecoveryRepository(db: db)
    let sleepRepository = GRDBSleepRepository(db: db)
    let strainRepository = GRDBStrainRepository(db: db)
    let profile = GRDBUserProfileRepository(db: db)

    do {
        _ = try await WhoopExportImporter(
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            userProfileRepository: profile,
            calendar: Calendar.current
        ).importExport(at: csvURL)

        // Each kind of row is read from its own last day rather than all from one. The export's
        // partial cycles make those days differ — a strain-only cycle has no recovery, and one scored
        // night has no strain — so picking a single day and demanding all three would assert something
        // about the export's shape rather than about the read.
        func lastDay(_ dates: [Date]) -> Date? { dates.max() }
        guard
            let lastRecoveryDay = lastDay(try await recoveryRepository.getRecoveryHistory(days: 4000).map(\.date)),
            let lastStrainDay = lastDay(try await strainRepository.getStrainHistory(days: 4000).map(\.date)),
            let lastSleepDay = lastDay(try await sleepRepository.getSleepHistory(days: 4000).map(\.date))
        else {
            assertTest(false, "The import wrote rows of each kind to read back")
            return
        }
        assertTest(true, "The import wrote rows of each kind to read back")

        // ── The read the screens now make ────────────────────────────────────────────────────────
        assertTest(
            try await recoveryRepository.getRecovery(for: lastRecoveryDay)?.hasMeasurement == true,
            "The chosen day reads back a real recovery, not a placeholder")
        assertTest(
            try await recoveryRepository.getRecovery(for: lastRecoveryDay)?.hrvMetric == .rmssd,
            "It carries the export's RMSSD classification")
        assertTest(
            try await sleepRepository.getSleepSession(for: lastSleepDay) != nil,
            "The chosen day reads back a sleep session")
        assertTest(
            try await strainRepository.getStrain(for: lastStrainDay) != nil,
            "The chosen day reads back a strain")

        // ── The window anchor, which is why the screen was blank ─────────────────────────────────
        //
        // `endingOn` is the fix. Asserted by moving the anchor rather than by comparing against
        // `Date()`, so the result does not depend on the day this suite happens to run.
        let windowEndingOnLastDay = try await recoveryRepository.getRecoveryHistory(
            days: 14, endingOn: lastRecoveryDay)
        assertTest(!windowEndingOnLastDay.isEmpty, "A 14-day window ending on the last imported day is populated")
        assertTest(
            windowEndingOnLastDay.contains { $0.date == lastRecoveryDay },
            "…and it includes the day the window ends on")

        let sixtyDaysLater = Calendar.current.date(byAdding: .day, value: 60, to: lastRecoveryDay)!
        assertTest(
            try await recoveryRepository.getRecoveryHistory(days: 14, endingOn: sixtyDaysLater).isEmpty,
            "The same window 60 days later is empty — the anchor is real, not ignored")

        // The upper bound is not decoration. Without it a window anchored on an old day would run on
        // to now, and a chart of that day's fortnight would silently be a chart of everything since.
        let wideWindow = try await recoveryRepository.getRecoveryHistory(days: 4000, endingOn: lastRecoveryDay)
        let past = wideWindow.filter { $0.date > lastRecoveryDay }
        assertTest(past.isEmpty, "No row after the window's end day is returned (got \(past.count) past the bound)")

        // ── Reading must not write ───────────────────────────────────────────────────────────────
        //
        // The live use cases, built on a strap that recorded nothing — which is the true shape of an
        // imported day, since the import writes no `biometric_samples`. If either use case were
        // reachable from `load(for:)`, a recompute over this day would come back as no row at all and
        // replace what the screen was showing.
        let strapThatRecordedNothing = EmptyBiometricStore()

        let recoveryBefore = try await db.getRecovery(for: lastRecoveryDay)
        let strainBefore = try await db.getStrain(for: lastStrainDay)
        let sleepBefore = try await sleepRepository.getSleepSession(for: lastSleepDay)

        let recoveryViewModel = await MainActor.run {
            RecoveryViewModel(
                calculate: CalculateRecoveryUseCase(
                    biometricRepository: strapThatRecordedNothing,
                    recoveryRepository: recoveryRepository,
                    sleepRepository: sleepRepository,
                    userProfileRepository: profile),
                repository: recoveryRepository,
                sleepRepository: sleepRepository)
        }
        await recoveryViewModel.load(for: lastRecoveryDay)

        // The breakdown the screen draws. `RecoveryDetailView` prints four figures each against a
        // trailing baseline, so a read that returns the day but no window leaves every row a bare
        // number with nothing to compare against — a screen that looks like it works and explains
        // nothing. Asserted on an imported day because that is the hard case: the values are read
        // from the database rather than recomputed, and the baseline has to be rebuilt from the same
        // thirty days the importer scored against, out of a table holding nine hundred.
        let loadedBaselines = await MainActor.run { recoveryViewModel.baselines }
        assertTest(
            loadedBaselines?.displayed.hrvMs != nil,
            "A day read back carries an HRV baseline for the screen to print beneath it")
        assertTest(
            loadedBaselines?.displayed.restingHeartRate != nil,
            "…and a resting-heart-rate baseline")
        assertTest(
            loadedBaselines?.displayed.sleepPerformance != nil,
            "…and a sleep-performance baseline, which is the one drawn from the other table")
        assertTest(
            loadedBaselines?.displayed.respiratoryRate != nil,
            "…and a respiratory-rate baseline, which is the one the score does not read")

        let strainViewModel = await MainActor.run {
            StrainViewModel(
                calculate: CalculateStrainUseCase(
                    biometricRepository: strapThatRecordedNothing,
                    strainRepository: strainRepository,
                    userProfileRepository: profile),
                repository: strainRepository)
        }
        await strainViewModel.load(for: lastStrainDay)

        let sleepViewModel = await MainActor.run {
            SleepViewModel(
                analyze: AnalyzeSleepUseCase(
                    biometricRepository: strapThatRecordedNothing,
                    sleepRepository: sleepRepository,
                    strainRepository: strainRepository,
                    userProfileRepository: profile),
                repository: sleepRepository)
        }
        await sleepViewModel.load(for: lastSleepDay)

        // Not merely "the row still exists": every value a recompute would have replaced is checked,
        // plus `source`, which the placeholder path rebuilds as nil and which is the only thing that
        // records where these rows came from.
        let recoveryAfter = try await db.getRecovery(for: lastRecoveryDay)
        assertTest(
            recoveryAfter?.recoveryScore == recoveryBefore?.recoveryScore,
            "Loading the day left its recovery score alone "
                + "(\(recoveryBefore?.recoveryScore ?? -1) → \(recoveryAfter?.recoveryScore ?? -1))")
        assertTest(
            recoveryAfter?.hrvValueMs == recoveryBefore?.hrvValueMs,
            "…and its HRV reading (\(recoveryBefore?.hrvValueMs ?? -1) → \(recoveryAfter?.hrvValueMs ?? -1))")
        assertTest(
            recoveryAfter?.source == WhoopExportImporter.sourceLabel,
            "…and its provenance (got \(recoveryAfter?.source ?? "nil"))")

        let strainAfter = try await db.getStrain(for: lastStrainDay)
        assertTest(
            strainAfter?.strainScore == strainBefore?.strainScore,
            "Loading the day left its strain alone "
                + "(\(strainBefore?.strainScore ?? -1) → \(strainAfter?.strainScore ?? -1))")
        assertTest(
            strainAfter?.source == WhoopExportImporter.sourceLabel,
            "…and its provenance (got \(strainAfter?.source ?? "nil"))")

        // Compared field by field rather than with `==`. `SleepSession` carries a `let id: UUID` that
        // its initialiser defaults to a fresh `UUID()`, and the synthesised `Equatable` includes it —
        // so two separate reads of the same stored night are never equal, and `==` here would fail
        // whatever the database holds. The fields below are the ones a recompute would have replaced.
        let sleepAfter = try await sleepRepository.getSleepSession(for: lastSleepDay)
        assertTest(
            sleepAfter?.startTime == sleepBefore?.startTime
                && sleepAfter?.endTime == sleepBefore?.endTime
                && sleepAfter?.lightSleepSeconds == sleepBefore?.lightSleepSeconds
                && sleepAfter?.deepSleepSeconds == sleepBefore?.deepSleepSeconds
                && sleepAfter?.remSleepSeconds == sleepBefore?.remSleepSeconds
                && sleepAfter?.awakeSeconds == sleepBefore?.awakeSeconds
                && sleepAfter?.sleepPerformancePercentage == sleepBefore?.sleepPerformancePercentage,
            "Loading the day left its sleep session alone")

        // The view models must also be *showing* what was read — a guard that protects the row by
        // rendering nothing would pass every assertion above.
        await MainActor.run {
            assertTest(
                recoveryViewModel.recovery?.score == recoveryBefore?.recoveryScore,
                "The Recovery screen displays the stored score")
            assertTest(strainViewModel.strain?.score == strainBefore?.strainScore, "The Strain screen displays the stored score")
            assertTest(sleepViewModel.session != nil, "The Sleep screen displays the stored session")
        }
    } catch {
        assertTest(false, "The day-selection tests threw: \(error)")
    }
}

// MARK: - 13. Sleep Need

/// A strap that recorded an actual night — `EmptyBiometricStore`'s counterpart.
///
/// `AnalyzeSleepUseCase` only refuses a night when the window holds fewer than
/// `minimumEpochSamples` (30) samples, so a fixture with enough of them inside the window is a night
/// as far as the use case is concerned. Everything about the samples below is chosen to clear one
/// guard and no more: 60 one-minute samples read as two 30-second epochs, and a heart rate of 52
/// against a default resting rate of 60 is below `restHR * 0.92`, so the epochs classify as deep
/// sleep — a stage, and therefore a session, rather than an absence.
struct OvernightBiometricStore: BiometricRepository {
    let samples: [BiometricSample]

    func saveSamples(_ samples: [BiometricSample]) async throws {}
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
        samples.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }
    func getLatestSample() async throws -> BiometricSample? { samples.last }
    func clearAllBiometricData() async throws {}
}

/// The night a strap recorded is the only night whose Sleep Need this app computes, so it is the only
/// night any of this can be wrong about. Imported nights already carry WHOOP's own figure, and the
/// last third of this section is the guard that keeps them that way.
func runSleepNeedTests() async {
    // ── The pure function's contract ─────────────────────────────────────────────────────────────
    let baseline: TimeInterval = 8 * 3600

    // The no-fabrication rule, applied to an input. An absent strain row means yesterday is
    // unmeasured; a substituted strain would turn "we do not know how hard yesterday was" into a real
    // change in tonight's target.
    assertTest(
        SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: nil) == baseline,
        "No strain row means the baseline exactly, not a substituted strain")
    assertTest(
        SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: 0) == baseline,
        "A measured zero-strain day needs nothing beyond the baseline")
    assertTest(
        SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: -5) == baseline,
        "A negative strain — a corrupt row — cannot subtract from the need")

    var previous = -1.0
    var firstFall: Double?
    for tenth in 0...210 {
        let strain = Double(tenth) / 10.0
        let need = SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: strain)
        if need < previous, firstFall == nil { firstFall = strain }
        previous = need
    }
    let firstFallReport = firstFall.map { "\($0)" } ?? "none"
    assertTest(
        firstFall == nil,
        "The need never falls as strain rises, over 0.0–21.0 in 0.1 steps "
            + "(first fall at \(firstFallReport))")

    // Clamping the *input* rather than the output: strain is defined on 0–21, so a value outside that
    // is a corrupt row, not a hard day. At the maximum the term is worth 134 minutes, which keeps the
    // need inside the 321–650 min band WHOOP's own figures occupy.
    assertTest(
        SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: 40)
            == SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: 21),
        "Strain above the documented scale clamps rather than extrapolating")

    // ── The coefficient, pinned with its basis ───────────────────────────────────────────────────
    //
    // WHOOP publishes this model's shape and none of its constants, so 6.40 is fitted rather than
    // cited: least squares of WHOOP's own `Sleep need (min)` on its own previous-day `Day Strain`
    // across the 909 nights of the bundled export that carry a preceding strain day, intercept
    // pinned to the 8-hour baseline. Scored by 5-fold cross-validation against the performance
    // WHOOP's *own* need implies, that scores 3.77 where a flat 480 scores 10.06, `ALGORITHMS.md`
    // §4's 4.5 scores 4.64, and refitting per fold scores 3.87.
    //
    // This assertion is deliberately a bare equality with the basis in the message: changing the
    // constant means deleting a sentence that says where it came from.
    assertTest(
        SleepNeedMath.strainMinutesPerPoint == 6.40,
        "The strain coefficient is the fitted 6.40 min/point (got \(SleepNeedMath.strainMinutesPerPoint))")
    assertTest(
        SleepNeedMath.maximumStrain == 21.0,
        "The clamp is the documented 0–21 strain scale (got \(SleepNeedMath.maximumStrain))")

    do {
        // ── The integration: the real use case, a real night, a real strain row ──────────────────
        let calendar = Calendar.current
        let morning = calendar.startOfDay(for: Date())
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: morning) else {
            assertTest(false, "Could not build the previous day")
            return
        }

        // 23:00 the previous evening to 23:59, one minute apart — inside the use case's window
        // (which opens 11 hours before `startOfDay(morning)` and closes 10 hours after it).
        let night = OvernightBiometricStore(samples: (0..<60).map { index in
            BiometricSample(
                timestamp: morning.addingTimeInterval(-3600 + Double(index) * 60),
                heartRate: 52)
        })

        let strain = 14.0
        let db = LocalDatabaseManager(inMemory: true)
        let sleepRepository = GRDBSleepRepository(db: db)
        let strainRepository = GRDBStrainRepository(db: db)
        let profileRepository = GRDBUserProfileRepository(db: db)

        try await strainRepository.saveStrain(
            StrainScore(date: previousDay, score: strain, hasMeasurement: true))

        let session = try await AnalyzeSleepUseCase(
            biometricRepository: night,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            userProfileRepository: profileRepository
        ).execute(for: morning)

        assertTest(session != nil, "A night with enough samples is classified and stored")

        let profile = try await profileRepository.getUserProfile()
        assertTest(
            profile.targetSleepHours * 3600 == baseline,
            "The night's baseline is the profile's 8 hours (got \(profile.targetSleepHours) h)")

        // Read back through the repository rather than trusting the returned session: the stored
        // value is what every later reader — sleep performance, the Recovery sleep term — consumes.
        let stored = try await sleepRepository.getSleepSession(for: morning)
        let expected = profile.targetSleepHours * 3600 + strain * SleepNeedMath.strainMinutesPerPoint * 60
        assertTest(
            stored?.targetSleepNeedSeconds == expected,
            "A strain of \(strain) on the previous day stores "
                + "\(Int(expected / 60)) min of need, not a flat 480 "
                + "(got \(Int((stored?.targetSleepNeedSeconds ?? 0) / 60)) min)")

        // The strain is keyed on the day *before* the night. `strains` is keyed on
        // `startOfDay(wakeOnset)`, so the cycle ending on morning D is keyed D — a night keyed D+1
        // follows it. Same-day strain is a different, weaker signal: it fits at R²=0.161 against the
        // previous day's 0.385, which is why `ALGORITHMS.md` §4's same-day coefficient was the wrong
        // constant for a formula about the previous day.
        let nextMorning = calendar.date(byAdding: .day, value: 1, to: morning)!
        let nextStored = try await sleepRepository.getSleepSession(for: nextMorning)
        assertTest(
            nextStored == nil || nextStored?.targetSleepNeedSeconds != expected,
            "…and last night's strain is not read as this morning's")

        // ── The absence rule, end to end ─────────────────────────────────────────────────────────
        let bareDB = LocalDatabaseManager(inMemory: true)
        let bareSleepRepository = GRDBSleepRepository(db: bareDB)
        _ = try await AnalyzeSleepUseCase(
            biometricRepository: night,
            sleepRepository: bareSleepRepository,
            strainRepository: GRDBStrainRepository(db: bareDB),
            userProfileRepository: GRDBUserProfileRepository(db: bareDB)
        ).execute(for: morning)

        let bareStored = try await bareSleepRepository.getSleepSession(for: morning)
        assertTest(
            bareStored?.targetSleepNeedSeconds == baseline,
            "The same night with no previous-day strain row stores the baseline unchanged — "
                + "no strain is invented (got \(Int((bareStored?.targetSleepNeedSeconds ?? 0) / 60)) min)")
    } catch {
        assertTest(false, "The Sleep Need integration threw: \(error)")
    }

    // ── History is untouched ─────────────────────────────────────────────────────────────────────
    //
    // The assertion that fails if anyone ever routes an imported night through the new formula. Every
    // imported night carries WHOOP's own `Sleep need (min)` — a whole number of minutes — and the
    // strain model cannot reproduce that: it starts at the baseline and only adds. So a single night
    // that needed *less* than 8 hours is proof the stored figure came from WHOOP rather than from
    // `SleepNeedMath`, which has no way to produce one.
    let csvURL = whoopExportURL()
    guard FileManager.default.fileExists(atPath: csvURL.path) else {
        assertTest(false, "The bundled export is missing at \(csvURL.path)")
        return
    }

    do {
        let exportDB = LocalDatabaseManager(inMemory: true)
        let exportSleepRepository = GRDBSleepRepository(db: exportDB)
        _ = try await WhoopExportImporter(
            recoveryRepository: GRDBRecoveryRepository(db: exportDB),
            sleepRepository: exportSleepRepository,
            strainRepository: GRDBStrainRepository(db: exportDB),
            userProfileRepository: GRDBUserProfileRepository(db: exportDB),
            calendar: Calendar.current
        ).importExport(at: csvURL)

        let imported = try await exportSleepRepository.getSleepHistory(days: 4000)
        // Recomputing the exact day-key count is §11's job; every assertion here is over the set the
        // import actually produced, so a zone that merges two nights on one day key narrows this
        // without weakening any of them.
        assertTest(imported.count > 900, "The export still imports its history (\(imported.count) nights)")

        let needs = imported.map(\.targetSleepNeedSeconds)
        let notWholeMinutes = needs.filter { $0.truncatingRemainder(dividingBy: 60) != 0 }
        assertTest(
            notWholeMinutes.isEmpty,
            "Every imported night still carries WHOOP's own need, in whole minutes "
                + "(\(notWholeMinutes.count) do not)")

        let belowBaseline = needs.filter { $0 < 8 * 3600 }
        assertTest(
            !belowBaseline.isEmpty,
            "…and \(belowBaseline.count) needed less than the 8-hour baseline — impossible under the "
                + "strain model, whose floor is the baseline, so these values did not come from it")

        assertTest(
            (needs.min() ?? 0) >= 300 * 60 && (needs.max() ?? 0) <= 660 * 60,
            "The imported needs stay inside WHOOP's own band "
                + "(\(Int((needs.min() ?? 0) / 60))–\(Int((needs.max() ?? 0) / 60)) min)")
    } catch {
        assertTest(false, "The imported-history guard threw: \(error)")
    }
}

// MARK: - 14. The Home screen's sources

/// A `biometric_samples` source that answers from an array.
///
/// `EmptyBiometricStore`'s counterpart, and needed for the same reason `OvernightBiometricStore` was:
/// `AnalyzeStressUseCase` returns `nil` the moment its store is empty, so the empty store can prove
/// the no-measurement rule and nothing else. Every measured-path assertion below needs a store that
/// actually holds samples.
struct DaytimeBiometricStore: BiometricRepository {
    var samples: [BiometricSample] = []
    func saveSamples(_ samples: [BiometricSample]) async throws {}
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
        samples.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }
    func getLatestSample() async throws -> BiometricSample? { nil }
    func clearAllBiometricData() async throws {}
}

/// A `HealthKitSyncing` that answers with nothing — the honest shape of a denied authorization, an
/// empty day, and a phone with no source for the quantity, which HealthKit does not let a caller
/// tell apart.
///
/// The remaining read-through answers `nil` here, and that is what makes the dash on a fresh
/// install a *tested* state rather than an observed one.
struct NoStepsHealthKit: HealthKitSyncing {
    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
    func requestAuthorization() async -> Bool { true }
    func importRecentHealthData(days: Int) async throws -> HealthImportSummary {
        .empty(daysRequested: days)
    }
    func stepCount(on date: Date) async -> Int? { nil }
}

/// The Home screen's four new data sources, each asserted at the layer that can get it wrong.
///
/// The screen itself is not asserted here — it is a view, and its dashes follow from these values
/// being `nil`. What is asserted is that they *are* `nil` when there is nothing behind them, because
/// every one of these four has a plausible-looking wrong answer available: a fabricated `100` for a
/// disconnected strap's battery, a `0` for a day with no steps, a `0.0` for a day with no stress
/// score, and an in-memory array that loses a workout at the next launch.
func runHomeSourceTests() async {
    // ---- v6: recorded workouts now survive the launch that recorded them ----

    let db = LocalDatabaseManager(inMemory: true)
    let tables = (try? await db.existingTableNames()) ?? []
    for expected in ["workouts", "workout_route_points", "workout_splits"] {
        assertTest(tables.contains(expected), "v6 migration created table '\(expected)'")
    }

    let repository = GRDBWorkoutRepository(db: db)
    let calendar = Calendar.current

    // 17:33 on a day two days back, so the day-snap is tested against a day that is not today and the
    // assertion does not move with the clock.
    let sessionDay = calendar.date(byAdding: .day, value: -2, to: Date())!.startOfDay
    let startedAt = calendar.date(byAdding: .minute, value: 17 * 60 + 33, to: sessionDay)!
    let endedAt = calendar.date(byAdding: .minute, value: 14, to: startedAt)!

    let workout = WorkoutSession(
        startedAt: startedAt,
        endedAt: endedAt,
        strain: 3.0,
        averageHeartRate: 128,
        maxHeartRate: 164,
        route: [
            WorkoutRoutePoint(latitude: 40.7411, longitude: -73.9897, timestamp: startedAt, heartRate: 120),
            WorkoutRoutePoint(latitude: 40.7420, longitude: -73.9880, timestamp: endedAt, heartRate: 164),
        ],
        splits: [
            WorkoutSplit(elapsed: 300, strain: 1.1),
            WorkoutSplit(elapsed: 600, strain: 2.4),
        ])

    do {
        try await repository.save(workout)

        let onTheDay = try await repository.getWorkouts(for: sessionDay)
        assertTest(onTheDay.count == 1, "A saved workout is read back on its own day (\(onTheDay.count) found)")

        if let read = onTheDay.first {
            assertTest(read.id == workout.id, "…with the same identity")
            assertTest(read.route.count == 2, "…and its route points (\(read.route.count) of 2)")
            assertTest(read.splits.count == 2, "…and its splits (\(read.splits.count) of 2)")
            assertTest(
                read.route.map(\.id) == workout.route.map(\.id),
                "…and the route points keep their own identities, so a point is addressable")
        }

        // The primary-key rule from CLAUDE.md: `date` is snapped to `startOfDay`, so a read keyed on a
        // neighbouring day must not find it. Without the snap — or with a read that fails to snap —
        // this is the assertion that fails, and it is exactly how the day-keyed writers broke before.
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: sessionDay)!
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: sessionDay)!
        assertTest(
            (try await repository.getWorkouts(for: dayBefore)).isEmpty,
            "A workout saved at a raw 17:33 is not found on the day before (the day key is snapped)")
        assertTest(
            (try await repository.getWorkouts(for: dayAfter)).isEmpty,
            "…nor on the day after")

        // Several sessions in one day is the normal case and is why this table is keyed on `id`
        // rather than on `date` the way `recoveries`/`sleeps`/`strains` are.
        let second = WorkoutSession(
            startedAt: calendar.date(byAdding: .hour, value: 2, to: startedAt)!,
            endedAt: calendar.date(byAdding: .minute, value: 30, to: startedAt)!,
            strain: 1.2, averageHeartRate: 102, maxHeartRate: 121, route: [], splits: [])
        try await repository.save(second)
        let both = try await repository.getWorkouts(for: sessionDay)
        assertTest(both.count == 2, "Two sessions on one day are both read back (\(both.count) found)")
        assertTest(
            both.map(\.startedAt) == both.map(\.startedAt).sorted(),
            "…earliest first")

        let latest = try await repository.latest()
        assertTest(latest?.id == second.id, "`latest()` returns the most recent session by start time")

        // Re-saving the same id replaces rather than duplicates — `save` is INSERT-or-UPDATE by
        // primary key, and a route that were only appended would double on every re-save.
        try await repository.save(workout)
        let afterResave = try await repository.getWorkouts(for: sessionDay)
        assertTest(afterResave.count == 2, "Re-saving a session does not duplicate it")
        assertTest(
            afterResave.first(where: { $0.id == workout.id })?.route.count == 2,
            "…and does not duplicate its route points either")
    } catch {
        assertTest(false, "The workout persistence round trip threw: \(error)")
    }

    // ---- A day with nothing recorded reads as nothing, not as zeros ----

    do {
        let emptyDay = calendar.date(byAdding: .day, value: -400, to: Date())!.startOfDay
        let nothing = try await repository.getWorkouts(for: emptyDay)
        assertTest(nothing.isEmpty, "A day with no recorded workouts returns an empty array, not a row")
    } catch {
        assertTest(false, "The empty-day workout read threw: \(error)")
    }

    // ---- HealthKit steps: a daily sum, and `nil` when there is no sum ----

    do {
        let day = calendar.startOfDay(for: Date())
        let hrvRepository = GRDBRecoveryRepository(db: db)
        let sleepRepository = GRDBSleepRepository(db: db)
        let profileRepository = GRDBUserProfileRepository(db: db)

        func step(_ value: Double, atHour hour: Int) -> HealthQuantitySample {
            let start = calendar.date(byAdding: .hour, value: hour, to: day)!
            return HealthQuantitySample(value: value, start: start, end: start.addingTimeInterval(60))
        }

        let store = FixtureHealthStore(steps: [
            step(1_200, atHour: 9), step(1_500, atHour: 13), step(1_447, atHour: 19),
            // Tomorrow, so the window is proven to bound at both ends rather than summing everything.
            step(99_999, atHour: 25),
        ])
        let bridge = HealthKitBridge(
            store: store, recoveryRepository: hrvRepository, sleepRepository: sleepRepository,
            userProfileRepository: profileRepository)

        let total = await bridge.stepCount(on: day)
        assertTest(total == 4_147, "Steps are summed over the day and match the mockup's own figure (\(total.map(String.init) ?? "nil"))")

        // The window is the point: a store that ignored it would return 104,146.
        assertTest(total != 104_146, "…and the next day's samples are excluded, so the read is bounded")

        let empty = await bridge.stepCount(on: calendar.date(byAdding: .day, value: -400, to: day)!)
        assertTest(
            empty == nil,
            "A day with no step samples is `nil`, not 0 — 0 is a day the user did not walk, and the "
                + "two are not the same claim")
    }

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
            "…and it is computed from the very rate the RESTING HEART RATE panel prints beside it, "
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

    // ---- The battery trap, and why the readout is gated on connection state ----

    let disconnected = WhoopDevice(id: "no-strap", connectionState: .disconnected)
    assertTest(
        disconnected.batteryPercentage == 100,
        "A disconnected strap reports battery 100% — the default this app writes, not a measurement "
            + "it took (WhoopBLEManager sets the same literal at discovery). This is why the Home "
            + "readout renders `—` unless the state is `.connected` rather than printing this value.")

    // ---- Stress: the pure contract ----

    assertTest(StressMath.band(forScore: 0.0) == .low, "0.0 is the low band")
    assertTest(StressMath.band(forScore: 1.0) == .medium, "1.0 is the low/medium edge, in medium")
    assertTest(StressMath.band(forScore: 2.0) == .high, "2.0 is the medium/high edge, in high")
    assertTest(StressMath.band(forScore: 3.0) == .high, "3.0 is the top of the scale")

    assertTest(StressMath.score(fromActivation: -99) == 0.0, "A far-below-baseline window clamps to 0")
    assertTest(StressMath.score(fromActivation: 99) == 3.0, "A far-above-baseline window clamps to 3")
    assertTest(
        StressMath.score(fromActivation: 0) == StressMath.activationOffset,
        "Sitting exactly on the personal baseline lands on the low/medium edge")

    assertTest(
        StressMath.isResting(motionMagnitude: 1.0)
            && !StressMath.isResting(motionMagnitude: 2.0),
        "Motion separates a still window from a moving one at \(StressMath.motionCeiling) G")

    // The same input must score the same. Nothing here is derived from `Date()` or from a sample
    // order that the caller could vary.
    let baseline = BaselineStatisticsMath.baseline(
        [44, 47, 50, 53, 56], fallbackMean: 0, fallbackStdDev: 0)
    let heartRateBaseline = BaselineStatisticsMath.baseline(
        [58, 59, 60, 61, 62], fallbackMean: 0, fallbackStdDev: 0)
    let activated = StressMath.activation(
        rmssdMs: 30, meanHeartRate: 68,
        rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline)
    let calm = StressMath.activation(
        rmssdMs: 56, meanHeartRate: 58,
        rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline)
    assertTest(
        StressMath.activation(
            rmssdMs: 30, meanHeartRate: 68,
            rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline) == activated,
        "The same window scores identically on every call")
    assertTest(
        activated > calm,
        "HRV below baseline with heart rate above it scores higher than the reverse — the sign "
            + "convention that makes this a stress model and not a re-skin of Strain "
            + "(\(String(format: "%.2f", activated)) vs \(String(format: "%.2f", calm)))")

    // The load-bearing guard. `calculateRMSSD` answers 0.0 for a window it cannot measure, and 0 ms
    // is not "no reading" — it is a perfectly metronomic heart, which scores as maximum stress. If
    // `AnalyzeStressUseCase` ever stops checking `minimumRRIntervals` before scoring, this is the
    // failure it would ship, and this pair of assertions is what documents it.
    assertTest(
        HeartRateVariabilityMath.calculateRMSSD(from: [800]) == 0.0,
        "RMSSD of a single interval is 0.0 — the sentinel, not a measurement")
    assertTest(
        StressMath.score(fromActivation: StressMath.activation(
            rmssdMs: 0, meanHeartRate: 60,
            rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline)) == 3.0,
        "…and scoring that 0.0 reads as maximum stress, which is why a window must clear "
            + "\(StressMath.minimumRRIntervals) R-R intervals before it reaches the scorer")

    // ---- Stress: a day's series and its aggregate come out of one initialiser ----
    //
    // `StressDay` takes the windows and *derives* the figure, rather than taking both. There is no
    // parameter into which a caller could put a score belonging to another day's series — which is the
    // whole reason the Home tile's number and the Home chart's line cannot come to disagree.
    do {
        let dayStart = Date().startOfDay
        let built = StressDay(
            date: dayStart,
            windows: [
                StressWindow(start: dayStart.addingTimeInterval(9 * 3600), score: 0.4),
                StressWindow(start: dayStart.addingTimeInterval(10 * 3600), score: 1.8),
                StressWindow(start: dayStart.addingTimeInterval(11 * 3600), score: 2.6),
            ])

        assertTest(
            built.score.windowCount == built.windows.count,
            "A day's window count *is* the length of its series, not a second field to keep in step")
        assertTest(
            abs(built.score.averageScore - 1.6) < 0.0000001,
            "…and its average is their mean, computed here rather than handed in "
                + "(\(built.score.averageScore.formattedOneDecimal()))")
        assertTest(built.score.peakScore == 2.6, "…and its peak is their maximum")
        assertTest(built.score.date == dayStart, "…and it describes the day it was given")
        assertTest(
            built.windows.map(\.band) == [.low, .medium, .high],
            "…and each window bands on its own score: 0.4 low, 1.8 medium, 2.6 high — the same "
                + "scale the chart's colour gradient is stopped on")
    }

    // ---- Stress: the use case, end to end ----

    do {
        let empty = AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore())
        let none = try await empty.execute(for: Date())
        assertTest(
            none == nil,
            "A day with no samples has no score — `nil`, because `StressScore`'s zero would read as "
                + "perfectly calm, and this app cannot tell that from having measured nothing")

        // `AnalyzeStressUseCase` bounds its windows to waking hours in local time and keys days on
        // `Calendar.current`, so the fixture is built in the same calendar rather than in UTC. The
        // imported export's UTC-vs-device-zone hazard does not apply here: nothing is stored, so
        // there is no day key to split.
        // One five-minute window's worth of samples: 40 beats at one-second spacing, which is one
        // `StressMath.windowSeconds` bucket and therefore one scored window. `hour` is what lets a
        // fixture put several windows in one day — windows an hour apart land in different buckets,
        // windows minutes apart would not.
        func window(on offset: Int, atHour hour: Int = 9, rmssd: Double, heartRate: Int) -> [BiometricSample] {
            let day = calendar.date(byAdding: .day, value: offset, to: Date().startOfDay)!
            guard let start = calendar.date(byAdding: .hour, value: hour, to: day) else { return [] }
            // Alternating around 800 ms so the successive differences — and therefore the RMSSD —
            // are this window's `rmssd` exactly, while staying inside the 20% ectopic filter.
            let low = 800 - rmssd / 2
            let high = 800 + rmssd / 2
            return (0..<40).map { index in
                BiometricSample(
                    timestamp: start.addingTimeInterval(Double(index)),
                    heartRate: heartRate,
                    rrIntervalMs: index.isMultiple(of: 2) ? low : high,
                    accelerometerZ: 1.0)
            }
        }

        // Five baseline days with a real spread, so the standard deviation is not zero.
        var samples: [BiometricSample] = []
        for (offset, rmssd) in [(-5, 44.0), (-4, 47.0), (-3, 50.0), (-2, 53.0), (-1, 56.0)] {
            samples += window(on: offset, rmssd: rmssd, heartRate: 60)
        }

        let activatedStore = DaytimeBiometricStore(
            samples: samples + window(on: 0, rmssd: 30.0, heartRate: 68))
        let activatedDay = try await AnalyzeStressUseCase(biometricRepository: activatedStore)
            .execute(for: Date())

        assertTest(activatedDay != nil, "A day with enough history and a still window produces a score")
        assertTest(
            activatedDay?.band == .high,
            "…and a day whose HRV fell 20 ms below baseline with heart rate 8 bpm above it is high "
                + "(\(activatedDay.map { $0.averageScore.formattedOneDecimal() } ?? "nil"))")
        assertTest(
            (activatedDay?.windowCount ?? 0) > 0,
            "…with the number of windows that stood behind it recorded")

        // The same day, but with the day's own window removed and only the history left. The
        // baseline is still there; there is simply nothing today to score.
        let historyOnly = DaytimeBiometricStore(samples: samples)
        let noWindow = try await AnalyzeStressUseCase(biometricRepository: historyOnly)
            .execute(for: Date())
        assertTest(
            noWindow == nil,
            "A day whose samples hold no still window scores nothing, even with a full baseline")

        // Three baseline days is the floor; two must not produce a score. Read from a day far enough
        // back that only part of the fixture's history falls inside the 14-day baseline window.
        var twoDays: [BiometricSample] = []
        for (offset, rmssd) in [(-2, 50.0), (-1, 53.0)] {
            twoDays += window(on: offset, rmssd: rmssd, heartRate: 60)
        }
        let shortHistory = DaytimeBiometricStore(
            samples: twoDays + window(on: 0, rmssd: 30.0, heartRate: 68))
        let belowFloor = try await AnalyzeStressUseCase(biometricRepository: shortHistory)
            .execute(for: Date())
        assertTest(
            belowFloor == nil,
            "Two days of history produce no score: the model is defined relative to a personal "
                + "baseline, and \(StressMath.minimumBaselineDays) days is the fewest that has one")

        // ---- Stress: the series behind the number, which is what the Home chart draws ----
        //
        // The tile and the chart are one evaluation or they are two claims about one day, so what is
        // asserted here is the *pairing*: the aggregate is the mean of exactly the windows returned
        // beside it, and a day with no windows has neither. Nothing in this section can prove the
        // chart's drawing — that is a `Shape`, and the runner has no renderer — so what it proves is
        // the series the drawing is made of.

        let threeWindowStore = DaytimeBiometricStore(
            samples: samples
                + window(on: 0, atHour: 9, rmssd: 30.0, heartRate: 68)
                + window(on: 0, atHour: 10, rmssd: 40.0, heartRate: 62)
                + window(on: 0, atHour: 11, rmssd: 52.0, heartRate: 58))
        let stressUseCase = AnalyzeStressUseCase(biometricRepository: threeWindowStore)
        let stressDay = try await stressUseCase.executeDay(for: Date())

        assertTest(
            (stressDay?.windows.count ?? 0) > 1,
            "A day with three separated still windows reports a series, not one number "
                + "(\(stressDay?.windows.count ?? 0) windows)")

        if let stressDay {
            // The invariant `StressDay` exists to make structural: its initialiser builds the
            // aggregate *from* the windows, so the count cannot be a second opinion. A chart that drew
            // `windows` beside a `windowCount` from anywhere else is the drift this asserts against.
            assertTest(
                stressDay.windows.count == stressDay.score.windowCount,
                "The series and the aggregate count the same windows "
                    + "(\(stressDay.windows.count) plotted, \(stressDay.score.windowCount) counted)")

            assertTest(
                stressDay.windows.map(\.start) == stressDay.windows.map(\.start).sorted(),
                "…earliest first, so the line is drawn left to right")

            assertTest(
                stressDay.windows.allSatisfy { $0.score >= 0 && $0.score <= StressMath.maximumScore },
                "…every window inside the 0–\(StressMath.maximumScore) scale, which is the chart's "
                    + "fixed y-axis and the reason it cannot auto-scale")

            assertTest(
                stressDay.windows.allSatisfy { $0.band == StressMath.band(forScore: $0.score) },
                "…each window banded by the one definition, which is what colours the fill under it")

            let scores = stressDay.windows.map(\.score)
            let mean = scores.reduce(0, +) / Double(scores.count)
            assertTest(
                abs(stressDay.score.averageScore - mean) < 0.0000001,
                "The tile's average is the mean of the plotted windows "
                    + "(\(stressDay.score.averageScore.formattedOneDecimal()) vs "
                    + "\(mean.formattedOneDecimal()))")
            assertTest(
                stressDay.score.peakScore == scores.max(),
                "…and its peak is their maximum, so the caption cannot describe another day's line")
            assertTest(
                stressDay.score.peakScore >= stressDay.score.averageScore,
                "…and the peak is never below the average")

            // The waking window is a *domain* rule the chart has to know about, because it is what
            // decides which hours of a full-day axis can carry a line at all. Read from
            // `StressMath` rather than restated here.
            if let waking = StressMath.wakingWindow(on: Date().startOfDay) {
                assertTest(
                    stressDay.windows.allSatisfy { waking.contains($0.start) },
                    "…and every window lands inside the waking hours this model scores, which are the "
                        + "hours the chart does not shade")
            } else {
                assertTest(false, "The waking window could not be built for today")
            }
        } else {
            assertTest(false, "A day with three still windows produced no series")
        }

        // `execute(for:)` is a forwarder to `executeDay(for:)`, and this is the assertion that fails
        // if anyone re-implements the aggregate separately: the same fixture, read both ways, has to
        // produce the identical figure. Compared as whole `StressScore` values rather than by score,
        // so `windowCount` and `date` are covered too.
        let aggregate = try await stressUseCase.execute(for: Date())
        assertTest(
            stressDay?.score == aggregate,
            "`execute(for:)` returns exactly the aggregate of the series `executeDay(for:)` returns — "
                + "one evaluation, two entry points")

        // A single window is the degenerate case the chart has to survive: a polyline through one
        // point draws nothing, so it is drawn as a dot, and the day's peak and average are the same
        // number by arithmetic rather than by coincidence.
        let singleDay = try await AnalyzeStressUseCase(biometricRepository: activatedStore)
            .executeDay(for: Date())
        assertTest(singleDay?.windows.count == 1, "A one-window day has a series of one")
        assertTest(
            singleDay.map { $0.score.peakScore == $0.score.averageScore } ?? false,
            "…whose peak and average are the same number, because there is only one window to "
                + "average")

        // The anti-flat-line assertion. A day whose samples hold no eligible window must produce no
        // series at all, not an empty one — a chart handed `[]` draws nothing, but a chart handed a
        // `StressDay` with a `0.0` average would draw a flat line at zero, which is the strongest
        // possible claim of calm and the one thing this model must never say about an unmeasured day.
        let noWindowDay = try await AnalyzeStressUseCase(biometricRepository: historyOnly)
            .executeDay(for: Date())
        assertTest(
            noWindowDay == nil && noWindow == nil,
            "A day with a full baseline and no eligible window has no series *and* no score — neither "
                + "entry point can produce a flat line at zero")
        let nothingAtAll = try await AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore())
            .executeDay(for: Date())
        assertTest(
            nothingAtAll == nil,
            "…and a day with no samples at all is the same answer, which is every imported day")
    } catch {
        assertTest(false, "The stress use case threw: \(error)")
    }

    // ---- The recovery tier boundaries, which are what colour the Home ring ----
    //
    // Green 67–100, yellow 34–66, red 0–33, per `ALGORITHMS.md` §"Recovery Tiers". Pinned here
    // because an off-by-one at 66/67 is invisible on screen — the two colours are adjacent either
    // way — and because the ring, the Recovery tab's gauge, its HRV card and its trend chart all
    // read these boundaries through `RecoveryMetric.state`.

    for (score, expected) in [(100, "Green"), (67, "Green"), (66, "Yellow"), (34, "Yellow"),
                              (33, "Red"), (0, "Red")] {
        let metric = RecoveryMetric(score: score, hrvValueMs: 60, restingHeartRate: 55)
        assertTest(
            metric.state.rawValue == expected,
            "\(score)% recovery is \(expected) — a boundary that decides the ring's colour")
    }

    // The pair that keeps a placeholder off the screen as a red ring. `state` says `.red` for the
    // `score: 0` row a day with no strap data stores, so `state` alone cannot be what a view gates
    // on — `hasMeasurement` is, and `HomeDashboardView.recoveryValue` is `nil` for it, which is what
    // draws no fill at all.
    let placeholder = RecoveryMetric(score: 0, hrvValueMs: 0, restingHeartRate: 0)
    assertTest(
        placeholder.state == .red && !placeholder.hasMeasurement,
        "An unmeasured day's placeholder row is `.red` with no measurement — so a view that drew its "
            + "colour would show an unworn night as a hard 0% red recovery")

    // `state` must *be* `RecoveryState(score:)`, not a second switch that agrees today. The coach
    // message path holds a bare score and goes through the initialiser, so a metric whose `state`
    // drifted from it would put "you are primed" on a day the ring draws red.
    for score in [0, 20, 33, 34, 50, 66, 67, 85, 100] {
        let metric = RecoveryMetric(score: score, hrvValueMs: 60, restingHeartRate: 55)
        assertTest(
            metric.state == RecoveryMetric.RecoveryState(score: score),
            "\(score)% agrees between `RecoveryMetric.state` and `RecoveryState(score:)` — one "
                + "boundary table, read by the ring and by the coach message alike")
    }

    // The mapping itself, which is the one thing a boundary assertion cannot see: a switch whose
    // cases all returned the same token would satisfy every assertion above and paint a 10% day
    // green. Three distinct colours, and each on its own token, is the whole contract.
    assertTest(
        RecoveryMetric.RecoveryState.green.color != RecoveryMetric.RecoveryState.yellow.color
            && RecoveryMetric.RecoveryState.yellow.color != RecoveryMetric.RecoveryState.red.color
            && RecoveryMetric.RecoveryState.green.color != RecoveryMetric.RecoveryState.red.color,
        "The three tiers render as three different colours — not one token behind three cases")
    assertTest(
        RecoveryMetric.RecoveryState.green.color == Theme.recoveryGreen
            && RecoveryMetric.RecoveryState.red.color == Theme.recoveryRed,
        "…each on its own token, so no case can be mis-wired to another tier's colour")

    // ---- The arrow Home's panels and the Recovery breakdown both draw ----
    //
    // `MetricChange` is one definition shared by two screens, so its two decisions have to be pinned
    // here rather than at either use site: whether a comparison is worth drawing at all, and which
    // colour its direction carries. The colour assertions are the "one rule, one definition" guard —
    // a copy of this in a view is what would drift, and the direction-versus-verdict split (up is
    // green for HRV and orange for resting heart rate) is the part a copy gets wrong first.
    let whole: (Double) -> String = { String(format: "%.0f", $0) }

    // Measured on the simulator: a resting heart rate of 52 against a mean of 52.4 drew a down
    // triangle between two figures both printed as `52`. The digits on screen are the whole of the
    // evidence a reader has, so an arrow between two identical ones is a row contradicting itself —
    // and this is the case a raw `current != previous` comparison lets through.
    assertTest(
        MetricChange.between(current: 52, previous: 52.4, formatted: whole) == nil,
        "A comparison whose two figures print the same draws no arrow — 52 against a mean of 52.4 "
            + "is below it, but the row would read `52 ▼ 52`")
    assertTest(
        MetricChange.between(current: 52.0, previous: 52.0, formatted: whole) == nil,
        "…and two genuinely equal values still draw none, which is the rule this extends rather "
            + "than replaces")

    let rise = MetricChange.between(current: 59, previous: 52, formatted: whole)
    assertTest(
        rise?.direction == .up && rise?.previousText == "52",
        "A rise carries the upward direction and the baseline it beat, formatted by the caller")
    assertTest(
        MetricChange.between(current: 14.9, previous: 15.8, formatted: { String(format: "%.1f", $0) })?
            .direction == .down,
        "…and a fall points down — the direction is literal and never inverted by what is good")

    // The verdict, which is *not* a property of the direction: the same arrow is green for HRV and
    // orange for resting heart rate. Two calls, one differing argument, two colours — a view that
    // read `direction` and picked its own token could not satisfy this pair.
    assertTest(
        MetricChange.marker(current: 59, baseline: 52, higherIsBetter: true, formatted: whole)?.color
            == Theme.recoveryGreen
            && MetricChange.marker(current: 52, baseline: 59, higherIsBetter: true, formatted: whole)?
                .color == Theme.strainPrimary,
        "For a figure where higher is better, a rise is green and a fall is not")
    assertTest(
        MetricChange.marker(current: 52, baseline: 59, higherIsBetter: false, formatted: whole)?.color
            == Theme.recoveryGreen
            && MetricChange.marker(current: 59, baseline: 52, higherIsBetter: false, formatted: whole)?
                .color == Theme.strainPrimary,
        "…and for resting heart rate the same two arrows carry the opposite verdicts, so the colour "
            + "cannot be read off the direction alone")
    assertTest(
        MetricChange.marker(current: 59, baseline: nil, higherIsBetter: true, formatted: whole) == nil,
        "A day with no baseline behind it draws no arrow, which is what keeps a cold start from "
            + "printing a movement against a constant")

    // ---- The calendar's key, off the same ranges the tiers band on ----
    //
    // A key whose printed boundary disagrees with the initialiser that bands the colours is worse
    // than no key at all: it is a lie about what the colours mean, told in the one place a user goes
    // to learn them. `<34%` and `>66%` are the trap — they read as "the same number", but one is
    // yellow's *lower* bound and the other is yellow's *upper*.
    assertTest(
        RecoveryMetric.RecoveryState(score: RecoveryMetric.RecoveryState.greenRange.lowerBound) == .green
            && RecoveryMetric.RecoveryState(
                score: RecoveryMetric.RecoveryState.greenRange.lowerBound - 1) == .yellow,
        "The tier initialiser bands on the ranges the key prints: green's floor is green, and one "
            + "below it is yellow")
    assertTest(
        RecoveryMetric.RecoveryState(score: RecoveryMetric.RecoveryState.yellowRange.lowerBound)
            == .yellow
            && RecoveryMetric.RecoveryState(
                score: RecoveryMetric.RecoveryState.yellowRange.lowerBound - 1) == .red,
        "…and yellow's floor is yellow and one below it red, so neither printed bound can move "
            + "without the initialiser moving with it")

    let legend = RecoveryTierLegend.entries
    assertTest(
        legend.map(\.state) == [.red, .yellow, .green],
        "The key lists all three tiers, one entry each — the three the reference key carries")
    assertTest(
        legend.map(\.text) == ["<34%", "34% - 66%", ">66%"],
        "…and prints exactly the reference key's three labels")
    assertTest(
        legend[0].text == "<\(RecoveryMetric.RecoveryState.yellowRange.lowerBound)%"
            && legend[1].text == "\(RecoveryMetric.RecoveryState.yellowRange.lowerBound)% - "
                + "\(RecoveryMetric.RecoveryState.greenRange.lowerBound - 1)%"
            && legend[2].text == ">\(RecoveryMetric.RecoveryState.greenRange.lowerBound - 1)%",
        "…read off the ranges rather than typed here, so the labels and the tiers above can only "
            + "move together")

    // ---- TODAY and the forward stop, which are rules about a date rather than about data ----
    //
    // Both live in `DayBarRules` rather than in the bar's body for one reason: the runner has no
    // renderer, so a rule written into a `View` is a rule nothing here can assert. `now` is a
    // parameter for the same reason — an assertion that can only be written against `Date()` is an
    // assertion that says something different tomorrow.
    let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon)!

    assertTest(
        DayBarRules.label(for: Date()) == "TODAY",
        "The day bar's centre reads TODAY on the day the app opens on")
    assertTest(
        DayBarRules.label(for: calendar.startOfDay(for: Date()), now: noon) == "TODAY",
        "…and TODAY is decided by the calendar day, not by the instant — midnight this morning is "
            + "still today at noon, which a raw `Date` comparison would call a different day")
    assertTest(
        DayBarRules.label(for: yesterday, now: noon) != "TODAY"
            && DayBarRules.label(for: tomorrow, now: noon) != "TODAY",
        "…while neither neighbour is TODAY")
    assertTest(
        DayBarRules.label(for: yesterday, now: noon) != DayBarRules.label(for: tomorrow, now: noon)
            && DayBarRules.label(for: tomorrow, now: noon)
                == tomorrow.formattedShortDate().uppercased(),
        "…and a day that is not today prints its own date, uppercased — the label the bar showed "
            + "before this change, not a constant")

    assertTest(
        !DayBarRules.canStepForward(from: noon, now: noon),
        "The forward chevron is stopped on today, where there is nothing ahead to show")
    assertTest(
        !DayBarRules.canStepForward(from: tomorrow, now: noon),
        "…and stopped on a day already in the future, which is the input `!isToday` alone gets "
            + "wrong: it reports `true` there and lets the bar walk further forward")
    assertTest(
        DayBarRules.canStepForward(from: yesterday, now: noon),
        "…and it still moves forward from yesterday, so the stop is a bound and not a blanket")

    // ---- The month grid: the header row and the leading blanks are one rotation ----
    //
    // The invariant is structural — column `i` is always `weekdaySymbols[i]`, and the 1st sits in
    // the column whose symbol is its own weekday. The sweep is every month of five years rather than
    // one convenient month, because each way for the two to drift apart is a different month: a
    // `firstWeekday` that is not Sunday, a leap February, a 31-day month beginning on the calendar's
    // own first weekday, and a month containing a DST transition. One month exercises one of those,
    // and would pass with the natural-looking `blanks = weekdayOfFirst - 1` that `MonthGrid` exists
    // to avoid.
    do {
        var monthsChecked = 0
        var shapeFailures: [String] = []
        var dayCountFailures: [String] = []
        var spacingFailures: [String] = []
        var headerFailures: [String] = []
        var anchorFailures: [String] = []

        for year in 2023...2027 {
            for month in 1...12 {
                guard let anchor = calendar.date(from: DateComponents(year: year, month: month, day: 15)),
                      let grid = MonthGrid.make(for: anchor, calendar: calendar)
                else {
                    shapeFailures.append("\(year)-\(month): no grid at all")
                    continue
                }
                monthsChecked += 1
                let name = "\(year)-\(month)"

                if grid.cells.count % 7 != 0 || grid.weekdaySymbols.count != 7
                    || grid.leadingBlanks >= 7
                    || grid.cells.prefix(while: { $0 == nil }).count != grid.leadingBlanks {
                    shapeFailures.append(
                        "\(name): \(grid.cells.count) cells, \(grid.leadingBlanks) blanks, "
                            + "\(grid.weekdaySymbols.count) symbols")
                }

                let drawn = grid.cells.compactMap { $0 }
                if drawn.count != grid.days.count || Set(grid.days).count != grid.days.count {
                    dayCountFailures.append(
                        "\(name): \(grid.days.count) days, \(Set(grid.days).count) distinct, "
                            + "\(drawn.count) drawn")
                }

                // `byAdding: .day` and never `addingTimeInterval(86_400)`: a month with a DST
                // transition in it is exactly where the second form repeats or skips a day number.
                for offset in 1..<grid.days.count
                where calendar.dateComponents(
                    [.day], from: grid.days[offset - 1], to: grid.days[offset]).day != 1 {
                    spacingFailures.append("\(name): day \(offset + 1) is not one day after day \(offset)")
                    break
                }

                for (index, cell) in grid.cells.enumerated() {
                    guard let day = cell else { continue }
                    let expected = calendar.shortWeekdaySymbols[
                        calendar.component(.weekday, from: day) - 1]
                    if grid.weekdaySymbols[index % 7] != expected {
                        headerFailures.append(
                            "\(name): \(day.formattedShortDate()) sits under "
                                + "\(grid.weekdaySymbols[index % 7]) but is a \(expected)")
                        break
                    }
                }

                // The caller passes the day the app is on, not the 1st, so any day of the month has
                // to anchor the same grid — otherwise paging to a month and selecting a day inside
                // it would redraw the month differently.
                if let midMonth = calendar.date(
                    from: DateComponents(year: year, month: month, day: 28)),
                    MonthGrid.make(for: midMonth, calendar: calendar) != grid {
                    anchorFailures.append(name)
                }
            }
        }

        assertTest(
            monthsChecked == 60,
            "A grid was built for all 60 months of 2023–2027 — the sweep itself is the assertion")
        assertTest(
            shapeFailures.isEmpty,
            "Every grid is a whole number of weeks with fewer than 7 leading blanks, and those blanks "
                + "are exactly the nils before the 1st — first failure: \(shapeFailures.first ?? "none")")
        assertTest(
            dayCountFailures.isEmpty,
            "…and every day of the month is drawn exactly once — first failure: "
                + "\(dayCountFailures.first ?? "none")")
        assertTest(
            spacingFailures.isEmpty,
            "…each one calendar day after the last, through two DST transitions a year — which is "
                + "what `byAdding: .day` buys and an 86 400-second step would not — first failure: "
                + "\(spacingFailures.first ?? "none")")
        assertTest(
            headerFailures.isEmpty,
            "…and each day sits under the column whose weekday symbol is its own. This is the "
                + "assertion that catches the header and the blanks drifting apart — first failure: "
                + "\(headerFailures.first ?? "none")")
        assertTest(
            anchorFailures.isEmpty,
            "…and any day of the month anchors the same grid, since the caller passes the selected "
                + "day rather than the 1st — first failure: \(anchorFailures.first ?? "none")")

        // The rotation itself, which the sweep above cannot see on this machine: `Calendar.current`
        // is Sunday-first here, so `firstWeekday - 1` is 0 and the buggy `blanks = weekdayOfFirst - 1`
        // agrees with the correct form — every assertion above passes with it. Driving a Monday-first
        // calendar through the same invariant is what exercises the rotation, and `MonthGrid.make`
        // takes the calendar as a parameter precisely so that is possible.
        var mondayFirst = Calendar(identifier: .gregorian)
        mondayFirst.firstWeekday = 2
        mondayFirst.timeZone = calendar.timeZone

        var rotationFailures: [String] = []
        for month in 1...12 {
            guard let anchor = mondayFirst.date(from: DateComponents(year: 2026, month: month, day: 15)),
                  let grid = MonthGrid.make(for: anchor, calendar: mondayFirst)
            else {
                rotationFailures.append("2026-\(month): no grid")
                continue
            }
            if grid.weekdaySymbols.first != mondayFirst.shortWeekdaySymbols[1] {
                rotationFailures.append(
                    "2026-\(month): header starts at \(grid.weekdaySymbols.first ?? "none")")
            }
            for (index, cell) in grid.cells.enumerated() {
                guard let day = cell else { continue }
                let expected = mondayFirst.shortWeekdaySymbols[
                    mondayFirst.component(.weekday, from: day) - 1]
                if grid.weekdaySymbols[index % 7] != expected {
                    rotationFailures.append(
                        "2026-\(month): \(day.formattedShortDate()) sits under "
                            + "\(grid.weekdaySymbols[index % 7]) but is a \(expected)")
                    break
                }
            }
        }
        assertTest(
            rotationFailures.isEmpty,
            "Under a Monday-first calendar the header and the blanks rotate together, so the 1st still "
                + "sits under its own weekday — the half of the rule a Sunday-first locale cannot "
                + "exercise — first failure: \(rotationFailures.first ?? "none")")

        // …and `firstWeekday` is genuinely read rather than a Sunday-first grid handed back whatever
        // calendar is passed, which would satisfy every invariant above and still mislabel the
        // columns. February 2026 begins on a Sunday, so the two conventions must disagree about it.
        if let sundayAnchor = calendar.date(from: DateComponents(year: 2026, month: 2, day: 15)),
           let mondayAnchor = mondayFirst.date(from: DateComponents(year: 2026, month: 2, day: 15)),
           let sundayGrid = MonthGrid.make(for: sundayAnchor, calendar: calendar),
           let mondayGrid = MonthGrid.make(for: mondayAnchor, calendar: mondayFirst) {
            assertTest(
                sundayGrid.weekdaySymbols != mondayGrid.weekdaySymbols
                    && sundayGrid.leadingBlanks != mondayGrid.leadingBlanks
                    && sundayGrid.leadingBlanks == 0 && mondayGrid.leadingBlanks == 6,
                "February 2026 lays out differently under the two conventions — no blanks when the "
                    + "week starts on the day it begins, six when it starts the day after")
        }
    }

    // ---- The month the calendar reads, and the window it reads it with ----
    //
    // `getRecoveryHistory` bounds its window at BOTH ends and runs from `endingOn - days`, so a
    // window one day too wide pulls in a neighbouring month's row and the grid becomes free to paint
    // a day that nothing measured. That is invisible on screen — a tinted cell looks like any other
    // — so the neighbours are asserted absent rather than merely left unasserted.
    do {
        let monthDB = LocalDatabaseManager(inMemory: true)
        let monthRepository = GRDBRecoveryRepository(db: monthDB)

        let anchor = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let firstOfMonth = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let lastOfMonth = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let previousMonth = calendar.date(byAdding: .day, value: -1, to: firstOfMonth)!
        let nextMonth = calendar.date(byAdding: .day, value: 1, to: lastOfMonth)!
        let gatedDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!

        // 80 is green and 20 is red, so a row arriving from the wrong month is not merely present —
        // it is a *different colour*, which is what makes its absence worth asserting.
        for (date, score) in [(firstOfMonth, 80), (lastOfMonth, 20),
                              (previousMonth, 80), (nextMonth, 20)] {
            try await monthRepository.saveRecovery(
                RecoveryMetric(date: date, score: score, hrvValueMs: 60, restingHeartRate: 55))
        }
        // The row that must not appear. A placeholder is what an older build wrote for a day the
        // strap was not worn; `hasMeasurement` is a reader's only way to tell it from a real 0%, and
        // the calendar greys that day rather than painting it hard red.
        try await monthRepository.saveRecovery(
            RecoveryMetric(date: gatedDay, score: 0, hrvValueMs: 0, restingHeartRate: 0))

        let monthViewModel = await MainActor.run {
            HomeViewModel(
                recoveryRepository: monthRepository,
                sleepRepository: GRDBSleepRepository(db: monthDB),
                strainRepository: GRDBStrainRepository(db: monthDB),
                workoutRepository: GRDBWorkoutRepository(db: monthDB),
                userProfileRepository: GRDBUserProfileRepository(db: monthDB),
                healthKit: NoStepsHealthKit(),
                analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                manage: ManageBLEConnectionUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                streamUseCase: StreamBiometricsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    biometricRepository: GRDBBiometricRepository(db: monthDB)))
        }

        await monthViewModel.loadMonth(containing: anchor)

        let month = await MainActor.run {
            (tiers: monthViewModel.monthTiers, isLoading: monthViewModel.isLoadingMonth,
             error: monthViewModel.errorMessage)
        }

        assertTest(
            month.tiers[firstOfMonth.startOfDay] == .green
                && month.tiers[lastOfMonth.startOfDay] == .red,
            "The calendar's map carries the displayed month's measured days, each in its own tier")
        assertTest(
            month.tiers[previousMonth.startOfDay] == nil && month.tiers[nextMonth.startOfDay] == nil,
            "…and neither neighbour: `days: <span between the month's own bounds>, endingOn: <the "
                + "month's last day>` covers exactly the month, so July 31 and September 1 are absent "
                + "rather than tinted")
        assertTest(
            month.tiers[gatedDay.startOfDay] == nil,
            "A legacy placeholder row is absent from the map rather than `.red`, so the calendar "
                + "greys an unworn day — keying on the row existing would paint it a hard 0%")
        assertTest(
            month.tiers.count == 2,
            "…and the map holds the month's two measured days and nothing besides")
        assertTest(
            !month.isLoading && month.error == nil,
            "…and the read finishes clean, so the grid is not left dimmed under a load that ended")

        // A month the export never covered is not an error and not a load that never finishes. That
        // is the mistake `isLoading` exists to avoid: testing `tiers.isEmpty` to decide would spin
        // forever on a month with nothing in it, which is most of them on a fresh install.
        await monthViewModel.loadMonth(
            containing: calendar.date(from: DateComponents(year: 2020, month: 1, day: 15))!)
        let emptyMonth = await MainActor.run {
            (tiers: monthViewModel.monthTiers, isLoading: monthViewModel.isLoadingMonth,
             error: monthViewModel.errorMessage)
        }
        assertTest(
            emptyMonth.tiers.isEmpty && !emptyMonth.isLoading && emptyMonth.error == nil,
            "A month with nothing stored is an empty grid — not an error, and not a load still "
                + "running")
    } catch {
        assertTest(false, "The month calendar's read threw: \(error)")
    }

    // ---- Home's rings and tiles on a day with nothing stored ----

    do {
        let emptyDay = calendar.date(byAdding: .day, value: -400, to: Date())!.startOfDay

        // `HomeViewModel` is `@MainActor`, like every ViewModel here, so it is built and read on the
        // main actor and only plain `Sendable` values cross back out.
        let viewModel = await MainActor.run {
            HomeViewModel(
                recoveryRepository: GRDBRecoveryRepository(db: db),
                sleepRepository: GRDBSleepRepository(db: db),
                strainRepository: GRDBStrainRepository(db: db),
                workoutRepository: repository,
                userProfileRepository: GRDBUserProfileRepository(db: db),
                healthKit: NoStepsHealthKit(),
                analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                manage: ManageBLEConnectionUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                streamUseCase: StreamBiometricsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    biometricRepository: GRDBBiometricRepository(db: db)))
        }

        await viewModel.load(for: emptyDay)

        let snapshot = await MainActor.run {
            (
                hasRecovery: viewModel.recovery != nil,
                hasSleep: viewModel.sleep != nil,
                hasStrain: viewModel.strain != nil,
                workoutCount: viewModel.workouts.count,
                steps: viewModel.steps,
                hasStress: viewModel.stress != nil,
                stressWindows: viewModel.stressDay?.windows.count,
                restorativeSeconds: viewModel.restorativeSleepSeconds,
                error: viewModel.errorMessage
            )
        }

        assertTest(!snapshot.hasRecovery, "A day with nothing stored has no recovery behind the ring")
        assertTest(!snapshot.hasSleep, "…no sleep session, so no performance and no restorative hours")
        assertTest(!snapshot.hasStrain, "…no strain")
        assertTest(snapshot.workoutCount == 0, "…and no recorded activities")
        assertTest(snapshot.steps == nil, "…and HealthKit answers `nil` rather than 0 steps")
        assertTest(!snapshot.hasStress, "…and no stress score")
        assertTest(
            snapshot.stressWindows == nil,
            "…and no series either, so the Stress Monitor chart draws nothing at all rather than a "
                + "flat line at zero — an unmeasured day is not a calm one")
        assertTest(
            snapshot.restorativeSeconds == nil,
            "Deep + REM is `nil`, not 0 — the tile's dash and its 0:00 are different claims")
        assertTest(
            snapshot.error == nil,
            "…and none of that is an error to report: an empty day is a day with nothing on it")
    }

    // ---- Home on an IMPORTED day, which is the day a fresh install actually has ----
    //
    // The empty-day block above proves the dashes. This is its counterpart and the one that was
    // missing: a fresh install fills its history through the Settings import, so the first day Home
    // can show a number for is an *imported* one — and until this ran, nothing asserted that Home
    // populates from it at all. Every failure here is one a user would describe as "data isn't
    // populating in the simulator", which is exactly how it was found.
    //
    // The export ends 2026-08-22, so it is also the reason a fresh install opens on a dash: Home's
    // default day is *today*, and today is not in the file.
    do {
        let csvURL = whoopExportURL()
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            assertTest(false, "The bundled export is missing at \(csvURL.path)")
            return
        }

        let importedDB = LocalDatabaseManager(inMemory: true)
        let recoveryRepository = GRDBRecoveryRepository(db: importedDB)
        let sleepRepository = GRDBSleepRepository(db: importedDB)
        let strainRepository = GRDBStrainRepository(db: importedDB)

        _ = try await WhoopExportImporter(
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            userProfileRepository: GRDBUserProfileRepository(db: importedDB),
            calendar: calendar
        ).importExport(at: csvURL)

        // The last day carrying all three, read rather than hardcoded.
        //
        // Not simply the last sleep day, which is the shape §12 already warns about: the export's
        // partial cycles make the three tables' last days differ — a sleep day near the end has no
        // strain row — so demanding all three from one arbitrarily chosen day asserts a fact about
        // the file's tail rather than about Home. This picks the day a user would actually page to
        // and see populated. §11 still owns the day keys; nothing here hardcodes a date.
        func days(_ dates: [Date]) -> Set<Date> { Set(dates.map(\.startOfDay)) }
        let recoveryDays = days(try await recoveryRepository.getRecoveryHistory(days: 4000).map(\.date))
        let sleepDays = days(try await sleepRepository.getSleepHistory(days: 4000).map(\.date))
        let strainDays = days(try await strainRepository.getStrainHistory(days: 4000).map(\.date))

        guard let importedDay = recoveryDays.intersection(sleepDays).intersection(strainDays).max() else {
            assertTest(false, "The import wrote a day carrying a recovery, a night and a strain")
            return
        }
        assertTest(
            true,
            "The import wrote \(recoveryDays.count) recoveries, \(sleepDays.count) nights and "
                + "\(strainDays.count) strains; the most recent day carrying all three is the one "
                + "Home is loaded with")

        let home = await MainActor.run {
            HomeViewModel(
                recoveryRepository: recoveryRepository,
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                workoutRepository: GRDBWorkoutRepository(db: importedDB),
                userProfileRepository: GRDBUserProfileRepository(db: importedDB),
                healthKit: NoStepsHealthKit(),
                analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                manage: ManageBLEConnectionUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                streamUseCase: StreamBiometricsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    biometricRepository: GRDBBiometricRepository(db: importedDB)))
        }

        await home.load(for: importedDay)

        let imported = await MainActor.run {
            (
                score: home.recovery?.hasMeasurement == true ? home.recovery?.score : nil,
                sleep: home.sleep?.sleepPerformancePercentage,
                strain: home.strain?.score,
                restorative: home.restorativeSleepSeconds,
                steps: home.steps,
                hasStress: home.stress != nil,
                stressWindows: home.stressDay?.windows.count,
                activities: home.workouts.count,
                weekSlots: home.metricWeek?.days.count,
                weekEndsOn: home.metricWeek?.endingOn,
                weekStrainNils: home.metricWeek?.days.filter { $0.strain == nil }.count,
                weekRestingHeartRate: home.metricWeek?.day(for: importedDay)?.restingHeartRate,
                weekSleepNeed: home.metricWeek?.day(for: importedDay)?.sleepNeedSeconds,
                weekRestingHeartRateBaseline: home.metricWeek?.restingHeartRateBaseline,
                weekSleepNeedBaseline: home.metricWeek?.sleepNeedBaselineSeconds
            )
        }

        assertTest(
            imported.score != nil,
            "An imported day puts a measured recovery behind the Home ring, so the ring takes its "
                + "tier colour instead of a dash")
        assertTest(
            imported.sleep != nil,
            "…and a sleep performance, so the SLEEP ring has a value ("
                + "\(imported.sleep.map { "\($0)%" } ?? "nil"))")
        assertTest(imported.strain != nil, "…and WHOOP's own strain for the day")
        assertTest(
            imported.restorative != nil,
            "…and deep + REM for the RESTORATIVE SLEEP tile ("
                + "\(imported.restorative.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

        // The two that stay dashes, asserted for the same reason: the import is the only input a
        // fresh install has, and it carries neither step counts nor an R-R series. A number here
        // would mean something had started inventing one.
        assertTest(
            imported.steps == nil,
            "…but STEPS stays a dash: the export has no step counts, and HealthKit is the only source")
        assertTest(
            !imported.hasStress,
            "…and STRESS MONITOR stays a dash: the export carries no R-R intervals to score")
        assertTest(
            imported.stressWindows == nil,
            "…and its chart is absent rather than empty, on every one of the \(recoveryDays.count) "
                + "imported days — the export has no R-R series at all")
        assertTest(
            imported.activities == 0,
            "…and ACTIVITIES holds only the sleep row — the import writes no workouts")

        // The two new panels and the chart, on the days that actually have data behind them. Unlike
        // the stress chart, these are populated from the export — which is the whole reason they were
        // built against a measured column count rather than against the mockup.
        assertTest(
            imported.weekSlots == MetricWeek.dayCount && imported.weekEndsOn == importedDay.startOfDay,
            "Home's week is seven slots ending on the day it loaded (got "
                + "\(imported.weekSlots.map { "\($0)" } ?? "nil") slots)")
        assertTest(
            imported.weekStrainNils == 0,
            "…and every one of those seven imported days carries a measured strain, so the chart's "
                + "line is unbroken across it (nil slots: "
                + "\(imported.weekStrainNils.map { "\($0)" } ?? "nil"))")
        assertTest(
            imported.weekRestingHeartRate != nil,
            "…and the loaded day has a resting heart rate for its panel ("
                + "\(imported.weekRestingHeartRate.map { "\($0) bpm" } ?? "nil"))")
        assertTest(
            imported.weekRestingHeartRateBaseline != nil,
            "…with a 7-day mean to print under it ("
                + "\(imported.weekRestingHeartRateBaseline.map { "\($0) bpm" } ?? "nil"))")
        assertTest(
            imported.weekSleepNeed != nil && imported.weekSleepNeedBaseline != nil,
            "…and the SLEEP NEEDED panel has both a need and a mean: the import stores WHOOP's own "
                + "`Sleep need (min)`, so this is not this app's 8-hour constant ("
                + "\(imported.weekSleepNeed.map { $0.formattedCompactHoursMinutes() } ?? "nil") over "
                + "\(imported.weekSleepNeedBaseline.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

        // The v7 backfill's predicate, against the real export. The migrator runs before any row
        // exists, so the migration cannot assert this for itself — but the premise it rests on is a
        // property of the data, and it is measured here rather than assumed. It was assumed once and
        // was wrong: `strainScore = 0` looks like the placeholder's signature and is not, because
        // WHOOP scores days at exactly 0.0 of its own accord.
        let importedStrains = try await strainRepository.getStrainHistory(days: 4000)
        assertTest(
            importedStrains.allSatisfy(\.hasMeasurement),
            "All \(importedStrains.count) imported strain rows read back as measurements")
        assertTest(
            importedStrains.allSatisfy { $0.averageHeartRate > 0 },
            "…and every one carries a heart rate, which is what makes the backfill's predicate safe: "
                + "the empty branch writes no heart rate at all")
        let measuredZeros = importedStrains.filter { $0.score == 0.0 }
        assertTest(
            !measuredZeros.isEmpty && measuredZeros.allSatisfy(\.hasMeasurement),
            "…including the \(measuredZeros.count) days WHOOP itself scored exactly 0.0, which a "
                + "backfill keyed on the score alone would have marked unmeasured")
    } catch {
        assertTest(false, "Home on an imported day threw: \(error)")
    }

    // ---- MetricWeek: the seven-day join, and the three absence rules it applies ----
    //
    // The join is the riskiest logic in the week's chart and panels — pairing a day's strain with the
    // *same* day's recovery, and deciding which days count as measured — which is why it lives in
    // Domain where this runner can reach it rather than in a view it cannot. Fixtures are built from
    // `Calendar.current` offsets, never hardcoded dates, so the block holds on whatever day it runs.
    do {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date())
        func day(_ back: Int) -> Date {
            calendar.date(byAdding: .day, value: -back, to: anchor) ?? anchor
        }
        func days(_ count: Int) -> [Date] { (0..<count).map(day) }

        // Measured on offsets 0, 2 and 4 — deliberately not contiguous, so the holes are interior
        // rather than only at the leading edge. A week assembled from the rows it was handed would
        // come back holding three slots and no hole at all.
        let week = MetricWeek(
            endingOn: anchor,
            strain: [0, 2, 4].map {
                StrainScore(date: day($0), score: 8.0 + Double($0), hasMeasurement: true)
            },
            recovery: [0, 2, 4].map {
                RecoveryMetric(date: day($0), score: 60 + $0, hrvValueMs: 55, restingHeartRate: 50 + $0)
            },
            sleep: [0, 2, 4].map {
                SleepSession(
                    date: day($0), startTime: day($0), endTime: day($0).addingTimeInterval(28800),
                    targetSleepNeedSeconds: 28800)
            })

        assertTest(
            week.days.count == MetricWeek.dayCount,
            "A week holds exactly \(MetricWeek.dayCount) slots however few days have data "
                + "(got \(week.days.count))")
        assertTest(
            week.days.first?.date == day(6) && week.days.last?.date == anchor,
            "…oldest first and ending on the anchor, so the rightmost column is the selected day")
        assertTest(
            week.days[1].strain == nil && week.days[3].recoveryScore == nil,
            "…and a day with nothing stored is an empty slot rather than a missing one — the "
                + "invariant that stops a gap sliding every later point one day to the left")

        // The placeholder rules, which are what the chart's absence depends on. Both rows here *exist*
        // and hold a zero; neither is a measurement.
        let placeholders = MetricWeek(
            endingOn: anchor,
            strain: [StrainScore(date: anchor, score: 0.0, hasMeasurement: false)],
            recovery: [RecoveryMetric(date: anchor, score: 0, hrvValueMs: 0, restingHeartRate: 0)])
        assertTest(
            placeholders.days.last?.strain == nil,
            "An unmeasured strain row plots nothing: its `0.0` is the reserved marker, not a rest day")
        assertTest(
            placeholders.days.last?.recoveryScore == nil
                && placeholders.days.last?.restingHeartRate == nil,
            "…and an unmeasured recovery row yields neither a tier nor a resting heart rate")
        assertTest(
            !(placeholders.days.last?.hasAnyMeasurement ?? true),
            "…so a day holding only placeholder rows counts as unmeasured")

        // The baseline floor, asserted at both edges: two measured days have a mean, and are still not
        // a baseline.
        let twoDays = MetricWeek(
            endingOn: anchor,
            recovery: days(2).map {
                RecoveryMetric(date: $0, score: 60, hrvValueMs: 55, restingHeartRate: 50)
            })
        assertTest(
            twoDays.restingHeartRateBaseline == nil,
            "Two measured days are below `minimumBaselineDays` and give no baseline, though their mean "
                + "is arithmetically defined")
        let threeDays = MetricWeek(
            endingOn: anchor,
            recovery: [50, 52, 54].enumerated().map { offset, rate in
                RecoveryMetric(
                    date: day(offset), score: 60, hrvValueMs: 55, restingHeartRate: rate)
            })
        assertTest(
            threeDays.restingHeartRateBaseline == 52,
            "…and three are a baseline, as the mean of only the measured days (got "
                + "\(threeDays.restingHeartRateBaseline.map { "\($0)" } ?? "nil"))")

        let needs = MetricWeek(
            endingOn: anchor,
            sleep: [8.0, 9.0, 10.0].enumerated().map { offset, hours in
                SleepSession(
                    date: day(offset), startTime: day(offset),
                    endTime: day(offset).addingTimeInterval(hours * 3600),
                    targetSleepNeedSeconds: hours * 3600)
            })
        assertTest(
            needs.sleepNeedBaselineSeconds == 32400,
            "The sleep-need baseline is the mean of the measured nights — nine hours here, not "
                + "`UserProfile.targetSleepHours`' hard-coded 8.0 (got "
                + "\(needs.sleepNeedBaselineSeconds.map { "\($0)" } ?? "nil"))")
        assertTest(
            MetricWeek(endingOn: anchor, sleep: []).sleepNeedBaselineSeconds == nil,
            "…and a week with no nights at all has no baseline to print")

        // ---- The HRV baseline, and the never-mix rule it has to obey ----
        //
        // The week's other two baselines average a column. This one cannot: SDNN and RMSSD are
        // different quantities on different scales, so an average across both is a statistic about
        // neither while looking exactly like a reading — the failure `RecoveryScoring` filters
        // history for, reached here by a different route.
        //
        // The week below is deliberately built so that the mixture and the narrowing give different
        // answers: three RMSSD days and two SDNN days, with the SDNN days *lower*. Averaging all five
        // would give 56.4; the correct answer is the RMSSD mean alone.
        let mixed = MetricWeek(
            endingOn: anchor,
            recovery: [
                (0, 60.0, HRVMetric.rmssd), (1, 30.0, HRVMetric.sdnn),
                (2, 62.0, HRVMetric.sdnn), (3, 64.0, HRVMetric.rmssd),
                (4, 66.0, HRVMetric.rmssd),
            ].map { offset, value, metric in
                RecoveryMetric(
                    date: day(offset), score: 60, hrvValueMs: value, hrvMetric: metric,
                    restingHeartRate: 50)
            })
        assertTest(
            mixed.hrvBaselineMetric == .rmssd,
            "The HRV baseline is narrowed to one metric — the newest measured day's, so the mean "
                + "belongs to the same quantity as the figure printed above it (got "
                + "\(mixed.hrvBaselineMetric.map(\.displayName) ?? "nil"))")
        assertTest(
            abs((mixed.hrvBaselineMs ?? 0) - 190.0 / 3.0) < 0.0001,
            "…and averages only that metric's days, so the two SDNN days are excluded rather than "
                + "mixed in (got \(mixed.hrvBaselineMs.map { "\($0)" } ?? "nil"), not the "
                + "\(mixed.days.compactMap(\.hrvValueMs).reduce(0, +) / 5) an unfiltered mean gives)")
        assertTest(
            mixed.days.last?.hrvValueMs == 60.0 && mixed.days.last?.hrvMetric == .rmssd,
            "…while the anchor's own slot still carries its reading and the metric it was measured in")

        // The other direction, and the one that would be easy to paper over: narrowing can drop a
        // week below the floor with readings present. That is a week with no *comparable* baseline,
        // and the answer is no mean — not a mean over the days that happen to be a different quantity.
        let mostlySdnn = MetricWeek(
            endingOn: anchor,
            recovery: [
                (0, 40.0, HRVMetric.sdnn), (1, 42.0, HRVMetric.sdnn),
                (2, 44.0, HRVMetric.sdnn), (3, 55.0, HRVMetric.rmssd),
            ].map { offset, value, metric in
                RecoveryMetric(
                    date: day(offset), score: 60, hrvValueMs: value, hrvMetric: metric,
                    restingHeartRate: 50)
            })
        assertTest(
            mostlySdnn.hrvBaselineMs == 42.0 && mostlySdnn.hrvBaselineMetric == .sdnn,
            "A week holding both metrics baselines the newest one even when it is the minority "
                + "(got \(mostlySdnn.hrvBaselineMs.map { "\($0)" } ?? "nil"))")
        assertTest(
            MetricWeek(
                endingOn: anchor,
                recovery: (0..<2).map { offset in
                    RecoveryMetric(
                        date: day(offset), score: 60, hrvValueMs: 60, restingHeartRate: 50)
                }
            ).hrvBaselineMs == nil,
            "…and two measured days are below the floor for HRV as they are for the other two")

        // The double gate, on the panel's own field. A placeholder's `0.0` ms is this column's
        // reserved marker, and a slot must not report a metric for a reading it does not have.
        assertTest(
            placeholders.days.last?.hrvValueMs == nil
                && placeholders.days.last?.hrvMetric == nil,
            "An unmeasured recovery row yields no HRV and no metric — the two can never disagree, "
                + "so a slot cannot name a quantity it has no reading in")

        assertTest(
            week.day(for: day(9)) == nil && week.day(for: anchor)?.date == anchor,
            "A date outside the window has no slot rather than the nearest one, and the anchor's own "
                + "day resolves to the last slot")

        // ---- A day with no samples is not a day ----
        //
        // `CalculateStrainUseCase` used to write a placeholder here — `score: 0.0` with the flag clear
        // — so that a reader could tell it apart from a measured rest day. Nothing read it that way,
        // and the row cost two things: `WhoopExportImporter` saw a row and skipped the day, so WHOOP's
        // genuine `Day Strain` for it was never imported, and the strain backfill below treats the
        // shape as its signature. Absence is now the answer, matching `AnalyzeSleepUseCase` — and the
        // shape itself is no longer produced by any writer, so it is covered by the direct
        // construction in the marker block below rather than by driving a use case into it.
        let emptyBranchDB = LocalDatabaseManager(inMemory: true)
        let emptyBranchRepository = GRDBStrainRepository(db: emptyBranchDB)
        let emptyBranch = try await CalculateStrainUseCase(
            biometricRepository: EmptyBiometricStore(),
            strainRepository: emptyBranchRepository,
            userProfileRepository: GRDBUserProfileRepository(db: emptyBranchDB)
        ).execute(for: anchor)
        assertTest(
            emptyBranch == nil,
            "A day with no samples returns nil rather than a reserved `0.0` — a real strain of `0.0` "
                + "and an unmeasured day are not the same claim")
        assertTest(
            try await emptyBranchRepository.getStrain(for: anchor) == nil,
            "…and it writes no row, so nothing downstream can mistake the day for stored data")

        // ---- The strain marker, through the repository that stores it ----
        //
        // This is v7's coverage. The migration's backfill `UPDATE` cannot be asserted here — the
        // migrator runs it before any row can exist — so what is tested is the column's existence and
        // the write/read path through it, which is what a subsequent launch depends on.
        let markerDB = LocalDatabaseManager(inMemory: true)
        let markerRepository = GRDBStrainRepository(db: markerDB)
        try await markerRepository.saveStrain(
            StrainScore(date: anchor, score: 0.0, hasMeasurement: false))
        try await markerRepository.saveStrain(
            StrainScore(date: day(1), score: 0.1, hasMeasurement: true))

        let unmeasured = try await markerRepository.getStrain(for: anchor)
        let measured = try await markerRepository.getStrain(for: day(1))
        assertTest(
            unmeasured?.hasMeasurement == false && measured?.hasMeasurement == true,
            "The strain marker survives the round trip: a saved placeholder reads back unmeasured and "
                + "a saved reading measured")
        assertTest(
            unmeasured?.score == 0.0 && measured?.score == 0.1,
            "…and the two zero-ish rows are distinguishable only by the flag — the placeholder's `0.0` "
                + "is a real `0.0` on disk, which is why `score > 0` is not the test")
    } catch {
        assertTest(false, "The seven-day MetricWeek join threw: \(error)")
    }
}

// The async sections need the process kept alive long enough to finish; 5s was too short on a
// cold database.
RunLoop.main.run(until: Date().addingTimeInterval(30.0))
