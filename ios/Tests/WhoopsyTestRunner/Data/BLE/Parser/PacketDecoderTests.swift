import Foundation
import Whoopsy

// MARK: - 2. Packet Decoder Tests

/// The section's body. Driven from top level by `runSynchronousSections(_:)`.
enum PacketDecoderTests {
    static func run() {
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
        // documented one (byte 1 is a *length*, not a command), and `docs/BLE_PROTOCOL.md` §2 documents no
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
        // the type/opcode confusion `docs/BLE_PROTOCOL.md` §3 also flags in the handshake table. A command frame
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

        // 5. The envelope itself. A 4.0 frame read under the 5.0 envelope is refused rather than parsed
        // with the wrong offsets — the property that makes the envelope, and not the type byte, the thing
        // that separates the generations. It is refused for a mundane reason: the 5.0 declared length
        // lives at `[2..4]`, so a 4.0 frame's `lengthLow` is read as the 5.0 length's high half and the
        // frame comes out absurdly long.
        assertTest(
            decoder.decodeProprietaryFrame(data: wellFormed, profile: .whoop5) == nil,
            "The decoder refuses a 4.0 frame under the 5.0 envelope")

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
    }
}
