import Foundation
import Whoopsy

// MARK: - 16. The accelerometer candidate

/// A file of §16's body, called by `StepTests.run()` beside the two other probe blocks.
///
/// **What it proves is that the triplet is read where the decoder says it is, gated on a magnitude a
/// wrist can have, and reported rather than promoted.** The sleep classifier's whole stillness spine
/// rests on `R18` body 24 — the offsets `HeartRatePayloadDecoder.acceleration(inPayload:)` uses — and
/// that decode has never been checked against a real record. A wrong origin here does not raise: it
/// yields `nil` (out of band) or a plausible vector that is not acceleration, and either way the night
/// is classified from a signal nobody validated.
///
/// Nothing in this file says the offset is right. It says which offset is read, that an impossible
/// magnitude is refused rather than clamped, and that the drain's summary counts both.
enum AccelerometerCandidateProbeTests {
    static func run() async throws {
        func writeUInt32(_ payload: inout [UInt8], offset: Int, _ value: UInt32) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
            payload[offset + 2] = UInt8((value >> 16) & 0xFF)
            payload[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        func writeFloat(_ payload: inout [UInt8], offset: Int, _ value: Float) {
            writeUInt32(&payload, offset: offset, value.bitPattern)
        }

        /// An R18 payload with a chosen triplet, at the offsets the decoder reads.
        func payload(
            x: Float?, y: Float?, z: Float?,
            unix: UInt32 = 1_700_000_000,
            bytes: Int = HeartRatePayloadDecoder.r18PayloadBytes
        ) -> Data {
            var payload = [UInt8](repeating: 0, count: bytes)
            writeUInt32(&payload, offset: AccelerometerCandidateProbe.unixPayloadOffset, unix)
            if let x { writeFloat(&payload, offset: AccelerometerCandidateProbe.xPayloadOffset, x) }
            if let y { writeFloat(&payload, offset: AccelerometerCandidateProbe.yPayloadOffset, y) }
            if let z { writeFloat(&payload, offset: AccelerometerCandidateProbe.zPayloadOffset, z) }
            return Data(payload)
        }

        // ── A wrist-shaped vector is in band, and its magnitude is the triplet's own ────────────────
        guard let resting = AccelerometerCandidateProbe.decode(
            payload: payload(x: 0.12, y: -0.05, z: 0.99))
        else {
            assertTest(false, "A payload carrying three floats at the documented offsets decodes")
            return
        }
        assertTest(resting.isPlausible,
                   "A vector of about 1 g is inside the 0.5–2 g band — a wrist under gravity")
        assertTest(abs(resting.magnitude - 1.0) < 0.02,
                   "The magnitude is the triplet's own (got \(String(format: "%.4f", resting.magnitude)))")
        assertTest(abs(resting.x - 0.12) < 1e-5 && abs(resting.z - 0.99) < 1e-5,
                   "…and each component reads back as written, so the three offsets are distinct")
        assertTest(resting.unix == 1_700_000_000,
                   "…and the record's own stamp comes with it, so a dump can be placed on a night")

        // ── An impossible magnitude is reported, never clamped ──────────────────────────────────────
        guard let freefall = AccelerometerCandidateProbe.decode(payload: payload(x: 0, y: 0, z: 0)),
              let wild = AccelerometerCandidateProbe.decode(payload: payload(x: 0, y: 0, z: 9))
        else {
            assertTest(false, "An out-of-band triplet still decodes — it is evidence, not a refusal")
            return
        }
        assertTest(!freefall.isPlausible,
                   "A zero vector is out of band: the decoder refuses it as a still wearer, and so "
                       + "does the probe, because 0 g is free fall rather than stillness")
        assertTest(!wild.isPlausible,
                   "…and 9 g is not a wrist either. Both are reported `out` rather than clamped to the "
                       + "nearest bound, which is the whole reason the probe exists")
        assertTest(freefall.magnitude == 0,
                   "The magnitude is still computed and printed for an out-of-band record (got "
                       + "\(freefall.magnitude))")

        // ── A short payload is not a record ────────────────────────────────────────────────────────
        assertTest(
            AccelerometerCandidateProbe.decode(payload: Data(repeating: 0, count: 40)) == nil,
            "A payload with no room for three floats is refused rather than reading past its end")

        // ── The line and the summary ────────────────────────────────────────────────────────────────
        assertTest(AccelerometerCandidateProbe.line(for: resting, at: Date()).contains("in"),
                   "A plausible record's line says so, so a dump is readable without arithmetic")

        var accumulator = AccelerometerAccumulator()
        _ = accumulator.observe(resting)
        _ = accumulator.observe(freefall)
        _ = accumulator.observe(wild)
        let summary = accumulator.summary() ?? ""
        assertTest(summary.contains("records=3") && summary.contains("in-band=1"),
                   "The drain's summary counts every record it walked and how many were plausible — "
                       + "the figure that says whether body 24 is where this code says it is "
                       + "(\(summary))")

        accumulator.reset()
        assertTest(accumulator.summary() == nil,
                   "A reset drain reports nothing rather than repeating the last night's counts")
    }
}
