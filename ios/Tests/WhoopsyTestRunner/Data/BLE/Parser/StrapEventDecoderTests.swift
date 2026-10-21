import Foundation
import Whoopsy

// MARK: - 16. Packet 48 / 0x30 — the strap's own events

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved verbatim.
/// `StepTests.run()` calls it after `HeartRatePayloadDecoderTests`, because it is the third walk over
/// a drained or notified frame and the only one that changes `WhoopDevice` rather than samples.
///
/// **What it proves is that the event number is read from the byte the two envelopes agree on and the
/// timestamp from the one they do not.** The event field is the inner `cmd` — frame 10 on the 5.0 and
/// 6 on the 4.0 — because `WhoopRawFrame` splits every inner record at `[type, seq, cmd]`; the
/// timestamp is payload offset 1, which is frame 12 and frame 8. The fixtures are hand-built in frame
/// coordinates, so a decoder reading a fixed offset is correct for exactly one generation and fails
/// here for the other.
enum StrapEventDecoderTests {
    static func run() async throws {
        func writeUInt32(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt32) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8((value >> 8) & 0xFF)
            frame[frameOffset + 2] = UInt8((value >> 16) & 0xFF)
            frame[frameOffset + 3] = UInt8((value >> 24) & 0xFF)
        }

        /// A 5.0 event record: the event number goes in the inner `cmd` at frame 10, its unix seconds
        /// at payload 1 = frame 12, and the rest of the body is `body` bytes this build does not read.
        func fiveEvent(event: UInt8, unix: UInt32, body: Int = 12) -> [UInt8] {
            var frame = StepTests.fiveFrame(
                type: WhoopProtocolProfile.whoop5.packetTypes.event, payloadBytes: body)
            frame[10] = event
            writeUInt32(&frame, frameOffset: 12, unix)
            StepTests.sealFive(&frame)
            return frame
        }

        /// The 4.0's counterpart: `cmd` at frame 6, timestamp at frame 8, under the four-byte-shorter
        /// envelope. The body length is `body + 4` so both fixtures carry the same payload.
        func fourEvent(event: UInt8, unix: UInt32, body: Int = 16) -> [UInt8] {
            var frame = StepTests.fourFrame(
                type: WhoopProtocolProfile.whoop4.packetTypes.event, payloadBytes: body)
            frame[6] = event
            writeUInt32(&frame, frameOffset: 8, unix)
            StepTests.sealFour(&frame)
            return frame
        }

        assertTest(
            WhoopProtocolProfile.whoop4.packetTypes.event == 0x30
                && WhoopProtocolProfile.whoop5.packetTypes.event == 48,
            "The event packet is `0x30` on the 4.0 and 48 on the 5.0 — one role, two numbers, which is "
                + "why the decoder asks the profile rather than testing a literal")

        let stamp: UInt32 = 1_700_000_000
        let five = decoder.decodeProprietaryFrame(
            data: Data(fiveEvent(event: 10, unix: stamp)), profile: .whoop5)
            .flatMap { StrapEventDecoder.decode(frame: $0) }
        assertTest(
            five?.rawEvent == 10 && five?.kind == .wristOff,
            "A 5.0 event number is read at frame 10, the inner `cmd`: 10 is `WRIST_OFF`, so a decoder "
                + "reading the payload's first byte instead would report whatever the timestamp's low "
                + "byte happens to be")
        assertTest(
            five?.timestamp == Date(timeIntervalSince1970: 1_700_000_000),
            "…and its unix seconds are at payload 1 (frame 12), which is what dates the event rather "
                + "than the arrival instant")

        let four = decoder.decodeProprietaryFrame(
            data: Data(fourEvent(event: 10, unix: stamp)), profile: .whoop4)
            .flatMap { StrapEventDecoder.decode(frame: $0) }
        assertTest(
            four?.rawEvent == 10 && four?.kind == .wristOff,
            "The 4.0 reads the same number at frame 6 — four bytes earlier, because its payload origin "
                + "is — and reaches the same verdict")
        assertTest(
            four?.timestamp == Date(timeIntervalSince1970: 1_700_000_000),
            "…and its timestamp is at frame 8 rather than 12: a decoder with a fixed frame offset is "
                + "right for one generation and shifts the other by four bytes of its own clock")

        let mappings: [(UInt8, StrapEventDecoder.Kind)] = [
            (3, .batteryLevel),
            (7, .chargingOn),
            (8, .chargingOff),
            (9, .wristOn),
            (10, .wristOff),
            (13, .rtcLost),
            (15, .boot),
            (16, .setRTC),
        ]
        for (number, expected) in mappings {
            let event = decoder.decodeProprietaryFrame(
                data: Data(fiveEvent(event: number, unix: stamp)), profile: .whoop5)
                .flatMap { StrapEventDecoder.decode(frame: $0) }
            assertTest(
                event?.kind == expected,
                "Event \(number) maps to \(expected) — the reference's numbering, one case per number "
                    + "this app names; anything else is `.other(n)` and log-only")
        }

        let unknown = decoder.decodeProprietaryFrame(
            data: Data(fiveEvent(event: 99, unix: stamp)), profile: .whoop5)
            .flatMap { StrapEventDecoder.decode(frame: $0) }
        assertTest(
            unknown?.kind == .other(99) && unknown?.rawEvent == 99,
            "An unnamed number is still reported, as `.other(99)` carrying the byte: a log that reads "
                + "`other(99)` is how the next capture names it")

        let noClock = decoder.decodeProprietaryFrame(
            data: Data(fiveEvent(event: 9, unix: 0)), profile: .whoop5)
            .flatMap { StrapEventDecoder.decode(frame: $0) }
        assertTest(
            noClock != nil && noClock?.timestamp == nil && noClock?.kind == .wristOn,
            "A zero timestamp yields the event with `timestamp == nil` rather than dropping it: a strap "
                + "whose RTC was never set still reports its wrist, and the state is true even when the "
                + "clock is not — dropping it would leave `isOnBody` stale")

        assertTest(
            StrapEventDecoder.decode(
                frame: WhoopRawFrame(generation: .whoop5, type: 48, seq: 0, cmd: 10,
                                     payload: Data([0, 0x00, 0xF1, 0x53])) ) == nil,
            "A four-byte payload is refused: the timestamp field alone does not fit, so the record is "
                + "truncated rather than a timestamp of zero")
        assertTest(
            StrapEventDecoder.decode(
                frame: WhoopRawFrame(generation: .whoop5, type: 47, seq: 0, cmd: 10,
                                     payload: Data([0, 0x00, 0xF1, 0x53, 0x65])) ) == nil,
            "A type-47 frame claiming event number 10 is refused: the packet type is what decides the "
                + "record, and a drained record's layout selector is not an event")
        assertTest(
            StrapEventDecoder.decode(
                frame: WhoopRawFrame(generation: .standardBleHR, type: 48, seq: 0, cmd: 10,
                                     payload: Data([0, 0x00, 0xF1, 0x53, 0x65])) ) == nil,
            "…and a transport with no proprietary profile is refused, because there is no event packet "
                + "type to compare against")
    }
}
