import Foundation
import Whoopsy

// MARK: - 16. The R18 step-counter fields

/// The offsets NOOP publishes for `R18`'s step counter, activity class and source.
///
/// **These are hand-built frames, not a capture.** The layout is NOOP's reverse-engineering and no
/// strap on this machine has produced one; `docs/BLE_PROTOCOL.md` §6 carries it as an unvalidated
/// candidate and §7's capture is what would settle it. A green run here proves the decoder reads the
/// bytes it says it reads, and nothing about whether the strap writes them there.
enum StepCounterPayloadDecoderTests {

    static func run() async throws {
        func writeUInt16(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt16) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8(value >> 8)
        }

        func writeUInt32(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt32) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8((value >> 8) & 0xFF)
            frame[frameOffset + 2] = UInt8((value >> 16) & 0xFF)
            frame[frameOffset + 3] = UInt8((value >> 24) & 0xFF)
        }

        /// A type-47 record with the R18 selector, written in **frame** coordinates: the offsets are
        /// the reference's own and the decoder is the only side that subtracts the 11-byte origin.
        func r18Frame(
            counter: UInt16,
            unix: UInt32 = 1_700_000_000,
            activityClass: UInt8 = 1,
            source: UInt8 = 0,
            payloadBytes: Int = HeartRatePayloadDecoder.r18PayloadBytes,
            type: UInt8 = WhoopProtocolProfile.whoop5.packetTypes.historicalData,
            layout: UInt8 = HeartRatePayloadDecoder.historicalLayout
        ) -> [UInt8] {
            var frame = StepTests.fiveFrame(type: type, payloadBytes: payloadBytes)
            frame[9] = layout
            writeUInt32(&frame, frameOffset: 15, unix)       // payload 4
            writeUInt16(&frame, frameOffset: 57, counter)    // payload 46
            frame[63] = activityClass                        // payload 52
            frame[64] = source                               // payload 53
            StepTests.sealFive(&frame)
            return frame
        }

        let decoder = WhoopPacketDecoder()
        func decode(
            _ bytes: [UInt8],
            profile: WhoopProtocolProfile = .whoop5
        ) -> StepCounterSample? {
            decoder.decodeProprietaryFrame(data: Data(bytes), profile: profile)
                .flatMap { StepCounterPayloadDecoder.decode(frame: $0) }
        }

        let decoded = decode(r18Frame(counter: 12_345, activityClass: 2, source: 0x10))
        assertTest(
            decoded?.counter == 12_345,
            "The counter is read as a little-endian u16 from frame 57 — the payload origin is "
                + "subtracted once, in the decoder (\(String(describing: decoded?.counter)))")
        assertTest(
            decoded?.activityClass == 2,
            "The activity class is read from frame 63 and surfaced as the strap's own code")
        assertTest(
            decoded?.counterIsSoftware == true,
            "Frame 64 holding 0x10 says the value at 57 is the software override, not the hardware "
                + "pedometer — the distinction the accumulator needs to avoid a false delta")
        assertTest(
            decoded?.timestamp == Date(timeIntervalSince1970: 1_700_000_000),
            "The record is stamped with the strap's own unix time, not the arrival instant: a banked "
                + "record has no other way onto the day it was measured")
        assertTest(
            decode(r18Frame(counter: 1, source: 0x00))?.counterIsSoftware == false,
            "Any other source byte is the hardware counter")

        assertTest(
            decode(r18Frame(counter: 1, activityClass: 3))?.activityClass == nil
                && decode(r18Frame(counter: 1, activityClass: 0xFF))?.activityClass == nil,
            "A reserved activity code is `nil` rather than passed through as a number — the decoder "
                + "will not let a caller compare 3 against walk/run and reject it for the wrong reason")

        assertTest(
            decode(r18Frame(counter: 1), profile: .whoop5MG)?.counter == 1,
            "The 5.0 MG shares the layout and the profile")

        assertTest(
            decode(r18Frame(counter: 1, payloadBytes: 108)) == nil,
            "A payload one byte short is refused rather than truncated: a short R18 is a truncated "
                + "record, and reading past its end would invent a counter from the next frame's bytes")

        assertTest(
            decode(r18Frame(counter: 1, unix: 0)) == nil
                && decode(r18Frame(counter: 1, unix: 1_500_000_000)) == nil,
            "A stamp of zero, or any stamp before 2020, is refused — the cutoff `v24` uses. A strap "
                + "whose RTC was lost stamps history in 2000, and a counter filed there is steps no "
                + "screen can draw")

        assertTest(
            decode(r18Frame(counter: 1, layout: 21)) == nil,
            "An R21 selector under the same packet type is a different layout and is refused")

        assertTest(
            decode(r18Frame(
                counter: 1,
                type: WhoopProtocolProfile.whoop5.packetTypes.realtimeRawData)) == nil,
            "A live motion record carries no counter and is refused")

        assertTest(
            decode(r18Frame(counter: 1), profile: .whoop4) == nil,
            "The 4.0 has no R18 record and no counter: the decoder is 5.0/MG only, which is why the "
                + "peak detector remains for that generation")
    }
}
