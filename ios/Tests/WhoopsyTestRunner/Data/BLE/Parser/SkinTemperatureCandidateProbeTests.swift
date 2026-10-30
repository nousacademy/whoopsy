import Foundation
import Whoopsy

// MARK: - 16. The skin-temperature candidates

/// A file of §16's body, called by `StepTests.run()` after `Spo2CandidateProbeTests`, because it reads
/// the same R18 record at two possible offsets.
///
/// **What it proves is that both offsets are read, gated and logged, and that neither is promoted to a
/// measurement.** The reference documents a `u16` raw ÷ 100 field without pinning which byte origin its
/// "byte 73" counts from, and this codebase already uses both conventions — so a wrong choice here
/// would produce a number that still reads as a temperature. The probe is the step that settles it;
/// nothing in this file says a temperature is known.
enum SkinTemperatureCandidateProbeTests {
    static func run() async throws {
        func writeUInt32(_ payload: inout [UInt8], offset: Int, _ value: UInt32) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
            payload[offset + 2] = UInt8((value >> 16) & 0xFF)
            payload[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        func writeUInt16(_ payload: inout [UInt8], offset: Int, _ value: UInt16) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
        }

        /// An R18 payload in payload coordinates, which is the side the probe reads.
        func payload(
            unix: UInt32 = 1_700_000_000,
            body: UInt16? = nil,
            frame: UInt16? = nil,
            bytes: Int = HeartRatePayloadDecoder.r18PayloadBytes
        ) -> Data {
            var payload = [UInt8](repeating: 0, count: bytes)
            writeUInt32(&payload, offset: 4, unix)
            if let body { writeUInt16(&payload, offset: SkinTemperatureCandidateProbe.bodyPayloadOffset, body) }
            if let frame { writeUInt16(&payload, offset: SkinTemperatureCandidateProbe.framePayloadOffset, frame) }
            return Data(payload)
        }

        // MARK: The two offsets

        let decoded = SkinTemperatureCandidateProbe.decode(
            payload: payload(body: 3_412, frame: 3_508))
        assertTest(
            decoded?.bodyCelsius == 34.12 && decoded?.frameCelsius == 35.08,
            "Both candidates are read where the two conventions put byte 73 — payload 83 and payload "
                + "62 — and both are raw ÷ 100")
        assertTest(
            decoded?.bodyIsPlausible == true && decoded?.frameIsPlausible == true,
            "…and each is judged against the reference's own 5–45 °C range rather than against the "
                + "other")

        // MARK: The gate

        let absurd = SkinTemperatureCandidateProbe.decode(
            payload: payload(body: 40_000, frame: 3_500))
        assertTest(
            absurd?.bodyCelsius == 400.0 && absurd?.bodyIsPlausible == false,
            "A candidate far outside the range is reported **out** rather than clamped — an impossible "
                + "value is evidence about the offset, not a bad reading")
        assertTest(
            absurd?.frameIsPlausible == true,
            "…and the other candidate on the same record is still judged on its own")

        assertTest(
            SkinTemperatureCandidateProbe.decode(payload: payload(unix: 0)) == nil,
            "A record with no stamp has no candidates, on the oxygen probe's rule")

        // MARK: The accumulator

        var accumulator = SkinTemperatureAccumulator()
        for index in 0..<5 {
            let line = accumulator.observe(
                SkinTemperatureCandidateProbe.decode(
                    payload: payload(
                        unix: 1_700_000_000 + UInt32(index),
                        body: UInt16(3_400 + index * 10),
                        frame: 40_000))!)
            if index >= SkinTemperatureAccumulator.maximumRawLines {
                assertTest(line == nil, "Only the first few records dump a raw line, whatever the drain's size")
            }
        }
        let summary = accumulator.summary()
        assertTest(
            summary?.contains("records=5") == true && summary?.contains("body[in=5") == true,
            "The drain's summary counts every record and reports the body candidate's mean and range")
        assertTest(
            summary?.contains("frame[in=0]") == true,
            "…and reports the frame candidate as never in range on this drain, which is the shape a "
                + "wrong offset takes")

        accumulator.reset()
        assertTest(
            accumulator.summary() == nil,
            "…and a reset drain has nothing to summarise, so the next one starts clean")
    }
}
