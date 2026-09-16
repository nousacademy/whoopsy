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
//
// This section used to be four assertions that could not fail: `crc8Val >= 0` on a `UInt8` (never
// false), `!= 0` for the other two (which only rules out identically zero), and a frame-layout check
// against the encoder's own constant. A wrong polynomial, a wrong byte order and a wrong *input* all
// passed — which is exactly how `buildPacket` hashed three bytes into a CRC8 the format says covers
// two, on every command frame this app has ever sent, without anything noticing.
//
// It is now built on the four vectors `BLE_PROTOCOL.md` §2.1 records from the two reverse-engineering
// references' own published frames. These are checkable with no strap, and they are the assertions
// that fail if the arithmetic or the frame layout moves.
print("\n[1/15] Testing CRC Algorithms & Framing...")

// The 4.0 header CRC8 is over the two length bytes only, poly 0x07. Both values are the references'
// own, quoted in §2.1.
assertTest(CRCUtils.crc8(Data([0x08, 0x00])) == 0xA8, "crc8([0x08, 0x00]) == 0xA8 (reference vector)")
assertTest(CRCUtils.crc8(Data([0x10, 0x00])) == 0x57, "crc8([0x10, 0x00]) == 0x57 (reference vector)")

// The 5.0 `CLIENT_HELLO` is a static 16-byte frame, so it validates the CRC16-Modbus over the first
// six header bytes *and* the CRC32 over the inner record in one. Neither is wired to a frame this
// build can build — `profile(for:)` returns nil for both 5.0 generations — but the arithmetic being
// correct is what makes the eventual envelope a matter of framing rather than of checksums.
let hello50 = Data([
    0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
    0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
])
assertTest(
    CRCUtils.crc16Modbus(hello50.subdata(in: 0..<6)) == 0x71E6,
    "crc16Modbus(5.0 hello[0..<6]) == 0x71E6 (reference vector)")
assertTest(
    CRCUtils.crc32(hello50.subdata(in: 8..<12)) == 0x8D5C3E36,
    "crc32(5.0 hello payload) == 0x8D5C3E36 (reference vector)")

// The 4.0 envelope, end to end. `hapticAlarmCommand` carries a two-byte payload, so the inner record
// is `type seq cmd 03 01` — five bytes — and `length` is that plus four.
let haptic = WhoopPacketEncoder.hapticAlarmCommand(
    profile: .whoop4, seq: 0x07, durationSeconds: 3, pattern: 1)
assertTest(haptic != nil, "Encoder builds a frame for the 4.0 envelope")
if let haptic {
    assertTest(haptic[0] == 0xAA, "Frame start of frame is 0xAA")
    // The defect this section could not see before: the CRC8 input. `length` is 9, so the two length
    // bytes are `09 00` and the reference says the checksum over them is 0x57.
    assertTest(haptic[1] == 0x09 && haptic[2] == 0x00, "Frame declares length 9 (5 inner bytes + 4)")
    assertTest(
        haptic[3] == CRCUtils.crc8(Data([haptic[1], haptic[2]])),
        "Header crc8 is over the two length bytes only")
    assertTest(haptic[4] == WhoopProtocolProfile.whoop4.packetTypes.command, "Inner type is the command type")
    assertTest(haptic[5] == 0x07, "Inner seq echoes the sequence number handed in")
    assertTest(haptic[6] == 0x10, "Inner cmd is 0x10 (haptic alarm)")
    assertTest(haptic.count == 13, "Total frame size is length + 4")
    // CRC32 covers the inner record `frame[4 ..< length]`, not the payload alone.
    let inner = haptic.subdata(in: 4..<9)
    let trailer = haptic.subdata(in: 9..<13)
    let declared = UInt32(trailer[trailer.startIndex])
        | (UInt32(trailer[trailer.startIndex + 1]) << 8)
        | (UInt32(trailer[trailer.startIndex + 2]) << 16)
        | (UInt32(trailer[trailer.startIndex + 3]) << 24)
    assertTest(declared == CRCUtils.crc32(inner), "Payload crc32 covers the inner record, not the payload")
}

// The two CRC8 vectors are quoted for specific *declared lengths*, so they are reachable only from a
// frame that declares those lengths — 0x08 is an inner record of four bytes (a one-byte payload), 0x10
// one of twelve. Asserting them against the frame that produces each is what ties the arithmetic to
// the layout; quoted bare in §1 above they validate the polynomial and nothing else.
let lengthEight = WhoopPacketEncoder.buildPacket(
    profile: .whoop4, type: WhoopProtocolProfile.whoop4.packetTypes.command,
    seq: 0, cmd: 0x05, payload: Data([0x01]))!
assertTest(
    lengthEight[1] == 0x08 && lengthEight[2] == 0x00 && lengthEight[3] == 0xA8,
    "A frame declaring length 8 carries crc8 0xA8 (the reference vector, in place)")
let lengthSixteen = WhoopPacketEncoder.buildPacket(
    profile: .whoop4, type: WhoopProtocolProfile.whoop4.packetTypes.command,
    seq: 0, cmd: 0x05, payload: Data(repeating: 0x01, count: 9))!
assertTest(
    lengthSixteen[1] == 0x10 && lengthSixteen[2] == 0x00 && lengthSixteen[3] == 0x57,
    "A frame declaring length 16 carries crc8 0x57 (the reference vector, in place)")

// A sequence that advances and wraps rather than repeating a constant. A repeated `seq` would be a
// second invented value sitting where a field is expected — the same class of error as a fabricated
// battery percentage, and just as invisible.
let seqCounter = WhoopCommandSequence()
let seqValues = (0..<256).map { _ in seqCounter.next() }
assertTest(seqValues.first == 1, "Command sequence starts at 1")
assertTest(seqValues.last == 0, "Command sequence wraps at 256 rather than overflowing")
assertTest(Set(seqValues).count == 256, "Command sequence produces 256 distinct values before repeating")

// The envelope is selected by generation, and refusing is the default.
//
// `WhoopProtocolProfile.profile(for:)` is the choke point the whole generation-aware path rests on: it
// answers nil for every envelope this build has not implemented, and every command writer refuses on
// nil. The property worth pinning is the refusal, because the failure it prevents is silent — the
// packet-type numberings do not overlap between generations, so a 4.0-framed command written to a 5.0
// strap is a *different message* rather than a rejected one.
assertTest(WhoopProtocolProfile.profile(for: .whoop4) == .whoop4, "whoop4 has a profile")
for generation in [WhoopHardwareGeneration.whoop5, .whoop5MG, .standardBleHR, .simulator] {
    assertTest(
        WhoopProtocolProfile.profile(for: generation) == nil,
        "\(generation.rawValue) has no profile — this build cannot frame for it")
}
let catalog = WhoopProtocolCatalog()
assertTest(catalog.supportsProprietarySync(.whoop4), "Catalog reports sync implemented for 4.0")
for generation in [WhoopHardwareGeneration.whoop5, .whoop5MG, .standardBleHR, .simulator] {
    assertTest(
        !catalog.supportsProprietarySync(generation),
        "Catalog reports sync not implemented for \(generation.rawValue)")
}

// The three models the user can choose, derived from the cases rather than listed beside them — a
// hardcoded list is one that a new case silently fails to join.
assertTest(
    WhoopHardwareGeneration.selectableModels == [.whoop4, .whoop5, .whoop5MG],
    "The selectable models are exactly the three straps, 5.0 and MG distinct")

// A hand-built 5.0-shaped profile, so the encoder's refusal is asserted against a real profile value
// rather than against `nil`. `headerChecksum` is the field the builder switches on.
let syntheticFive = WhoopProtocolProfile(
    generation: .whoop5,
    headerChecksum: .crc16ModbusOverHeader,
    innerOrigin: 8,
    innerPrefixBytes: 3,
    packetTypes: WhoopProtocolProfile.PacketTypes(
        command: 35, commandResponse: 36, historicalData: 47, event: 48, metadata: 49))
assertTest(
    WhoopPacketEncoder.pingCommand(profile: syntheticFive, seq: 1) == nil,
    "Encoder refuses to build a frame under an envelope it has no builder for")
assertTest(
    WhoopPacketEncoder.hapticAlarmCommand(profile: syntheticFive, seq: 1) == nil,
    "Every command builder refuses the unimplemented envelope")

// Which model a strap is: a stored choice, never overridden by the guess.
//
// The precedence rule, asserted directly. `resolvedGeneration` is a static function of its two inputs
// precisely so this is reachable — constructing a `WhoopBLEManager` would raise a system Bluetooth
// prompt in the middle of a test run.
assertTest(
    WhoopBLEManager.resolvedGeneration(stored: .whoop5MG, advertisedName: "WHOOP Strap")
        == .whoop5MG,
    "A stored choice wins over the name heuristic")
assertTest(
    WhoopBLEManager.resolvedGeneration(stored: .whoop4, advertisedName: "WHOOP 5.0")
        == .whoop4,
    "A stored choice is not overridden by a name that advertises the opposite")
assertTest(
    WhoopBLEManager.resolvedGeneration(stored: nil, advertisedName: "WHOOP 5.0") == .whoop5,
    "With nothing stored, the name heuristic still answers")
assertTest(
    WhoopBLEManager.resolvedGeneration(stored: nil, advertisedName: "WHOOP Strap") == .whoop4,
    "An unnamed strap falls back to 4.0 — the heuristic cannot read a name it was never given")

// MARK: - 2. Packet Decoder Tests
print("\n[2/15] Testing WHOOP Packet Decoder...")
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

// Proprietary 0xAA frames.
//
// This used to decode a frame built in the *encoder's* old layout — `[0xAA, 0x01, 16, 0x00]`, cmd at
// index 1 — into a `.liveBiometric` payload the app had invented. Two things were wrong with that and
// both are why this block is now built from the encoder instead of by hand: the layout was not the
// documented one (byte 1 is a *length*, not a command), and `BLE_PROTOCOL.md` §2 documents no
// live-telemetry packet type at all. The decoder now returns the envelope's contents undecoded, which
// is the half that is specified, and the assertions below pin the four checks it performs.
let envelopeProfile = WhoopProtocolProfile.whoop4

// A well-formed frame, produced by the encoder so the two halves cannot drift apart unnoticed. It is
// a *command* frame, which is one of the five types §2 does document.
let wellFormed = WhoopPacketEncoder.buildPacket(
    profile: envelopeProfile,
    type: envelopeProfile.packetTypes.command,
    seq: 0x2A,
    cmd: 0x10,
    payload: Data([0x03, 0x01]))!
let rawFrame = decoder.decodeProprietaryFrame(data: wellFormed, profile: envelopeProfile)
assertTest(rawFrame != nil, "Decoded a well-formed proprietary 0xAA frame")
assertTest(rawFrame?.generation == .whoop4, "The frame reports the generation it was framed for")
assertTest(rawFrame?.type == envelopeProfile.packetTypes.command, "Type is read from inner[0] (0x23)")
assertTest(rawFrame?.seq == 0x2A, "Seq is read from inner[1]")
assertTest(rawFrame?.cmd == 0x10, "Cmd is read from inner[2] — the field the old decoder called a length")
assertTest(rawFrame?.payload == Data([0x03, 0x01]), "Payload is everything after the three-byte prefix")

// Dispatch is type-first, and the type is not the cmd. Under the documented envelope the old
// `case 0x30` fired on a payload length and the old `case 0x20` on a command, which is the whole of
// the type/opcode confusion `BLE_PROTOCOL.md` §3 also flags in the handshake table. A command frame
// whose cmd happens to equal a *packet type* constrains them to be different fields.
let cmdEqualsType = WhoopPacketEncoder.buildPacket(
    profile: envelopeProfile,
    type: envelopeProfile.packetTypes.historicalData,
    seq: 1,
    cmd: envelopeProfile.packetTypes.command,
    payload: Data())!
let historical = decoder.decodeProprietaryFrame(data: cmdEqualsType, profile: envelopeProfile)
assertTest(
    historical?.type == envelopeProfile.packetTypes.historicalData,
    "A cmd equal to the command type does not change the frame's type")
assertTest(
    historical?.cmd == envelopeProfile.packetTypes.command,
    "The opcode is reported in its own field, not conflated with the type")

// The four checks, each asserted as a refusal. Before this the decoder could not fail: any `0xAA`
// byte was a frame boundary, a payload byte that happened to be `0xAA` was indistinguishable from
// one, and no inbound checksum was verified anywhere in `Sources/`.
func reject(_ data: Data, _ message: String) {
    assertTest(
        decoder.decodeProprietaryFrame(data: data, profile: envelopeProfile) == nil,
        message)
}

// 1. Start of frame.
var badSOF = wellFormed
badSOF[0] = 0xAB
reject(badSOF, "A frame not beginning 0xAA is refused")

// 2. Header checksum — the byte the 4.0 format specifies CRC8 over, corrupted.
var badHeaderCRC = wellFormed
badHeaderCRC[3] = badHeaderCRC[3] &+ 1
reject(badHeaderCRC, "A frame with a wrong header crc8 is refused")

// 3. Payload checksum, over the inner record.
var badPayloadCRC = wellFormed
badPayloadCRC[5] = badPayloadCRC[5] &+ 1
reject(badPayloadCRC, "A frame whose inner record does not match its crc32 is refused")

// 4. Declared length — a truncated frame, and one whose length field was never true. A parser that
// sliced on the declared length alone would read past the buffer or return plausible garbage.
reject(wellFormed.dropLast(), "A truncated frame is refused")
var lyingLength = wellFormed
lyingLength[1] = 0x40
assertTest(
    decoder.decodeProprietaryFrame(data: lyingLength, profile: envelopeProfile) == nil,
    "A frame declaring a length beyond its own size is refused")

