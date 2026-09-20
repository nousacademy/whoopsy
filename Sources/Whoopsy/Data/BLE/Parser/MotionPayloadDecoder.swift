import Foundation

/// Walks a validated proprietary frame's motion payload into a `MotionBatch`.
///
/// `MotionBatch` itself lives in `Domain/Entities/MotionBatch.swift` — it is a measurement, not a wire
/// shape, and the stream protocol that carries it is a `Domain` one.
///
/// **Everything here is a layout `BLE_PROTOCOL.md` §6 publishes, and nothing here is inferred.** The
/// two layouts are R10 (the 4.0's live stream) and R21 (the 5.0/MG's, live on packet 43 and banked on
/// packet 47). Both are 100 samples per axis of little-endian `i16`, and — the fact that makes one
/// pedometer serve both — **both carry the same two scales**.
///
/// ## The offsets are frame-absolute, and that is the mistake this file exists to not make
///
/// §6's tables give every offset from the **frame's** first byte, not from the payload's. A
/// `WhoopRawFrame.payload` begins after the envelope *and* after the three `[type][seq][cmd]` bytes,
/// so the payload origin is `innerOrigin + innerPrefixBytes` — **11** under the 5.0 envelope and
/// **7** under the 4.0's. Indexing `payload[28]` for `ax` is therefore an off-by-eleven that reads a
/// plausible float out of the wrong place: it does not crash, it does not fail a checksum, and it
/// produces a step count. The spec's own numbers are kept verbatim below and the subtraction happens
/// once, in `decode`.
///
/// ## A per-generation difference must not collapse into a fallback
///
/// Every branch here is chosen by the frame's **generation**, never by trying one layout and falling
/// back to the other when it does not fit. The two would overlap on a coincidental length and a
/// fallback would decode one strap's record with the other's offsets — silently, since both layouts
/// are i16 arrays of the same shape. A record whose payload is not exactly the expected length is
/// refused, and a record type this app models no motion lane for is refused, both by returning `nil`.
public enum MotionPayloadDecoder {

    /// R21's payload, exactly: 1,244 bytes, fixed.
    ///
    /// Not a minimum. §6 calls the record "fixed 1,244 bytes", and a length test rather than a
    /// truncation is what keeps a shorter record from being walked off its own end.
    public static let r21PayloadBytes = 1244

    /// R10's payload: the 4.0's `REALTIME_RAW_DATA` variant declaring **1917** bytes.
    ///
    /// The declared length counts the inner record plus the four-byte trailer, so the payload is
    /// `1917 − 4 − 3` = **1910**. Written as its own constant with the arithmetic in the comment
    /// rather than as `1917 - 7` inline, because the declared figure is the one §6 publishes and a
    /// reader needs to be able to find it.
    public static let r10PayloadBytes = 1910

    /// Samples per axis, in both layouts. One second of motion at 100 Hz.
    public static let samplesPerAxis = 100

    /// `1/4096` g per LSB — a ±8 g full scale over a signed `i16`. §6 states it for both layouts.
    public static let accelerometerGPerLSB = 1.0 / 4096.0

    /// `2000/32768` deg/s per LSB — a ±2000 dps full scale. `0.06103515625`.
    public static let gyroscopeDpsPerLSB = 2000.0 / 32768.0

    /// Decodes a motion record, or returns `nil` when the frame carries none this app can walk.
    ///
    /// - Parameters:
    ///   - frame: A frame whose envelope has already been validated. The payload is **not**
    ///     re-checked against a checksum — `decodeProprietaryFrame` did that, and the frame-level
    ///     CRC32 covers every byte this reads.
    ///   - receivedAt: The instant the notification was decoded. Used only for the 4.0's live record,
    ///     which carries no timestamp of its own; see `MotionBatch.timestampIsFromStrap`.
    public static func decode(frame: WhoopRawFrame, receivedAt: Date) -> MotionBatch? {
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation) else { return nil }
        let payload = frame.payload
        let origin = profile.innerOrigin + profile.innerPrefixBytes
        let types = profile.packetTypes

