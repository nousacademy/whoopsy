import Foundation
import Whoopsy

// MARK: - 16. The oxygen candidate byte

/// A file of §16's body, called by `StepTests.run()` after `HeartRatePayloadDecoderTests`, because it
/// reads the same R18 record one field further along.
///
/// **What it proves is that the byte is read where noop's `@82` puts it and that nothing claims it is
/// a measurement.** The probe is instrumentation: a value outside 70–100 is classified rather than
/// printed as a reading, the accumulator never turns its counters into a stored figure, and the log
/// sink writes a line a person can read off the phone. **It says nothing about whether the byte is
/// oxygen at all** — that is the cross-device contradiction `docs/BLE_PROTOCOL.md` records, and no
/// assertion here can settle it.
enum Spo2CandidateProbeTests {
    static func run() async throws {
        func writeUInt32(_ payload: inout [UInt8], offset: Int, _ value: UInt32) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
            payload[offset + 2] = UInt8((value >> 16) & 0xFF)
            payload[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        /// A raw R18 frame built in payload coordinates, which is the side the probe reads.
        func rawFrame(
            unix: UInt32 = 1_700_000_000,
            candidate: UInt8 = 0,
            sleepState: UInt8 = 0,
            neighbours: [UInt8] = [],
            generation: WhoopHardwareGeneration = .whoop5,
            type: UInt8 = 47,
            seq: UInt8 = 18,
            payloadBytes: Int = HeartRatePayloadDecoder.r18PayloadBytes
        ) -> WhoopRawFrame {
            var payload = [UInt8](repeating: 0, count: payloadBytes)
            if payloadBytes > 7 { writeUInt32(&payload, offset: 4, unix) }
            for (index, value) in neighbours.enumerated() where 63 + index < payloadBytes {
                payload[63 + index] = value
            }
            // Written **after** the neighbour fill, because payload 70 and 71 sit inside the
            // 63–81 window: the scan's own bytes include the two the probe names.
            if payloadBytes > 71 {
                payload[70] = sleepState
                payload[71] = candidate
            }
            return WhoopRawFrame(
                generation: generation,
                type: type,
                seq: seq,
                cmd: 0,
                payload: Data(payload))
        }

        // MARK: The offset

        let decoded = Spo2CandidateProbe.decode(frame: rawFrame(
            candidate: 97,
            sleepState: 0x20,
            neighbours: Array(repeating: 0xAB, count: 19)))
        assertTest(
            decoded?.value == 97,
            "The candidate is payload 71 — frame 82 — the offset noop calls `spo2_candidate_82`; a "
                + "probe reading frame 82 as a payload index would land three bytes short and this "
                + "fixture would not read 97")
        assertTest(
            decoded?.unix == 1_700_000_000
                && decoded?.sleepState == 0x20,
            "The record's own unix stamp (payload 4) and the sleep-state byte (payload 70) come from the "
                + "same record, so a capture line cannot pair one night's value with another's state")
        assertTest(
            decoded?.neighbours.count == 19
                && decoded?.neighbours.first == 0xAB
                && decoded?.neighbours.last == 0xAB,
            "The neighbour window is payload 63–81 — frame 74–92, nineteen bytes — which is what the "
                + "offset-specificity scan needs to rule out a neighbouring field")

        // The same byte, reached through the real envelope, so the payload origin is not the probe's
        // own assumption: the fixture writes frame 82 and only the decoder subtracts the 11 bytes.
        var envelope = StepTests.fiveFrame(
            type: WhoopProtocolProfile.whoop5.packetTypes.historicalData,
            payloadBytes: HeartRatePayloadDecoder.r18PayloadBytes)
        envelope[9] = HeartRatePayloadDecoder.historicalLayout
        envelope[15] = 0x00
        envelope[16] = 0x00
        envelope[17] = 0x00
        envelope[18] = 0x00
        for index in 74...92 { envelope[index] = 0x11 }
        // Frame 81 and 82 are neighbours of themselves: the scan window 74–92 contains both, which is
        // the point of scanning it rather than a fixed offset list.
        envelope[81] = 0x20
        envelope[82] = 88
        StepTests.sealFive(&envelope)
        let enveloped = WhoopPacketDecoder()
            .decodeProprietaryFrame(data: Data(envelope), profile: .whoop5)
            .flatMap { Spo2CandidateProbe.decode(frame: $0) }
        assertTest(
            enveloped?.value == 88,
            "A frame written at frame byte 82 and decoded through the 5.0 envelope reads 88, which is "
                + "the origin rule (payload = frame − 11) applied once by the decoder and not twice")
        assertTest(
            enveloped?.sleepState == 0x20,
            "…and frame 81 arrives as payload 70, so the two offsets the reference names cannot be "
                + "transposed without this fixture's value moving")
        var expectedNeighbours = Array(repeating: UInt8(0x11), count: 19)
        expectedNeighbours[70 - 63] = 0x20
        expectedNeighbours[71 - 63] = 88
        assertTest(
            enveloped?.neighbours == expectedNeighbours,
            "…and frame 74–92 arrives as the nineteen neighbours, with the sleep state and the candidate "
                + "at their own places inside that window — the scan covers the byte rather than standing "
                + "beside it")

        // MARK: The gate

        assertTest(
            Spo2CandidateProbe.decode(frame: rawFrame(generation: .whoop4)) == nil,
            "A 4.0 frame with type 47, selector 18 and 109 payload bytes is refused: the generations "
                + "share the packet number, and only the 5.0/MG has this layout under it")
        assertTest(
            Spo2CandidateProbe.decode(frame: rawFrame(seq: 17)) == nil
                && Spo2CandidateProbe.decode(frame: rawFrame(type: 48)) == nil
                && Spo2CandidateProbe.decode(frame: rawFrame(payloadBytes: 108)) == nil,
            "A wrong selector, a wrong type or a payload one byte short is refused, so the probe cannot "
                + "read a record this app's own heart-rate walk would not have accepted")

        // MARK: The tri-mode gate

        func band(_ value: UInt8) -> Spo2CandidateObservation.Band? {
            Spo2CandidateProbe.decode(frame: rawFrame(candidate: value))?.band
        }
        assertTest(
            band(70) == .inBand && band(97) == .inBand && band(100) == .inBand,
            "70–100 inclusive is the in-band reading noop treats as a percentage, including both ends")
        assertTest(
            band(0) == .absent && band(69) == .diagnostic && band(1) == .diagnostic,
            "0 is the normal awake/idle state and 1–69 is a diagnostic code, not a low reading: printing "
                + "a diagnostic as 69% would invent a desaturation that is really a status byte")
        assertTest(
            band(0x80) == .sentinel && band(0xA0) == .sentinel,
            "Bit 7 is a saturation sentinel rather than a value — 0xA0 is 160, which an unclassified "
                + "read would print as a number no pulse oximeter can report")
        assertTest(
            band(101) == .unclassified && band(127) == .unclassified,
            "101–127 has never been observed and stays unclassified rather than being folded into a "
                + "neighbour band: a guess here would decide the byte's meaning by fiat")

        let asleep = Spo2CandidateProbe.decode(frame: rawFrame(sleepState: 0x20))
        let awake = Spo2CandidateProbe.decode(frame: rawFrame(sleepState: 0x10))
        assertTest(
            asleep?.isAsleep == true && awake?.isAsleep == false,
            "The asleep label is `(byte >> 4) & 0x03 == 2`: 0x20 is asleep and 0x10 is not, which is the "
                + "reference's own test rather than `sleepState != 0`")
        assertTest(
            Spo2CandidateProbe.decode(frame: rawFrame(sleepState: 0x30))?.isAsleep == false,
            "…and 0x30 is a different band state, not a louder asleep: the mask is load-bearing")

        // MARK: The accumulator

        var accumulator = Spo2CandidateAccumulator()
        assertTest(
            accumulator.summary() == nil && !accumulator.hasObservations,
            "A drain that saw no record produces no summary at all, so the log cannot report a night "
                + "of zeros the strap never sent")
        assertTest(
            accumulator.observe(Spo2CandidateObservation(
                unix: 1_700_000_000, value: 0, sleepState: 0, neighbours: [])) == nil,
            "A record outside 70–100 does not spend the raw-line budget")

        let inBand = [97, 98, 99, 96]
        var emitted: [String] = []
        for (index, value) in inBand.enumerated() {
            let observation = Spo2CandidateObservation(
                unix: 1_700_000_000 + UInt32(index * 60),
                value: UInt8(value),
                sleepState: 0x20,
                neighbours: Array(repeating: 0x00, count: 19))
            accumulator.observe(Spo2CandidateObservation(
                unix: observation.unix, value: 1, sleepState: 0x20, neighbours: []))   // diagnostic
            accumulator.observe(Spo2CandidateObservation(
                unix: observation.unix, value: 0xA0, sleepState: 0x20, neighbours: [])) // sentinel
            if let line = accumulator.observe(observation) { emitted.append(line) }
        }
        assertTest(
            emitted.count == Spo2CandidateAccumulator.maximumRawLines,
            "The raw dump is capped at three in-band records however long the drain, while the counters "
                + "still cover every record: a night is tens of thousands of frames and a file is not")
        assertTest(
            emitted.first?.contains("value=97") == true
                && emitted.first?.contains("band=in-band") == true
                && emitted.first?.contains("asleep=true") == true
                && emitted.first?.contains("sleep=0x20") == true
                && emitted.first?.contains("neighbours=[") == true,
            "A dumped line carries the raw value, its band, the sleep state and the neighbour bytes — the "
                + "evidence the offset scan needs, with nothing rendered as a reading")

        let summary = accumulator.summary() ?? ""
        assertTest(
            summary.contains("r18=13"),
            "The summary counts every record the probe examined (one absent, then four groups of three), "
                + "not only the ones that produced lines")
        assertTest(
            summary.contains("in-band=4") && summary.contains("mean=97.5"),
            "The in-band mean is over the four real values (97, 98, 99, 96), so a diagnostic or sentinel "
                + "folded into the mean would move this figure")
        assertTest(
            summary.contains("min=96") && summary.contains("max=99"),
            "…and the range is the in-band range, which is what a nightly comparison is read against")
        assertTest(
            summary.contains("asleep=4") && summary.contains("sentinels=4")
                && summary.contains("diagnostic=4") && summary.contains("absent=1")
                && summary.contains("unclassified=0"),
            "Every band is counted separately, so a night that produced only sentinels reads as zeros "
                + "with four sentinels rather than as a failed probe")
        assertTest(
            summary.contains("first=2023-11-14T22:13:20Z") && summary.contains("last=2023-11-14T22:16:20Z"),
            "The first and last in-band stamps bracket the run of samples, which is how a capture shows "
                + "the ~30-sample burst arriving at ~1 Hz")

        accumulator.reset()
        assertTest(
            accumulator.summary() == nil && !accumulator.hasObservations,
            "`reset()` clears the counters, so one drain's summary cannot be printed by the next")

        // MARK: The file sink

        let directory = packageRoot().appendingPathComponent("tmp/build/capture-log-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = CaptureLog(fileName: "probe.txt", directory: directory)
        log.append("spo2probe summary r18=1 in-band=1 mean=97.0")
        let written = try String(contentsOf: log.url, encoding: .utf8)
        assertTest(
            written.contains("spo2probe summary r18=1 in-band=1 mean=97.0")
                && written.hasPrefix("20"),
            "A line reaches the file with a UTC timestamp prefix, which is what makes a capture in "
                + "Documents readable without Xcode's log window")
        assertTest(
            log.url.lastPathComponent == "probe.txt"
                && log.url.deletingLastPathComponent().standardizedFileURL.path
                    == directory.standardizedFileURL.path,
            "The sink writes into the directory it was given, so the suite never appends to the "
                + "developer's real Documents folder")

        let filler = String(repeating: "x", count: 1_000)
        for _ in 0..<70 { log.append(filler) }
        let rotated = directory.appendingPathComponent("probe.txt.1")
        let attributes = try? FileManager.default.attributesOfItem(atPath: log.url.path)
        let currentSize = (attributes?[.size] as? Int) ?? 0
        assertTest(
            FileManager.default.fileExists(atPath: rotated.path),
            "Past ~64 KB the file rotates to `<name>.1` instead of growing without bound, which is the "
                + "cap `docs/TODO.md` §5 asks for")
        assertTest(
            currentSize <= CaptureLog.maximumBytes,
            "…and the live file stays at or below the cap, so a long walk cannot fill the sandbox")
        try? FileManager.default.removeItem(at: directory)
    }
}
