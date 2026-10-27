import Foundation
import Whoopsy

// MARK: - 16. The three heart-rate records, and the command that arms one of them

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved verbatim.
/// `StepTests.run()` calls it, after `MotionPayloadDecoderTests`, because this is the second record
/// walk over the same type-47 envelope.
///
/// **What it proves is that a drained and a live heart rate decode at the offsets the reference
/// gives, and it says nothing about hardware.** No strap's R18 record and no type-24 record has been
/// captured here; the fixtures are hand-built from `docs/BLE_PROTOCOL.md` §4 so a wrong offset fails
/// against the published layout rather than against this app's own arithmetic.
///
/// **Three records rather than two, and the third is the 4.0's.** R18 is the 5.0/MG drain's type-47
/// heart-rate record; packet 40 is its live one; **type-47 selector 24 is the 4.0's drain record**, a
/// different layout under the other envelope with signed millisecond intervals rather than ticks.
/// The two generations share the type byte and nothing else, which is why the selector and the
/// generation are both tested.
enum HeartRatePayloadDecoderTests {
    static func run() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

        func writeUInt32(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt32) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8((value >> 8) & 0xFF)
            frame[frameOffset + 2] = UInt8((value >> 16) & 0xFF)
            frame[frameOffset + 3] = UInt8((value >> 24) & 0xFF)
        }

        func writeUInt16(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt16) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8(value >> 8)
        }

        /// One `f32` little-endian at a **payload** offset, written in frame coordinates (payload 0 is
        /// frame 11 under the 5.0 envelope).
        func writeFloat32(_ frame: inout [UInt8], payloadOffset: Int, _ value: Float) {
            let bits = value.bitPattern
            let base = 11 + payloadOffset
            frame[base] = UInt8(bits & 0xFF)
            frame[base + 1] = UInt8((bits >> 8) & 0xFF)
            frame[base + 2] = UInt8((bits >> 16) & 0xFF)
            frame[base + 3] = UInt8((bits >> 24) & 0xFF)
        }

        /// A type-47 record with the R18 layout selector, written in **frame** coordinates: the
        /// offsets are the reference's own, and the decoder is the only side that subtracts the
        /// 11-byte origin.
        func r18Frame(
            heartRate: UInt8,
            unix: UInt32,
            declaredIntervals: UInt8,
            ticks: [UInt16],
            payloadBytes: Int = HeartRatePayloadDecoder.r18PayloadBytes
        ) -> [UInt8] {
            var frame = StepTests.fiveFrame(
                type: WhoopProtocolProfile.whoop5.packetTypes.historicalData,
                payloadBytes: payloadBytes)
            frame[9] = HeartRatePayloadDecoder.historicalLayout
            writeUInt32(&frame, frameOffset: 11, 0x0000_00BC)   // record index
            writeUInt32(&frame, frameOffset: 15, unix)          // unix seconds
            frame[22] = heartRate                               // payload 11
            frame[23] = declaredIntervals                       // payload 12
            for (index, value) in ticks.prefix(4).enumerated() {
                writeUInt16(&frame, frameOffset: 24 + index * 2, value)
            }
            StepTests.sealFive(&frame)
            return frame
        }

        /// A packet-40 live notification. Its payload offsets are 5/6/7, so in frame coordinates the
        /// heart rate is at 16, the count at 17 and the intervals at 18.
        func packetForty(heartRate: UInt8, declaredIntervals: UInt8, ticks: [UInt16]) -> [UInt8] {
            var frame = StepTests.fiveFrame(
                type: WhoopProtocolProfile.whoop5.packetTypes.realtimeHeartRate ?? 40,
                payloadBytes: 7 + ticks.count * 2)
            frame[16] = heartRate
            frame[17] = declaredIntervals
            for (index, value) in ticks.enumerated() {
                writeUInt16(&frame, frameOffset: 18 + index * 2, value)
            }
            StepTests.sealFive(&frame)
            return frame
        }

        // MARK: R18 — the drained record

        assertTest(
            WhoopProtocolProfile.whoop5.packetTypes.realtimeHeartRate == 40
                && WhoopProtocolProfile.whoop5MG.packetTypes.realtimeHeartRate == 40,
            "Both 5.0 profiles name packet 40 as the live heart-rate record — the notification "
                + "`TOGGLE_REALTIME_HR` starts")
        assertTest(
            WhoopProtocolProfile.whoop4.packetTypes.realtimeHeartRate == nil,
            "…and the 4.0 names none, because that generation has no packet 40 and its live pulse is "
                + "the standard 0x2A37 characteristic")

        let historicalFrame = r18Frame(
            heartRate: 62,
            unix: 1_700_000_000,
            declaredIntervals: 3,
            ticks: [1024, 512, 256])   // 1000 ms, 500 ms, 250 ms
        assertTest(
            historicalFrame.count == 124,
            "The hand-built R18 frame is 124 bytes: 8 header + (3 + 109) + 4, which is the reference's "
                + "frame figure and the arithmetic `r18PayloadBytes` records")
        let r18Decoded = decoder.decodeProprietaryFrame(data: Data(historicalFrame), profile: .whoop5)
        assertTest(
            r18Decoded?.payload.count == HeartRatePayloadDecoder.r18PayloadBytes,
            "…and carries R18's exact payload length of 109")
        let r18 = r18Decoded.flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }
        assertTest(
            r18?.heartRate == 62,
            "The heart rate is read at payload 11 — frame 22 — so a decoder that forgot the 11-byte "
                + "origin would read the record-index byte and this would not be a pulse")
        assertTest(
            r18?.timestamp == Date(timeIntervalSince1970: 1_700_000_000),
            "The record is stamped with the strap's own unix seconds at payload 4 (frame 15), not with "
                + "the arrival instant: a drained sample belongs to the day it was measured on")
        assertTest(
            r18?.timestamp != receivedAt,
            "…which is a different instant from the fixture's deliberately distant arrival clock, so a "
                + "decoder substituting `Date()` fails here rather than passing silently")
        assertTest(
            r18?.rrIntervalsMs == [1000.0, 500.0, 250.0],
            "The three R-R intervals are 1/1024 s ticks read at payload 13 + 2i: 1024 reads 1000 ms, 512 "
                + "reads 500 ms and 256 rounds to 250 ms — the last one is the nearest-millisecond rule, "
                + "not a truncation, which would print 249")
        assertTest(
            HeartRatePayloadDecoder.milliseconds(forTicks: 1) == 1.0
                && HeartRatePayloadDecoder.milliseconds(forTicks: 768) == 750.0,
            "The 1/1024 s → ms conversion rounds: one tick is 0.98 ms and reads 1, and 768 ticks is "
                + "750.5 ms and reads 750 — the `+ 512` half-step is what makes both true")

        assertTest(
            HeartRatePayloadDecoder.decodeHistorical(
                frame: decoder.decodeProprietaryFrame(
                    data: Data(r18Frame(heartRate: 0, unix: 1_700_000_000,
                                        declaredIntervals: 0, ticks: [])),
                    profile: .whoop5)!) == nil,
            "A zero heart rate is refused: it is the strap's startup state rather than a pulse, and a "
                + "stored zero would read as a measured cardiac arrest")
        assertTest(
            HeartRatePayloadDecoder.decodeHistorical(
                frame: decoder.decodeProprietaryFrame(
                    data: Data(r18Frame(heartRate: 62, unix: 0,
                                        declaredIntervals: 0, ticks: [])),
                    profile: .whoop5)!) == nil,
            "A zero unix is refused: a record with no clock has no day to be filed under, and 1970 "
                + "would be the wrong-day failure the clock set exists to avoid")

        for wrong in [108, 110] {
            let frame = r18Frame(
                heartRate: 62, unix: 1_700_000_000, declaredIntervals: 0, ticks: [], payloadBytes: wrong)
            assertTest(
                decoder.decodeProprietaryFrame(data: Data(frame), profile: .whoop5)
                    .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
                "A 5.0 type-47 record carrying \(wrong) payload bytes is refused: R18's 109 is exact, so "
                    + "a short record is not walked off its own end and a long one is not truncated")
        }

        let clamped = r18Frame(
            heartRate: 62, unix: 1_700_000_000, declaredIntervals: 200,
            ticks: [1024, 1024, 1024, 1024])
        assertTest(
            decoder.decodeProprietaryFrame(data: Data(clamped), profile: .whoop5)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }?
                .rrIntervalsMs?.count == 4,
            "A count byte of 200 yields four intervals, not two hundred: the reference caps R18's field "
                + "at four, and the clamp is what keeps a corrupt count from reading a record as a night")
        let withZeroTick = r18Frame(
            heartRate: 62, unix: 1_700_000_000, declaredIntervals: 3,
            ticks: [1024, 0, 512])
        assertTest(
            decoder.decodeProprietaryFrame(data: Data(withZeroTick), profile: .whoop5)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }?
                .rrIntervalsMs == [1000.0, 500.0],
            "A zero interval is dropped rather than stored: a zero R-R is a missing field, not two beats "
                + "at the same instant")

        // The other two type-47 layouts are not heart-rate records.
        var imuLayout = StepTests.fiveFrame(type: 47, payloadBytes: 1229)
        imuLayout[9] = 21
        StepTests.sealFive(&imuLayout)
        assertTest(
            decoder.decodeProprietaryFrame(data: Data(imuLayout), profile: .whoop5)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "An R21 IMU record is refused even when its payload is long enough to hold a heart-rate "
                + "field: the layout selector, not the length, decides what a type-47 record is")

        // MARK: R18's accelerometer — the stillness signal a night needs

        /// The same record with mean acceleration X/Y/Z at body 24, which is payload 34.
        func r18WithAcceleration(x: Float, y: Float, z: Float) -> BiometricSample? {
            var frame = r18Frame(heartRate: 60, unix: 1_790_000_000, declaredIntervals: 0, ticks: [])
            writeFloat32(&frame, payloadOffset: 34, x)
            writeFloat32(&frame, payloadOffset: 38, y)
            writeFloat32(&frame, payloadOffset: 42, z)
            StepTests.sealFive(&frame)
            return decoder.decodeProprietaryFrame(data: Data(frame), profile: .whoop5)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }
        }

        let still = r18WithAcceleration(x: 0.10, y: -0.20, z: 0.97)
        // `Float` → `Double` widens the literal (0.1 becomes 0.10000000149…), so the axes are
        // compared at the precision the field actually carries.
        func near(_ value: Double?, _ expected: Double) -> Bool {
            guard let value else { return false }
            return abs(value - expected) < 1e-6
        }
        assertTest(
            near(still?.accelerometerX, 0.10) && near(still?.accelerometerY, -0.20)
                && near(still?.accelerometerZ, 0.97),
            "R18 **body 24 is mean acceleration X/Y/Z**, three `f32` in g at payload 34 — read into "
                + "the sample because the strap does not bank `R21` in flash, so this is the only "
                + "stillness evidence a phone-away night carries "
                + "(\(still?.accelerometerX ?? .nan), \(still?.accelerometerY ?? .nan), "
                + "\(still?.accelerometerZ ?? .nan))")

        let zeroAcceleration = r18WithAcceleration(x: 0, y: 0, z: 0)
        assertTest(
            zeroAcceleration?.accelerometerX == nil && zeroAcceleration?.accelerometerZ == nil,
            "…and a magnitude outside 0.5–2 g is **refused**: an all-zero triplet is free fall, not a "
                + "motionless wrist, and a fabricated zero would read as perfect stillness to every "
                + "threshold in the sleep classifier")

        let saturated = r18WithAcceleration(x: 0, y: 0, z: 9)
        assertTest(
            saturated?.accelerometerZ == nil,
            "…as is a reading of 9 g, which no wrist under gravity produces")

        // MARK: The 4.0's type-24 record

        /// A 4.0 type-47 record with layout selector 24, written in **frame** coordinates — the
        /// published offsets are record-relative, and the decoder is the only side that subtracts
        /// the 7-byte 4.0 origin.
        func v24Frame(
            heartRate: UInt8,
            unix: UInt32,
            declaredIntervals: UInt8,
            intervals: [Int16],
            payloadBytes: Int = HeartRatePayloadDecoder.whoop4MinimumPayloadBytes,
            seq: UInt8 = HeartRatePayloadDecoder.whoop4HistoricalLayout
        ) -> [UInt8] {
            var frame = StepTests.fourFrame(
                type: WhoopProtocolProfile.whoop4.packetTypes.historicalData,
                payloadBytes: payloadBytes)
            frame[5] = seq
            writeUInt32(&frame, frameOffset: 11, unix)          // payload 4
            frame[21] = heartRate                               // payload 14
            frame[22] = declaredIntervals                       // payload 15
            for (index, value) in intervals.prefix(4).enumerated() {
                writeUInt16(&frame, frameOffset: 23 + index * 2, UInt16(bitPattern: value))
            }
            StepTests.sealFour(&frame)
            return frame
        }

        let v24FrameBytes = v24Frame(
            heartRate: 58, unix: 1_700_000_000, declaredIntervals: 3,
            intervals: [1000, 500, 250])
        assertTest(
            v24FrameBytes.count == 97,
            "The hand-built type-24 frame is 97 bytes: 4 header + (3 + 86) + 4 — the published minimum "
                + "inner length of 89 plus the 4.0 envelope's four-byte head and trailer")
        let v24Decoded = decoder.decodeProprietaryFrame(data: Data(v24FrameBytes), profile: .whoop4)
        assertTest(
            v24Decoded?.payload.count == HeartRatePayloadDecoder.whoop4MinimumPayloadBytes,
            "…and carries an 86-byte payload, which is the record's 89-byte minimum minus the three "
                + "inner prefix bytes")
        let v24 = v24Decoded.flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }
        assertTest(
            v24?.heartRate == 58,
            "The 4.0's heart rate is read at payload 14 — frame 21 — so a decoder that forgot the "
                + "7-byte origin would read the record's own clock bytes as a pulse")
        assertTest(
            v24?.timestamp == Date(timeIntervalSince1970: 1_700_000_000),
            "…and the record is stamped with its own unix seconds at payload 4 (frame 11), which is what "
                + "files a drained 4.0 sample onto the day it was measured")
        assertTest(
            v24?.rrIntervalsMs == [1000.0, 500.0, 250.0],
            "The 4.0's R-R intervals are **signed little-endian milliseconds** at payload 16 + 2i, unlike "
                + "R18's unsigned 1/1024 s ticks — a decoder that reused `readUInt16` and the tick scale "
                + "would read 1000 ms as 0.98 here, and this is the assertion that separates the two")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 58, unix: 1_700_000_000, declaredIntervals: 151,
                                    intervals: [900, 900, 900, 900])),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }?
                .rrIntervalsMs?.count == 4,
            "A declared count past the record's own cap yields four intervals, not 151: the clamp is "
                + "what keeps a corrupt count from walking a record off its end")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 58, unix: 1_700_000_000, declaredIntervals: 3,
                                    intervals: [-5, 800, 0])),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) }?
                .rrIntervalsMs == [800.0],
            "A negative or zero interval is dropped: the field is signed, and a negative R-R is a "
                + "sentinel rather than two beats arriving before they left")

        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 58, unix: 1_700_000_000, declaredIntervals: 0,
                                    intervals: [], seq: 25)),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "A type-47 record whose selector is 25 is refused: 24 is the generation's heart-rate "
                + "layout, and another selector is a different record whose bytes are not a pulse")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 58, unix: 1_700_000_000, declaredIntervals: 0,
                                    intervals: [], payloadBytes: 85)),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "An 85-byte payload is refused: the record's minimum is 86, so a short one is not walked "
                + "past its own end")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 0, unix: 1_700_000_000, declaredIntervals: 0,
                                    intervals: [])),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "A zero 4.0 heart rate is refused, the same rule as R18's: a stored zero reads as a "
                + "measured cardiac arrest")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 58, unix: 0, declaredIntervals: 0, intervals: [])),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "…and a zero clock is refused, because 1970 is a wrong day rather than no day")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(v24Frame(heartRate: 58, unix: 1_700_000_000, declaredIntervals: 0,
                                    intervals: [], payloadBytes: 109, seq: 18)),
                profile: .whoop4)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "A 4.0 record carrying the 5.0's R18 selector is refused: the two generations have a record "
                + "each, and decoding one with the other's offsets reads sensor bytes as a pulse")
        assertTest(
            decoder.decodeProprietaryFrame(
                data: Data(StepTests.fiveFrame(
                    type: 47, payloadBytes: HeartRatePayloadDecoder.whoop4MinimumPayloadBytes)),
                profile: .whoop5)
                .flatMap { HeartRatePayloadDecoder.decodeHistorical(frame: $0) } == nil,
            "…and the mirror: an 86-byte 5.0 type-47 record is refused, because R18's 109 is exact "
                + "there — a v24-shaped frame under the wrong envelope is not a fallback")

        // MARK: Packet 40 — the live record

        let liveFrame = packetForty(heartRate: 71, declaredIntervals: 2, ticks: [1024, 2048])
        let live = decoder.decodeProprietaryFrame(data: Data(liveFrame), profile: .whoop5)
            .flatMap { HeartRatePayloadDecoder.decodeLive(frame: $0, receivedAt: receivedAt) }
        assertTest(
            live?.heartRate == 71,
            "Packet 40's heart rate is at payload 5 — frame 16 — which the arm the strap was waiting "
                + "for (`0x03 TOGGLE_REALTIME_HR`) is what causes it to send")
        assertTest(
            live?.timestamp == receivedAt,
            "A live notification is stamped with its arrival instant, the same convention 0x2A37 uses: "
                + "its own unix field overlaps the inner record's command byte and is deliberately not read")
        assertTest(
            live?.rrIntervalsMs == [1000.0, 2000.0],
            "…and its intervals are the same 1/1024 s ticks at payload 7 + 2i")
        assertTest(
            HeartRatePayloadDecoder.decodeLive(
                frame: WhoopRawFrame(
                    generation: .whoop5, type: 40, seq: 0, cmd: 0,
                    payload: Data([0, 0, 0, 0, 0, 71, 9, 0, 4])),
                receivedAt: receivedAt)?.rrIntervalsMs == [1000.0],
            "A count larger than the record is clamped to the bytes actually present rather than walked "
                + "off the end — one interval fits here, so one is what comes out")
        assertTest(
            HeartRatePayloadDecoder.decodeLive(
                frame: WhoopRawFrame(
                    generation: .whoop5, type: 40, seq: 0, cmd: 0,
                    payload: Data([0, 0, 0, 0, 0, 0, 0, 0])),
                receivedAt: receivedAt) == nil,
            "A live packet with heartRate 0 is refused for the same reason an R18 one is")
        assertTest(
            HeartRatePayloadDecoder.decodeLive(
                frame: WhoopRawFrame(
                    generation: .whoop4, type: 40, seq: 0, cmd: 0,
                    payload: Data([0, 0, 0, 0, 0, 71, 0, 0, 4])),
                receivedAt: receivedAt) == nil,
            "…and a 4.0 frame claiming packet 40 is refused: that generation does not produce it, and a "
                + "fallback here would decode one generation's bytes as another's")

        // MARK: The command that arms it

        let arm = WhoopCommandFrames.realtimeHeartRate(profile: .whoop5, seq: 0x31)
        let armFrame = arm.flatMap { decoder.decodeProprietaryFrame(data: $0, profile: .whoop5) }
        assertTest(
            armFrame?.cmd == WhoopProtocolProfile.whoop5.syncOpcodes?.toggleRealtimeHR
                && armFrame?.cmd == 0x03,
            "`TOGGLE_REALTIME_HR` is command 3 under the 5.0's opcode table — the enable a bonded 5.0 "
                + "needs before it notifies packet 40")
        assertTest(
            armFrame?.payload == Data([0x01]),
            "…and its body is the one verified byte, `0x01`: the builder has no disarm form because "
                + "nothing establishes what the other body would be")
        assertTest(
            arm.flatMap { $0.first } == 0xAA,
            "…framed under the 5.0 envelope, which is what makes it writable to this generation")
        assertTest(
            WhoopCommandFrames.realtimeHeartRate(profile: .whoop4, seq: 0x31) == nil,
            "The 4.0 gets no arm at all: 0x03 is not an opcode there, and writing it would be a "
                + "different command rather than a no-op")
    }
}
