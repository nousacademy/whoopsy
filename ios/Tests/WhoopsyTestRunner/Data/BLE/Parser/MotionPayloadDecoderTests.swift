import Foundation
import Whoopsy

// MARK: - 16. Both layouts, exact lengths, and the generation dispatch

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum MotionPayloadDecoderTests {
    static func run() async throws {
        // MARK: Both layouts, against hand-built frames

        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

        // The 4.0 frame builder lives on `StepTests` beside `fiveFrame`, because the heart-rate
        // decoder's file needs the same envelope and a second copy would be a second definition
        // of §2's header.

        /// Writes one lane of 100 little-endian `i16`s at a **frame** offset.
        func writeLane(_ frame: inout [UInt8], frameOffset: Int, raw: [Int16]) {
            for (index, value) in raw.enumerated() {
                let at = frameOffset + index * 2
                let bits = UInt16(bitPattern: value)
                frame[at] = UInt8(bits & 0xFF)
                frame[at + 1] = UInt8(bits >> 8)
            }
        }

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

        // The raw values are chosen so each scale is exercised exactly once: every one of these is a
        // power-of-two denominator over its full scale, so the expected figures below are exact doubles
        // and can be pinned as literals rather than to a tolerance.
        var ax = [Int16](repeating: 0, count: 100)
        ax[0] = 4096        //  1.0 g
        ax[5] = 1000        //  0.244140625 g
        ax[6] = 2000        //  0.48828125 g
        ax[99] = -2048      // -0.5 g
        var ay = [Int16](repeating: 0, count: 100)
        ay[0] = 2048        //  0.5 g
        var az = [Int16](repeating: 0, count: 100)
        az[0] = 1024        //  0.25 g
        var gx = [Int16](repeating: 0, count: 100)
        gx[0] = -16384      // -1000 dps
        var gy = [Int16](repeating: 0, count: 100)
        gy[0] = 8192        //  500 dps
        var gz = [Int16](repeating: 0, count: 100)
        gz[99] = 16384      //  1000 dps

        var r21 = StepTests.fiveFrame(type: WhoopProtocolProfile.whoop5.packetTypes.historicalData, payloadBytes: 1229)
        assertTest(
            r21.count == 1244,
            "The hand-built R21 frame is 1244 bytes: 8 header + (3 + 1229) + 4 — §6's *frame* figure, which "
                + "is the payload plus an 11-byte origin and a 4-byte trailer and is not the length the "
                + "layout guard compares")
        writeLane(&r21, frameOffset: 28, raw: ax)
        writeLane(&r21, frameOffset: 228, raw: ay)
        writeLane(&r21, frameOffset: 428, raw: az)
        writeLane(&r21, frameOffset: 640, raw: gx)
        writeLane(&r21, frameOffset: 840, raw: gy)
        writeLane(&r21, frameOffset: 1040, raw: gz)
        writeUInt32(&r21, frameOffset: 15, 1_700_000_000)
        writeUInt16(&r21, frameOffset: 19, 16384)   // 16384/32768 s = 0.5 s
        StepTests.sealFive(&r21)

        let r21Decoded = decoder.decodeProprietaryFrame(data: Data(r21), profile: .whoop5)
        assertTest(
            r21Decoded?.type == 47 && r21Decoded?.payload.count == 1229,
            "The hand-built R21 frame validates under the 5.0 envelope and carries a 1229-byte payload")
        let banked = r21Decoded.flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) }
        assertTest(banked != nil, "…and decodes into a motion batch")

        assertTest(
            WhoopProtocolProfile.whoop5.innerOrigin + WhoopProtocolProfile.whoop5.innerPrefixBytes == 11,
            "R21's offsets are frame-absolute from byte 11 — 8 of envelope plus the 3 prefix bytes — which "
                + "is the subtraction the decoder does and this fixture deliberately does not")
        assertTest(
            banked?.accelerometerG.x.first == 1.0 && banked?.accelerometerG.x[99] == -0.5,
            "`ax` reads 4096 raw as 1.0 g at the head of its lane and -2048 as -0.5 g at the end: a wrong "
                + "origin, a wrong scale or a reversed byte order each move one of these two")
        assertTest(
            banked?.accelerometerG.x[5] == 0.244140625 && banked?.accelerometerG.x[6] == 0.48828125,
            "…and the two samples in the lane's middle are the values written there, which is what pins "
                + "the lane's internal alignment rather than only its two ends")
        assertTest(
            banked?.accelerometerG.y.first == 0.5 && banked?.accelerometerG.z.first == 0.25,
            "`ay` and `az` are read from their own frame offsets: 228 and 428, not 228 and 428 of anything "
                + "else — the three accelerometer lanes abut, so a lane read one slot wide would take its "
                + "neighbour's first sample")
        assertTest(
            banked?.gyroscopeDps?.x.first == -1000.0 && banked?.gyroscopeDps?.z[99] == 1000.0,
            "The gyroscope lanes use the second scale — 2000/32768 deg/s per LSB, so -16384 raw is -1000 "
                + "dps where the accelerometer's scale would have called it -4.0 g")
        assertTest(
            banked?.gyroscopeDps?.y.first == 500.0,
            "…and 8192 raw is 500 dps, which is not a value the accelerometer's scale can produce from it")
        assertTest(
            banked?.start == Date(timeIntervalSince1970: 1_700_000_000.5)
                && banked?.timestampIsFromStrap == true,
            "The record's own clock is read: unix seconds at frame 15 with the 1/32768 s fraction at 19, "
                + "so 1700000000 + 16384/32768 is 1700000000.5, and it is marked as the strap's")
        assertTest(
            banked?.start != receivedAt,
            "…and it is not the arrival instant: the fixture's `receivedAt` is a deliberately distant "
                + "2000000000, so a decoder that substituted it — the wrong-day failure a banked record "
                + "exists to avoid — fails here rather than passing silently")
        assertTest(
            banked?.sampleIntervalSeconds == 0.01 && banked?.accelerometerG.x.count == 100,
            "One hundred samples an interval of 0.01 s apart: one second of motion at 100 Hz")
        assertTest(
            banked?.generation == .whoop5,
            "The batch carries the frame's generation, which is what the banked path and the live path "
                + "share rather than differing on")

        // ---- The live R21 record keys on arrival, not on the strap's clock ----
        //
        // **This block exists because a real strap's clock was wrong and the tile went blank.** A 5.0
        // whose RTC was lost stamped every live record with `2000-01-03`, and `TrackStepsUseCase`
        // faithfully filed a whole walk's steps under that day — a key no screen asks for, so Home drew `—`
        // through the whole walk. A banked record must keep its stamp (it is the only way to place an
        // overnight drain on the right day), but a live one arrives as it is measured, so the arrival
        // instant is both available and unspoofable by a bad RTC.
        var r21Live = StepTests.fiveFrame(
            type: WhoopProtocolProfile.whoop5.packetTypes.realtimeRawData, payloadBytes: 1229)
        writeLane(&r21Live, frameOffset: 28, raw: ax)
        writeLane(&r21Live, frameOffset: 228, raw: ay)
        writeLane(&r21Live, frameOffset: 428, raw: az)
        writeLane(&r21Live, frameOffset: 640, raw: gx)
        writeLane(&r21Live, frameOffset: 840, raw: gy)
        writeLane(&r21Live, frameOffset: 1040, raw: gz)
        // 946,900,000 is 2000-01-03 — the stamp a lost RTC produces, and the exact failure measured.
        writeUInt32(&r21Live, frameOffset: 15, 946_900_000)
        writeUInt16(&r21Live, frameOffset: 19, 0)
        StepTests.sealFive(&r21Live)

        let r21LiveDecoded = decoder.decodeProprietaryFrame(data: Data(r21Live), profile: .whoop5)
        assertTest(
            r21LiveDecoded?.type == WhoopProtocolProfile.whoop5.packetTypes.realtimeRawData,
            "The live R21 fixture is packet 43, the type `didUpdateValueFor` routes as live motion")
        let live21 = r21LiveDecoded.flatMap {
            MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt)
        }
        assertTest(
            live21?.start == receivedAt && live21?.timestampIsFromStrap == false,
            "A **live** R21 record takes the arrival instant, not its own field — the frame here carries "
                + "2000-01-03, which is what a strap with a lost RTC stamps, and trusting it is what filed "
                + "a real walk's steps under a day nothing draws "
                + "(decoded \(String(describing: live21?.start)))")
        assertTest(
            banked?.start != receivedAt && live21?.start == receivedAt,
            "…and the two packet types are the split that makes both correct at once: the banked record "
                + "keeps the strap's stamp and the live one does not, so an overnight drain still lands "
                + "on the night it measured while today's walk lands on today")

        // The decoy. §6's `ax` is at frame 28; read as payload-relative it would be payload 28 = frame 39,
        // whose pair straddles the lane's samples 5 and 6 — so a decoder that forgot the origin reads a
        // plausible number out of the wrong place and this fixture can tell the two apart. Without these
        // two samples carrying different values, both readings would be 0 and the assertion would pass
        // whichever one the decoder did.
        let decoy = Int16(bitPattern: UInt16(r21[39]) | (UInt16(r21[40]) << 8))
        assertTest(
            decoy == -12285 && Double(decoy) * MotionPayloadDecoder.accelerometerGPerLSB != 1.0,
            "A decoder reading §6's `ax` offset as payload-relative would take frame 39's pair — \(decoy) "
                + "raw, ≈\(Double(decoy) * MotionPayloadDecoder.accelerometerGPerLSB) g — where the "
                + "frame-absolute reading gives 1.0, so this fixture separates the two readings")

        var r10ax = [Int16](repeating: 0, count: 100)
        r10ax[0] = 4096     //  1.0 g
        r10ax[3] = 3000     //  0.732421875 g
        r10ax[4] = 4000     //  0.9765625 g
        r10ax[99] = -4096   // -1.0 g
        var r10ay = [Int16](repeating: 0, count: 100)
        r10ay[0] = 2048     //  0.5 g
        var r10az = [Int16](repeating: 0, count: 100)
        r10az[0] = -1024    // -0.25 g
        var r10gx = [Int16](repeating: 0, count: 100)
        r10gx[99] = -16384  // -1000 dps
        var r10gy = [Int16](repeating: 0, count: 100)
        r10gy[0] = 8192     //  500 dps
        let r10gz = [Int16](repeating: 0, count: 100)

        var r10 = StepTests.fourFrame(type: WhoopProtocolProfile.whoop4.packetTypes.realtimeRawData, payloadBytes: 1910)
        assertTest(
            r10.count == 1921,
            "The hand-built R10 frame is 1921 bytes: 4 header + (3 + 1910) + 4 — the 4.0's type-43 record "
                + "declaring 1917, which counts the inner record plus its trailer")
        writeLane(&r10, frameOffset: 89, raw: r10ax)
        writeLane(&r10, frameOffset: 289, raw: r10ay)
        writeLane(&r10, frameOffset: 489, raw: r10az)
        writeLane(&r10, frameOffset: 692, raw: r10gx)
        writeLane(&r10, frameOffset: 892, raw: r10gy)
        writeLane(&r10, frameOffset: 1092, raw: r10gz)
        StepTests.sealFour(&r10)

        assertTest(
            WhoopProtocolProfile.whoop4.innerOrigin + WhoopProtocolProfile.whoop4.innerPrefixBytes == 7,
            "R10's offsets are frame-absolute from byte 7 — 4 of envelope plus the 3 prefix bytes, a "
                + "different origin from the 5.0's for the same three-byte inner prefix")
        assertTest(
            WhoopPacketEncoder.buildPacket(
                profile: .whoop4, type: 0x2B, seq: 0x11, cmd: 0x00,
                payload: Data(Array(r10[7..<(r10.count - 4)]))).map { Array($0) } == r10,
            "The hand-built 4.0 frame is byte-identical to `buildPacket`'s, which is a different "
                + "construction whose CRC layout §1 pins to §2.1's published vectors — so the fixture's "
                + "envelope is evidenced rather than a second opinion about it")

        let r10Decoded = decoder.decodeProprietaryFrame(data: Data(r10), profile: .whoop4)
        assertTest(
            r10Decoded?.type == 43 && r10Decoded?.payload.count == 1910,
            "The hand-built R10 frame validates under the 4.0 envelope carrying its 1910-byte payload")
        let live = r10Decoded.flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) }
        assertTest(
            live?.accelerometerG.x.first == 1.0 && live?.accelerometerG.x[3] == 0.732421875
                && live?.accelerometerG.x[4] == 0.9765625 && live?.accelerometerG.x[99] == -1.0,
            "R10's `ax` lane at frame 89 reads 1.0, 0.732421875, 0.9765625 and -1.0 g at indices 0, 3, 4 "
                + "and 99 — four literals that fail if the origin is out by the seven bytes that separate "
                + "the two layouts")
        assertTest(
            live?.accelerometerG.y.first == 0.5 && live?.accelerometerG.z.first == -0.25,
            "…and `ay` and `az` at 289 and 489 carry their own signs, so a lane read from the wrong offset "
                + "is caught rather than accidentally agreeing")
        assertTest(
            live?.gyroscopeDps?.x[99] == -1000.0 && live?.gyroscopeDps?.y.first == 500.0,
            "…and the two gyroscope lanes read the same 2000/32768 scale the 5.0's do, which is the fact "
                + "that lets one pedometer and one threshold serve both generations")
        assertTest(
            live?.start == receivedAt && live?.timestampIsFromStrap == false,
            "The 4.0's live record carries no timestamp this app can read, so `start` is the arrival "
                + "instant and `timestampIsFromStrap` says so — the one place the two generations key a day "
                + "differently, made explicit rather than implied")
        assertTest(
            live?.generation == .whoop4,
            "…and the batch carries the 4.0's generation")

        // The 4.0's decoy: the origin is 7, so a payload-relative read of frame 89 would take frame 96 —
        // the high byte of `ax[3]` and the low byte of `ax[4]`, which is why those two carry 3000 and
        // 4000 rather than the zeros the rest of the lane holds.
        let r10Decoy = Int16(bitPattern: UInt16(r10[96]) | (UInt16(r10[97]) << 8))
        assertTest(
            r10Decoy == -24565 && Double(r10Decoy) * MotionPayloadDecoder.accelerometerGPerLSB != 1.0,
            "A payload-relative read of R10's `ax` would take frame 96's pair — \(r10Decoy) raw, "
                + "≈\(Double(r10Decoy) * MotionPayloadDecoder.accelerometerGPerLSB) g — where the "
                + "frame-absolute reading gives 1.0")

        // MARK: Exact lengths

        for wrong in [1228, 1230] {
            var frame = StepTests.fiveFrame(type: 47, payloadBytes: wrong)
            StepTests.sealFive(&frame)
            let decoded = decoder.decodeProprietaryFrame(data: Data(frame), profile: .whoop5)
            assertTest(
                decoded != nil
                    && decoded.flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) }
                        == nil,
                "A 5.0 type-47 record carrying \(wrong) payload bytes passes both envelope checksums and "
                    + "is then refused by the layout: R21's 1229 is exact, not a minimum, so a record that "
                    + "is one byte short is not walked off its own end and one that is long is not truncated")
        }
        for wrong in [1909, 1911] {
            var frame = StepTests.fourFrame(type: 0x2B, payloadBytes: wrong)
            StepTests.sealFour(&frame)
            let decoded = decoder.decodeProprietaryFrame(data: Data(frame), profile: .whoop4)
            assertTest(
                decoded != nil
                    && decoded.flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) }
                        == nil,
                "A 4.0 type-43 record carrying \(wrong) payload bytes is refused the same way: R10's 1910 "
                    + "is exact")
        }

        // MARK: The generation dispatch

        var fourTypeFortySeven = StepTests.fourFrame(
            type: WhoopProtocolProfile.whoop4.packetTypes.historicalData, payloadBytes: 1244)
        StepTests.sealFour(&fourTypeFortySeven)
        let asFour = decoder.decodeProprietaryFrame(data: Data(fourTypeFortySeven), profile: .whoop4)
        assertTest(
            asFour?.type == 47,
            "A 4.0-envelope type-47 record is a valid frame — the type numbering is shared between the "
                + "two generations, which is why the envelope and not the type byte is the discriminator")
        assertTest(
            asFour.flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) } == nil,
            "…and it decodes to no motion at all: under the 4.0 profile type 47 is the flash heart-rate "
                + "record, not a motion lane, so the generation decides before any length is looked at")
        var fourTypeFortyThree = StepTests.fourFrame(type: 0x2B, payloadBytes: 1244)
        StepTests.sealFour(&fourTypeFortyThree)
        let asFourRaw = decoder.decodeProprietaryFrame(data: Data(fourTypeFortyThree), profile: .whoop4)
        assertTest(
            asFourRaw?.type == 43
                && asFourRaw.flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) } == nil,
            "The same 1244 payload under the 4.0 profile is refused too: the 4.0 walks R10 at 1910 bytes, "
                + "so a length that fits R21 does not by itself select R21 — which is the assertion that "
                + "fails if a per-generation difference ever collapses into a fallback")

        var liveR21 = r21
        liveR21[8] = WhoopProtocolProfile.whoop5.packetTypes.realtimeRawData
        StepTests.sealFive(&liveR21)   // the type byte is inside the CRC32's input, so the frame is re-sealed
        let liveBatch = decoder.decodeProprietaryFrame(data: Data(liveR21), profile: .whoop5)
            .flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) }
        // **The motion is equal; the clocks are not, and that is the rule.** This assertion used to
        // compare whole batches, which was true while both transports took the record's own stamp. A
        // live record now keys on arrival — see the block above — so the fields that must match are
        // the lanes, the interval and the generation, while `start`/`timestampIsFromStrap` are the
        // deliberate difference. Comparing the motion is also the stronger claim: it is what "one
        // layout over two transports" actually means.
        let liveIsSameMotion = liveBatch.map { live in
            banked.map { banked in
                live.accelerometerG == banked.accelerometerG
                    && live.gyroscopeDps == banked.gyroscopeDps
                    && live.sampleIntervalSeconds == banked.sampleIntervalSeconds
                    && live.generation == banked.generation
            } ?? false
        } ?? false
        assertTest(
            liveIsSameMotion,
            "A live type-43 record and a banked type-47 one carrying the same bytes decode to the same "
                + "motion — one layout over two transports, which is what lets a walk's steps and a "
                + "drained night's reach one accumulator and one stored row")
        assertTest(
            liveBatch?.start != banked?.start && liveBatch?.start == receivedAt,
            "…and they differ only in which clock keys the day: the banked batch keeps the strap's "
                + "stamp, the live one takes the arrival instant")
        assertTest(
            decoder.decodeProprietaryFrame(data: Data(liveR21), profile: .whoop5MG)
                .flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) }?
                .generation == .whoop5MG,
            "…and the same bytes under the MG profile yield an MG batch: the two 5.0 cases are separate "
                + "because the reference does not settle whether they agree on the wire")

        var metadata = StepTests.fiveFrame(type: 49, payloadBytes: 1244)
        StepTests.sealFive(&metadata)
        assertTest(
            decoder.decodeProprietaryFrame(data: Data(metadata), profile: .whoop5)
                .flatMap { MotionPayloadDecoder.decode(frame: $0, receivedAt: receivedAt) } == nil,
            "A type-49 metadata record is not motion, and is refused even at the motion layout's own "
                + "length — so the type is read rather than the length alone")
        let motionless = WhoopRawFrame(
            generation: .simulator, type: 43, seq: 0, cmd: 0, payload: Data(repeating: 0, count: 1244))
        assertTest(
            MotionPayloadDecoder.decode(frame: motionless, receivedAt: receivedAt) == nil,
            "A frame from a generation with no proprietary envelope decodes to no motion whatever its "
                + "length, because the layout is chosen by the profile and there is none to choose")
    }
}