        switch frame.generation {
        case .whoop4:
            // The 4.0's live stream only. Its `historicalData` type is deliberately not routed: that
            // is the type-24 flash record, one sample per second of accelerometer and nothing else,
            // and it is **not** a step source — a walking cadence is ≈1.5–2 Hz and a 1 Hz series
            // cannot represent anything above 0.5 Hz. Refusing it is what keeps it from being walked
            // as if it were motion.
            guard frame.type == types.realtimeRawData else { return nil }
            return decodeR10(payload: payload, origin: origin, receivedAt: receivedAt)

        case .whoop5, .whoop5MG:
            // Live and banked are the *same* record here, which is the fact the whole 5.0 path rests
            // on: a drained packet 47 and a live packet 43 carry one R21 layout at 100 Hz, so a
            // night's steps and a walk's steps arrive through one decoder and one accumulator.
            guard frame.type == types.realtimeRawData || frame.type == types.historicalData else {
                return nil
            }
            return decodeR21(payload: payload, origin: origin, generation: frame.generation)

        case .standardBleHR, .simulator:
            return nil
        }
    }

    // MARK: - R21 — the 5.0 / MG layout

    /// The R21 field offsets, **in the frame's own coordinates**, exactly as §6 tabulates them.
    ///
    /// Kept frame-absolute rather than converted once here, so a reader can check this against the
    /// spec's table line by line. `decodeR21` is the one place the origin is subtracted.
    enum R21 {
        static let unixSeconds = 15        // u32
        static let unixFraction = 19       // u16, 1/32768 s
        static let accelerometerX = 28     // 100 × i16
        static let accelerometerY = 228
        static let accelerometerZ = 428
        static let gyroscopeX = 640
        static let gyroscopeY = 840
        static let gyroscopeZ = 1040
    }

    private static func decodeR21(
        payload: Data, origin: Int, generation: WhoopHardwareGeneration
    ) -> MotionBatch? {
        guard payload.count == r21PayloadBytes else { return nil }

        func lane(_ frameOffset: Int) -> [Double]? {
            readLane(payload, at: frameOffset - origin, scale: accelerometerGPerLSB)
        }
        func gyroLane(_ frameOffset: Int) -> [Double]? {
            readLane(payload, at: frameOffset - origin, scale: gyroscopeDpsPerLSB)
        }

        guard let ax = lane(R21.accelerometerX), let ay = lane(R21.accelerometerY),
              let az = lane(R21.accelerometerZ),
              let gx = gyroLane(R21.gyroscopeX), let gy = gyroLane(R21.gyroscopeY),
              let gz = gyroLane(R21.gyroscopeZ)
        else { return nil }

        // The record's own clock: `seconds + fraction / 32768`. Both fields are frame-absolute and
        // both sit well inside the exact-length guard above, so the reads cannot fall out of range and
        // there is no failure branch to take — what matters is the one this function *declines* to
        // take: `decodeR10` substitutes `receivedAt` because the live 4.0 record carries no clock, and
        // substituting it here would file a drained record under the day it was fetched rather than
        // the day it was measured, which is precisely the wrong-day failure the stamp exists to avoid.
        // A record whose stamp is a plausible zero is a separate question and belongs to the caller's
        // window check, not to the decoder.
        let fraction = Double(readUInt16(payload, at: R21.unixFraction - origin))
        let seconds = Double(readUInt32(payload, at: R21.unixSeconds - origin))
        let stamp = Date(timeIntervalSince1970: seconds + fraction / 32768.0)

        return MotionBatch(
            generation: generation,
            start: stamp,
            timestampIsFromStrap: true,
            sampleIntervalSeconds: 1.0 / Double(samplesPerAxis),
            accelerometerG: MotionAxes(x: ax, y: ay, z: az),
            gyroscopeDps: MotionAxes(x: gx, y: gy, z: gz))
    }

    // MARK: - R10 — the 4.0's live layout

    /// The R10 field offsets, **in the frame's own coordinates**, as §6 tabulates them.
    enum R10 {
        static let accelerometerX = 89     // 100 × i16
        static let accelerometerY = 289
        static let accelerometerZ = 489
        static let gyroscopeX = 692
        static let gyroscopeY = 892
        static let gyroscopeZ = 1092
    }

    private static func decodeR10(
        payload: Data, origin: Int, receivedAt: Date
    ) -> MotionBatch? {
        guard payload.count == r10PayloadBytes else { return nil }

        func lane(_ frameOffset: Int) -> [Double]? {
            readLane(payload, at: frameOffset - origin, scale: accelerometerGPerLSB)
        }
        func gyroLane(_ frameOffset: Int) -> [Double]? {
            readLane(payload, at: frameOffset - origin, scale: gyroscopeDpsPerLSB)
        }

        guard let ax = lane(R10.accelerometerX), let ay = lane(R10.accelerometerY),
              let az = lane(R10.accelerometerZ),
              let gx = gyroLane(R10.gyroscopeX), let gy = gyroLane(R10.gyroscopeY),
              let gz = gyroLane(R10.gyroscopeZ)
        else { return nil }

        // No timestamp is read, because §6 publishes none for this record — and for a live stream
        // that costs nothing: the record arrives as it is measured, so the arrival instant is the
        // measurement instant. `timestampIsFromStrap` is what tells a caller which claim it holds.
        return MotionBatch(
            generation: .whoop4,
            start: receivedAt,
            timestampIsFromStrap: false,
            sampleIntervalSeconds: 1.0 / Double(samplesPerAxis),
            accelerometerG: MotionAxes(x: ax, y: ay, z: az),
            gyroscopeDps: MotionAxes(x: gx, y: gy, z: gz))
    }

    // MARK: - The readers

    /// Reads `samplesPerAxis` little-endian `i16`s starting at a **payload** index, scaled to a unit.
    ///
    /// Returns `nil` rather than a short array when the lane would run past the payload, so a caller
    /// cannot be handed a truncated axis and go on to diff it against a full one. The length guards
    /// above already make that unreachable for both layouts; this is the second lock on the same
    /// door, and it is the one that holds if a layout's offsets are ever edited without its length.
    private static func readLane(_ payload: Data, at offset: Int, scale: Double) -> [Double]? {
        let end = offset + samplesPerAxis * 2
        guard offset >= 0, end <= payload.count else { return nil }
        let start = payload.startIndex + offset
        var samples = [Double]()
        samples.reserveCapacity(samplesPerAxis)
        for index in stride(from: start, to: start + samplesPerAxis * 2, by: 2) {
            let raw = Int16(bitPattern: UInt16(payload[index]) | (UInt16(payload[index + 1]) << 8))
            samples.append(Double(raw) * scale)
        }
        return samples
    }

    private static func readUInt16(_ payload: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < payload.count else { return 0 }
        let start = payload.startIndex + offset
        return UInt16(payload[start]) | (UInt16(payload[start + 1]) << 8)
    }

    private static func readUInt32(_ payload: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < payload.count else { return 0 }
        let start = payload.startIndex + offset
        return UInt32(payload[start])
            | (UInt32(payload[start + 1]) << 8)
            | (UInt32(payload[start + 2]) << 16)
            | (UInt32(payload[start + 3]) << 24)
    }
}