// 5. The envelope itself. A profile this build cannot slice is refused rather than parsed with 4.0's
// offsets — the same property `profile(for:)` enforces one level up, asserted here at the decoder.
assertTest(
    decoder.decodeProprietaryFrame(data: wellFormed, profile: syntheticFive) == nil,
    "The decoder refuses an envelope it has no offsets for")

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
print("\n[3/15] Testing HRV (RMSSD, SDNN, pNN50) & Artifact Rejection...")
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
print("\n[4/15] Testing Strain Integrator & Karvonen Zones...")
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
print("\n[5/15] Testing Recovery z-Score Baseline Model...")
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
print("\n[6/15] Testing DI Container, Use Cases & Data Sovereignty Export...")
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
    print("\n[7/15] Testing migrations, biometric round-trip and day-keyed writes...")
    await runPersistenceTests()

    // MARK: - 8. HRV Metric Isolation & Baseline Guards
    print("\n[8/15] Testing HRV metric isolation, baseline guards and formatters...")
    runScoringAndFormatterTests()

    // MARK: - 9. HealthKit Import (hermetic: fixture store + in-memory database)
    print("\n[9/15] Testing HealthKit import attribution, skipping and idempotency...")
    await runHealthKitImportTests()

    // MARK: - 10. Days with no data
    print("\n[10/15] Testing no-data days store zeros, and zeros never enter a baseline...")
    await runNoDataDayTests()

    // MARK: - 11. WHOOP export import (real CSV, in-memory database)
    print("\n[11/15] Testing the WHOOP export import against the real file...")
    await runWhoopExportImportTests()

    // MARK: - 12. Choosing a day
    print("\n[12/15] Testing that a chosen day is read, and an imported day is never overwritten...")
    await runDaySelectionTests()

    // MARK: - 13. Sleep Need
    print("\n[13/15] Testing that a night's Sleep Need follows the previous day's Strain...")
    await runSleepNeedTests()

    // MARK: - 14. The Home screen's sources
    print("\n[14/15] Testing recorded workouts, HealthKit steps, the Stress Monitor, the recovery ring tiers and the seven-day MetricWeek join...")
    await runHomeSourceTests()

    // MARK: - 15. The typical range
    print("\n[15/15] Testing the sleep stage typical range, its whole-percent column, its absence rules, the night's heading and the hours-vs-needed card...")
    await runTypicalRangeTests()

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
    // `naps` is `v11`'s table and is the only id-keyed one of the six — see §14 for why.
    for expected in ["recoveries", "sleeps", "strains", "user_profiles", "biometric_samples", "naps"] {
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

    // **The anchor the real screen passes is an instant, and every fixture above is snapped** — which
    // is how the day came to be inside its own baseline on the Recovery page while these assertions
    // passed. `RecoveryViewModel.loadBaselines` hands `RecoveryScoring.baselineWindow` the `Date` it
    // is displaying, which is `Date()` or the day a caller seeded, and on every day this app runs that
    // is some hours after midnight — so a raw `< day` let the day's own `startOfDay` row through and
    // the printed mean was taken over a different set of days than the score above it. Measured on
    // the simulator: 2026-08-17 printed an HRV baseline of 53 and a sleep-performance baseline of 80,
    // where the strictly-before window gives 52 and 78. The 2026-08-22 screenshot both windows agree
    // on is the reason it went unnoticed — they diverge on roughly one day in fifteen.
    let midMorning = day(0).addingTimeInterval(9 * 3600 + 37 * 60)
    assertTest(
        !RecoveryScoring.baselineWindow(before: midMorning, in: withToday)
            .contains { $0.date == day(0) },
        "An instant anchor mid-way through the day still excludes that day's own row — the anchor is "
            + "snapped to the calendar day, so the screen and the importer cannot disagree about "
            + "which days the mean covers")
    assertTest(
        RecoveryScoring.baselineWindow(before: midMorning, in: withToday).count == scoringWindowDays,
        "…and the window it returns is still the full \(scoringWindowDays) days, so snapping the "
            + "anchor drops the day rather than the oldest observation")

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
    assertTest(
        RecoveryScoring.baselineWindow(before: midMorning, in: nightsPlusToday).count == 3,
        "…and it stays strictly before under the instant anchor the screen actually passes (got "
            + "\(RecoveryScoring.baselineWindow(before: midMorning, in: nightsPlusToday).count)) — "
            + "this overload is the one that carried the sleep-performance row's printed mean, which "
            + "read 80 on a day the strictly-before window makes 78")

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
        case .stepCount: all = []
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

/// `sleeps.csv`, which this app reads for its nap rows and nothing else — see `parseNaps`.
/// The day key the synthetic nap fixture lands on, derived from the file rather than retyped — the
/// same shape §11 uses for the export's own day keys, so the assertion holds in any time zone.
func crossingNapsStart(syntheticURL: URL, calendar: Calendar) -> Date {
    let rows = (try? WhoopExportParser.parseNaps(at: syntheticURL)) ?? []
    return calendar.startOfDay(for: rows.first?.sleepOnset ?? Date())
}

func whoopNapsURL() -> URL {
    whoopExportURL().deletingLastPathComponent()
        .appendingPathComponent("sleeps.csv")
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
    let napRepository = GRDBNapRepository(db: db)
    let importer = WhoopExportImporter(
        recoveryRepository: recoveryRepository,
        sleepRepository: sleepRepository,
        strainRepository: strainRepository,
        napRepository: napRepository,
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
        let strainSurplus = summary.strainsWritten - summary.recoveriesWritten
        if !recoveryDaysWithoutStrain.isEmpty {
            assertTest(
                summary.strainOnlyDays > strainSurplus,
                "The set difference (\(summary.strainOnlyDays)) exceeds strains − recoveries "
                    + "(\(strainSurplus)) because "
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
        assertTest(
            knownSleep?.sleepDebtSeconds == 77 * 60,
            "Sleep debt became seconds (77 min), not minutes — a raw 77 would render as a 1-minute "
                + "debt on a row that reads in minutes (got \(knownSleep?.sleepDebtSeconds ?? -1))")
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

        // ── Naps, which are a second file rather than a second table ─────────────────────────────
        //
        // `sleeps.csv`'s eight nap rows are its entire unique contribution: its other 910 rows are
        // this file's 910 nights, set-for-set. So the whole of this path is exercised here against
        // the real file rather than a fixture, and the two properties that matter are asserted
        // separately — that a nap lands on the day it was *taken*, and that it is stored as a nap
        // (a window and a duration) and never as a night carrying a performance.
        let napsURL = whoopNapsURL()
        var napsWritten = 0
        if !FileManager.default.fileExists(atPath: napsURL.path) {
            assertTest(false, "The bundled sleep file is missing at \(napsURL.path)")
        } else {
            let napRows = try WhoopExportParser.parseNaps(at: napsURL)
            assertTest(!napRows.isEmpty, "The sleep file carries nap rows (\(napRows.count))")
            assertTest(napRows.allSatisfy { $0.isNap == true }, "…and every row it returns is one")

            // Pointed at the cycle file, the nap parser must refuse rather than find nothing. This is
            // the assertion that fails if `Nap` stops being a required column: without it the parser
            // reads the whole cycle file, filters to zero rows, and reports a successful import of
            // nothing — the failure shape `WhoopExportError` exists to prevent.
            do {
                _ = try WhoopExportParser.parseNaps(at: csvURL)
                assertTest(false, "Pointing the nap parser at the cycle file throws")
            } catch let error as WhoopExportError {
                if case .missingColumns(let names) = error {
                    assertTest(
                        names == ["Nap"],
                        "…naming the one column the cycle file lacks, by its own header spelling "
                            + "(got \(names))")
                } else {
                    assertTest(false, "The nap parser refused the cycle file with \(error)")
                }
            }

            napsWritten = try await importer.importNaps(at: napsURL)
            assertTest(
                napsWritten == napRows.count,
                "Every parsed nap is written (\(napsWritten) of \(napRows.count))")

            // Read back through the same keyed lookup the sleep screen uses. The day key is the nap's
            // own onset, stated as a property rather than a count so it holds in any time zone.
            var readBackNaps: [SleepNap] = []
            for day in Set(napRows.compactMap { $0.sleepOnset.map(dayCalendar.startOfDay(for:)) }) {
                readBackNaps += try await napRepository.getNaps(on: day)
            }
            assertTest(
                readBackNaps.count == napsWritten,
                "Every written nap is reachable by the day it was taken "
                    + "(\(readBackNaps.count) of \(napsWritten))")
            assertTest(
                readBackNaps.allSatisfy { $0.date == dayCalendar.startOfDay(for: $0.startTime) },
                "Every nap's day key is its own onset, not its wake")
            assertTest(
                readBackNaps.allSatisfy { $0.id == String(Int($0.startTime.timeIntervalSince1970)) },
                "…and its identity is that same instant, so a re-import updates the row it wrote")

            // The measured fact behind `SleepNap`'s whole reason for existing: every nap is shorter
            // than every need on the same rows. WHOOP's own `Sleep performance %` for these eight is
            // 6–43 because its denominator is a *night's* need, so reading it as a performance would
            // file a deliberate 33-minute nap as a 6% night. Both figures are the file's rather than
            // hardcoded, so the assertion says the same thing on any export.
            let napAsleep = napRows.compactMap(\.asleepMinutes)
            let napNeeds = napRows.compactMap(\.sleepNeedMinutes)
            assertTest(
                napAsleep.count == napRows.count && napNeeds.count == napRows.count,
                "Every nap row carries both an asleep duration and a need")
            if let longestNap = napAsleep.max(), let shortestNeed = napNeeds.min() {
                assertTest(
                    longestNap < shortestNeed,
                    "The longest nap (\(Int(longestNap)) min) is shorter than the shortest need "
                        + "(\(Int(shortestNeed)) min), which is why a nap's own performance is not "
                        + "a performance")
            }

            // A nap's window is not the night table's rule, and the difference is a whole day. Driven
            // through a synthetic *file* rather than the export, because which of the export's eight
            // cross midnight depends on the device time zone — this does not. It carries the whole
            // slice: parse, key, write, read back, which is what makes it a test of the path rather
            // than of one function.
            // The zone is written as the *device's* offset, not as UTC. The export's timestamps are
            // local wall-clock plus the zone they were recorded in, and the day key is then snapped
            // with `Calendar.current` — so a fixture pinned to UTC asserts this property only on a
            // machine that happens to run in UTC. Written as the device's own offset, 23:48 → 02:36
            // crosses local midnight wherever the suite runs, which is what makes it a test of the
            // rule rather than of the time zone.
            let deviceOffset = TimeZone.current.secondsFromGMT()
            let sign = deviceOffset < 0 ? "-" : "+"
            let magnitude = abs(deviceOffset)
            let deviceZoneLabel = String(
                format: "UTC%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)

            let syntheticURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("whoopsy-nap-fixture.csv")
            try ("Cycle start time,Cycle timezone,Wake onset,Sleep onset,Nap,"
                + "Asleep duration (min),Sleep need (min)\n"
                + "2024-08-26 23:48:00,\(deviceZoneLabel),2024-08-27 02:36:00,"
                + "2024-08-26 23:48:00,true,149,585\n")
                .write(to: syntheticURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: syntheticURL) }

            let crossingDB = LocalDatabaseManager(inMemory: true)
            let crossingRepository = GRDBNapRepository(db: crossingDB)
            let crossingWritten = try await WhoopExportImporter(
                recoveryRepository: GRDBRecoveryRepository(db: crossingDB),
                sleepRepository: GRDBSleepRepository(db: crossingDB),
                strainRepository: GRDBStrainRepository(db: crossingDB),
                napRepository: crossingRepository,
                userProfileRepository: GRDBUserProfileRepository(db: crossingDB),
                calendar: dayCalendar
            ).importNaps(at: syntheticURL)

            let crossingNaps = try await crossingRepository.getNaps(
                on: crossingNapsStart(syntheticURL: syntheticURL, calendar: dayCalendar))
            assertTest(crossingWritten == 1, "A nap file with one nap writes one row (got \(crossingWritten))")
            if let crossing = crossingNaps.first {
                assertTest(
                    crossing.date == dayCalendar.startOfDay(for: crossing.startTime),
                    "A nap that ends the next morning is filed under the evening it began")
                assertTest(
                    crossing.date != dayCalendar.startOfDay(for: crossing.endTime),
                    "…which is a different day from its wake, so the night table's rule would have "
                        + "moved it a day forward")
                assertTest(
                    crossing.asleepSeconds == 149 * 60,
                    "…and its duration is the asleep figure, not the length of its window "
                        + "(got \(crossing.asleepSeconds) s)")
            } else {
                assertTest(false, "The crossing-midnight nap is readable on the evening it began")
            }
        }

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

        // Naps are idempotent by a different mechanism than the day-keyed tables — an id derived from
        // the nap's own start instant rather than a snapped day — and it is worth its own assertion,
        // because a fresh `UUID()` here would write eight more rows on every press of the button.
        let secondNaps = try await importer.importNaps(at: whoopNapsURL())
        var napsAfterSecond: [SleepNap] = []
        for day in Set(try WhoopExportParser.parseNaps(at: whoopNapsURL())
            .compactMap { $0.sleepOnset.map(dayCalendar.startOfDay(for:)) }) {
            napsAfterSecond += try await napRepository.getNaps(on: day)
        }
        assertTest(
            secondNaps == napsWritten,
            "A second nap import writes \(napsWritten) rows again, every one onto a row that "
                + "already existed (got \(secondNaps))")
        assertTest(
            napsAfterSecond.count == napsWritten,
            "…and adds none: the table still holds \(napsWritten) naps (got \(napsAfterSecond.count))")
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
    let napRepository = GRDBNapRepository(db: db)
    let profile = GRDBUserProfileRepository(db: db)

    do {
        _ = try await WhoopExportImporter(
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            napRepository: napRepository,
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

        // The week card at the foot of the same screen. A `nil` week and a week with no measurement in
        // it draw the same thing — no chart — so a wiring break here is invisible on screen, which is
        // why the assignment is asserted rather than left to the screenshot.
        let loadedWeek = await MainActor.run { recoveryViewModel.week }
        assertTest(
            loadedWeek != nil,
            "A day loaded through the view model builds the week card's window")
        assertTest(
            loadedWeek?.days.count == MetricWeek.dayCount,
            "…with exactly \(MetricWeek.dayCount) slots (got \(loadedWeek?.days.count ?? -1))")
        assertTest(
            loadedWeek?.endingOn == lastRecoveryDay.startOfDay,
            "…ending on the day that was loaded, not on today")
        assertTest(
            loadedWeek?.days.last?.recoveryScore == recoveryBefore?.recoveryScore,
            "…whose last slot carries the stored day's own score, so the bar and the ring describe one day")

        // A deliberate documentation of the narrowing, in the shape of the `batteryPercentage == 100`
        // assertion below: the page's week is built from the recovery history **alone**, so `strain` is
        // `nil` on every slot and that `nil` means *not asked for* rather than *not measured*. This
        // fails loudly if anyone points the week at a strain-plotted view, where every day of it would
        // read as unmeasured.
        assertTest(
            loadedWeek?.days.allSatisfy { $0.strain == nil } == true,
            "The Recovery page's week carries no strain on any slot — it is built from one history, and that `nil` is 'not asked for', not 'not measured'")

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
                repository: sleepRepository,
                napRepository: napRepository,
                biometricRepository: strapThatRecordedNothing)
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

        // The same night, for the two values this turn gave a strap producer. The fixture's samples
        // carry no R-R series at all, so neither has anything to be computed from and both must be
        // **absent**. `respiratoryRate` is the one the strap has no sensor for, and a `0` there would
        // read as a stopped breath; `sleepDebtSeconds` is absent because this is the first night, and
        // a `0` would claim the user is in perfect sleep credit.
        assertTest(
            stored?.respiratoryRate == nil,
            "A night whose samples carry no R-R series stores no respiratory rate — the R-R series is "
                + "the only thing on the strap path that can produce one")
        assertTest(
            stored?.sleepDebtSeconds == nil,
            "…and no sleep debt, because there is no earlier night to accumulate from and `0` is a "
                + "measurement this app has not made")

        // ── Whose need it is, which is the one thing the two producers' rows do not show ─────────
        //
        // This night carries a need and no debt, but the debt is absent for the *incidental* reason
        // above — a first night has no priors — and not because this path cannot produce one.
        // `SleepDebtMath` gives it one from the second night onward, so a stored row is not evidence
        // of which producer wrote it and nothing in the two figures is either. The flag is: WHOOP's
        // need is a total containing its debt term and this app's is not, and the need card's box is
        // drawn on that difference alone.
        assertTest(
            stored?.hasWhoopSleepNeed == false,
            "A classified night reads back as **this app's** need rather than WHOOP's, so the need "
                + "card draws its bars and no breakdown box for it")

        // The `?? true` is deliberate and is the shape that makes this assertion bite: were the flag
        // ever lost from the entity, the fallback would hand the split the value that *permits* it and
        // this would fail alongside the assertion above rather than passing for want of a value.
        assertTest(
            SleepNeedBreakdown.breakdown(
                needSeconds: expected,
                debtSeconds: 3600,
                hasWhoopNeed: stored?.hasWhoopSleepNeed ?? true) == nil,
            "…and that night's own need with an hour of debt produces no split, because a debt on a "
                + "`SleepNeedMath` need is not a part of it — the box's first row would be labelled "
                + "for two of WHOOP's terms over a figure holding neither")

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

    // ── Sleep Consistency ────────────────────────────────────────────────────────────────────────
    //
    // `SleepConsistencyMath` is the second fitted model in this section and its constants are pinned
    // the same way. The assertions below are the ones that fail if the link function, the weights,
    // the ordering or the window change — each of which was a measured finding, not a preference.
    //
    // Every night here is built on one calendar day and differs only in clock time. `nightClockMinutes`
    // reads hour and minute and nothing else, so which day a date sits on is not part of the model —
    // which is exactly the property that lets an onset before midnight and a wake after it be compared
    // without the caller deciding which day either belongs to.
    //
    // The clock times are set with `bySettingHour:`, not by adding minutes to midnight: `date(byAdding:
    // .minute,)` adds *elapsed* time, so on a spring-forward day 420 minutes after midnight is 08:00
    // on the wall and every literal below would move. The hours used here (22:00–23:59, 06:00–07:59)
    // are outside both the 02:00 gap and the 01:00 fold, so the wall clock is unambiguous all year.
    do {
        let consistencyCalendar = Calendar.current
        let consistencyBase = consistencyCalendar.startOfDay(for: Date())

        /// A clock time, `shift` minutes earlier than `hour`:`minute` on the same wall clock.
        func earlier(_ hour: Int, _ minute: Int, by shift: Int) -> (Int, Int) {
            let total = (hour * 60 + minute - shift + 1440) % 1440
            return (total / 60, total % 60)
        }

        func night(dayOffset: Int, onset: (Int, Int), wake: (Int, Int)) -> SleepConsistencyMath.Night {
            let day = consistencyCalendar.date(
                byAdding: .day, value: -dayOffset, to: consistencyBase)!
            let onsetDate = consistencyCalendar.date(
                bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!
            let wakeDate = consistencyCalendar.date(
                bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!
            return SleepConsistencyMath.Night(day: day, onset: onsetDate, wake: wakeDate)
        }

        // Tonight at 23:00–07:00, and four priors at the same clock times, each shifted later-to-
        // earlier by the given number of minutes on *both* boundaries. The shifts are newest-first.
        func scored(priorsNewestFirst shifts: [Int]) -> Int? {
            let history = shifts.enumerated().map { index, shift in
                night(
                    dayOffset: index + 1,
                    onset: earlier(23, 0, by: shift),
                    wake: earlier(7, 0, by: shift))
            }
            return SleepConsistencyMath.consistency(
                for: night(dayOffset: 0, onset: (23, 0), wake: (7, 0)), history: history)
        }

        // ── The formula, pinned to literals ──────────────────────────────────────────────────────
        //
        // P is the recency-weighted mean circular boundary shift in minutes and C = 107.4883 −
        // 1.81848·P^0.60 clipped to 0–100, so each case below is hand-computable from that sentence.
        // Four priors each 30 min off: P = (4+3+2+1)·30·2/10 = 60, raw 86.2754, C = 86. The three
        // newest 30 min off and the oldest on time: P = (4+3+2)·30·2/10 = 54, C = 88. An hour off on
        // every boundary: P = 120, C = 75. No shift at all: raw 107.4883, which the 0–100 clip
        // reduces to a perfect 100.
        let flat = scored(priorsNewestFirst: [0, 0, 0, 0])
        assertTest(
            flat == 100,
            "Four priors at the same clock time score the ceiling — P = 0 gives a raw 107.4883, "
                + "which clips to 100 (got \(flat.map(String.init) ?? "nil"))")
        let allThirty = scored(priorsNewestFirst: [30, 30, 30, 30])
        assertTest(
            allThirty == 86,
            "Four priors each 30 min off score 86 — P = 60, raw 86.2754 "
                + "(got \(allThirty.map(String.init) ?? "nil"))")
        let threeRecent = scored(priorsNewestFirst: [30, 30, 30, 0])
        assertTest(
            threeRecent == 88,
            "Three recent priors 30 min off and the oldest on time score 88 — P = 54 "
                + "(got \(threeRecent.map(String.init) ?? "nil"))")
        let allSixty = scored(priorsNewestFirst: [60, 60, 60, 60])
        assertTest(
            allSixty == 75,
            "An hour of drift on every boundary scores 75 — P = 120 "
                + "(got \(allSixty.map(String.init) ?? "nil"))")
        assertTest(
            SleepConsistencyMath.shiftInterceptPercent == 107.4883
                && SleepConsistencyMath.shiftCoefficient == 1.81848
                && SleepConsistencyMath.shiftExponent == 0.60,
            "The fitted constants are unchanged — they are a least-squares fit over the 891 scorable "
                + "nights of the bundled export, not a published figure, and the exponent is 0.60 "
                + "rather than 1 because the score is concave in the mean shift")

        // ── Recency weighting is real, and its direction is the assertion ────────────────────────
        //
        // The same total drift, concentrated in the recent priors or in the old ones, must not score
        // the same. 4:3:2:1 puts (4+3+2)·30 = 270 weighted minutes on the recent arrangement and
        // (1+2+3)·30 = 180 on the old one, so recent drift scores *lower*. An implementation that
        // sorted oldest-first, or that dropped the weights for a flat mean, gets 88 for both — which
        // is why this is a pair and not a single case.
        let oldDrift = scored(priorsNewestFirst: [0, 30, 30, 30])
        assertTest(
            threeRecent == 88 && oldDrift == 92,
            "Drift in the recent nights costs more than the same drift in the old ones "
                + "(\(threeRecent.map(String.init) ?? "nil") vs \(oldDrift.map(String.init) ?? "nil"))")

        // ── Circular distance, across midnight ───────────────────────────────────────────────────
        //
        // 23:50 and 00:10 are 20 minutes apart, not 1420. 297 of the export's 910 nights have an
        // onset before midnight, so a naive clock subtraction gets 613 of them wrong — and it is
        // wrong by the most exactly where the schedule is most regular.
        assertTest(
            SleepConsistencyMath.circularMinuteDistance(1430, 10) == 20,
            "23:50 and 00:10 are 20 minutes apart, not 1420")
        assertTest(
            SleepConsistencyMath.circularMinuteDistance(10, 1430) == 20,
            "…and the distance is symmetric")
        assertTest(
            SleepConsistencyMath.circularMinuteDistance(0, 720) == 720,
            "The widest possible gap is half a day, not a whole one")

        // The pivot is what makes the pair above 20 rather than 1420: night-clock minutes are
        // measured from noon, so an evening onset and a small-hours onset both land beside the 720
        // mark instead of at opposite ends of a 1440-long day.
        let lateOnset = SleepConsistencyMath.nightClockMinutes(
            night(dayOffset: 0, onset: (23, 50), wake: (7, 0)).onset)
        let earlyOnset = SleepConsistencyMath.nightClockMinutes(
            night(dayOffset: 0, onset: (0, 10), wake: (7, 0)).onset)
        assertTest(
            lateOnset == 710 && earlyOnset == 730,
            "The night clock pivots at noon — 23:50 is 710 and 00:10 is 730, so the two are 20 "
                + "apart (got \(Int(lateOnset)) and \(Int(earlyOnset)))")

        // A night whose priors sit 20 minutes away across midnight scores near the ceiling. Under a
        // naive minute-of-day difference the same pair differs by 1420 minutes, which the model would
        // clip to 0 — so this single assertion separates the two implementations by 91 points.
        let wrapHistory = (1...4).map { offset in
            night(dayOffset: offset, onset: (0, 10), wake: (7, 10))
        }
        let wrapped = SleepConsistencyMath.consistency(
            for: night(dayOffset: 0, onset: (23, 50), wake: (7, 30)), history: wrapHistory)
        assertTest(
            wrapped == 91,
            "A 23:50 onset against 00:10 priors scores 91 — P = 40, raw 90.8563 "
                + "(got \(wrapped.map(String.init) ?? "nil"))")

        // ── The window is four nights, counted in records rather than in days ────────────────────
        let baseNight = night(dayOffset: 0, onset: (23, 0), wake: (7, 0))
        for priorCount in 1...3 {
            let short = (1...priorCount).map { night(dayOffset: $0, onset: (23, 0), wake: (7, 0)) }
            assertTest(
                SleepConsistencyMath.consistency(for: baseNight, history: short) == nil,
                "\(priorCount) prior night\(priorCount == 1 ? "" : "s") is below the four-night "
                    + "window and scores nothing — there is no partial rendering, because at one "
                    + "prior the model's own MAE is 6.5, worse than saying nothing")
        }
        assertTest(
            SleepConsistencyMath.consistency(
                for: baseNight,
                history: (1...4).map { night(dayOffset: $0, onset: (23, 0), wake: (7, 0)) }) != nil,
            "The fourth prior is what makes a night scorable")
        assertTest(
            SleepConsistencyMath.priorNightCount == 4,
            "The window is four priors, not the three WHOOP's own description names — refitting the "
                + "whole model at each window size peaks at four (MAE 2.749 against 3.119 at three)")
        assertTest(
            SleepConsistencyMath.recencyWeights == [4, 3, 2, 1],
            "The recency weights are 4:3:2:1 (got \(SleepConsistencyMath.recencyWeights))")

        // ── A gap is not four days ───────────────────────────────────────────────────────────────
        //
        // The window is the four most recent *records*, whatever their dates. A night whose fourth
        // predecessor is 10 days back is still scorable. The alternative — deriving the window by
        // subtracting calendar days — is what the export's 137-day recording gap and its 297
        // pre-midnight onsets both break. The caller narrows the read to `historyLookbackDays`; the
        // model itself does not care how far back the record sits.
        let gapHistory = [
            night(dayOffset: 1, onset: (23, 0), wake: (7, 0)),
            night(dayOffset: 2, onset: (23, 0), wake: (7, 0)),
            night(dayOffset: 3, onset: (23, 0), wake: (7, 0)),
            night(dayOffset: 10, onset: (23, 0), wake: (7, 0)),
        ]
        assertTest(
            SleepConsistencyMath.consistency(for: baseNight, history: gapHistory) != nil,
            "A night whose fourth prior is 10 days back is still scored — the window is four "
                + "records, not four calendar days")
        assertTest(
            SleepConsistencyMath.consistency(for: baseNight, history: Array(gapHistory.prefix(3))) == nil,
            "…and the same history truncated to three records is not, so that assertion is about "
                + "the fourth record rather than about the gap being forgiven")

        // Ordering is the model's own, not the caller's: the repositories return oldest-first and
        // the importer walks the export in file order, so priors arriving shuffled must score what
        // priors arriving newest-first score.
        let shuffledHistory = [
            night(dayOffset: 3, onset: (23, 30), wake: (7, 30)),
            night(dayOffset: 1, onset: (22, 30), wake: (6, 30)),
            night(dayOffset: 4, onset: (23, 45), wake: (7, 45)),
            night(dayOffset: 2, onset: (23, 0), wake: (7, 0)),
        ]
        assertTest(
            SleepConsistencyMath.consistency(for: baseNight, history: shuffledHistory)
                == SleepConsistencyMath.consistency(
                    for: baseNight, history: shuffledHistory.sorted { $0.day > $1.day }),
            "The model sorts the history itself — a shuffled array scores what an ordered one does, "
                + "so the weights land on the right nights either way")

        // A night dated *after* the one being scored is not a predecessor. This is what keeps a
        // forward-dated row — a time-zone artefact, a clock change — from being taken as the most
        // recent prior and given the heaviest weight.
        let futureNight = night(dayOffset: -1, onset: (23, 0), wake: (7, 0))
        assertTest(
            SleepConsistencyMath.consistency(
                for: baseNight, history: gapHistory + [futureNight]) != nil
                && SleepConsistencyMath.consistency(
                    for: baseNight, history: Array(gapHistory.prefix(3)) + [futureNight]) == nil,
            "A night dated after the one being scored is not counted as a prior")
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
            napRepository: GRDBNapRepository(db: exportDB),
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

        // ── Sleep Consistency is WHOOP's number, not ours ────────────────────────────────────────
        //
        // Same shape of guard as the need above, and it needs one for the same reason: the importer
        // stores the export's `Sleep consistency %` verbatim, while a *strap* night goes through
        // `SleepConsistencyMath` — and the two are the same `Int` on the same column, so nothing but
        // an assertion keeps one from being quietly routed through the other.
        //
        // The property that separates them is disagreement. The model reproduces WHOOP's figure
        // closely but not exactly (in sample, 79% of nights within ±3 points), so if the stored values
        // had been recomputed rather than read, the two would agree on *every* night. Counting the
        // nights they disagree on by more than the model's own error bar is the assertion that fails
        // under that rewrite — and it is a count of a property rather than of a fixed number of
        // nights, so a device time zone that merges two day keys narrows it without breaking it.
        let consistencies = imported.compactMap(\.sleepConsistency)
        assertTest(
            consistencies.count > 850,
            "The export still imports its own consistency values (\(consistencies.count) of "
                + "\(imported.count) nights carry one)")
        let outOfBand = consistencies.filter { $0 < 0 || $0 > 100 }
        assertTest(
            outOfBand.isEmpty,
            "Every imported consistency value is inside WHOOP's own 0–100 scale "
                + "(\(outOfBand.count) are not, e.g. \(outOfBand.prefix(3)))")

        let importedNights = imported.map {
            SleepConsistencyMath.Night(day: $0.date, onset: $0.startTime, wake: $0.endTime)
        }
        let scorable = imported.filter { session in
            importedNights.filter { $0.day < session.date }.count >= SleepConsistencyMath.priorNightCount
        }
        let disagreements = scorable.filter { session in
            guard let stored = session.sleepConsistency else { return false }
            let computed = SleepConsistencyMath.consistency(
                for: SleepConsistencyMath.Night(
                    day: session.date, onset: session.startTime, wake: session.endTime),
                history: importedNights)
            guard let computed else { return false }
            return abs(stored - computed) > 3
        }
        assertTest(
            disagreements.count > 50,
            "The stored consistency values are WHOOP's, not this app's recomputation — the model and "
                + "the export disagree by more than 3 points on \(disagreements.count) of "
                + "\(scorable.count) scorable nights, which a recomputed column could not do")
    } catch {
        assertTest(false, "The imported-history guard threw: \(error)")
    }

    // ── Respiratory rate, from the R-R series ────────────────────────────────────────────────────
    //
    // `RespiratoryRateMath` is the first signal processing in this repo and the only model here that
    // **cannot be checked against a column**. The export carries WHOOP's own figure for 910 nights and
    // an R-R series for none of them, so there is no night in this app's possession where a known
    // respiratory rate and the beats that produced it are both present. What the assertions below
    // cover is the plumbing — a synthetic tachogram modulated at a known rate comes back at that rate
    // — and the rules that decide whether the beats may be used at all. They are not evidence that the
    // figure agrees with a real strap, and `ALGORITHMS.md` §4 says so in as many words.
    do {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        /// A synthetic tachogram: beats whose R-R intervals are modulated by one or two sinusoids of
        /// known rate, chopped into packets whose arrival instants are exactly one packet-span apart.
        ///
        /// That last part is the whole point. The arrivals are the *generated* beat times, so the seam
        /// between consecutive packets carries no residual and the series is perfectly continuous —
        /// exactly the series a strap would produce if it never dropped a beat. `arrivalSpacing:`
        /// overrides it to produce the discontinuous case the estimator has to refuse.
        func syntheticPackets(
            _ components: [(bpm: Double, amplitudeMs: Double)],
            meanRRMs: Double = 600,
            intervalsPerPacket: Int = 10,
            packetCount: Int = 20,
            arrivalSpacing: Double? = nil,
            anchor: Date? = nil
        ) -> [(arrival: Date, intervals: [Double])] {
            let total = intervalsPerPacket * packetCount
            var times: [Double] = [0]
            var intervals: [Double] = []
            intervals.reserveCapacity(total)
            for _ in 0..<total {
                let t = times[times.count - 1]
                let modulation = components.reduce(0.0) { sum, component in
                    sum + component.amplitudeMs
                        * sin(2 * Double.pi * (component.bpm / 60) * t)
                }
                let rr = meanRRMs + modulation
                intervals.append(rr)
                times.append(t + rr / 1000)
            }

            // `anchor` matters only for the end-to-end block: `AnalyzeSleepUseCase` reads its samples
            // over `[morning − 11 h, morning + 10 h]`, so a series pinned at the reference date is
            // filtered away before it is ever classified — the store returns nothing and the night is
            // `nil` for a reason that has nothing to do with the R-R series under test.
            return (0..<packetCount).map { packet in
                let lower = packet * intervalsPerPacket
                let arrival = (anchor ?? start).addingTimeInterval(
                    arrivalSpacing.map { Double(packet + 1) * $0 }
                        ?? times[lower + intervalsPerPacket])
                return (arrival, Array(intervals[lower..<(lower + intervalsPerPacket)]))
            }
        }

        func beatPacket(
            _ packet: (arrival: Date, intervals: [Double])
        ) -> RespiratoryRateMath.BeatPacket {
            RespiratoryRateMath.BeatPacket(arrival: packet.arrival, rrIntervalsMs: packet.intervals)
        }

        func rate(_ components: [(bpm: Double, amplitudeMs: Double)],
                  packetCount: Int = 20,
                  arrivalSpacing: Double? = nil) -> Double? {
            RespiratoryRateMath.respiratoryRate(
                from: syntheticPackets(
                    components, packetCount: packetCount, arrivalSpacing: arrivalSpacing
                ).map(beatPacket))
        }

        // The estimator recovers a known modulation. 200 intervals at a 600 ms mean is 120 s of beats,
        // which is 18 overlapping windows — well past the three a median needs.
        let fifteen = rate([(bpm: 15, amplitudeMs: 40)])
        assertTest(
            fifteen.map { abs($0 - 15) <= 1 } ?? false,
            "A 600 ms tachogram modulated at 15 bpm is reported at 15 "
                + "(got \(fifteen.map { "\($0)" } ?? "nil")) bpm")

        // A second rate, deliberately not on a DFT bin: 20 bpm is 0.3333 Hz against a 0.005 Hz grid,
        // so it only comes back through the parabolic refinement of the peak's neighbours.
        let twenty = rate([(bpm: 20, amplitudeMs: 40)])
        assertTest(
            twenty.map { abs($0 - 20) <= 1 } ?? false,
            "…and a rate off the bin grid — 20 bpm, between two bins — is still reported at 20 "
                + "(got \(twenty.map { "\($0)" } ?? "nil")) bpm")

        // ── The band edges ───────────────────────────────────────────────────────────────────────
        //
        // These two are the cases `rejectsEdgePeak` exists for, and neither is a flatness question:
        // a Hann taper's main lobe is 4/T = 0.125 Hz wide, so a 5 bpm modulation leaks its whole lobe
        // into the bottom of the band and a 30 bpm one leaks a tail that rises toward the top. Both
        // clear `minimumPeakToMeanRatio`, so a spectrum-only implementation reports a breathing rate
        // for a signal that is not breathing at all.
        //
        // The 30 bpm case is the one that sets `edgeGuardBins`, and it does so because the obvious
        // reading of it is wrong. It does *not* peak on the last bin; it peaks on bin 59 of 61, one
        // inside the top, at 5.61× the mean — so a one-bin edge test let it through as a confident
        // 23.6 bpm. The guard is two bins at each end, and the assertion below is what would fail if
        // anyone narrowed it back on the assumption that leakage peaks *on* the edge.
        let five = rate([(bpm: 5, amplitudeMs: 40)])
        assertTest(
            five == nil,
            "A 5 bpm modulation is below the band and must not be reported as a breathing rate at the "
                + "band's floor (got \(five.map { "\($0)" } ?? "nil")) bpm")
        let thirty = rate([(bpm: 30, amplitudeMs: 40)])
        assertTest(
            thirty == nil,
            "…and a 30 bpm modulation above the band is not reported at its ceiling "
                + "(got \(thirty.map { "\($0)" } ?? "nil")) bpm")

        // ── Contiguity, which is the assertion that matters ──────────────────────────────────────
        //
        // `rrIntervalsMs` holds one notification's beats, adjacent by definition; across notifications
        // they are not, and `timestamp` is an arrival instant rather than a beat time. Nothing in the
        // schema records which packets follow which, so a run has to be inferred — and inferring it
        // wrongly is the defect `CLAUDE.md` records against the two RMSSD consumers, which difference
        // one interval per notification and so difference beats that were never adjacent.
        let joined = syntheticPackets([(bpm: 15, amplitudeMs: 40)], packetCount: 12)
        assertTest(
            RespiratoryRateMath.isContiguous(beatPacket(joined[0]), beatPacket(joined[1])),
            "A seam the later packet's own span accounts for is contiguous")
        // Twelve packets and not six, and the count is load-bearing rather than arbitrary: ten
        // intervals of 600 ms is 6 s of beats per packet, so six packets span 36 s — one 32 s window
        // at a 5 s step, below `minimumWindows`, and the night would come back `nil` for a reason that
        // has nothing to do with contiguity. Twelve packets span 72 s and yield nine windows. Both
        // halves of this pair use the same count so the comparison isolates the arrival spacing.
        assertTest(
            rate([(bpm: 15, amplitudeMs: 40)], packetCount: 12) != nil,
            "Twelve packets arriving one span apart chain into a run long enough to score")

        let split = syntheticPackets([(bpm: 15, amplitudeMs: 40)], packetCount: 12, arrivalSpacing: 90)
        assertTest(
            !RespiratoryRateMath.isContiguous(beatPacket(split[0]), beatPacket(split[1])),
            "The same beats with 90 s between arrivals are not — the seam is 84 s wider than the "
                + "6 s of beats that could account for it")
        assertTest(
            rate([(bpm: 15, amplitudeMs: 40)], packetCount: 12, arrivalSpacing: 90) == nil,
            "…and a night whose notifications are not continuous is a dash, not a tachogram stitched "
                + "across the gap")

        // ── A rejected packet leaves a hole, it does not get spliced ─────────────────────────────
        //
        // `HeartRateVariabilityMath.filterRRIntervals` **deletes** intervals, which costs its own
        // callers nothing because they only read the surviving values. A tachogram is a series in
        // time, so a deleted interval removes that much real elapsed time and draws the beats either
        // side of it as adjacent. Rejecting the whole packet instead leaves a gap, and the structural
        // assertion is that the gap lands the neighbours in *different* runs.
        var holed = syntheticPackets([(bpm: 15, amplitudeMs: 40)], packetCount: 6)
        holed[3].intervals.append(2500)
        let usable = RespiratoryRateMath.usablePackets(from: holed.map(beatPacket))
        assertTest(
            usable.count == 5,
            "A packet carrying a 2500 ms interval — outside the 300–2000 ms range RMSSD already "
                + "defines — is dropped whole (kept \(usable.count) of 6)")
        assertTest(
            RespiratoryRateMath.contiguousRuns(in: usable).count == 2,
            "…and the hole it leaves breaks the run in two rather than being stitched over "
                + "(got \(RespiratoryRateMath.contiguousRuns(in: usable).count) runs)")

        // ── `nil`, never `0.0` ───────────────────────────────────────────────────────────────────
        let nothing = RespiratoryRateMath.respiratoryRate(from: [])
        assertTest(
            nothing == nil,
            "No packets is `nil` and not `0.0` — the value `HeartRateVariabilityMath.calculateRMSSD` "
                + "returns on insufficient data, which here would read as a stopped breath")
        assertTest(
            RespiratoryRateMath.respiratoryRate(from: [
                RespiratoryRateMath.BeatPacket(arrival: start, rrIntervalsMs: [])
            ]) == nil,
            "…and so is a night of samples that carry no R-R series at all, which is the shape every "
                + "imported day has")

        // ── Nyquist: the beats have to be fast enough to carry the band ──────────────────────────
        assertTest(
            abs(RespiratoryRateMath.bandTopHeartRateBpm
                - 2 * RespiratoryRateMath.bandHighHz * 60) < 0.001,
            "The band's top edge of 0.4 Hz needs 48 bpm to exist at all — a modulation cannot be "
                + "observed at a rate above half the beat rate that samples it")
        assertTest(
            RespiratoryRateMath.resolvableHighHz(medianRRMs: 600) == RespiratoryRateMath.bandHighHz,
            "At 100 bpm the whole band is resolvable")
        assertTest(
            abs(RespiratoryRateMath.resolvableHighHz(medianRRMs: 60_000 / 45) - 0.3375) < 0.0001,
            "At 45 bpm — an ordinary sleeping heart rate — the ceiling is 45/120 × 0.9 = 0.3375 Hz, "
                + "so a rate above ~20 bpm is not reported from beats that cannot carry it (got "
                + "\(RespiratoryRateMath.resolvableHighHz(medianRRMs: 60_000 / 45)))")
        assertTest(
            RespiratoryRateMath.resolvableHighHz(medianRRMs: 200) == RespiratoryRateMath.bandHighHz,
            "…and a fast heart rate never raises the ceiling above the band itself")

        // ── Two comparable in-band components, and the harmonic rule that is not there ───────────
        //
        // 9 bpm is 0.15 Hz and its double is 0.30 Hz — inside the same band, so a waveform whose
        // harmonic outweighs its fundamental would report twice the true rate. The estimator does not
        // correct that, it **declines** the window: admitting one requires its peak to clear
        // `minimumPeakToMeanRatio`, and a second comparable tone raises the band's mean as much as the
        // peak, so the ratio collapses. Measured, this tachogram scores 3.38 where the same 18 bpm
        // tone alone scores 6.51.
        //
        // That is the whole of the behaviour and both halves are asserted, because the pair is what
        // distinguishes "declined" from "broken": a bare `nil` here would equally be an estimator that
        // cannot read a slow rhythm at all. A harmonic rule was implemented against this case and
        // removed once the measurement showed it could never fire — every window it could have acted
        // on had already been declined by flatness. If someone reintroduces one, this assertion is
        // what will fail and tell them why.
        let twoTone = rate([(bpm: 9, amplitudeMs: 40), (bpm: 18, amplitudeMs: 44)])
        assertTest(
            twoTone == nil,
            "A tachogram carrying a comparable 9 bpm and 18 bpm component has no dominant period, so "
                + "it is a dash rather than a rate picked from two (got "
                + "\(twoTone.map { "\($0)" } ?? "nil") bpm)")
        let pure = rate([(bpm: 18, amplitudeMs: 44)])
        assertTest(
            pure.map { abs($0 - 18) <= 1 } ?? false,
            "…and a single 18 bpm modulation is read plainly, so the dash above is the second "
                + "component and not an inability to score this rate (got "
                + "\(pure.map { "\($0)" } ?? "nil") bpm)")
        let slow = rate([(bpm: 9, amplitudeMs: 40)])
        assertTest(
            slow.map { abs($0 - 9) <= 1 } ?? false,
            "…nor an inability to score a slow one — 9 bpm alone is reported at 9, which is the "
                + "answer the two-tone case above is denied (got "
                + "\(slow.map { "\($0)" } ?? "nil") bpm)")

        // ── Sleep debt ───────────────────────────────────────────────────────────────────────────
        //
        // The accumulation is **lagged**: a night's debt is built from the nights before it and never
        // from its own shortfall. That is measured, not assumed — WHOOP's own `Sleep debt (min)`
        // column correlates 0.891 with the *previous* night's shortfall and 0.506 with its own, and
        // the shortfalls are only 0.42 autocorrelated, so it is not collinearity. A same-night model
        // is the tempting wrong answer and it scores MAE 16.03 against the lagged 8.31; the assertion
        // that catches it is the one below where the target's own shortfall is 479 minutes and the
        // answer is 2177 seconds.
        let day = Calendar.current.startOfDay(for: Date())
        let need: TimeInterval = 480 * 60

        func night(_ nightsAgo: Int, asleepMinutes: Double) -> SleepDebtMath.Night {
            SleepDebtMath.Night(
                day: day.addingTimeInterval(-Double(nightsAgo) * 86_400),
                needSeconds: need,
                asleepSeconds: asleepMinutes * 60)
        }

        let target = SleepDebtMath.Night(day: day, needSeconds: need, asleepSeconds: 480 * 60)

        // Shortfalls, newest first: 100, 200, 0, 50, 300 minutes.
        //   D = 100 + 0.15×200 + 0.15²×0 + 0.15³×50 + 0.15⁴×300 = 130.320625 min
        //   debt = 0.4293 × 130.320625 = 55.9466 min = 3356.8 s
        let history = [
            night(1, asleepMinutes: 380),
            night(2, asleepMinutes: 280),
            night(3, asleepMinutes: 480),
            night(4, asleepMinutes: 430),
            night(5, asleepMinutes: 180),
        ]
        let debt = SleepDebtMath.sleepDebtSeconds(for: target, history: history)
        assertTest(
            debt.map { abs($0 - 3357) <= 2 } ?? false,
            "Five nights short by 100/200/0/50/300 min accumulate "
                + "0.4293 × 130.320625 min and store 3357 s "
                + "(got \(debt.map { "\($0)" } ?? "nil"))")

        // The closed form, not a walk. A recurrence has loop-carried state, so the order the history
        // arrives in changes the answer — walking the export in its own newest-first file order moves
        // MAE from 8.31 to 22.69. Sorting the priors explicitly makes that unrepresentable.
        assertTest(
            SleepDebtMath.sleepDebtSeconds(for: target, history: history.reversed()) == debt,
            "The same priors in reverse order give the same answer, because the window is sorted "
                + "rather than walked")

        // The gate: the lagged form has a base case, so one prior night is a complete answer. This is
        // deliberately *not* `SleepConsistencyMath`'s four, whose quantity is a mean over four and has
        // no partial rendering.
        assertTest(
            SleepDebtMath.sleepDebtSeconds(for: target, history: []) == nil,
            "A night with nothing before it has nothing to accumulate and draws a dash")
        let onePrior = SleepDebtMath.sleepDebtSeconds(
            for: target, history: [night(1, asleepMinutes: 380)])
        assertTest(
            onePrior.map { abs($0 - 2576) <= 2 } ?? false,
            "…and a single prior night short by 100 min is enough — 0.4293 × 100 min = 2576 s "
                + "(got \(onePrior.map { "\($0)" } ?? "nil"))")

        // Strictly earlier only. A forward-dated row is a corrupt row, not a heavier prior.
        let future = SleepDebtMath.Night(
            day: day.addingTimeInterval(86_400), needSeconds: need, asleepSeconds: 0)
        assertTest(
            SleepDebtMath.sleepDebtSeconds(for: target, history: history + [future]) == debt,
            "A night dated after the target contributes nothing to it — the window is "
                + "strictly-earlier, so the lag cannot be undone by a stray row")

        // The truncation is non-binding: the sixth prior is beyond `priorNightCount`, and the tail it
        // drops is worth at most 0.0005 × the export's largest single-night shortfall.
        assertTest(
            SleepDebtMath.sleepDebtSeconds(
                for: target, history: history + [night(6, asleepMinutes: 380)]) == debt,
            "A sixth prior night is outside the five-night window and changes nothing")

        // The ceiling is load-bearing rather than cosmetic: 8.5% of the model's own predictions on the
        // export exceed it before clamping, and WHOOP's own column has 105 of 910 rows stacked on it.
        let capped = SleepDebtMath.sleepDebtSeconds(
            for: target, history: (1...5).map { night($0, asleepMinutes: 0) })
        assertTest(
            capped == SleepDebtMath.maximumDebtMinutes * 60,
            "An accumulated shortfall past the ceiling reports the ceiling exactly — "
                + "\(Int(SleepDebtMath.maximumDebtMinutes)) min, got "
                + "\(capped.map { "\($0)" } ?? "nil") s")

        // `0` is a real answer here, and the distinction from `nil` is the whole reason the column is
        // nullable: WHOOP's own figure bottoms out at 0, so a night in credit is measured, not absent.
        let rested = SleepDebtMath.sleepDebtSeconds(
            for: target, history: (1...5).map { night($0, asleepMinutes: 480) })
        assertTest(
            rested == 0,
            "Five nights that each met their own need accumulate nothing, and that is `0` rather than "
                + "`nil` (got \(rested.map { "\($0)" } ?? "nil"))")

        // Each night against its own need — the property that lets an imported night, which carries
        // WHOOP's need, and a strap night, which carries this app's, share one column.
        assertTest(
            SleepDebtMath.shortfallMinutes(
                of: SleepDebtMath.Night(day: day, needSeconds: 400 * 60, asleepSeconds: 480 * 60)) == 0,
            "A night that slept past its own need contributes no negative shortfall")
        assertTest(
            SleepDebtMath.shortfallMinutes(
                of: SleepDebtMath.Night(day: day, needSeconds: 500 * 60, asleepSeconds: 450 * 60)) == 50,
            "…and a night is measured against its own need, so a 500 min need against 450 min asleep "
                + "is a 50 min shortfall")

        // ── End to end: the real use case, writing both values ───────────────────────────────────
        do {
            let calendar = Calendar.current
            let morning = calendar.startOfDay(for: Date())
            let db = LocalDatabaseManager(inMemory: true)
            let sleepRepository = GRDBSleepRepository(db: db)
            let strainRepository = GRDBStrainRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            // Three prior nights with hand-set needs and durations, written through the repository so
            // the read path is the real one. Their shortfalls are 80, 30 and 0 minutes.
            //   D = 80 + 0.15×30 + 0.15²×0 = 84.5 min;  debt = 0.4293 × 84.5 = 36.2759 min = 2177 s
            let priorShortfalls: [Double] = [80, 30, 0]
            for (offset, shortfall) in priorShortfalls.enumerated() {
                guard let priorDay = calendar.date(byAdding: .day, value: -(offset + 1), to: morning)
                else { continue }
                try await sleepRepository.saveSleepSession(
                    SleepSession(
                        date: priorDay,
                        startTime: priorDay.addingTimeInterval(-8 * 3600),
                        endTime: priorDay,
                        targetSleepNeedSeconds: need,
                        lightSleepSeconds: (480 - shortfall) * 60))
            }

            // A night whose samples carry a real R-R series, at a 900 ms mean (67 bpm — a plausible
            // sleeping rate, and above the 48 bpm the band's top edge needs) modulated at 15 bpm.
            // Packets of 50 intervals span 45 s and arrive 45 s apart, so the series is continuous.
            // Anchored inside the use case's own window rather than at the reference date, and 30
            // packets cover 22.5 minutes — over `minimumRunSeconds` with room for many windows.
            let beats = syntheticPackets(
                [(bpm: 15, amplitudeMs: 40)],
                meanRRMs: 900, intervalsPerPacket: 50, packetCount: 30,
                anchor: morning.addingTimeInterval(-6 * 3600))
            let night = OvernightBiometricStore(samples: beats.map { packet in
                BiometricSample(
                    timestamp: packet.arrival,
                    heartRate: 67,
                    rrIntervalsMs: packet.intervals)
            })

            let session = try await AnalyzeSleepUseCase(
                biometricRepository: night,
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                userProfileRepository: profileRepository
            ).execute(for: morning)

            assertTest(session != nil, "A night whose samples carry an R-R series is still classified")
            let stored = try await sleepRepository.getSleepSession(for: morning)

            let rate = stored?.respiratoryRate
            assertTest(
                rate.map { abs($0 - 15) <= 1 } ?? false,
                "A strap night now stores its own respiratory rate, read off its own beats — the "
                    + "literal `14.4` that stood here reached the Recovery screen as a measurement "
                    + "(got \(rate.map { "\($0)" } ?? "nil")) bpm")

            // 2177 s, and *not* the capped 7620 a same-night model would produce from the target's own
            // 479-minute shortfall. That gap is what this assertion is for.
            let storedDebt = stored?.sleepDebtSeconds
            assertTest(
                storedDebt.map { abs($0 - 2177) <= 2 } ?? false,
                "…and stores its own sleep debt, accumulated from the three nights before it and "
                    + "never from its own shortfall (got \(storedDebt.map { "\($0)" } ?? "nil")) s, "
                    + "against the 7620 a same-night model would cap at")
        } catch {
            assertTest(false, "The respiratory-rate and sleep-debt integration threw: \(error)")
        }
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

    // ---- v11: naps are the second id-keyed table, and the same rules hold ----
    //
    // `naps` follows `workouts` rather than `sleeps` for the reason that table does: a day holds one
    // night but several naps, so a `date` primary key would make the second nap overwrite the first.
    // The day-snap still applies, and it is asserted on the same 17:33 shape so the two tables are
    // visibly under one rule.
    do {
        let napRepository = GRDBNapRepository(db: db)

        // 17:33 and 21:10 two days back, so nothing moves with the clock.
        let napDay = calendar.date(byAdding: .day, value: -2, to: Date())!.startOfDay
        let firstStart = calendar.date(byAdding: .minute, value: 17 * 60 + 33, to: napDay)!
        let secondStart = calendar.date(byAdding: .minute, value: 21 * 60 + 10, to: napDay)!

        // The `date` here is deliberately the **raw** start instant, not `start.startOfDay`. The
        // repository is what snaps it, centrally, the way it does for every other day-keyed writer —
        // and a fixture that snapped its own date first would make the assertion below pass whether
        // or not that snap existed. Confirmed by mutation: dropping the snap from `saveNap` left this
        // block green until this line was fixed.
        func nap(startingAt start: Date, minutes: Double) -> SleepNap {
            SleepNap(
                id: String(Int(start.timeIntervalSince1970)),
                date: start,
                startTime: start,
                endTime: start.addingTimeInterval(minutes * 60),
                asleepSeconds: minutes * 60)
        }

        // Written latest-first, so a repository that returned insertion order rather than sorting
        // would fail the ordering assertion below rather than passing it by luck.
        try await napRepository.saveNap(nap(startingAt: secondStart, minutes: 25), source: "test")
        try await napRepository.saveNap(nap(startingAt: firstStart, minutes: 40), source: "test")

        let onTheDay = try await napRepository.getNaps(on: napDay)
        assertTest(onTheDay.count == 2, "Two naps on one day are both read back (\(onTheDay.count) found)")
        assertTest(
            onTheDay.allSatisfy { $0.date == napDay },
            "…and each was stored under the day key the read uses, not the raw instant it was written at")
        assertTest(
            onTheDay.map(\.startTime) == onTheDay.map(\.startTime).sorted(),
            "…earliest first, whatever order they were written in")

        // The same primary-key rule as `workouts`. A read keyed on a neighbouring day must not find
        // them, and a write at a raw 17:33 must still be reachable through the day key.
        assertTest(
            (try await napRepository.getNaps(on: calendar.date(byAdding: .day, value: -1, to: napDay)!))
                .isEmpty,
            "A nap saved at a raw 17:33 is not found on the day before (the day key is snapped)")
        assertTest(
            (try await napRepository.getNaps(on: calendar.date(byAdding: .day, value: 1, to: napDay)!))
                .isEmpty,
            "…nor on the day after")

        // Empty is an ordinary answer, not a missing one: it means the user did not nap. The sleep
        // screen draws no nap row at all for it, which is a different rendering from the `—` a row
        // with a value nobody measured would get.
        let noNapDay = calendar.date(byAdding: .day, value: -400, to: Date())!.startOfDay
        assertTest(
            (try await napRepository.getNaps(on: noNapDay)).isEmpty,
            "A day with no naps returns an empty array rather than a row")

        // Re-saving the same identity replaces rather than duplicates — `save` is INSERT-or-UPDATE by
        // primary key, and this is the whole of what makes the import idempotent.
        try await napRepository.saveNap(nap(startingAt: firstStart, minutes: 55), source: "test")
        let afterResave = try await napRepository.getNaps(on: napDay)
        assertTest(afterResave.count == 2, "Re-saving a nap does not duplicate it")
        assertTest(
            afterResave.first?.asleepSeconds == 55 * 60,
            "…it updates the row it wrote (got \(afterResave.first?.asleepSeconds ?? -1) s)")
    } catch {
        assertTest(false, "The nap persistence round trip threw: \(error)")
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
    // `MetricChange` is one definition shared by two screens, so its three decisions have to be pinned
    // here rather than at either use site: whether a comparison is worth drawing at all, which way the
    // glyph points, and what colour that carries. The colour assertions are the "one rule, one
    // definition" guard — a copy of this in a view is what would drift, and the direction-versus-
    // verdict split (up is green for HRV and *worse* for resting heart rate) is the part a copy gets
    // wrong first.
    //
    // The verdict is three states, and the middle one is the reason the colour cannot be derived from
    // the direction: a figure equal to its average has no direction to point, so it draws a dot and
    // carries a colour no arrow ever uses. That case used to be `nil` — "nothing to compare" — which
    // conflated *no measurement* with *no movement*, two different answers the screen must render
    // differently. `nil` is now reserved for a missing side.
    let whole: (Double) -> String = { String(format: "%.0f", $0) }

    // Measured on the simulator: a resting heart rate of 52 against a mean of 52.4 drew a down
    // triangle between two figures both printed as `52`. The digits on screen are the whole of the
    // evidence a reader has, so an arrow between two identical ones is a row contradicting itself —
    // and this is the case a raw `current != previous` comparison lets through.
    let printedAlike = MetricChange.between(
        current: 52, previous: 52.4, higherIsBetter: false, formatted: whole)
    assertTest(
        printedAlike?.verdict == .same && printedAlike?.direction == nil
            && printedAlike?.previousText == "52",
        "A comparison whose two figures print the same is a *dot*, not an arrow — 52 against a mean "
            + "of 52.4 is genuinely below it, but the row would read `52 ▼ 52`")
    assertTest(
        MetricChange.between(current: 52.0, previous: 52.0, higherIsBetter: true, formatted: whole)?
            .verdict == .same,
        "…and two genuinely equal values reach the same verdict by the same gate, which is the rule "
            + "this extends rather than replaces")
    assertTest(
        MetricChange.between(current: 52, previous: 52.4, higherIsBetter: true, formatted: whole)?
            .symbolName == "circle.fill",
        "…and the equal case draws `circle.fill`, so a row that has not moved renders as one "
            + "without a direction glyph that would contradict its own two figures")
    assertTest(
        MetricChange.color(for: .same) == Theme.recoveryYellow
            && MetricChange.color(for: .same) != MetricChange.color(for: .better)
            && MetricChange.color(for: .same) != MetricChange.color(for: .worse),
        "The middle verdict is its own token — a dot sharing the up-arrow's green would report a "
            + "figure sitting on its average as an improvement")

    let rise = MetricChange.between(current: 59, previous: 52, higherIsBetter: true, formatted: whole)
    assertTest(
        rise?.direction == .up && rise?.previousText == "52" && rise?.symbolName
            == "arrowtriangle.up.fill",
        "A rise carries the upward direction and the baseline it beat, formatted by the caller")
    assertTest(
        MetricChange.between(current: 14.9, previous: 15.8, higherIsBetter: true, formatted: {
            String(format: "%.1f", $0)
        })?.direction == .down,
        "…and a fall points down — the direction is literal and never inverted by what is good")

    // The verdict, which is *not* a property of the direction: the same up arrow is green for HRV and
    // red for resting heart rate. Two calls, one differing argument, two colours — a view that read
    // `direction` and picked its own token could not satisfy this pair.
    assertTest(
        MetricChange.between(current: 59, previous: 52, higherIsBetter: true, formatted: whole)?
            .color == Theme.recoveryGreen
            && MetricChange.between(current: 52, previous: 59, higherIsBetter: true, formatted: whole)?
                .color == Theme.recoveryRed,
        "For a figure where higher is better, a rise is green and a fall is red")
    assertTest(
        MetricChange.between(current: 52, previous: 59, higherIsBetter: false, formatted: whole)?
            .color == Theme.recoveryGreen
            && MetricChange.between(current: 59, previous: 52, higherIsBetter: false, formatted: whole)?
                .color == Theme.recoveryRed,
        "…and for resting heart rate the same two arrows carry the opposite verdicts, so the colour "
            + "cannot be read off the direction alone")
    assertTest(
        MetricChange.between(current: 59, previous: 52, higherIsBetter: true, formatted: whole)?.direction
            == MetricChange.between(current: 59, previous: 52, higherIsBetter: false, formatted: whole)?
                .direction,
        "…though both still point the same way, which is what keeps the glyph literal while the "
            + "colour carries the judgement")
    assertTest(
        MetricChange.between(current: 59, previous: nil, higherIsBetter: true, formatted: whole) == nil
            && MetricChange.between(current: nil, previous: 52, higherIsBetter: true, formatted: whole)
                == nil,
        "A day with no baseline behind it — or no figure of its own — draws nothing at all, which is "
            + "what keeps a cold start from printing a movement against a constant, and what keeps "
            + "`nil` meaning `unmeasured` rather than `unchanged`")

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
            napRepository: GRDBNapRepository(db: importedDB),
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

        // ---- The week charts' series, on the same narrowing ----
        //
        // `WeekLineSeries` is what `WeekLineChartView` plots, and it is a type rather than logic in
        // that view's body for the reason `DayBarRules` is: the runner has no renderer, so a rule
        // written into a `View` is a rule nothing can assert. Both rules below are ones this app has
        // already got wrong somewhere else — the mixture, and the interpolated gap.
        //
        // **The two line charts answer "which days plot" differently, and that is the whole of the
        // difference between them.** Resting heart rate is one quantity in one unit, so every measured
        // day plots and its series needs no narrowing; HRV cannot, because SDNN and RMSSD are
        // different quantities on different scales. The fixtures below are shared by both blocks
        // deliberately — the same week has to give the RHR series more points than the HRV one, or the
        // narrowing is not being applied.
        //
        // The fixtures are the two above, reused deliberately: `mixed` is already built so the
        // narrowed answer and the unfiltered one differ, which is exactly what makes it able to fail.
        // The two SDNN days in it are *measured*, and the chart must drop them anyway — a mixed week
        // plots fewer points than it has readings, which is why the count of points is not the count
        // of measured days.
        if let mixedSeries = WeekLineSeries(hrvWeek: mixed) {
            assertTest(
                mixedSeries.points.map(\.slot) == [2, 3, 6],
                "The HRV chart plots only the week's own metric, so a week holding both plots fewer "
                    + "points than it has readings — the two SDNN days here are measured and are "
                    + "still dropped (got slots \(mixedSeries.points.map(\.slot)), and the week's own "
                    + "quantity is "
                    + "\(mixed.hrvBaselineMetric.map(\.displayName) ?? "nil"))")
            assertTest(
                mixedSeries.runs.map { $0.map(\.slot) } == [[2, 3], [6]],
                "…and the line breaks at the gap the narrowing made: slots 4 and 5 are measured, in "
                    + "the other quantity, and a segment drawn across them would be a reading this "
                    + "chart never took (got \(mixedSeries.runs.map { $0.map(\.slot) }))")
        } else {
            assertTest(false, "The mixed week yields no HRV series at all, so no chart is drawn")
        }

        // The minority case, from the other fixture: narrowing to the newest metric leaves three
        // adjacent SDNN days and drops the one RMSSD day, so the series is a single unbroken run and
        // the RMSSD reading is not plotted as a collapse on an SDNN axis.
        if let sdnnSeries = WeekLineSeries(hrvWeek: mostlySdnn) {
            assertTest(
                mostlySdnn.hrvBaselineMetric == .sdnn
                    && sdnnSeries.points.map(\.slot) == [4, 5, 6]
                    && sdnnSeries.runs.count == 1,
                "A week whose newest reading is the minority still plots its own quantity, so the "
                    + "single RMSSD day is dropped rather than drawn on an SDNN axis (got metric "
                    + "\(mostlySdnn.hrvBaselineMetric.map(\.displayName) ?? "nil") at slots "
                    + "\(sdnnSeries.points.map(\.slot)))")
        } else {
            assertTest(false, "The mostly-SDNN week yields no HRV series at all")
        }

        // The other line chart, on the same week. Every one of `mixed`'s five days carries a resting
        // rate, so this series has five points where the HRV one has three — which is the assertion
        // that fails if anyone folds the narrowing into the shared series type and quietly drops RHR
        // days that were never in two quantities.
        if let mixedRates = WeekLineSeries(restingHeartRateWeek: mixed) {
            assertTest(
                mixedRates.points.map(\.slot) == [2, 3, 4, 5, 6]
                    && mixedRates.runs.count == 1,
                "The resting-heart-rate chart plots every measured day and narrows nothing, so the "
                    + "same week that gives the HRV line three points gives this one five (got slots "
                    + "\(mixedRates.points.map(\.slot)) in "
                    + "\(mixedRates.runs.count) run(s))")
            assertTest(
                mixedRates.points.allSatisfy { $0.value == 50 },
                "…and each point is that day's own rate rather than a mean of the week's, since a "
                    + "chart of one repeated number would draw a flat line that looks like data")
        } else {
            assertTest(false, "The week's measured days yield no resting-heart-rate series")
        }

        // A hole in the middle, which is the rule the two charts share. The day at slot 4 has no row
        // at all, so it has no rate; the line has to break there rather than join slot 3 to slot 5,
        // which would draw a reading across a day nothing measured.
        if let holedRates = WeekLineSeries(
            restingHeartRateWeek: MetricWeek(
                endingOn: anchor,
                recovery: [0, 1, 3, 4].map { offset in
                    RecoveryMetric(
                        date: day(offset), score: 60, hrvValueMs: 60, hrvMetric: .rmssd,
                        restingHeartRate: 50)
                }))
        {
            assertTest(
                holedRates.points.map(\.slot) == [2, 3, 5, 6]
                    && holedRates.runs.map { $0.map(\.slot) } == [[2, 3], [5, 6]],
                "A day with no rate ends a run, so the line breaks at the hole rather than joining "
                    + "the days either side of it (got "
                    + "\(holedRates.runs.map { $0.map(\.slot) }))")
        } else {
            assertTest(false, "A week with four measured days yields no series")
        }

        // An unmeasured week has no series, which is what omits the card — and is not the same as an
        // empty one. Seven labelled columns with no line or bar in them is a week of zeros drawn once
        // per column, the same fabrication a point at zero would be. Asserted for all five charts,
        // because each card is omitted on its own series and one of them going non-optional would put
        // an empty frame on the page.
        let blankWeek = MetricWeek(endingOn: anchor, recovery: [])
        assertTest(
            WeekLineSeries(hrvWeek: blankWeek) == nil
                && WeekLineSeries(restingHeartRateWeek: blankWeek) == nil
                && WeekLineSeries(respiratoryRateWeek: blankWeek) == nil
                && WeekBarSeries(recoveryWeek: blankWeek) == nil
                && WeekBarSeries(sleepPerformanceWeek: blankWeek) == nil,
            "A week with no reading in it has no series rather than an empty one, for any of the "
                + "five charts, so every card is omitted instead of drawn empty")

        // ---- The third line, and the precision rule that only it exercises ----
        //
        // Respiratory rate is the one quantity here that is not read to whole units, and the week
        // below is the reference week's own — measured off the imported export, 14.8 15.4 14.9 14.9
        // 14.9 16.5 14.9 — chosen because it is the case that fails if anyone prints it the way the
        // other two are printed. Rounded to whole numbers it reads 15 15 15 15 15 17 15: six distinct
        // days collapsed into one number, and the 16.5 that is the week's entire point erased. So the
        // assertion is not "it formats" but "it does not lose the reading".
        // Written offset-first like the fixtures above, so `day(offset)` is the day each rate is
        // filed under and the slot it lands in is `6 - offset` — the anchor is slot 6.
        let referenceRespiratory = MetricWeek(
            endingOn: anchor,
            recovery: [
                (0, 14.9), (1, 16.5), (2, 14.9), (3, 14.9), (4, 14.9), (5, 15.4), (6, 14.8),
            ].map { offset, rate in
                RecoveryMetric(
                    date: day(offset), score: 60, hrvValueMs: 60, hrvMetric: .rmssd,
                    restingHeartRate: 52, respiratoryRate: rate)
            })
        if let breaths = WeekLineSeries(respiratoryRateWeek: referenceRespiratory) {
            assertTest(
                breaths.points.map(\.slot) == [0, 1, 2, 3, 4, 5, 6] && breaths.runs.count == 1,
                "The respiratory-rate chart plots every measured day and narrows nothing, so a full "
                    + "week is seven points in one run (got slots \(breaths.points.map(\.slot)) in "
                    + "\(breaths.runs.count) run(s))")
            assertTest(
                breaths.valueDecimals == 1,
                "…and reads its numbers to one decimal, which is the resolution the column is stored "
                    + "at — printing this week whole would render six of its seven days as `15`")
            assertTest(
                breaths.points.map { String(format: "%.\(breaths.valueDecimals)f", $0.value) }
                    == ["14.8", "15.4", "14.9", "14.9", "14.9", "16.5", "14.9"],
                "…so the labels the chart draws for the reference week are the week's own figures (got "
                    + "\(breaths.points.map { String(format: "%.1f", $0.value) }))")
        } else {
            assertTest(false, "The reference respiratory week yields no series at all")
        }

        // The other two are whole-number quantities and must stay that way: a `52.0` bpm or a `47.0`
        // ms would claim a resolution neither column is stored at. Asserted together because the
        // precision now lives in one shared property and a single edit could move all three.
        assertTest(
            WeekLineSeries(hrvWeek: mixed)?.valueDecimals == 0
                && WeekLineSeries(restingHeartRateWeek: mixed)?.valueDecimals == 0
                && WeekLineSeries(respiratoryRateWeek: referenceRespiratory)?.valueDecimals == 1,
            "Each quantity carries its own resolution, so the fractional one cannot drag the other "
                + "two to a decimal they were never measured at")

        // The ungated pass-through, which is the one place in `makeDay` a value is not filtered. The
        // column has no reserved zero — it is optional on the row and on the slot — so the optional is
        // the whole rule, and the chart and the RESPIRATORY RATE row above it read the same value
        // through it. A gate here would let the chart omit a point the row prints.
        let onlyBreaths = MetricWeek(
            endingOn: anchor,
            recovery: [
                RecoveryMetric(
                    date: anchor, score: 0, hrvValueMs: 0, restingHeartRate: 0,
                    respiratoryRate: 14.4)
            ])
        assertTest(
            onlyBreaths.days.last?.respiratoryRate == 14.4,
            "A respiratory rate reaches its slot even from a row this app calls unmeasured, because "
                + "the column has no reserved zero to gate and the row above the chart is not gated "
                + "either (got \(onlyBreaths.days.last?.respiratoryRate.map { "\($0)" } ?? "nil"))")
        assertTest(
            onlyBreaths.days.last?.hasAnyMeasurement == false,
            "…while still not counting as a measurement on the STRAIN & RECOVERY chart, which draws "
                + "neither a respiratory rate nor anything else this row holds")

        // The reference week's own breaths, and the axis they fit to. A two-unit span against the
        // ladder's smallest step, which is the tightest fit in this app and the one where an
        // off-by-one in the snapping would be most visible.
        if let fitted = FittedAxis(values: [14.8, 15.4, 14.9, 14.9, 14.9, 16.5, 14.9]) {
            assertTest(
                fitted.lowerBound == 14 && fitted.upperBound == 17 && fitted.step == 1,
                "The reference week's breaths fit to a one-rpm step rather than to the data's own "
                    + "14.8…16.5 (got \(fitted.lowerBound)…\(fitted.upperBound) at step "
                    + "\(fitted.step))")
            assertTest(
                fitted.gridLines == [15, 16],
                "…and rule gridlines at whole breaths, which is as coarse as a reader can name on a "
                    + "two-unit span (got \(fitted.gridLines))")
        } else {
            assertTest(false, "The reference week's respiratory rates yield no axis")
        }

        // The reserved-zero row: a day an older build wrote as unmeasured. `makeDay` gates the rate on
        // `hasMeasurement && > 0`, so the `0` never reaches the series — the same double gate the
        // panel's own field is asserted on above, reached through the drawing this time. Without it a
        // placeholder day would plot a real-looking point at zero bpm.
        assertTest(
            WeekLineSeries(
                restingHeartRateWeek: MetricWeek(
                    endingOn: anchor,
                    recovery: [
                        RecoveryMetric(
                            date: anchor, score: 0, hrvValueMs: 0, restingHeartRate: 0)
                    ])) == nil,
            "A reserved-zero row plots no point on the resting-heart-rate chart, so a day nothing "
                + "measured cannot arrive as a rate of zero")

        // The reference week's own rates, and the axis the screenshot's chart is drawn from. These are
        // the seven days the resting-heart-rate card was built against, measured off the imported
        // export — 55, 55, 52, 52, 49, 66, 52 — so a change to the fitting shows up here as numbers
        // rather than as a chart that merely looks a little different.
        if let fitted = FittedAxis(values: [55, 55, 52, 52, 49, 66, 52]) {
            assertTest(
                fitted.lowerBound == 45 && fitted.upperBound == 70 && fitted.step == 5,
                "The reference week's rates fit to a 5 bpm step rather than to the data's own 49…66 "
                    + "(got \(fitted.lowerBound)…\(fitted.upperBound) at step \(fitted.step))")
            assertTest(
                fitted.gridLines == [50, 55, 60, 65],
                "…and rule gridlines at those five-bpm values, so the reader can name every line "
                    + "without a label (got \(fitted.gridLines))")
        } else {
            assertTest(false, "The reference week's resting rates yield no axis")
        }

        // ---- The bars, and the two questions a bar series answers ----
        //
        // The page's two bar charts are one drawing, so which slots plot and what colour each bar is
        // now live in `WeekBarSeries` rather than in a `View`'s body — the reason `DayBarRules` is a
        // type. Neither rule is visible in a screenshot of a week where it happens not to bite, and
        // both were previously unassertable.
        //
        // The recovery bars first: the rule they carry is that a day with no score gets no bar, which
        // `mixed` exercises because only five of its seven slots hold a row.
        if let scores = WeekBarSeries(recoveryWeek: mixed) {
            assertTest(
                scores.points.map(\.slot) == [2, 3, 4, 5, 6],
                "The recovery bars cover exactly the days carrying a score — five of the seven slots, "
                    + "and the two with no row draw no bar rather than a zero-height one (got "
                    + "\(scores.points.map(\.slot)))")
            assertTest(
                scores.points.allSatisfy { $0.value == 60 },
                "…and each bar states its own day's score, which is what the tier colour below is "
                    + "computed from (got \(scores.points.map(\.value)))")
        } else {
            assertTest(false, "A week of five scored days yields no recovery bar series")
        }
        assertTest(
            WeekBarSeries(recoveryWeek: mixed)?.palette == .recoveryTier,
            "The recovery bars take their colour from the day's own tier — so the colour is the "
                + "reading rather than decoration")
        // The gridlines are the tier edges, so they move with the tiers: an off-by-one at 66/67 in
        // `RecoveryState` would leave the bars coloured by one boundary and measured against another.
        assertTest(
            WeekBarSeries(recoveryWeek: mixed)?.gridEdges == [0.34, 0.67],
            "…and the two lines it grids at are 34% and 67%, read off the tier ranges rather than "
                + "typed, so a reader can see the boundaries the bar colours come from (got "
                + "\((WeekBarSeries(recoveryWeek: mixed)?.gridEdges ?? []).map { "\($0)" }))")

        // A night with a known need, so the chain from a `sleeps` row through `MetricDay` to a drawn
        // bar is asserted end to end rather than at one end. The figures are chosen for their
        // arithmetic — a 30% night is the case a chart is worth drawing for — and are not anyone's
        // week: the app's own imported nights run to a different set of percentages.
        func night(_ offset: Int, fraction: Double) -> SleepSession {
            SleepSession(
                date: day(offset),
                startTime: day(offset),
                endTime: day(offset),
                targetSleepNeedSeconds: 8 * 3600,
                lightSleepSeconds: fraction * 8 * 3600)
        }
        // Written offset-first like the fixtures above, so `day(offset)` is the night each is filed
        // under and the slot it lands in is `6 - offset` — the anchor is slot 6.
        let sleepWeek = MetricWeek(
            endingOn: anchor,
            sleep: [
                (0, 0.81), (1, 0.30), (2, 0.81), (3, 0.82), (4, 0.82), (5, 0.76), (6, 0.81),
            ].map { offset, fraction in night(offset, fraction: fraction) })

        if let performance = WeekBarSeries(sleepPerformanceWeek: sleepWeek) {
            assertTest(
                performance.points.map(\.slot) == [0, 1, 2, 3, 4, 5, 6],
                "The sleep-performance bars cover every classified night, so a full week is seven "
                    + "bars (got \(performance.points.map(\.slot)))")
            assertTest(
                performance.points.map(\.value) == [81, 76, 82, 82, 81, 30, 81],
                "…and each bar states that night's own percentage, computed from its staged minutes "
                    + "over its need — the whole chain from a stored night to a drawn bar (got "
                    + "\(performance.points.map(\.value)))")
        } else {
            assertTest(false, "A week of seven classified nights yields no sleep bar series")
        }
        assertTest(
            WeekBarSeries(sleepPerformanceWeek: sleepWeek)?.palette == .sleepPerformance,
            "The sleep bars are one flat colour rather than tiered, because this app has no "
                + "sleep-performance bands to colour by")
        assertTest(
            WeekBarSeries(sleepPerformanceWeek: sleepWeek)?.gridEdges.isEmpty == true,
            "…and consequently carry no gridlines at all. Round quarters under bars with no "
                + "thresholds would be lines at meaningful-looking places that mean nothing, which is "
                + "the opposite of what the recovery chart's gridlines are for")

        // ---- The fifth chart is omitted on its own data, and it is the one that can be alone ----
        //
        // Sleep performance is read off a `sleeps` row and the other four off a `recoveries` row, so
        // this is the only card on the page that can be drawn on a week all the others are absent
        // from. The strap records nights and recoveries independently, so it is a real week and not a
        // constructed one.
        assertTest(
            WeekBarSeries(recoveryWeek: sleepWeek) == nil
                && WeekLineSeries(hrvWeek: sleepWeek) == nil
                && WeekLineSeries(restingHeartRateWeek: sleepWeek) == nil
                && WeekLineSeries(respiratoryRateWeek: sleepWeek) == nil
                && WeekBarSeries(sleepPerformanceWeek: sleepWeek) != nil,
            "A week whose only data is its nights draws the sleep-performance chart and none of the "
                + "other four, rather than omitting the whole section or drawing four empty frames")
        assertTest(
            WeekBarSeries(sleepPerformanceWeek: mixed) == nil
                && WeekBarSeries(recoveryWeek: mixed) != nil,
            "…and the omissions are independent the other way: a week of recovery rows with no "
                + "nights draws the recovery bars and no sleep chart")
        assertTest(
            sleepWeek.days.last?.recoveryScore == nil
                && sleepWeek.days.last?.sleepPerformance == 81
                && sleepWeek.days.last?.hasAnyMeasurement == true,
            "A slot can hold a night and no recovery row at all, and still count as measured — "
                + "through the night's need, which is the field `hasAnyMeasurement` already reads. "
                + "That is why excluding the performance from it is redundant rather than "
                + "load-bearing")

        // The one path by which a bar could state a figure with no measurement behind it, asserted as
        // the trap it is rather than as a behaviour. `SleepSession.sleepPerformancePercentage` guards
        // `targetSleepNeedSeconds > 0` with a hard `100`, and `sleepNeedSeconds` on the same slot is
        // gated to `nil` — so the pair disagree, which is only visible when they are asserted
        // together. The chart plots the 100 because the SLEEP PERFORMANCE row above it prints the same
        // 100, and dropping the bar here would make two statements of one figure contradict. It is
        // unreachable on stored nights — every imported row with a wake onset carries a need, and the
        // strap path computes one — so this fails loudly if anyone makes it reachable, which is the
        // point.
        let needlessNight = MetricWeek(
            endingOn: anchor,
            sleep: [
                SleepSession(
                    date: anchor, startTime: anchor, endTime: anchor, targetSleepNeedSeconds: 0)
            ])
        assertTest(
            needlessNight.days.last?.sleepPerformance == 100
                && needlessNight.days.last?.sleepNeedSeconds == nil,
            "A night stored with no need states a performance of exactly 100 — the guard inside "
                + "`SleepSession.sleepPerformancePercentage` standing in for a denominator that was "
                + "not there — while the need on the same slot is nil, and the chart draws that 100 "
                + "because the row above it prints it (got performance "
                + "\(needlessNight.days.last?.sleepPerformance.map { "\($0)" } ?? "nil"), need "
                + "\(needlessNight.days.last?.sleepNeedSeconds.map { "\($0)" } ?? "nil"))")

        // ---- The fitted axis ----
        //
        // The one auto-scaled axis in this app, and the assertions that keep it from becoming the
        // thing the fixed-scale rule forbids. The bounds are round and the gridlines are values a
        // reader can name; `32…67` is the reference week's own range, so these are the numbers the
        // screenshot's chart is drawn from.
        if let fitted = FittedAxis(values: [47, 51, 59, 58, 63, 32, 67]) {
            assertTest(
                fitted.lowerBound == 30 && fitted.upperBound == 70 && fitted.step == 10,
                "The fitted axis rounds out to a step a reader can name rather than to the data's "
                    + "own extremes (got \(fitted.lowerBound)…\(fitted.upperBound) at step "
                    + "\(fitted.step))")
            assertTest(
                fitted.gridLines == [40, 50, 60],
                "…and rules its gridlines at those round values, strictly inside the bounds so the "
                    + "frame's own edges are not drawn twice (got \(fitted.gridLines))")
            assertTest(
                fitted.upperBound >= 67 && fitted.lowerBound <= 32,
                "The bounds contain every value they were fitted to, so nothing the chart hands this "
                    + "can be clamped away by the frame")
        } else {
            assertTest(false, "The reference week's values yield no axis at all")
        }

        // A flat week is still a band to draw in. Without the widening a zero-span range would put
        // the line on the frame's edge and leave the fraction dividing by zero.
        if let flat = FittedAxis(values: [55, 55, 55]) {
            assertTest(
                flat.upperBound > flat.lowerBound,
                "A week where every reading is identical still gets a non-zero range (got "
                    + "\(flat.lowerBound)…\(flat.upperBound))")
        } else {
            assertTest(false, "A flat week yields no axis, which would draw an empty frame")
        }

        assertTest(
            FittedAxis(values: []) == nil,
            "An axis with nothing to describe is nil rather than a default range, so a caller cannot "
                + "draw an empty frame through it")

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

/// §15 — the sleep detail screen's typical-range card.
///
/// Three kinds of thing are asserted here, and they are separate on purpose. The **arithmetic** the
/// card's percent column is made of; the **layout rule** its bars are drawn from; and the **absence
/// rules** that decide when there is no card, no dashed markers and no comparison. The runner has no
/// renderer, so no assertion below says anything about the drawing — what it says is that every number
/// and every decision the drawing is made of is right, which is the reason `SleepStageRangeScoring` and
/// `TypicalRangeBarLayout` are types rather than bodies.
///
/// The export block at the end is the only part that touches the real file, and every assertion in it
/// is a **property** rather than a count of nights: a device time zone that merges two day keys
/// narrows it without weakening it, which is the shape §11 asks new assertions here to take.
func runTypicalRangeTests() async {
    func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.0001 }

    // ── 1. The percentile ────────────────────────────────────────────────────────────────────────
    //
    // Pinned against literals rather than against a second implementation, and the literals are
    // reproducible outside this codebase: the definition is R's `quantile(type = 7)` and NumPy's
    // default, so a changed interpolation method fails here instead of agreeing with itself.
    assertTest(
        near(BaselineStatisticsMath.percentile([1, 2, 3, 4], at: 0.25) ?? .nan, 1.75),
        "p25 of 1…4 is 1.75 — linear interpolation at position 0.75 between the 1st and 2nd")
    assertTest(
        near(BaselineStatisticsMath.percentile([1, 2, 3, 4], at: 0.5) ?? .nan, 2.5),
        "…p50 is 2.5, the midpoint the interpolated form and the median agree on")
    assertTest(
        near(BaselineStatisticsMath.percentile([1, 2, 3, 4], at: 0.75) ?? .nan, 3.25),
        "…and p75 is 3.25 — 0.25 of the way from the 3rd to the 4th, not a third of the way")

    // The two ends are the order statistics themselves, which is what makes a one-night window
    // degenerate rather than wrong.
    assertTest(
        BaselineStatisticsMath.percentile([4, 1, 3, 2], at: 0) == 1
            && BaselineStatisticsMath.percentile([4, 1, 3, 2], at: 1) == 4,
        "p0 is the minimum and p100 the maximum, whatever order the caller handed them in")

    // The degenerate inputs. n=1 returns itself at every fraction — the count floor at the call site
    // is what stops a single night becoming its own typical range, not this function.
    assertTest(
        BaselineStatisticsMath.percentile([7], at: 0.25) == 7
            && BaselineStatisticsMath.percentile([7], at: 0.9) == 7,
        "One observation is its own percentile at every fraction")
    assertTest(
        near(BaselineStatisticsMath.percentile([10, 20], at: 0.25) ?? .nan, 12.5)
            && near(BaselineStatisticsMath.percentile([10, 20], at: 0.75) ?? .nan, 17.5),
        "Two observations interpolate at a quarter and three quarters of their gap")

    // `nil`, and never `0`: a percentile of nothing is not zero, and a zero here would draw a 0–0%
    // typical range on a night whose window held nothing.
    assertTest(
        BaselineStatisticsMath.percentile([], at: 0.5) == nil,
        "An empty window has no percentile — `nil` rather than a `0` that would draw as a range")
    assertTest(
        BaselineStatisticsMath.percentile([1, 2, .nan, 3], at: 0.25).map { near($0, 1.5) } == true,
        "A NaN is dropped rather than sorted, so the interpolation runs over the three real values "
            + "and p25 is 1.5")
    assertTest(
        BaselineStatisticsMath.percentile([1, 2, 3], at: .nan) == nil,
        "A non-finite fraction is `nil` — the guard that keeps a NaN from poisoning every comparison")

    // The caller's array is the caller's. Sorting in place would reorder a history a caller still
    // needs in its own order — which the repository reads are, oldest-first.
    let unsorted = [4.0, 1.0, 3.0, 2.0]
    _ = BaselineStatisticsMath.percentile(unsorted, at: 0.5)
    assertTest(
        unsorted == [4, 1, 3, 2],
        "…and the array handed in is not reordered — the sort is on a copy")

    // ── 2. The percent column ────────────────────────────────────────────────────────────────────
    //
    // The rule the card's four figures are drawn from, and the reason it is largest-remainder rather
    // than rounding: the card prints `DURATION` above the column, so a column summing to 99 or 101
    // contradicts the total printed at the top of its own card.
    let halves = SleepStageRangeScoring.wholePercents(
        ofSeconds: [10800, 10800, 3600, 3600])
    assertTest(
        halves == [38, 38, 12, 12],
        "3h/3h/1h/1h is 37.5/37.5/12.5/12.5 — floors sum to 98 and the two spare seats go to the "
            + "largest remainders, giving [38, 38, 12, 12] "
            + "(got \((halves ?? []).map { "\($0)" }.joined(separator: ", ")))")
    assertTest(
        halves?.reduce(0, +) == 100,
        "…and the column sums to exactly 100, which naive rounding does not: it gives "
            + "38 + 38 + 13 + 13 = 102")

    // A three-way tie on the remainder, broken by position so the answer is reproducible rather than
    // dependent on how a sort happened to order equal keys.
    assertTest(
        SleepStageRangeScoring.wholePercents(ofSeconds: [1, 1, 1, 0]) == [34, 33, 33, 0],
        "Three equal thirds tie on their remainder and the spare seat goes to the first row — the "
            + "tie-break that makes this column reproducible")

    assertTest(
        SleepStageRangeScoring.wholePercents(ofSeconds: [1, 1, 1, 1]) == [25, 25, 25, 25],
        "Four equal stages need no seat at all — the floors already sum to 100")

    // No total to divide by, in every form one can arrive. Each of these is a `nil` and not a
    // four-zero column, which is the difference between "we could not describe this night" and "this
    // night was 0% awake".
    assertTest(
        SleepStageRangeScoring.wholePercents(ofSeconds: []) == nil
            && SleepStageRangeScoring.wholePercents(ofSeconds: [0, 0, 0, 0]) == nil,
        "An empty list and an all-zero night both have no column — `nil`, not four zeros")
    assertTest(
        SleepStageRangeScoring.wholePercents(ofSeconds: [-1, 2, 3, 4]) == nil
            && SleepStageRangeScoring.wholePercents(ofSeconds: [.nan, 1, 1, 1]) == nil
            && SleepStageRangeScoring.wholePercents(ofSeconds: [.infinity, 1, 1, 1]) == nil,
        "A negative, a NaN and an infinity each make the column `nil` rather than a silent wrong answer")

    // The property, over every fixture above rather than only the ones with a pinned answer: each
    // percent is within one of its exact share. That is the guarantee largest-remainder actually
    // makes, and it holds for any input.
    let fixtures: [[TimeInterval]] = [
        [10800, 10800, 3600, 3600], [15120, 6480, 5760, 1440], [3600, 14400, 5400, 5400],
        [1, 2, 3, 7], [1, 1, 1, 0],
    ]
    let farOff = fixtures.filter { durations in
        guard let percents = SleepStageRangeScoring.wholePercents(ofSeconds: durations) else {
            return true
        }
        let total = durations.reduce(0, +)
        return zip(percents, durations).contains { percent, seconds in
            abs(Double(percent) - seconds / total * 100) > 1
        }
    }
    assertTest(
        farOff.isEmpty,
        "Every percent in every fixture is within one of its exact share (\(farOff.count) fixtures "
            + "are not)")

    // ── 3. The bar's layout ──────────────────────────────────────────────────────────────────────
    let banded = TypicalRangeBarLayout(
        percent: 50,
        typical: SleepStageRangeScoring.Typical(lowPercent: 20, highPercent: 80))
    assertTest(
        near(banded.filledFraction, 0.5) && near(banded.unfilledFraction, 0.5),
        "Half the night fills half the track, and the remainder is its complement")
    assertTest(
        near(banded.lowFraction ?? .nan, 0.2) && near(banded.highFraction ?? .nan, 0.8),
        "A band in percentage points lands on the track's own 0–100% scale at 0.2 and 0.8")
    assertTest(
        near(TypicalRangeBarLayout(percent: 0, typical: nil).filledFraction, 0)
            && near(TypicalRangeBarLayout(percent: 100, typical: nil).unfilledFraction, 0),
        "A stage that took none of the night fills none of the track, and one that took all of it "
            + "leaves no remainder to hatch")

    // The clamps, which are a guard rather than a rule — see the type's doc comment — but a guard
    // that has to hold for a mark not to be drawn off the end of the scale.
    assertTest(
        TypicalRangeBarLayout(
            percent: 50, typical: SleepStageRangeScoring.Typical(lowPercent: -10, highPercent: 250)
        ).lowFraction == 0
            && TypicalRangeBarLayout(
                percent: 50,
                typical: SleepStageRangeScoring.Typical(lowPercent: -10, highPercent: 250)
            ).highFraction == 1,
        "A bound outside the scale is clamped to the track rather than drawn past it")
    assertTest(
        TypicalRangeBarLayout(
            percent: 50, typical: SleepStageRangeScoring.Typical(lowPercent: .nan, highPercent: .nan)
        ).lowFraction == 0,
        "A non-finite bound collapses to zero instead of taking the whole bar with it — every "
            + "comparison against a NaN is false, so a clamp cannot catch one")
    assertTest(
        TypicalRangeBarLayout(percent: 50, typical: nil).lowFraction == nil
            && TypicalRangeBarLayout(percent: 50, typical: nil).highFraction == nil,
        "**No band, no markers** — `nil` and not a pair of zeros, which would put two dashed bounds "
            + "at the left edge of every row on a thin window")

    // ── 4. The summary, and its absence rules ────────────────────────────────────────────────────
    //
    // Fixed day offsets from today, so nothing here says something different tomorrow. The priors are
    // built so the four deep shares are 20/25/30/35% of an eight-hour night: the quartiles are then
    // hand-computable, and both are exact in binary, so they can be pinned as literals rather than to
    // a tolerance.
    func night(
        dayOffset: Int,
        light: TimeInterval,
        deep: TimeInterval,
        rem: TimeInterval,
        awake: TimeInterval,
        need: TimeInterval = 8 * 3600
    ) -> SleepSession {
        let day = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!)
        let onset = day.addingTimeInterval(-8 * 3600)
        return SleepSession(
            date: day,
            startTime: onset,
            endTime: onset.addingTimeInterval(light + deep + rem + awake),
            targetSleepNeedSeconds: need,
            lightSleepSeconds: light,
            deepSleepSeconds: deep,
            remSleepSeconds: rem,
            awakeSeconds: awake)
    }

    /// An eight-hour night whose deep share is `deepPercent` and whose light and REM split the rest.
    func prior(dayOffset: Int, deepPercent: Double) -> SleepSession {
        let deep = 28800 * deepPercent / 100
        let half = (28800 - deep) / 2
        return night(
            dayOffset: dayOffset, light: half, deep: deep, rem: half, awake: 0)
    }

    let priors = [
        prior(dayOffset: 40, deepPercent: 20),
        prior(dayOffset: 30, deepPercent: 25),
        prior(dayOffset: 20, deepPercent: 30),
        prior(dayOffset: 10, deepPercent: 35),
    ]

    // 1h awake / 4h light / 1.5h deep / 1.5h REM — an eight-hour night whose exact shares are
    // 12.5 / 50 / 18.75 / 18.75. Two seats are spare and both go to the 18.75s.
    let target = night(
        dayOffset: 0, light: 14400, deep: 5400, rem: 5400, awake: 3600)

    assertTest(
        SleepStageRangeScoring.stages == [.awake, .light, .deep, .rem],
        "The card's rows come off `SleepStageType.allCases`, which is the reference's order already")

    guard let summary = SleepStageRangeScoring.summary(for: target, priorNights: priors) else {
        assertTest(false, "A night with an eight-hour sleep period produced no summary")
        return
    }

    assertTest(
        summary.rows.map(\.percent) == [12, 50, 19, 19],
        "The four shares are whole, in stage order, and sum to 100 "
            + "(got \(summary.rows.map(\.percent)))")
    assertTest(
        summary.durationSeconds == target.sleepPeriodSeconds,
        "DURATION is the total the four shares divide — the identity the card asserts by printing "
            + "both above one another")
    assertTest(
        summary.restorativeSeconds == target.restorativeSleepSeconds
            && summary.restorativeSeconds == 10800,
        "Restorative sleep is the entity's own deep + REM, carried rather than re-summed by the card")
    assertTest(
        summary.rows.first { $0.stage == .awake }?.seconds == 3600,
        "…and each row carries its own stage's duration, read through the one stage-to-field switch")

    // The headline. `HOURS OF SLEEP` is the title of the card and this is the figure under it, so the
    // assertion that matters is the identity the card prints: asleep + awake = DURATION, checked
    // against the two figures printed a card below rather than against the entity the two were read
    // from. It is the one that fails if the headline is ever taken from a different sum than the rows.
    assertTest(
        summary.asleepSeconds == 25200 && summary.awakeSeconds == 3600,
        "The headline is the night's three sleep stages — 7h of a night whose fourth row is 1h awake "
            + "(got \(summary.asleepSeconds.formattedCompactHoursMinutes()))")
    assertTest(
        summary.asleepSeconds + summary.awakeSeconds == summary.durationSeconds,
        "…and it adds up with the awake row to the DURATION the typical-range card prints, which is "
            + "the check a reader can make on the screen itself")
    assertTest(
        summary.typicalAsleepSeconds == 28800,
        "The window's mean hours of sleep is 8h — its four priors carry no wake at all (got "
            + "\(summary.typicalAsleepSeconds.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

    // The headline's comparison, through the exact call the card makes. Tonight's 7h against a typical
    // 8h is worse news, and `higherIsBetter: true` is the judgement that says so — the same judgement
    // the restorative row makes, so a longer night cannot be red on one row and green on the other.
    let asleepChange = MetricChange.between(
        current: summary.asleepSeconds,
        previous: summary.typicalAsleepSeconds,
        higherIsBetter: true,
        formatted: { $0.formattedCompactHoursMinutes() })
    assertTest(
        asleepChange?.verdict == .worse && asleepChange?.direction == .down
            && asleepChange?.previousText == "8:00",
        "Tonight's 7:00 asleep against a typical 8:00 reads as worse, and prints the mean it was read "
            + "against")

    // The bands. The priors' deep shares are 20/25/30/35%, so the type-7 quartiles are 23.75 and
    // 31.25; light and REM are 40/37.5/35/32.5%, giving 34.375 and 38.125; awake is zero every night.
    assertTest(
        summary.rows.count == 4 && summary.rows.allSatisfy({ $0.typical != nil }),
        "Four prior nights clear the count floor, so all four rows carry a band")
    assertTest(
        summary.rows.first { $0.stage == .deep }?.typical
            == SleepStageRangeScoring.Typical(lowPercent: 23.75, highPercent: 31.25),
        "Deep's band is the middle half of the priors' own deep shares, in percentage points")
    assertTest(
        summary.rows.first { $0.stage == .light }?.typical
            == SleepStageRangeScoring.Typical(lowPercent: 34.375, highPercent: 38.125),
        "…and light's is its own, not a copy of deep's — four bands, four quantities")
    assertTest(
        summary.rows.first { $0.stage == .awake }?.typical
            == SleepStageRangeScoring.Typical(lowPercent: 0, highPercent: 0),
        "A stage that was zero on every prior night has a zero-width band, which is a real answer "
            + "and not the `nil` a thin window gives")

    assertTest(
        summary.nightCount == 4,
        "The band's window is reported as the count it was taken over (got \(summary.nightCount))")
    assertTest(
        summary.typicalRestorativeSeconds == 18360,
        "Restorative sleep is read against the window's **mean** of deep + REM — 5h 6m over these "
            + "four priors (got \(summary.typicalRestorativeSeconds.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

    // The footer's comparison, through the exact call the card makes. A night 5h 6m of typical
    // restorative against tonight's 3h is worse news, and `MetricChange` decides that on the
    // formatted pair — which is what the card prints.
    let change = MetricChange.between(
        current: summary.restorativeSeconds,
        previous: summary.typicalRestorativeSeconds,
        higherIsBetter: true,
        formatted: { $0.formattedCompactHoursMinutes() })
    assertTest(
        change?.verdict == .worse && change?.direction == .down && change?.previousText == "5:06",
        "Tonight's 3:00 restorative against a typical 5:06 reads as worse, and prints the mean it "
            + "was read against")

    // ── The count floor, at both edges ───────────────────────────────────────────────────────────
    if let twoPriors = SleepStageRangeScoring.summary(
        for: target, priorNights: Array(priors.suffix(2))) {
        assertTest(
            twoPriors.rows.allSatisfy({ $0.typical == nil })
                && twoPriors.nightCount == 0
                && twoPriors.typicalRestorativeSeconds == nil
                && twoPriors.typicalAsleepSeconds == nil,
            "Two nights are below `minimumBaselineDays`, so every band is withheld — all four carriers "
                + "of that one fact together — but the shares and durations are readings the night "
                + "really has and are still drawn")
        assertTest(
            twoPriors.rows.map(\.percent) == [12, 50, 19, 19],
            "…the percent column is unaffected by a thin window, which is what makes it a separate "
                + "state from an absent card")
    } else {
        assertTest(false, "A thin window returned no summary at all; it must still describe the night")
    }

    if let threePriors = SleepStageRangeScoring.summary(
        for: target, priorNights: Array(priors.suffix(3))) {
        assertTest(
            threePriors.rows.allSatisfy({ $0.typical != nil }) && threePriors.nightCount == 3,
            "Three nights are the other edge: the floor is inclusive, and every band reappears")
    } else {
        assertTest(false, "Three nights is `minimumBaselineDays` and must produce a summary")
    }

    // ── A stored night with no sleep period is not a prior ───────────────────────────────────────
    //
    // It has no share to contribute, so counting it would manufacture a baseline out of nights that
    // have none; and its zero restorative sleep would drag the mean down, which is the second half of
    // the same mistake. Both are asserted, because the mean is the one that fails silently.
    let empty = night(dayOffset: 5, light: 0, deep: 0, rem: 0, awake: 0)
    if let withEmpty = SleepStageRangeScoring.summary(
        for: target, priorNights: priors + [empty]) {
        assertTest(
            withEmpty.nightCount == 4,
            "A stored night with no sleep period is dropped from the window rather than counted "
                + "(got \(withEmpty.nightCount) of 5)")
        assertTest(
            withEmpty.typicalRestorativeSeconds == 18360,
            "…and it does not drag the restorative mean toward zero — an unfiltered mean over the "
                + "same five nights is 4:04, not the 5:06 the four real nights give")
    } else {
        assertTest(false, "Five nights, one of them empty, still produced no summary")
    }

    // Two real nights and one empty: the filter runs **before** the count floor, or three nights
    // would clear it and the bands would be built over two of them.
    if let belowFloor = SleepStageRangeScoring.summary(
        for: target, priorNights: Array(priors.suffix(2)) + [empty]) {
        assertTest(
            belowFloor.nightCount == 0 && belowFloor.rows.allSatisfy({ $0.typical == nil }),
            "Three stored nights of which one has no sleep period leave two, which is below "
                + "`minimumBaselineDays` — so the filter is applied before the floor, not after it")
    } else {
        assertTest(false, "A window emptied below the floor must still describe the night itself")
    }

    // ── No night, no summary ─────────────────────────────────────────────────────────────────────
    let blank = night(dayOffset: 0, light: 0, deep: 0, rem: 0, awake: 0)
    assertTest(
        SleepStageRangeScoring.summary(for: blank, priorNights: priors) == nil,
        "A session with no sleep period produces **no** summary — the card is then not drawn at all, "
            + "rather than drawn as four `0%` rows, which would be a picture of a night")

    // ── 5. The window the bands are taken over ───────────────────────────────────────────────────
    //
    // The windowing itself is `RecoveryScoring`'s, reused rather than re-derived, so what is asserted
    // here is that the reuse is sound for nights: strictly before, snapped to the calendar day, and
    // capped at the constant the caption on the screen is built from.
    let fortyNights = (1...40).reversed().map { prior(dayOffset: $0, deepPercent: 20) }
    let today = Calendar.current.startOfDay(for: Date())
    let sameDay = night(dayOffset: 0, light: 14400, deep: 5400, rem: 5400, awake: 3600)
    let later = night(dayOffset: -1, light: 14400, deep: 5400, rem: 5400, awake: 3600)

    let window = RecoveryScoring.baselineWindow(before: today, in: fortyNights + [sameDay, later])
    assertTest(
        window.count == 30,
        "Forty nights, the target's own day and a later one still narrow to "
            + "`baselineWindowDays` = \(RecoveryScoring.baselineWindowDays) (got \(window.count))")
    assertTest(
        !window.contains { $0.date >= today },
        "…and neither the night itself nor a night dated after it is inside the window — the "
            + "strict-before rule, compared on the calendar day")
    assertTest(
        window.allSatisfy { $0.date < today },
        "…which is what keeps a night out of its own baseline — the defect the snapped anchor in "
            + "`baselineWindow` records, where the printed mean was taken over a different set of "
            + "days than the score above it")

    // The lookback the view model reads with. If this were `baselineWindowDays` the helper would be
    // handed thirty *days* and could not fill a window of thirty *nights* across the export's
    // recording gap, which is the whole reason the two constants are separate.
    assertTest(
        RecoveryScoring.baselineWindowLookbackDays > RecoveryScoring.baselineWindowDays,
        "The read reaches back further than the window it fills "
            + "(\(RecoveryScoring.baselineWindowLookbackDays) days for "
            + "\(RecoveryScoring.baselineWindowDays) nights)")

    // ── 6. The two mappings the card draws through ───────────────────────────────────────────────
    //
    // The stage-to-colour switch was lifted out of `HypnogramChartView` so this card could not be a
    // second definition of it. This is the assertion that fails if anyone writes a second one: the
    // four tokens the hypnogram has always drawn, unchanged, reachable from one place.
    assertTest(
        SleepStageType.awake.color == Theme.sleepAwake
            && SleepStageType.light.color == Theme.sleepLight
            && SleepStageType.deep.color == Theme.sleepDeep
            && SleepStageType.rem.color == Theme.sleepRem,
        "`SleepStageType.color` is the app's one stage-to-token mapping, and it is the hypnogram's")

    // ── 7. What a listener hears ─────────────────────────────────────────────────────────────────
    //
    // The strings are built outside the view for the reason the whole file is: nothing here has a
    // renderer, so an accessibility label assembled inside a `body` is a string no assertion can read.
    let deepRow = SleepStageRangeScoring.Row(
        stage: .deep, seconds: 5580, percent: 20,
        typical: SleepStageRangeScoring.Typical(lowPercent: 15.4, highPercent: 22.6))
    assertTest(
        SleepTypicalRangeCard.spokenStageRow(deepRow)
            == "Deep / SWS, 20 percent of the night, 1h 33m, typical 15 to 23 percent",
        "A stage row is announced with its share and its band, and its duration is spoken as a "
            + "duration rather than as the `1:33` printed on the screen")

    let unbandedRow = SleepStageRangeScoring.Row(
        stage: .rem, seconds: 5580, percent: 20, typical: nil)
    assertTest(
        SleepTypicalRangeCard.spokenStageRow(unbandedRow)
            == "REM, 20 percent of the night, 1h 33m, no typical range yet",
        "…and a row with no band says so rather than falling silent, since 'we cannot say what is "
            + "typical for you yet' is an answer")

    assertTest(
        SleepTypicalRangeCard.spokenRestorativeRow(seconds: 9960, typicalSeconds: 11820)
            == "Restorative sleep, 2h 46m, typical 3h 17m",
        "The footer is announced as a duration and the mean it is read against — the pair the "
            + "reference prints as 2:46 ▼ 3:17")
    assertTest(
        SleepTypicalRangeCard.spokenRestorativeRow(seconds: 9960, typicalSeconds: nil)
            == "Restorative sleep, 2h 46m, no typical range yet",
        "…with no comparison claimed when the window produced no mean")

    // ── 8. The night's heart rate ────────────────────────────────────────────────────────────────
    //
    // The chart's whole substance is a value rather than a shape in a `body`, for the reason this file
    // exists at all: nothing in this runner has a renderer, so a line's rules are only assertable if
    // they are arithmetic. Skipped on a night the app never wrote a sample for — which is every night
    // on this machine — these are the assertions that would have said so.
    let hrDay = Calendar.current.startOfDay(for: Date())
    let hrOnset = hrDay
    let hrWake = hrDay.addingTimeInterval(7 * 3600)

    func hrSample(at seconds: TimeInterval, bpm: Int) -> BiometricSample {
        BiometricSample(timestamp: hrOnset.addingTimeInterval(seconds), heartRate: bpm)
    }

    // Two absences the screen draws as one `No Data`, and both are `nil` rather than an empty series.
    assertTest(
        HoursOfSleepChartSeries(samples: [], start: hrOnset, end: hrWake) == nil,
        "A night with no samples has no series — `nil` is the card's `No Data`, not an empty frame")
    assertTest(
        HoursOfSleepChartSeries(samples: [hrSample(at: 600, bpm: 0)], start: hrOnset, end: hrWake) == nil,
        "…nor does a night whose only samples carry a `0`: an absent reading is not a reading of zero, "
            + "which is the rule `hasMeasurement` enforces on every other metric in this app")
    assertTest(
        HoursOfSleepChartSeries(samples: [hrSample(at: 0, bpm: 60)], start: hrWake, end: hrOnset) == nil,
        "A window that is not a window is `nil` rather than a division by a negative length")
    assertTest(
        HoursOfSleepChartSeries(
            samples: [hrSample(at: 60, bpm: 50)], start: hrOnset, end: hrWake)?.runs.count == 1,
        "A night the app heard from once is one run of one point — it was measured, and refusing to "
            + "draw it would be the same fabrication as a dash over a stored reading")

    let mixed = [
        hrSample(at: 1200, bpm: 58),
        hrSample(at: 0, bpm: 54),
        hrSample(at: 600, bpm: 61),
        hrSample(at: -600, bpm: 99),
        hrSample(at: 9 * 3600, bpm: 99),
    ]
    guard let hrSeries = HoursOfSleepChartSeries(samples: mixed, start: hrOnset, end: hrWake) else {
        assertTest(false, "Three in-window samples produced no series")
        return
    }
    assertTest(
        hrSeries.points.map(\.bpm) == [54, 61, 58],
        "The points come back in time order whatever order the read handed them in "
            + "(got \(hrSeries.points.map(\.bpm)))")
    assertTest(
        hrSeries.points.count == 3,
        "…and the two samples outside the night's window are dropped rather than clamped onto its "
            + "edges, which would place a reading at a time it was not taken")

    // The gap rule, asserted as a **pair**: either half alone passes on a wrong constant. A stream
    // that never splits looks right until the day it spans a dropout, and a stream split at a
    // threshold far below the constant still splits at the constant.
    let justInside = HoursOfSleepChartSeries(
        samples: [
            hrSample(at: 0, bpm: 55),
            hrSample(at: HoursOfSleepChartSeries.maximumGapSeconds, bpm: 57),
        ],
        start: hrOnset, end: hrWake)
    assertTest(
        justInside?.runs.count == 1,
        "Two readings exactly `maximumGapSeconds` apart are one run — the boundary is inclusive, so a "
            + "live stream's own sampling interval cannot split a night that was recorded throughout")
    let justOutside = HoursOfSleepChartSeries(
        samples: [
            hrSample(at: 0, bpm: 55),
            hrSample(at: HoursOfSleepChartSeries.maximumGapSeconds + 1, bpm: 57),
        ],
        start: hrOnset, end: hrWake)
    assertTest(
        justOutside?.runs.count == 2,
        "…and one second further apart is two runs: a segment drawn across that hole is a curve "
            + "through five minutes nothing measured")
    assertTest(
        justOutside?.runs.flatMap { $0 }.count == justOutside?.points.count,
        "…and a split loses no reading — the runs partition the points rather than filtering them")

    // The axis. Fixed, never fitted to the night: the same argument `StressMonitorChartView` makes
    // for pinning its 0–3 scale, and it holds here night to night.
    assertTest(
        hrSeries.axis == .standard && HoursOfSleepChartAxis.standard.gridLines == [30, 50, 70, 90],
        "A night inside the standard bounds carries the reference's own four labels on a fixed "
            + "30–110 scale")
    assertTest(
        hrSeries.axis.fraction(30) == 0 && hrSeries.axis.fraction(110) == 1
            && near(hrSeries.axis.fraction(70), 0.5),
        "The scale's ends map to 0 and 1 and its midpoint to 0.5 — the mapping every shape draws "
            + "through, in one place")

    // Widening rather than clamping, in whole steps, only as far as it must — and re-anchoring the
    // labels, since a widened axis that kept the old ones would print numbers it is no longer on.
    assertTest(
        HoursOfSleepChartAxis.fit([120]).upperBound == 120
            && HoursOfSleepChartAxis.fit([120]).lowerBound == 30,
        "A peak above the standard ceiling raises the ceiling to it and leaves the floor alone")
    assertTest(
        HoursOfSleepChartAxis.fit([125]).upperBound == 130,
        "…rounding up to the next 10 bpm step rather than to the nearest, so the bound always "
            + "contains the value that forced it")
    assertTest(
        HoursOfSleepChartAxis.fit([18]).lowerBound == 10
            && HoursOfSleepChartAxis.fit([18]).gridLines.first == 10,
        "…and a trough below the floor lowers it the same way, moving the labels with it")
    assertTest(
        HoursOfSleepChartAxis.fit([]) == .standard
            && HoursOfSleepChartAxis.fit([.nan, .infinity]) == .standard,
        "Nothing finite to fit leaves the standard axis rather than an unbounded one")

    // The band mark's two rules. `BandEdges` is a `Shape`, and a `Shape`'s path is a value, so the one
    // part of the mark that is arithmetic is assertable: the rules are inset so they sit inside the
    // span they describe, a rect too small to inset draws nothing rather than inverting, and — the
    // assertion that matters most, because it is the whole of the shape — there are exactly two
    // subpaths, one at each side, and neither of them is horizontal.
    //
    // A path's elements are readable, so the count is not inferred from the bounding rect: a closed
    // rectangle inset by `(0.75, 0)` has the *same* bounding rect as these two lines do, and an
    // assertion on the rect alone would pass on the box this mark replaced.
    let field = CGRect(x: 0, y: 0, width: 40, height: 12)
    let edges = BandEdges(inset: 0.75).path(in: field)
    assertTest(
        edges.boundingRect == field.insetBy(dx: 0.75, dy: 0),
        "The typical-range band's rules are drawn inside the band's own span, so a band's edge is "
            + "painted on the band's edge rather than half a stroke outside it — and they run the "
            + "full height, because the height is the caller's overhang and not the stroke's")
    var moves = 0
    var lines = 0
    var others = 0
    edges.forEach { element in
        switch element {
        case .move: moves += 1
        case .line: lines += 1
        default: others += 1
        }
    }
    assertTest(
        moves == 2 && lines == 2 && others == 0,
        "…and it is two straight rules and nothing else — two moves, two lines, no closing segment "
            + "(got \(moves) moves, \(lines) lines, \(others) others). A top and a bottom stroke would "
            + "close the mark into a box, which is the shape this replaced, and the bounding rect "
            + "cannot tell the two apart")
    assertTest(
        BandEdges(inset: 0.75).path(in: CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty,
        "…and a rect narrower than twice its inset is empty — the guard that keeps a degenerate band "
            + "from being drawn as two rules crossed over each other")

    // ── 9. The read, end to end ──────────────────────────────────────────────────────────────────
    //
    // The values above are the chart's substance; this is the same night arriving through the read the
    // card makes. It runs against an in-memory database rather than the export because the subject is
    // the **window**: the two samples below sit either side of midnight, and the night is filed under
    // the morning it ended on — so a read scoped to the day's own bounds would return the later one
    // and drop the earlier, drawing every night half-length.
    do {
        let hrDB = LocalDatabaseManager(inMemory: true)
        let hrSleepRepository = GRDBSleepRepository(db: hrDB)

        let day = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -3, to: Date())!)
        let onset = day.addingTimeInterval(-3600)
        let wake = day.addingTimeInterval(6 * 3600)
        try await hrSleepRepository.saveSleepSession(
            SleepSession(
                date: day,
                startTime: onset,
                endTime: wake,
                lightSleepSeconds: 14400,
                deepSleepSeconds: 5400,
                remSleepSeconds: 5400,
                awakeSeconds: 3600))

        let biometrics = OvernightBiometricStore(samples: [
            BiometricSample(timestamp: onset.addingTimeInterval(600), heartRate: 52),
            BiometricSample(timestamp: day.addingTimeInterval(3600), heartRate: 58),
        ])
        let readBack = await MainActor.run {
            SleepViewModel(
                analyze: AnalyzeSleepUseCase(
                    biometricRepository: biometrics,
                    sleepRepository: hrSleepRepository,
                    strainRepository: GRDBStrainRepository(db: hrDB),
                    userProfileRepository: GRDBUserProfileRepository(db: hrDB)),
                repository: hrSleepRepository,
                napRepository: GRDBNapRepository(db: hrDB),
                biometricRepository: biometrics)
        }
        await readBack.load(for: day)

        let readSeries = await MainActor.run { readBack.hoursOfSleepSeries }
        assertTest(
            readSeries?.points.map(\.bpm) == [52, 58],
            "The view model reads the night's heart rate over the night's own bounds — the 11 PM "
                + "reading precedes the midnight the night is filed under, and a day-scoped read "
                + "would have dropped it (got "
                + "\(readSeries.map { "\($0.points.count) points" } ?? "nil"))")
        assertTest(
            readSeries?.start == onset && readSeries?.end == wake,
            "…and the series' axis is those bounds, not the day's, so the two dashed markers stand at "
                + "the night's ends")
    } catch {
        assertTest(false, "The heart-rate read block threw: \(error)")
    }

    // ── 10. The real export ──────────────────────────────────────────────────────────────────────
    //
    // The same properties as above, but over 910 real nights rather than fixtures — which is what
    // catches a rounding rule that only works on the shapes someone thought to build. Properties and
    // not counts, so a device time zone that merges two day keys narrows this without breaking it.
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
            napRepository: GRDBNapRepository(db: exportDB),
            userProfileRepository: GRDBUserProfileRepository(db: exportDB),
            calendar: Calendar.current
        ).importExport(at: csvURL)

        let imported = try await exportSleepRepository.getSleepHistory(days: 4000)
        let withPeriod = imported.filter { $0.sleepPeriodSeconds > 0 }
        assertTest(
            withPeriod.count > 900,
            "The export still imports its nights with a sleep period (\(withPeriod.count))")

        func durations(_ session: SleepSession) -> [TimeInterval] {
            SleepStageRangeScoring.stages.map { session.seconds(of: $0) }
        }

        let notHundred = withPeriod.filter { session in
            guard let percents = SleepStageRangeScoring.wholePercents(
                ofSeconds: durations(session)) else { return true }
            return percents.reduce(0, +) != 100
        }
        assertTest(
            notHundred.isEmpty,
            "Every imported night's four shares sum to exactly 100 "
                + "(\(notHundred.count) of \(withPeriod.count) do not)")

        let farOff = withPeriod.filter { session in
            let values = durations(session)
            guard let percents = SleepStageRangeScoring.wholePercents(ofSeconds: values) else {
                return true
            }
            let total = values.reduce(0, +)
            return zip(percents, values).contains { percent, seconds in
                abs(Double(percent) - seconds / total * 100) > 1
            }
        }
        assertTest(
            farOff.isEmpty,
            "…and every one of those percents is within one of its exact share, which is the "
                + "guarantee the rule actually makes (\(farOff.count) nights are outside it)")

        let mismatched = withPeriod.filter { session in
            SleepStageRangeScoring.summary(for: session, priorNights: [])?.durationSeconds
                != session.sleepPeriodSeconds
        }
        assertTest(
            mismatched.isEmpty,
            "DURATION equals the night's own sleep period on every imported night — the identity the "
                + "evaluation verified against the CSV, re-verified here rather than assumed "
                + "(\(mismatched.count) disagree)")

        // The headline, over real history. Two claims, and the second is the one that matters: every
        // imported night carries a positive hours-of-sleep figure and it adds up with the awake row to
        // that night's own DURATION. That is what makes `HOURS OF SLEEP` a reading on every imported
        // night rather than a dash — the card's absence state belongs to the chart alone, and a
        // headline gated with the chart would blank a figure the export does store.
        let headlineMissing = withPeriod.filter { session in
            guard let s = SleepStageRangeScoring.summary(for: session, priorNights: []) else {
                return true
            }
            return s.asleepSeconds <= 0
        }
        assertTest(
            headlineMissing.isEmpty,
            "Every imported night carries a positive hours-of-sleep headline — the card is never "
                + "titled with a dash (\(headlineMissing.count) of \(withPeriod.count) are not)")
        let headlineMismatched = withPeriod.filter { session in
            guard let s = SleepStageRangeScoring.summary(for: session, priorNights: []) else {
                return true
            }
            return s.asleepSeconds + s.awakeSeconds != s.durationSeconds
        }
        assertTest(
            headlineMismatched.isEmpty,
            "…and on each of them it adds up with the awake row to the same DURATION the typical-range "
                + "card prints above the four rows (\(headlineMismatched.count) disagree)")

        // The bands over real history, on the export's newest night: four ordered bands, each inside
        // the 0–100 scale the bar is drawn on. What this cannot say is whether the bands are *good* —
        // a quartile is a definition, and the middle half is a choice this app made.
        if let newest = withPeriod.max(by: { $0.date < $1.date }) {
            let exportWindow = RecoveryScoring.baselineWindow(
                before: newest.date, in: imported)
            let real = SleepStageRangeScoring.summary(for: newest, priorNights: exportWindow)
            let bands = real?.rows.compactMap(\.typical) ?? []
            assertTest(
                bands.count == 4,
                "The export's newest night has four bands over a window of "
                    + "\(exportWindow.count) nights")
            assertTest(
                bands.allSatisfy { $0.lowPercent >= 0 && $0.highPercent <= 100 }
                    && bands.allSatisfy { $0.lowPercent <= $0.highPercent },
                "…each ordered and inside the 0–100 scale its bar is drawn on, so no marker can be "
                    + "drawn off the end of a track")
            // The count the card reports is the window *after* the same filter the bands were built
            // over, so it is the number of nights that actually contributed — not the length of the
            // list handed in.
            let usable = exportWindow.filter { $0.sleepPeriodSeconds > 0 }
            assertTest(
                real?.nightCount == usable.count,
                "…and the count the card reports is the window those bands were taken over "
                    + "(\(usable.count) of \(exportWindow.count) nights are usable)")
        }

        // ── The need's split, over real history ─────────────────────────────────────────────────
        //
        // Every imported night carries WHOOP's own need, and this is the block that holds the need
        // card's box to it. The identity is re-verified against 910 real rows rather than assumed
        // from the fixture block above, because the fixture's numbers were chosen by hand and the
        // export's were not.
        let withDebt = withPeriod.filter { ($0.sleepDebtSeconds ?? 0) > 0 }
        assertTest(
            withDebt.count > 800,
            "The export still carries a stored sleep debt on most of its nights — the column the need "
                + "card's box is the first and only consumer of (\(withDebt.count) of "
                + "\(withPeriod.count))")

        // The provenance has to survive the round trip before anything below can mean what it says:
        // the split is gated on it, and a night the mapper marked as not-WHOOP's would lose its box
        // with no error anywhere.
        let notWhoopsNeed = withPeriod.filter { !$0.hasWhoopSleepNeed }
        assertTest(
            notWhoopsNeed.isEmpty,
            "…and every one of them reads back with WHOOP's own need — `sleeps.source` reaching the "
                + "entity, which is the only thing separating the two producers "
                + "(\(notWhoopsNeed.count) of \(withPeriod.count) do not)")

        let splitMismatched = withDebt.filter { session in
            guard let b = SleepNeedBreakdown.breakdown(
                needSeconds: session.targetSleepNeedSeconds,
                debtSeconds: session.sleepDebtSeconds,
                hasWhoopNeed: session.hasWhoopSleepNeed) else { return true }
            return b.parts.count != 2
                || b.parts.reduce(0) { $0 + $1.seconds } != b.needSeconds
                || b.seconds(of: .minimumAndStrain) != session.targetSleepNeedSeconds
                    - (session.sleepDebtSeconds ?? 0)
        }
        assertTest(
            splitMismatched.isEmpty,
            "…and on every one of them the box's two figures sum to the need printed above it, with "
                + "the base term exactly `need − debt` — the identity the card asserts on screen "
                + "(\(splitMismatched.count) disagree)")

        // The guard that is unreachable, and the measurement that says so. `breakdown` refuses a debt
        // larger than its need, so a row that reached it would draw a part longer than the whole; the
        // base term's own range is what keeps the claim from going stale. A writer that started
        // storing the debt in the wrong unit — minutes where the column holds seconds, or a *deficit*
        // where it holds an accumulation — would land every night in this list.
        let baseSeconds = withDebt.compactMap { session -> TimeInterval? in
            guard let debt = session.sleepDebtSeconds else { return nil }
            return session.targetSleepNeedSeconds - debt
        }
        assertTest(
            baseSeconds.allSatisfy { $0 > 0 },
            "…and the base term is positive on every night, so no stored row reaches the "
                + "`debt > need` guard — the smallest is "
                + "\((baseSeconds.min() ?? 0).formattedCompactHoursMinutes())")
        assertTest(
            (baseSeconds.min() ?? 0) > 200 * 60 && (baseSeconds.max() ?? 0) < 600 * 60,
            "…and it spans the 228…523 min the design was evaluated against, which is the measurement "
                + "that makes the guard a guard against a future writer rather than a case this file "
                + "can reach (got \(Int((baseSeconds.min() ?? 0) / 60))…"
                + "\(Int((baseSeconds.max() ?? 0) / 60)) min)")

        // ── The window's mean performance, over real windows ─────────────────────────────────────
        //
        // Cross-checked against a mean computed here from the same filtered window rather than
        // against the model that produced it. The agreement is a statement about the *window*: a
        // window that had not been filtered the same way — one that counted a stored night with no
        // sleep period, whose performance is a real-looking `0` — would disagree on any night whose
        // neighbourhood holds one. Only the newest twenty nights are checked, because a window is
        // taken per night and the whole file would be 910 of them.
        let recent = withPeriod.sorted { $0.date > $1.date }.prefix(20)
        let meanMismatched = recent.filter { session -> Bool in
            let window = RecoveryScoring.baselineWindow(before: session.date, in: imported)
                .filter { $0.sleepPeriodSeconds > 0 }
            guard window.count >= RecoveryScoring.minimumBaselineDays else { return false }
            let hand = window.map { Double($0.sleepPerformancePercentage) }.reduce(0, +)
                / Double(window.count)
            guard let modelled = SleepStageRangeScoring.summary(
                for: session, priorNights: window)?.typicalPerformancePercent else { return true }
            return abs(hand - modelled) > 0.0001
        }
        assertTest(
            meanMismatched.isEmpty,
            "The mean the need card heads itself with is the mean of the window's own night figures, "
                + "over the same filtered window the typical-range card bands — cross-checked on the "
                + "export's 20 newest nights (\(meanMismatched.count) disagree)")
    } catch {
        assertTest(false, "The typical-range export block threw: \(error)")
    }

    // ── 6. The night's heading ───────────────────────────────────────────────────────────────────
    //
    // The one string on this screen with a branch in it, and the branch is a calendar-day question
    // rather than an instant one. Every fixture here is built in `Calendar.current` and the day is
    // named by `formattedShortDate()`, so nothing below depends on the device's time zone: the block
    // asserts the *shape* — today replaces the date, any other day is the date — and never the letters
    // `Wed, Aug 5`, which are only right in an English locale.
    let headingCalendar = Calendar.current
    func headingInstant(day: Int, hour: Int, minute: Int = 0) -> Date {
        headingCalendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    let headingDay = headingInstant(day: 5, hour: 12)
    let sameDayLate = headingInstant(day: 5, hour: 23, minute: 59)
    let nextDayEarly = headingInstant(day: 6, hour: 0, minute: 1)

    assertTest(
        SleepNightHeading.title == "Last Night's Sleep",
        "The heading over the hours-of-sleep card reads \(SleepNightHeading.title)")

    assertTest(
        SleepNightHeading.subtitle(for: headingDay, now: headingDay)
            == "Today vs. prior \(RecoveryScoring.baselineWindowDays) days",
        "On the day the user is having, the heading's date half is the word Today rather than the date "
            + "— and the window is the defaulted constant rather than a literal "
            + "(got \(SleepNightHeading.subtitle(for: headingDay, now: headingDay)))")

    // The pair that pins the rule as a *calendar-day* comparison. Either half alone passes on the
    // wrong implementation: a raw `date == now` is false at both instants, and a comparison on the
    // instant would print the date at 23:59 on the very day it is today.
    assertTest(
        SleepNightHeading.subtitle(for: headingDay, now: sameDayLate).hasPrefix("Today"),
        "…and it is still Today at 23:59, because the test is on the day and not on the instant")
    assertTest(
        !SleepNightHeading.subtitle(for: headingDay, now: nextDayEarly).hasPrefix("Today"),
        "…while at 00:01 the next morning the same day is a date again, which is what keeps the word "
            + "from being a statement about how recently the app was opened")

    assertTest(
        SleepNightHeading.subtitle(for: headingDay, now: nextDayEarly)
            == "\(headingDay.formattedShortDate()) vs. prior \(RecoveryScoring.baselineWindowDays) days",
        "A past night is named by its own date, in the app's one short-date form, over the same window")
    assertTest(
        !SleepNightHeading.subtitle(for: headingDay, now: headingDay).contains(
            headingDay.formattedShortDate()),
        "…and Today *replaces* that date rather than joining it, so the two can never both appear")

    assertTest(
        SleepNightHeading.subtitle(for: headingDay, windowDays: 7, now: headingDay)
            == "Today vs. prior 7 days",
        "The window is the parameter and not a constant baked into the sentence — a caller that asks "
            + "for a different window gets a different claim rather than the same one")

    assertTest(
        SleepNightHeading.spoken(for: headingDay, now: headingDay)
            == "Last Night's Sleep, Today vs. prior \(RecoveryScoring.baselineWindowDays) days",
        "The heading and its subtitle are announced as one sentence, so a listener is not left holding "
            + "the title while the date arrives on its own")

    // ── 8. Hours against the need ────────────────────────────────────────────────────────────────
    //
    // The reference's `HOURS VS. NEEDED` card, in the three kinds of thing it is made of: the split's
    // arithmetic, the bar layout that split is drawn on, and the two absences. The card itself is a
    // `View` and this runner has no renderer, which is why `SleepNeedBreakdown` and
    // `SleepNeedBarLayout` are values rather than bodies — exactly as `SleepStageRangeScoring` and
    // `TypicalRangeBarLayout` are for the card above it.
    //
    // The fixtures are the **mockup's own numbers**, so the literals below are the figures a reader
    // can read straight off the reference: 7:33 asleep against a 9:17 need is 81%, and the need's
    // debt is 1:44. Pinning them is what makes this block a check on the card rather than on a
    // fixture nobody has seen.
    let needSeconds = TimeInterval(557 * 60)     // 9:17
    let asleepSeconds = TimeInterval(453 * 60)   // 7:33
    let debtSeconds = TimeInterval(104 * 60)     // 1:44

    guard let breakdown = SleepNeedBreakdown.breakdown(
        needSeconds: needSeconds, debtSeconds: debtSeconds, hasWhoopNeed: true)
    else {
        assertTest(false, "A night with a stored need and a stored debt produced no breakdown")
        return
    }

    assertTest(
        breakdown.seconds(of: .debt) == debtSeconds,
        "The debt's part is the stored column **at face value** — the fit over all 910 imported "
            + "nights recovers it as an additive term at coefficient 0.98, so subtracting it is "
            + "recovering WHOOP's own other two terms rather than inventing a third quantity")

    assertTest(
        breakdown.seconds(of: .minimumAndStrain) == needSeconds - debtSeconds
            && breakdown.seconds(of: .minimumAndStrain) == TimeInterval(453 * 60),
        "…and the other part is `need − debt`, 7:33 — an arithmetic identity of two stored columns, "
            + "so the two parts sum to the printed total on every night rather than approximately")

    assertTest(
        breakdown.parts.reduce(0) { $0 + $1.seconds } == breakdown.needSeconds,
        "**The identity the card prints**: the box's two figures add up to the need above them, "
            + "which is the check a reader can make on the screen itself")

    assertTest(
        breakdown.parts.count == 2
            && breakdown.parts.map(\.component) == [.minimumAndStrain, .debt],
        "Two rows and not the reference's three: it splits its base term into Healthy Minimum and "
            + "Recent Strain, and no column of this export carries either of them separately")

    assertTest(
        SleepNeedBreakdown.Component.minimumAndStrain.displayName
            == "Healthy Minimum + Recent Strain"
            && SleepNeedBreakdown.Component.debt.displayName == "Sleep Debt",
        "The first row is named for **both** of WHOOP's terms, because it holds both — a row called "
            + "`Healthy Minimum` over a figure that also carries strain would be a mislabelled reading")

    assertTest(
        !SleepNeedBreakdown.Component.minimumAndStrain.isIncrement
            && SleepNeedBreakdown.Component.debt.isIncrement,
        "Only the debt is printed with a leading `+`: the first part is the remainder after the debt "
            + "is taken out, so signing it would claim it was added to something the card does not draw")

    // ── The split's guards, each one a different column state ────────────────────────────────────
    //
    // `0` and `nil` are different answers for the debt and this is the block that says so. A night in
    // perfect sleep credit carries a stored `0` and **does** have a breakdown — the term is present
    // and contributes nothing — while a night whose row was written before `v10` carries `nil` and
    // has none. Reading the second as the first is the fabrication every absence rule here forbids.
    assertTest(
        SleepNeedBreakdown.breakdown(needSeconds: needSeconds, debtSeconds: 0, hasWhoopNeed: true)
            .map { $0.parts.count == 2 && $0.seconds(of: .debt) == 0
                && $0.seconds(of: .minimumAndStrain) == needSeconds } == true,
        "A stored debt of **zero** is an ordinary night in perfect sleep credit, not an absence: the "
            + "breakdown exists and the whole need is the base term")

    assertTest(
        SleepNeedBreakdown.breakdown(needSeconds: needSeconds, debtSeconds: nil, hasWhoopNeed: true)
            == nil,
        "A row with no debt column — every imported night before `v10` — has **no** breakdown, so the "
            + "card draws its bars and no box rather than a box reading 0:00")

    assertTest(
        SleepNeedBreakdown.breakdown(needSeconds: needSeconds, debtSeconds: -60, hasWhoopNeed: true)
            == nil,
        "A negative debt is a corrupt row rather than a night in credit, and it is refused rather "
            + "than drawn as a negative segment")

    assertTest(
        SleepNeedBreakdown.breakdown(
            needSeconds: needSeconds, debtSeconds: needSeconds + 60, hasWhoopNeed: true) == nil,
        "…and so is a debt larger than the need it is a part of, which would draw a part longer than "
            + "the whole. Unreachable on this export — measured, `need − debt` spans 228…523 min "
            + "across all 910 imported nights — so this is a guard against a future writer, and it is "
            + "asserted rather than left as a claim")

    assertTest(
        SleepNeedBreakdown.breakdown(needSeconds: 0, debtSeconds: 0, hasWhoopNeed: true) == nil,
        "A night with no need has nothing to be a part of, and no bars to draw the parts on")

    // ── The gate, which is why `hasWhoopNeed` is a parameter at all ───────────────────────────────
    //
    // **Every guard above is about the stored pair; this one is about which producer wrote it.** A
    // strap night carries a need and a debt exactly as an imported one does — `AnalyzeSleepUseCase`
    // computes the debt with `SleepDebtMath` and stores it — so `debt != nil` never separated the two
    // producers and the card's box was drawn on strap nights too. It must not be: WHOOP's need is a
    // total containing its debt term, and `SleepNeedMath`'s deliberately omits it (`ALGORITHMS.md`
    // §4), so on a strap night `need − debt` is a base requirement short by the whole deficit, printed
    // under a row named for terms that need never had. The pair below is otherwise perfectly
    // splittable, which is the point — the flag alone is what withholds it.
    assertTest(
        SleepNeedBreakdown.breakdown(
            needSeconds: needSeconds, debtSeconds: debtSeconds, hasWhoopNeed: false) == nil,
        "A need this app computed carries **no** breakdown however ordinary its debt looks: the debt "
            + "is not a term of that need, so `Healthy Minimum + Recent Strain` over `need − debt` "
            + "would understate the base requirement by the deficit and add the deficit back")

    // ── The two bars, on one scale ───────────────────────────────────────────────────────────────
    assertTest(
        SleepNeedBarLayout(
            asleepSeconds: asleepSeconds, needSeconds: needSeconds, parts: breakdown.parts)
            .map { abs($0.asleepFraction - 27180.0 / 33420.0) < 0.000001 && $0.needFraction == 1 }
            == true,
        "The sleep bar spans `asleep ÷ need` of the need bar, which is the ratio the card heads "
            + "itself with — so the picture cannot contradict the 81% printed above it")

    assertTest(
        SleepNeedBarLayout(
            asleepSeconds: 453 * 60, needSeconds: needSeconds, parts: breakdown.parts
        ).map { $0.asleepFraction * 100 } .map { abs($0 - 81.33) < 0.01 } == true,
        "…and that ratio is the unrounded one, 81.33% against the `81` the entity prints — the bar is "
            + "not drawn to the rounded integer, which would step in whole percent")

    if let layout = SleepNeedBarLayout(
        asleepSeconds: asleepSeconds, needSeconds: needSeconds, parts: breakdown.parts) {
        assertTest(
            layout.segments.count == 2
                && layout.segments.first?.startFraction == 0
                && layout.segments.last?.endFraction == layout.needFraction,
            "The segments are contiguous from the track's left edge to the need bar's own end — a "
                + "hairline of track showing between two abutting parts would read as a third part")

        assertTest(
            abs((layout.segments.first?.endFraction ?? 0)
                - (layout.segments.last?.startFraction ?? 1)) < 0.000001,
            "…and each part ends exactly where the next begins, so the two cannot overlap by a "
                + "rounding error and draw one figure twice")

        assertTest(
            abs((layout.segments.last?.widthFraction ?? 0) - 6240.0 / 33420.0) < 0.000001,
            "The debt's width is its share of the need, 1:44 of 9:17 — the split is on the need's own "
                + "scale and not on an arbitrary fraction of the track")
    } else {
        assertTest(false, "The mockup's own night produced no bar layout")
    }

    // The over-sleep case. Fifteen of the export's nights carry more stage time than need, and on
    // those the **need** bar is the short one. Drawing them equal would say the night exactly met its
    // need, which is the one thing it did not do.
    assertTest(
        SleepNeedBarLayout(asleepSeconds: 10 * 3600, needSeconds: 8 * 3600)
            .map { $0.asleepFraction == 1 && abs($0.needFraction - 0.8) < 0.000001 } == true,
        "A night that overslept its need draws the sleep bar full and the need bar short, rather than "
            + "clamping both to the same length")

    // No split, no segments — and still a layout, which is the whole reason `parts` defaults to `[]`.
    // The bars are answerable for any night with a need in it, whether or not its composition is.
    assertTest(
        SleepNeedBarLayout(asleepSeconds: asleepSeconds, needSeconds: needSeconds)
            .map { $0.segments.isEmpty && $0.needFraction == 1 } == true,
        "A night whose row supports no split still gets a layout — with no segments — so a missing "
            + "breakdown cannot take the two bars down with it")

    assertTest(
        SleepNeedBarLayout(asleepSeconds: asleepSeconds, needSeconds: 0) == nil,
        "A non-positive need has no track to draw on, and a caller with no layout draws no card "
            + "rather than an empty one")

    assertTest(
        SleepNeedBarLayout(
            asleepSeconds: asleepSeconds,
            needSeconds: needSeconds,
            parts: [SleepNeedBreakdown.Part(component: .debt, seconds: -1)]) == nil,
        "A negative part is refused at the layout too, so a corrupt split cannot draw a bar running "
            + "backwards off the left edge of the track")

    // ── The window's mean performance ────────────────────────────────────────────────────────────
    //
    // The comparison the card heads itself with. Its three priors carry **different needs** — 8h, 9h
    // and 10h against the same 7h of sleep — so the mean is not a mean of three identical figures,
    // and the entity's own rounding is visible in it: 88, 78 and 70 average to 78.67, where averaging
    // the exact ratios (87.5, 77.78, 70) gives 78.43. The two are 0.24 apart and the assertion tells
    // them apart, which is what pins the mean as one *of the printed night figures* rather than of
    // the underlying seconds.
    func shortNight(dayOffset: Int, need: TimeInterval) -> SleepSession {
        night(dayOffset: dayOffset, light: 25200, deep: 0, rem: 0, awake: 0, need: need)
    }
    let needlessPriors = [
        shortNight(dayOffset: 30, need: 8 * 3600),
        shortNight(dayOffset: 20, need: 9 * 3600),
        shortNight(dayOffset: 10, need: 10 * 3600),
    ]
    let needTarget = shortNight(dayOffset: 0, need: 8 * 3600)

    if let performanceSummary = SleepStageRangeScoring.summary(
        for: needTarget, priorNights: needlessPriors) {
        assertTest(
            performanceSummary.typicalPerformancePercent.map { abs($0 - 236.0 / 3.0) < 0.0001 }
                == true,
            "The window's mean performance is the mean of the nights' own rounded figures — 88, 78 "
                + "and 70 — which is 78.67, and not the 78.43 an average of the exact ratios gives "
                + "(got \(performanceSummary.typicalPerformancePercent.map { String(format: "%.2f", $0) } ?? "nil"))")

        assertTest(
            performanceSummary.typicalPerformancePercent.map {
                abs($0 - 78.4259) > 0.1
            } == true,
            "…asserted against the wrong answer too, so the assertion above cannot pass by agreeing "
                + "with a re-derivation of the same thing")
    } else {
        assertTest(false, "A three-night window produced no summary at all")
    }

    // The empty night is dropped from the **performance** mean as well, and this is the case where
    // including it would be invisible on the card: it carries a need and no sleep, so its performance
    // is a real-looking `0`, and a mean over five nights where one is that zero is 80 against the 100
    // the four real nights give.
    if let withEmptyPerformance = SleepStageRangeScoring.summary(
        for: target, priorNights: priors + [empty]) {
        assertTest(
            withEmptyPerformance.typicalPerformancePercent.map { abs($0 - 100) < 0.0001 } == true,
            "A stored night with no sleep period contributes no performance either — its `0` is a "
                + "night that was not slept rather than a night that scored nothing, and an "
                + "unfiltered mean over the same five nights reads 80")
    } else {
        assertTest(false, "Five nights, one of them empty, still produced no summary")
    }

    // The fifth carrier of the one condition. `Summary`'s doc comment lists five equivalents of
    // `nightCount == 0`, and this is the assertion that holds the newest of them to it.
    if let twoPriorsPerformance = SleepStageRangeScoring.summary(
        for: target, priorNights: Array(priors.suffix(2))) {
        assertTest(
            twoPriorsPerformance.typicalPerformancePercent == nil
                && twoPriorsPerformance.typicalAsleepSeconds == nil
                && twoPriorsPerformance.typicalRestorativeSeconds == nil
                && twoPriorsPerformance.nightCount == 0
                && twoPriorsPerformance.rows.allSatisfy({ $0.typical == nil }),
            "Below `minimumBaselineDays` the mean performance is withheld along with the other four "
                + "carriers of the same fact — the card then prints its figure alone rather than "
                + "against a mean taken over two nights")
    } else {
        assertTest(false, "A thin window returned no summary at all; it must still describe the night")
    }

    // ── 6. The average boundaries ────────────────────────────────────────────────────────────────
    //
    // The two dashed rules on the consistency card. They are a recency-weighted **circular** mean of
    // the four priors' onsets and wakes, and the first assertion below is the one that fails if
    // anyone replaces the circular form with a straight average: on the night clock the two wakes
    // `1410` and `30` straddle the frame's own pivot, so their arithmetic mean is midnight and their
    // circular mean is noon. Twelve hours apart, on a rule a reader checks against the bars.
    assertTest(
        SleepConsistencyMath.circularMean([1410, 30]).map { near($0, 0) || near($0, 1440) } == true,
        "Two wakes 11:30 AM and 12:30 PM — night-clock 1410 and 30 — have a circular mean of noon. "
            + "The straight average of the same pair is 720, which on this frame is midnight: the "
            + "twelve-hour error circular averaging exists to remove "
            + "(got \(String(describing: SleepConsistencyMath.circularMean([1410, 30]))) )")

    // The same pair the score's own midnight assertion uses, on the other side of the pivot: a mean
    // that must *not* move. Both answers are 720 here, and the frames are what differ — which is why
    // the demonstration of the twelve-hour error is the formatted one at the end of this block.
    assertTest(
        SleepConsistencyMath.circularMean([710, 730]).map { near($0, 720) } == true,
        "23:50 and 00:10 are night-clock 710 and 730 and their circular mean is 720 — midnight, four "
            + "hours from either sample rather than twelve")

    // The weighting's direction, which a flat mean cannot see: the same four onsets, weighted, move
    // toward the two the weights favour. 715.9979 is the 4:3:2:1 sum of unit vectors at 177.5° and
    // 182.5° — `atan2(4·sin 2.5°, −10·cos 2.5°)` — computed by hand rather than by this code.
    let weightedMean = SleepConsistencyMath.circularMean(
        [710, 710, 730, 730], weights: [4, 3, 2, 1])
    assertTest(
        weightedMean.map { near($0, 715.9979) } == true
            && SleepConsistencyMath.circularMean([710, 710, 730, 730]).map { near($0, 720) } == true,
        "The recency weights move the rule toward the newer pair: the same four onsets average 720 "
            + "flat and 715.9979 weighted 4:3:2:1, which is the 23:50 side "
            + "(got \(String(describing: weightedMean)) )")

    // The degenerate inputs. The first is the one a component-wise guard gets wrong: `sin(.pi)` is
    // `1.2e-16` rather than `0`, so `x != 0 || y != 0` passes a true cancellation and answers six in
    // the morning. The rest are the ordinary absences.
    assertTest(
        SleepConsistencyMath.circularMean([0, 720]) == nil,
        "Two boundaries exactly twelve hours apart have no mean — a cancellation whose resultant is "
            + "the rounding error of the sum, and `nil` rather than an arbitrary one of the two")
    assertTest(
        SleepConsistencyMath.circularMean([]) == nil
            && SleepConsistencyMath.circularMean([1, 2], weights: [1]) == nil
            && SleepConsistencyMath.circularMean([1, 2], weights: [0, 0]) == nil,
        "An empty set, a weight count that does not match, and a set whose weights are all zero are "
            + "each `nil` — no rule rather than a rule through nothing")
    assertTest(
        SleepConsistencyMath.circularMean([1, .nan]).map { near($0, 1) } == true,
        "A non-finite sample is dropped rather than poisoning the sum, so the one real sample is "
            + "its own mean")

    // ── 7. The frame conversion ──────────────────────────────────────────────────────────────────
    //
    // `clockMinutes(fromNightClock:)` is the inverse the two callouts and the spoken description all
    // read through, and the frame is the one thing on this card a reader cannot check by eye. The two
    // literals are the card's own values.
    assertTest(
        near(SleepConsistencyMath.clockMinutes(fromNightClock: 714), 1434)
            && near(SleepConsistencyMath.clockMinutes(fromNightClock: 1196), 476),
        "Night-clock 714 is 11:54 PM and 1196 is 7:56 AM — the pair the card's two callouts print")
    assertTest(
        Date.formattedClock(minutesOfDay: 1434) == "11:54 PM"
            && Date.formattedClock(minutesOfDay: 476) == "7:56 AM",
        "The two callout strings themselves")
    // The formatter reads **minutes past midnight**, so the five axis ticks reach it already converted
    // — 1140 for the 7 PM the axis starts on, and so on — and these are the strings the gutter shows.
    assertTest(
        Date.formattedClock(minutesOfDay: 1140) == "7 PM"
            && Date.formattedClock(minutesOfDay: 1380) == "11 PM"
            && Date.formattedClock(minutesOfDay: 180) == "3 AM"
            && Date.formattedClock(minutesOfDay: 420) == "7 AM"
            && Date.formattedClock(minutesOfDay: 660) == "11 AM"
            && Date.formattedClock(minutesOfDay: 0) == "12 AM"
            && Date.formattedClock(minutesOfDay: 720) == "12 PM"
            && Date.formattedClock(minutesOfDay: 1440) == "12 AM"
            && Date.formattedClock(minutesOfDay: -30) == "11:30 PM",
        "Whole hours drop their `:00` — the five axis ticks are times of night and `:00` is three "
            + "characters of noise five times down a 40pt gutter — while a minute is printed, "
            + "midnight is `12 AM` and not `0 AM`, noon is `12 PM`, and a negative count wraps rather "
            + "than printing `-1:-30 PM` "
            + "(got 1140 → \(Date.formattedClock(minutesOfDay: 1140)), "
            + "180 → \(Date.formattedClock(minutesOfDay: 180)), "
            + "-30 → \(Date.formattedClock(minutesOfDay: -30)))")

    // The twelve-hour error, end to end and in the open. Reading the *naive* mean of the two clocks
    // through the formatter gives noon; reading the circular mean through the frame gives midnight.
    assertTest(
        Date.formattedClock(minutesOfDay: (1430 + 10) / 2) == "12 PM"
            && Date.formattedClock(
                minutesOfDay: SleepConsistencyMath.clockMinutes(
                    fromNightClock: SleepConsistencyMath.circularMean([710, 730]) ?? .nan))
                == "12 AM",
        "A bedtime of 11:50 PM and a mean of 00:10 — the naive average of 1430 and 10 minutes past "
            + "midnight is 720, which prints as `12 PM`; the circular mean on the night clock, "
            + "read back through the frame, prints `12 AM`. One of those is the middle of the night "
            + "and the other is lunchtime")

    // The inverse is an inverse, over every hour of the day and through a real `Date` rather than
    // through its own arithmetic restated. An hour the day does not have — a spring-forward gap — is
    // skipped rather than asserted against.
    let roundTrip: Bool = {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        return (0..<24).allSatisfy { hour -> Bool in
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base),
                  calendar.component(.hour, from: date) == hour
            else { return true }
            return near(
                SleepConsistencyMath.clockMinutes(
                    fromNightClock: SleepConsistencyMath.nightClockMinutes(date, calendar: calendar)),
                Double(hour * 60))
        }
    }()
    assertTest(
        roundTrip,
        "Every hour of the day survives `nightClockMinutes` → `clockMinutes` unchanged, so the "
            + "conversion and its inverse cannot disagree at any hour a user can go to bed")

    // ── 8. The five nights, the two rules and the figure ─────────────────────────────────────────
    //
    // Fixed clock times rather than elapsed offsets, for §13's reason: `date(byAdding: .minute,)`
    // adds elapsed time, so on a spring-forward day every literal below would move.
    do {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())

        func session(
            _ dayOffset: Int, onset: (Int, Int), wake: (Int, Int), stored: Int? = nil
        ) -> SleepSession {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
            return SleepSession(
                date: day,
                startTime: calendar.date(
                    bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!,
                endTime: calendar.date(
                    bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!,
                sleepConsistency: stored)
        }

        // Four identical priors and an anchor on the same clock times: perfect consistency, and a
        // rule that lands exactly on the bars.
        let anchor = session(0, onset: (23, 0), wake: (7, 0), stored: 91)
        let priors = (1...4).map { session($0, onset: (23, 0), wake: (7, 0), stored: 88) }
        let history = priors + [anchor]

        if let summary = SleepConsistencyScoring.summary(
            for: anchor, history: history, score: 91, typicalScore: 88) {
            assertTest(
                summary.bars.count == 5
                    && summary.bars.last?.isAnchor == true
                    && summary.bars.dropLast().allSatisfy { !$0.isAnchor },
                "Five columns, the anchor last — the four priors are the reference the fifth was "
                    + "scored against, and the order is the model's own window")

            assertTest(
                zip(summary.bars, summary.bars.dropFirst()).allSatisfy { $0.date < $1.date },
                "…and they run left to right in time, oldest first, which is what makes the "
                    + "weekday row under them read as a week rather than a set")

            assertTest(
                near(summary.bars.last?.onsetMinutes ?? .nan, 660)
                    && near(summary.bars.last?.wakeMinutes ?? .nan, 1140),
                "The anchor's boundaries are night-clock minutes and not `Date`s: 11 PM is 660 and "
                    + "7 AM is 1140 on the noon-pivot frame")

            assertTest(
                near(summary.typicalOnsetMinutes, 660) && near(summary.typicalWakeMinutes, 1140),
                "Four identical nights average to themselves — the rule lands on the bars it was "
                    + "taken from, which is what a reader checking the picture will see")

            if let layout = SleepConsistencyChartLayout(summary: summary) {
                assertTest(
                    near(layout.axisStartMinutes, 420) && near(layout.axisEndMinutes, 1380),
                    "The default axis is 7 PM to 11 AM — 420 to 1380 — and no boundary in this "
                        + "history is outside it, so nothing widened it")

                assertTest(
                    layout.axisLabels.map(\.text)
                        == ["7 PM", "11 PM", "3 AM", "7 AM", "11 AM"],
                    "Five ticks on the reference's own times. They are the quarter points of the axis "
                        + "rather than five literals, so a widened axis relabels itself — and on the "
                        + "default window the quarter points of a whole-hour span are whole hours "
                        + "(got \(layout.axisLabels.map(\.text).joined(separator: ", ")))")

                assertTest(
                    near(layout.bars.last?.topFraction ?? .nan, 0.25)
                        && near(layout.bars.last?.bottomFraction ?? .nan, 0.75)
                        && layout.bars.allSatisfy { $0.topFraction < $0.bottomFraction },
                    "The anchor spans a quarter to three quarters of a sixteen-hour axis — 11 PM to "
                        + "7 AM — and every bar's onset is above its wake")

                assertTest(
                    layout.typicalOnsetText == "11 PM" && layout.typicalWakeText == "7 AM",
                    "The two callouts print the rules as clock times, read back through the frame "
                        + "rather than through the number the model works in "
                        + "(got \(layout.typicalOnsetText) / \(layout.typicalWakeText))")
            } else {
                assertTest(false, "A perfectly ordinary five-night history produced no chart layout")
            }
        } else {
            assertTest(false, "Four priors and an anchor produced no summary")
        }

        // Below four priors there is no rule and no chart — the card is absent rather than drawn over
        // four empty columns. The figure the card would have headed itself with is on the breakdown
        // row above either way, so the absence hides no reading.
        assertTest(
            SleepConsistencyScoring.summary(
                for: anchor, history: Array(history.dropFirst(2)), score: 91, typicalScore: nil)
                == nil,
            "Two priors are not four: no summary, so no card — and `SleepConsistencyMath`'s own gate "
                + "is what refuses it rather than a second copy of the rule here")
        assertTest(
            SleepConsistencyMath.typicalBoundaries(
                for: SleepConsistencyScoring.night(from: anchor),
                history: Array(history.dropFirst(2)).map(SleepConsistencyScoring.night(from:)))
                == nil,
            "…and the rule is refused by the same gate as the score, so a chart can never be drawn "
                + "for a night the figure above it declined to score")

        // The twelve-hour demonstration at the card's own level: four priors straddling midnight, and
        // the rule comes back as midnight rather than as noon.
        //
        // The pair is **antisymmetric in time order** — 23:50, 00:10, 00:10, 23:50 newest first — and
        // that is what makes the answer exact rather than approximate. On the night clock the weights
        // read 710, 730, 730, 710, so the 4:3:2:1 sum puts `4 + 1` on one side of the pivot and
        // `3 + 2` on the other: the sine terms cancel to the bit and `atan2(0, −10·cos 2.5°)` is
        // exactly π, which is exactly 720. Grouped the other way the same four nights average
        // 715.9979 — still the middle of the night, but no longer a literal a reader can check.
        let crossing = [
            session(1, onset: (23, 50), wake: (7, 0)),
            session(2, onset: (0, 10), wake: (7, 0)),
            session(3, onset: (0, 10), wake: (7, 0)),
            session(4, onset: (23, 50), wake: (7, 0)),
        ]
        if let crossed = SleepConsistencyMath.typicalBoundaries(
            for: SleepConsistencyScoring.night(from: anchor),
            history: crossing.map(SleepConsistencyScoring.night(from:))) {
            assertTest(
                SleepConsistencyChartLayout.clockText(forNightClockMinutes: crossed.onsetMinutes)
                    == "12 AM",
                "Four bedtimes of 11:50 PM and 00:10 average to midnight **on a clock**, and the "
                    + "card's own conversion is what says so. Averaged as minutes past midnight they "
                    + "are 1430 and 10 and the mean prints `12 PM` — a rule drawn through the middle "
                    + "of the day, which is the bug this frame exists to prevent "
                    + "(got "
                    + "\(SleepConsistencyChartLayout.clockText(forNightClockMinutes: crossed.onsetMinutes)))")
        } else {
            assertTest(false, "Four priors straddling midnight produced no average boundaries")
        }

        // The axis widens in whole hours to hold a boundary outside it, and relabels itself.
        let early = session(1, onset: (17, 30), wake: (7, 0))
        let earlyHistory = [early] + (2...4).map { session($0, onset: (23, 0), wake: (7, 0)) }
        if let earlySummary = SleepConsistencyScoring.summary(
            for: anchor, history: earlyHistory + [anchor], score: 91, typicalScore: nil),
            let earlyLayout = SleepConsistencyChartLayout(summary: earlySummary) {
            assertTest(
                near(earlyLayout.axisStartMinutes, 300)
                    && near(earlyLayout.axisEndMinutes, 1380),
                "A 5:30 PM bedtime — night-clock 330 — pushes the top of the axis out to 5 PM and no "
                    + "further. Clipping would draw the bar at a position it does not have and "
                    + "dropping the night would lose one of the five the card is about")
            assertTest(
                earlyLayout.axisLabels.first?.text == "5 PM"
                    && earlyLayout.axisLabels[1].text == "9:30 PM",
                "…and the ticks follow the axis, which is why they are derived: a widened span of "
                    + "1080 minutes puts its second tick on a half hour and the label prints one "
                    + "(got \(earlyLayout.axisLabels.map(\.text).joined(separator: ", ")))")
        } else {
            assertTest(false, "A night outside the default axis produced no layout")
        }

        // A night whose interval contains noon cannot be drawn on a linear axis whose top is the
        // evening and whose foot is the morning: read forward from the onset the reader reaches midday
        // before the wake. No layout, so the card prints its figure and draws no chart.
        //
        // The span here is 11:00 → 13:00, two hours and not twelve, which is the point: the rule is
        // about the *interval*, not about a duration. A fifteen-hour mis-keyed row is refused for the
        // same reason and by the same comparison. The two rules are given valid minutes deliberately,
        // so the bar is the only thing that can fail the initialiser.
        let overnight = session(0, onset: (11, 0), wake: (13, 0), stored: 91)
        assertTest(
            SleepConsistencyChartLayout(
                summary: SleepConsistencyScoring.Summary(
                    bars: [
                        SleepConsistencyScoring.Bar(
                            date: overnight.date,
                            onsetMinutes: SleepConsistencyMath.nightClockMinutes(overnight.startTime),
                            wakeMinutes: SleepConsistencyMath.nightClockMinutes(overnight.endTime),
                            isAnchor: true)
                    ],
                    typicalOnsetMinutes: 600, typicalWakeMinutes: 660, score: 91,
                    typicalScore: nil))
                == nil,
            "A bar whose interval contains noon is refused rather than drawn upside down — its onset "
                + "reads 1380 on the night clock and its wake 60, so the pair would draw a bar "
                + "running backwards up the plot. That is a corrupt row and not an absence, and the "
                + "figure above the chart is a reading that stands either way")
    }

    // ── 9. The window mean ───────────────────────────────────────────────────────────────────────
    //
    // The figure's comparison, resolved night by night with the stored value taking precedence. The
    // assertion that matters is the second: a night neither path can score is **left out** of the
    // mean rather than counted as a zero, and a window of two scored nights and three unscored ones
    // is a mean over two rather than over five.
    do {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())

        func scoredNight(_ dayOffset: Int, _ score: Int?) -> SleepSession {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
            return SleepSession(
                date: day,
                startTime: calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!,
                endTime: calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day)!,
                sleepConsistency: score)
        }

        let threeStored = [scoredNight(1, 90), scoredNight(2, 92), scoredNight(3, 94)]
        assertTest(
            SleepConsistencyScoring.typicalScore(in: threeStored, history: threeStored)
                .map { near($0, 92) } == true,
            "Three stored figures average at face value — 90, 92, 94 is 92, and no model is run over "
                + "a night that already carries WHOOP's own answer")

        // Two nights with no stored figure and nothing to compute one from: fewer than four priors
        // each, so `SleepConsistencyMath` returns `nil` for both.
        let unscored = [scoredNight(4, nil), scoredNight(5, nil)]
        assertTest(
            SleepConsistencyScoring.typicalScore(in: unscored, history: unscored) == nil,
            "Two nights that cannot be scored are no mean at all — below `minimumBaselineDays` there "
                + "is no mean to take over two nights, and the card's spoken description says so "
                + "rather than naming a typical figure")

        assertTest(
            SleepConsistencyScoring.typicalScore(
                in: threeStored + unscored, history: threeStored + unscored)
                .map { near($0, 92) } == true,
            "…and adding two unscoreable nights to a window of three leaves the mean at 92. Counting "
                + "them as zeroes would make it 55.2 — a `0%` consistency is a claim about a night, and "
                + "no night was measured there")

        assertTest(
            SleepConsistencyScoring.typicalScore(
                in: [scoredNight(1, 90), scoredNight(2, nil)], history: [scoredNight(2, nil)])
                == nil,
            "One scored night and one that cannot be is still below the floor: the count is of the "
                + "nights in the mean, not of the nights in the window")
    }

    // ── 10. The card's own words ─────────────────────────────────────────────────────────────────
    //
    // The legend is the one place on this screen where the reference's word is deliberately not
    // used, so the word is asserted rather than left to a screenshot: nothing in this app produces a
    // recommendation, and `OPTIMAL BED/WAKETIME` would be a claim it cannot honour.
    assertTest(
        SleepConsistencyCard.legendLabel == "Avg Bed/Waketime"
            && !SleepConsistencyCard.legendLabel.localizedCaseInsensitiveContains("optimal"),
        "The rules are labelled an average and not WHOOP's `optimal` — they are the mean of the same "
            + "four nights the score above them reads, and this app computes no target "
            + "(got \(SleepConsistencyCard.legendLabel))")

    do {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        func spokenNight(_ dayOffset: Int, onset: (Int, Int), wake: (Int, Int)) -> SleepSession {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
            return SleepSession(
                date: day,
                startTime: calendar.date(
                    bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!,
                endTime: calendar.date(
                    bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!
            )
        }

        let anchor = spokenNight(0, onset: (23, 54), wake: (7, 56))
        let history = (1...4).map { spokenNight($0, onset: (23, 0), wake: (7, 0)) } + [anchor]

        if let summary = SleepConsistencyScoring.summary(
            for: anchor, history: history, score: 91, typicalScore: 88.4) {
            let spoken = SleepConsistencyCard.spoken(for: summary)
            assertTest(
                spoken.contains("Sleep Consistency, 91 percent")
                    && spoken.contains("typical 88 percent"),
                "The card is announced with its figure and its comparison — the mean rounds at the "
                    + "spoken form rather than in the model, so a 88.4 says 88 "
                    + "(got \(spoken))")
            assertTest(
                spoken.contains("11:54 PM") && spoken.contains("7:56 AM")
                    && spoken.contains("11 PM") && spoken.contains("7 AM")
                    && spoken.contains("4 nights"),
                "…and then with the chart it cannot see: the night's own two boundaries, then the "
                    + "two averages the rules draw, then how many nights those were taken over "
                    + "(got \(spoken))")
        } else {
            assertTest(false, "The spoken-description fixture produced no summary")
        }
    }

    // ── 11. The efficiency card ──────────────────────────────────────────────────────────────────
    //
    // Two things here have no renderer and so are asserted as words: the card's two slots carry a
    // note rather than a reading, and the note is the whole of what they currently say. The third is
    // the window mean's filter, which is the assertion that would silently pass a wrong rule — a
    // night with no sleep period reports `100%` through the entity's own guard, so a mean that
    // counted it would be averaging a fabricated perfect night.
    do {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())

        /// A night whose efficiency is exactly `asleep / (asleep + awake)`.
        func effNight(_ dayOffset: Int, asleep: TimeInterval, awake: TimeInterval) -> SleepSession {
            SleepSession(
                date: calendar.date(byAdding: .day, value: -dayOffset, to: base)!,
                startTime: base,
                endTime: base,
                lightSleepSeconds: asleep,
                awakeSeconds: awake)
        }

        func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.0001 }

        // Four nights at 100% and one at 50% is 90 — a literal a reader can check by hand.
        let full = effNight(1, asleep: 3600, awake: 0)
        let half = effNight(2, asleep: 1800, awake: 1800)
        assertTest(
            SleepEfficiencyScoring.typicalEfficiency(in: [full, full, full, full, half])
                .map { near($0, 90) } == true,
            "Four nights at 100 percent and one at 50 average to 90 "
                + "(got \(String(describing: SleepEfficiencyScoring.typicalEfficiency(in: [full, full, full, full, half]))))")

        // The discriminating pair. `SleepSession.sleepEfficiencyPercentage` guards a zero sleep
        // period by returning 100, so an empty night that is *not* filtered enters the mean as a
        // perfect one: the correct answer is 83.33 and the unfiltered one is 87.5.
        let empty = effNight(3, asleep: 0, awake: 0)
        assertTest(
            SleepEfficiencyScoring.typicalEfficiency(in: [full, full, half, empty])
                .map { near($0, 250.0 / 3.0) } == true,
            "A night with no sleep period is filtered out of the window before the mean is taken. "
                + "Counting it would print 87.5 by averaging in the `100` the entity's own guard "
                + "returns for a night with nothing to divide "
                + "(got \(String(describing: SleepEfficiencyScoring.typicalEfficiency(in: [full, full, half, empty]))))")

        // …and the floor counts the nights that survived the filter, not the ones in the window.
        assertTest(
            SleepEfficiencyScoring.typicalEfficiency(in: [full, full, empty]) == nil,
            "Two scored nights beside an empty one is still below `minimumBaselineDays`: the floor "
                + "is a count of measured nights, and a night with no sleep period is not one")

        // Efficiency and performance are different quantities, and the two cards print both.
        let short = SleepSession(
            date: base, startTime: base, endTime: base,
            targetSleepNeedSeconds: 7200,
            lightSleepSeconds: 3600,
            awakeSeconds: 0)
        assertTest(
            short.sleepEfficiencyPercentage == 100 && short.sleepPerformancePercentage == 50,
            "An hour slept through against a two-hour need is 100 percent efficiency and 50 percent "
                + "performance — asleep over the sleep period, and asleep over the need "
                + "(got \(short.sleepEfficiencyPercentage) and \(short.sleepPerformancePercentage))")

        // The card's words, because there is no renderer here to look at the slots.
        assertTest(
            SleepEfficiencyCard.strapDataNote == "Strap data not available."
                && SleepEfficiencyCard.strapMarker == "✱"
                && SleepEfficiencyCard.strapMarker != "—",
            "A slot with no producer says `Strap data not available.` under an asterisk, and the "
                + "marker is not this app's dash — a dash is a figure that was measured and came "
                + "back absent, and efficiency is measured on every night this app can show "
                + "(got \(SleepEfficiencyCard.strapMarker))")

        let noCount = SleepEfficiencyCard.spoken(
            efficiencyPercent: 94, asleepSeconds: 27180, awakeSeconds: 1740,
            typicalEfficiencyPercent: 87.4, disturbanceCount: nil, timelineLanes: nil)
        assertTest(
            noCount.contains("Sleep Efficiency, 94 percent")
                && noCount.contains("typical 87 percent")
                && noCount.contains("Asleep, 7h 33m")
                && noCount.contains("Awake, 0h 29m"),
            "The card is announced with its figure, its comparison and its two durations, and the "
                + "durations are spelled as durations rather than as the clock form printed "
                + "(got \(noCount))")

        assertTest(
            noCount.contains(SleepEfficiencyCard.strapDataNote)
                && noCount.contains("The night's sleep timeline was not recorded."),
            "…and both absences are spoken as well as drawn. A listener gets no slot and no "
                + "asterisk, so a description that omitted them would announce two figures and "
                + "silently drop the two things a sighted reader is told are missing "
                + "(got \(noCount))")

        let counted = SleepEfficiencyCard.spoken(
            efficiencyPercent: 94, asleepSeconds: 27180, awakeSeconds: 1740,
            typicalEfficiencyPercent: nil, disturbanceCount: 12, timelineLanes: nil)
        assertTest(
            counted.contains("Wake Events, 12")
                && !counted.contains(SleepEfficiencyCard.strapDataNote)
                && !counted.contains("typical"),
            "A night a strap counted disturbances for names the count and withholds both the note "
                + "and a comparison the window could not make "
                + "(got \(counted))")

        // ── The timeline lanes ───────────────────────────────────────────────────────────────────
        //
        // The card's middle is a picture, and this runner has no renderer — so what is asserted here
        // is the arithmetic the picture is made of, resolved into `SleepTimelineLanes` rather than
        // drawn. Three properties carry the weight: the absence rule, the merge, and the scale.
        let laneStart = Date(timeIntervalSince1970: 1_700_000_000)

        /// A night of `count` 30-second epochs of `stage`, laid end to end from `laneStart`.
        func epochs(_ stages: [SleepStageType]) -> [SleepStageSegment] {
            stages.enumerated().map { index, stage in
                let from = laneStart.addingTimeInterval(Double(index) * 30)
                return SleepStageSegment(
                    startTime: from, endTime: from.addingTimeInterval(30), stage: stage)
            }
        }

        assertTest(
            SleepTimelineLanes.make(segments: [], start: laneStart, end: laneStart.addingTimeInterval(3600))
                == nil,
            "A night with no segments has no timeline, and the card draws its note — an instance with "
                + "two empty lanes would be a drawn timeline of a night with neither sleep nor "
                + "wakefulness in it")

        assertTest(
            SleepTimelineLanes.make(
                segments: epochs([.light]), start: laneStart, end: laneStart) == nil,
            "…and neither does a night with no duration, which is the guard that keeps `make` from "
                + "dividing by zero into two `NaN` lanes — a mark that takes the whole bar with it "
                + "rather than one drawn in the wrong place")

        // Three adjacent asleep epochs. One span, not three: an unmerged lane is hundreds of abutting
        // rectangles on a real night, and anti-aliasing draws a hairline of track between each pair,
        // so eight hours of unbroken sleep comes out looking striped.
        let solid = SleepTimelineLanes.make(
            segments: epochs([.light, .light, .light]),
            start: laneStart, end: laneStart.addingTimeInterval(90))
        assertTest(
            solid?.asleep.count == 1
                && solid?.asleep.first?.start == 0
                && abs((solid?.asleep.first?.end ?? 0) - 1) < 1e-9,
            "Three abutting epochs of sleep are one run covering the whole period, not three "
                + "rectangles — the merge is what makes a lane mean `a stretch of this state` rather "
                + "than `an epoch` (got \(String(describing: solid?.asleep)))")

        // A waking in the middle. The asleep lane splits in two and the awake lane holds the gap —
        // the two lanes are complements, which is what makes the pair read as one night.
        let broken = SleepTimelineLanes.make(
            segments: epochs([.light, .awake, .deep]),
            start: laneStart, end: laneStart.addingTimeInterval(90))
        assertTest(
            broken?.asleep.count == 2 && broken?.awake.count == 1,
            "An awake epoch between two asleep ones splits the asleep lane in two and puts one run in "
                + "the awake lane (got \(String(describing: broken?.asleep)) / "
                + "\(String(describing: broken?.awake)))")

        assertTest(
            abs((broken?.awake.first?.start ?? 0) - 1.0 / 3) < 1e-9
                && abs((broken?.awake.first?.end ?? 0) - 2.0 / 3) < 1e-9,
            "…and the awake run sits at the middle third of the sleep period, which is the scale both "
                + "lanes are drawn on: a fraction of the night rather than of the day "
                + "(got \(String(describing: broken?.awake.first)))")

        // `deep` and `rem` are asleep for this purpose. Only `.awake` is awake, and a lane that
        // treated each sleep stage as its own state would leave the lane half empty on a real night.
        let stages = SleepTimelineLanes.make(
            segments: epochs([.light, .deep, .rem, .awake]),
            start: laneStart, end: laneStart.addingTimeInterval(120))
        assertTest(
            stages?.asleep.count == 1 && stages?.awake.count == 1,
            "All three sleep stages fill the asleep lane as one run, so only the fourth stage lands "
                + "in the awake lane (got \(String(describing: stages?.asleep)) / "
                + "\(String(describing: stages?.awake)))")

        // A segment outside the period is clamped into the lane rather than drawn off it: a mark
        // outside the scale reads as a different scale, not as a wrong reading.
        let overhang = SleepTimelineLanes.make(
            segments: [
                SleepStageSegment(
                    startTime: laneStart.addingTimeInterval(-600),
                    endTime: laneStart.addingTimeInterval(600), stage: .light)
            ],
            start: laneStart, end: laneStart.addingTimeInterval(600))
        assertTest(
            overhang?.asleep.first?.start == 0 && abs((overhang?.asleep.first?.end ?? 0) - 1) < 1e-9,
            "A segment reaching outside the sleep period is clamped into the lane rather than drawn "
                + "past its end (got \(String(describing: overhang?.asleep)))")

        // The spoken form, which is the only lane content a listener gets.
        let spokenLanes = SleepEfficiencyCard.spoken(
            efficiencyPercent: 94, asleepSeconds: 27180, awakeSeconds: 1740,
            typicalEfficiencyPercent: 87.4, disturbanceCount: nil, timelineLanes: broken)
        assertTest(
            spokenLanes.contains("The night's sleep timeline was recorded")
                && spokenLanes.contains("1 stretches of waking")
                && !spokenLanes.contains("was not recorded"),
            "A night with a timeline is announced as recorded and says how many stretches of waking "
                + "the lanes hold, rather than claiming no timeline was recorded "
                + "(got \(spokenLanes))")

        // **The two slots are gated apart.** A night can hold a stored timeline and no disturbance
        // count, and it must then speak one note and not two — a single `hasStrapData` flag would
        // have made both slots answer to one producer.
        assertTest(
            spokenLanes.contains(SleepEfficiencyCard.strapDataNote)
                && spokenLanes.contains("Wake Events"),
            "…and the `WAKE EVENTS` note is still spoken on that same night, because the count and "
                + "the timeline have different producers and neither speaks for the other "
                + "(got \(spokenLanes))")

        // ── The timeline survives the round trip ─────────────────────────────────────────────────
        //
        // Until `v12` the segments were computed and dropped at the write, so this is the assertion
        // that fails if the column, the record property or the mapper is removed: it is the whole
        // reason the card can draw a timeline on a night it was not running for.
        do {
            let timelineDB = LocalDatabaseManager(inMemory: true)
            let repo = GRDBSleepRepository(db: timelineDB)
            let segments = epochs([.light, .deep, .awake, .rem])
            let night = SleepSession(
                date: laneStart, startTime: laneStart,
                endTime: laneStart.addingTimeInterval(120),
                targetSleepNeedSeconds: 28800,
                lightSleepSeconds: 30, deepSleepSeconds: 30, remSleepSeconds: 30,
                awakeSeconds: 30,
                sleepStages: segments)
            try await repo.saveSleepSession(night)
            let roundTripped = try await repo.getSleepSession(for: laneStart)

            assertTest(
                roundTripped?.sleepStages.count == 4,
                "A night's stage timeline survives the write and the read — the column `v12` added is "
                    + "what lets a recording outlive the moment it was made "
                    + "(got \(roundTripped?.sleepStages.count ?? -1))")
            assertTest(
                roundTripped?.sleepStages.map(\.stage) == [.light, .deep, .awake, .rem],
                "…in order, with each epoch's own stage, so the timeline drawn from storage is the "
                    + "one the classifier made (got "
                    + "\(String(describing: roundTripped?.sleepStages.map(\.stage))))")

            // An imported night writes `[]` and must come back as an empty timeline rather than as a
            // stored empty one — "never staged" and "staged as nothing" are the same fact and only
            // one of them gets a representation.
            let imported = SleepSession(
                date: laneStart.addingTimeInterval(86400),
                startTime: laneStart, endTime: laneStart.addingTimeInterval(28800),
                targetSleepNeedSeconds: 28800,
                lightSleepSeconds: 14400, deepSleepSeconds: 7200, remSleepSeconds: 7200,
                awakeSeconds: 1800)
            try await repo.saveSleepSession(imported, source: WhoopExportImporter.sourceLabel)
            let importedBack = try await repo.getSleepSession(
                for: laneStart.addingTimeInterval(86400))

            assertTest(
                importedBack?.sleepStages.isEmpty == true,
                "A night with no timeline stores NULL and reads back empty, rather than storing an "
                    + "empty array that would make `was this night staged?` unanswerable from the row "
                    + "(got \(String(describing: importedBack?.sleepStages)))")
            assertTest(
                SleepTimelineLanes.make(
                    segments: importedBack?.sleepStages ?? [],
                    start: importedBack?.startTime ?? laneStart,
                    end: importedBack?.endTime ?? laneStart) == nil,
                "…and that empty timeline produces no lanes, so the card draws its note on an "
                    + "imported night — which is every night the export can supply, permanently")
        } catch {
            assertTest(false, "The timeline round trip threw: \(error)")
        }
    }

    do {
        let csvURL = whoopExportURL()
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            assertTest(false, "The bundled export is missing at \(csvURL.path)")
            return
        }

        let exportDB = LocalDatabaseManager(inMemory: true)
        let exportSleepRepository = GRDBSleepRepository(db: exportDB)
        _ = try await WhoopExportImporter(
            recoveryRepository: GRDBRecoveryRepository(db: exportDB),
            sleepRepository: exportSleepRepository,
            strainRepository: GRDBStrainRepository(db: exportDB),
            napRepository: GRDBNapRepository(db: exportDB),
            userProfileRepository: GRDBUserProfileRepository(db: exportDB),
            calendar: Calendar.current
        ).importExport(at: csvURL)

        let imported = try await exportSleepRepository.getSleepHistory(days: 4000)
        let withPeriod = imported.filter { $0.sleepPeriodSeconds > 0 }

        // The identity the card prints two separate figures for, over real data: a reader adding the
        // `ASLEEP` and `AWAKE` rows up reaches the ratio in the headline.
        let offBy = withPeriod.filter { session in
            let exact = session.totalTimeAsleepSeconds / session.sleepPeriodSeconds * 100
            return abs(exact - Double(session.sleepEfficiencyPercentage)) > 0.5
        }
        assertTest(
            offBy.isEmpty,
            "Every imported night's efficiency is its own asleep over its own sleep period, so the "
                + "two durations the card prints are the ratio above them "
                + "(\(offBy.count) of \(withPeriod.count) disagree)")

        // The two cards on this page print different numbers, and this is what says so: a mutation
        // pointing the efficiency card at the performance figure would agree on every night.
        let disagreeing = withPeriod.filter {
            $0.sleepEfficiencyPercentage != $0.sleepPerformancePercentage
        }
        assertTest(
            disagreeing.count > 800,
            "…and efficiency is not performance. The two agree on few enough nights that a card "
                + "reading one for the other is visible on real data "
                + "(\(disagreeing.count) of \(withPeriod.count) differ)")
    } catch {
        assertTest(false, "The efficiency block's export import threw: \(error)")
    }
}

// The async sections need the process kept alive long enough to finish; 5s was too short on a
// cold database.
RunLoop.main.run(until: Date().addingTimeInterval(30.0))
