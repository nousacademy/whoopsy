import Foundation

/// Walks the two proprietary records that carry a heart rate into a `BiometricSample`.
///
/// **This is the decoder the app was missing, and its absence is why a 5.0 delivered "no data".** The
/// standard SIG `0x2A37` characteristic is decoded in `WhoopPacketDecoder.decodeStandardHeartRate` and
/// was always honest about what it saw; the proprietary path validated every frame and then dropped the
/// two records that hold a heart rate on the floor:
///
/// - **packet 40**, the 5.0/MG's live `REALTIME_DATA` notification — the one `TOGGLE_REALTIME_HR`
///   (`0x03`) makes a bonded strap send;
/// - **R18**, the type-47 historical record whose layout selector (`frame.seq`) is 18, which is where
///   a drained strap's heart rate and R-R intervals live.
///
/// **The other two type-47 layouts are not heart-rate records and are refused here.** R20 is the optical
/// engine's raw sample stream (2,125 payload bytes) and R21 the 100 Hz IMU (1,229); a heart-rate number
/// assembled from either would be a byte of sensor data read as a pulse. R21 is `MotionPayloadDecoder`'s,
/// and R20 has no reader in this build.
///
/// **Both generations' historical heart-rate records are walked, and they are different layouts under
/// the same packet type.** A 4.0's is inner type 24 (the layout selector in `frame.seq`) under packet
/// `0x2F`; a 5.0/MG's is R18 (selector 18) under packet 47 — the same packet type, which is why the
/// dispatch is on `frame.generation` and not on the type byte. The 4.0 used to be refused outright;
/// only the fields below are read, and its accelerometer, contact, ADC and resting-HR fields stay
/// unread. The 4.0's live heart rate still arrives on `0x2A37`.
///
/// ## Every offset is payload-relative
///
/// `WhoopRawFrame.payload` starts after the envelope and the three `[type][seq][cmd]` bytes, so a
/// frame-absolute offset in `docs/BLE_PROTOCOL.md` §4 loses the origin (`11` on 5.0/MG, `7` on 4.0)
/// exactly once, here. The three tables this file implements, frame-absolute beside payload:
///
/// | field | R18 (frame) | R18 (payload) | 4.0 type 24 (frame) | 4.0 (payload) | packet 40 (payload) |
/// | :--- | :--- | :--- | :--- | :--- | :--- |
/// | record index | 11, u32 | 0 | 7, u32 | 0 | — |
/// | unix seconds | 15, u32 | 4 | 11, u32 | 4 | not read (arrival instant) |
/// | heart rate | 22, u8 | 11 | 21, u8 | 14 | 5 (u8) |
/// | R-R count | 23, u8 | 12 | 22, u8 | 15 | 6 (u8) |
/// | R-R intervals | 24 + 2i, u16 ticks | 13 + 2i | 23 + 2i, **i16 ms** | 16 + 2i | 7 + 2i |
///
/// **The interval widths differ, and so does the unit.** R18 and packet 40 carry `u16` in 1/1024 s
/// ticks; the 4.0 carries **signed `i16` milliseconds**, already in the unit this app stores. Calling
/// `milliseconds(forTicks:)` on a 4.0 interval divides an already-millisecond value and is the
/// copy-paste this file's two readers exist to prevent.
///
/// **R18's payload is exactly 109 bytes** (`124 − 8` header − `3` prefix − `4` trailer, the same
/// arithmetic `MotionPayloadDecoder.r21PayloadBytes` records for R21) and the exact length is a guard,
/// not a truncation. **The 4.0 record is not exact**: its header is 96 bytes with a minimum inner length
/// of 89, so the guard is `payload.count >= 86` and a longer record is still valid. Packet 40's length
/// is not exact either — its count byte bounds the interval list.
public enum HeartRatePayloadDecoder {

    /// R18's payload, exactly: 109 bytes, in a 124-byte frame.
    public static let r18PayloadBytes = 109

    /// The type-47 layout selector that names R18.
    ///
    /// `WhoopRawFrame.seq` is the selector, not a sequence number to be matched against anything: 18 is
    /// R18, 20 is R20 and 21 is R21, and the byte happens to arrive where every other record keeps its
    /// sequence.
    public static let historicalLayout: UInt8 = 18

    /// R18's interval field is one byte, and the reference caps it at four.
    public static let r18MaximumIntervals = 4

    /// The 4.0's historical layout selector: inner type 24 under packet `0x2F`.
    public static let whoop4HistoricalLayout: UInt8 = 24

    /// The 4.0 record's minimum payload. Its minimum inner length is 89, and the payload starts after
    /// the three `[type][seq][cmd]` bytes — so a record shorter than this cannot hold the resting-HR
    /// byte and is truncated rather than merely unusual. **A minimum, not an exact length**: the record's
    /// header is 96 bytes and a longer record is valid.
    public static let whoop4MinimumPayloadBytes = 86

    /// The 4.0's interval count is one byte and the reference caps it at four, as R18's is.
    public static let whoop4MaximumIntervals = 4

    /// Decodes a drained historical record, stamped by the strap's own clock.
    ///
    /// Dispatched on the generation because the two layouts share a packet type and nothing else — see
    /// the type's doc comment. Both branches return `nil` for a record that carries no reading this app
    /// may write:
    ///
    /// - **`unix == 0`** is a strap whose RTC was never set — there is no day to file the sample under,
    ///   and filing it under 1970 is the wrong-day failure the clock set exists to avoid.
    /// - **`heartRate == 0`** is the strap's startup state, not a pulse. noop observes it on the first
    ///   records of a session, and a stored zero would read as a measured cardiac arrest.
    /// - **A non-positive interval is dropped**, because a zero R-R is a missing field, not two beats at
    ///   once — and on the 4.0 the field is signed, so a negative reading is dropped rather than wrapped
    ///   into a 65-second interval.
    public static func decodeHistorical(frame: WhoopRawFrame) -> BiometricSample? {
        switch frame.generation {
        case .whoop4:
            return decodeWhoop4Historical(frame: frame)
        case .whoop5, .whoop5MG:
            return decodeR18Historical(frame: frame)
        case .standardBleHR, .simulator:
            return nil
        }
    }

    // MARK: - R18 (5.0 / MG)

    private static func decodeR18Historical(frame: WhoopRawFrame) -> BiometricSample? {
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation),
              frame.type == profile.packetTypes.historicalData,
              frame.seq == historicalLayout,
              frame.payload.count == r18PayloadBytes
        else { return nil }

        let payload = frame.payload
        let unix = readUInt32(payload, at: 4)
        guard unix > 0 else { return nil }

        let heartRate = Int(payload[payload.startIndex + 11])
        guard heartRate > 0 else { return nil }

        let declared = Int(payload[payload.startIndex + 12])
        let available = max(0, (payload.count - 13) / 2)
        let count = min(declared, r18MaximumIntervals, available)
        var intervals = [Double]()
        intervals.reserveCapacity(count)
        for index in 0..<count {
            let ticks = readUInt16(payload, at: 13 + index * 2)
            guard ticks > 0 else { continue }
            intervals.append(milliseconds(forTicks: ticks))
        }

        // **The accelerometer, which the drain was throwing away.** R18 body 24 is three `f32` in
        // g — mean acceleration X/Y/Z for that second — and it is the stillness signal the sleep
        // classifier needs. The strap does *not* bank `R21` motion records in flash (measured
        // 2026-10-26: every drained burst carried layouts 18 and 26, never 21), so a phone-away night
        // had heart rate and no epoch at all while this field sat in every record read.
        //
        // Body 24 is payload 34: the body starts at payload 10, which is why the heart rate's body 1
        // is read at payload 11. A magnitude outside 0.5–2 g is not a wrist under gravity and is
        // refused rather than stored as a plausible-looking zero — the one wrong answer the
        // stillness thresholds must never be handed.
        let acceleration = Self.acceleration(inPayload: payload)

        return BiometricSample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(unix)),
            heartRate: heartRate,
            rrIntervalsMs: intervals.isEmpty ? nil : intervals,
            accelerometerX: acceleration?.x,
            accelerometerY: acceleration?.y,
            accelerometerZ: acceleration?.z,
            skinTemperatureCelsius: Self.skinTemperature(inPayload: payload))
    }

    /// The night's skin temperature, from the offset the probe settled on.
    ///
    /// **This is the one candidate the app now reads as a measurement**, and it was promoted on
    /// evidence rather than on the reference's say-so. `SkinTemperatureCandidateProbe` reads two
    /// offsets for the field the community reference calls "byte 73": body 24's neighbour at payload
    /// 83, and the envelope-frame reading at payload 62. Drained records from the owner's 5.0 settled it
    /// — the body offset read `0.00` on **every** record, while the frame offset read a band ranging
    /// **a band inside the plausible range across every record**, rising smoothly over twenty minutes rather
    /// than stepping around. A field that is zero on one offset and a plausible, continuous temperature
    /// on the other is not ambiguous; what it is *not* is cross-checked against the official app, which
    /// is why the probe stays.
    ///
    /// The plausible band is the probe's own, 5–45 °C, and an out-of-band reading is **refused rather
    /// than clamped**: a wrist thermistor cannot read 0 °C, so a value outside the band is a misread and
    /// the honest answer is no reading at all.
    ///
    /// **The 4.0 has no equivalent.** Its type-24 record carries no temperature field this build has
    /// found, and a channel with no sensor behind it is `nil` rather than a plausible constant.
    public static func skinTemperature(inPayload payload: Data) -> Double? {
        let offset = SkinTemperatureCandidateProbe.framePayloadOffset
        guard offset + 1 < payload.count else { return nil }
        let celsius = Double(readUInt16(payload, at: offset)) / 100.0
        // Zero is the field's idle value and 5 °C is colder than any wrist: both are a record that did
        // not report one, and `nil` says so instead of a plausible-looking constant.
        guard SkinTemperatureCandidateProbe.plausibleCelsius.contains(celsius) else { return nil }
        return celsius
    }

    // MARK: - Type 24 (4.0)

    /// Walks the 4.0 record's unix stamp, heart rate and signed millisecond R-R intervals.
    ///
    /// **The intervals are appended as-is and never passed through `milliseconds(forTicks:)`.** This
    /// record carries `i16` **milliseconds**; the tick conversion belongs to the 5.0 layouts, and
    /// applying it here would divide every interval by 1.024 — a wrong value that still looks like a
    /// plausible R-R and would sail through every length check.
    ///
    /// **The sub-second field is deliberately not read.** It sits at payload 8 and no reference states
    /// its scale; the rest of the app keys samples on whole seconds, and a fabricated fraction is worse
    /// than whole-second precision.
    /// The mean acceleration triplet `R18` body 24 carries — **the one reader both decoders use**.
    ///
    /// `HeartRatePayloadDecoder` puts it on the sample and `StepCounterPayloadDecoder` puts it on the
    /// counter record; two copies of these offsets would be two chances to differ, and the step gate
    /// and the sleep spine would then be reading different fields while both looked right.
    ///
    /// A magnitude outside **0.5–2 g** is refused: a wrist under gravity cannot leave that band, so
    /// anything outside it is a misread rather than a still wearer. `0.0` in particular is free fall,
    /// which would land on the *still* side of every threshold in this app.
    public static func acceleration(inPayload payload: Data) -> AccelerationVector? {
        guard let x = readFloat32(payload, at: 34),
              let y = readFloat32(payload, at: 38),
              let z = readFloat32(payload, at: 42)
        else { return nil }
        let vector = AccelerationVector(x: x, y: y, z: z)
        guard vector.magnitude >= 0.5, vector.magnitude <= 2 else { return nil }
        return vector
    }

    /// One `f32` little-endian, or `nil` for a field that is out of range or not finite.
    ///
    /// A bit-pattern read rather than a `Data` slice, so the offset is one number in the same
    /// coordinate system as every other field this decoder reads.
    private static func readFloat32(_ data: Data, at offset: Int) -> Double? {
        guard offset >= 0, offset + 3 < data.count else { return nil }
        let bits = readUInt32(data, at: offset)
        let value = Float(bitPattern: bits)
        guard value.isFinite else { return nil }
        return Double(value)
    }

    private static func decodeWhoop4Historical(frame: WhoopRawFrame) -> BiometricSample? {
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation),
              frame.type == profile.packetTypes.historicalData,
              frame.seq == whoop4HistoricalLayout,
              frame.payload.count >= whoop4MinimumPayloadBytes
        else { return nil }

        let payload = frame.payload
        let unix = readUInt32(payload, at: 4)
        guard unix > 0 else { return nil }

        let heartRate = Int(payload[payload.startIndex + 14])
        guard heartRate > 0 else { return nil }

        let declared = Int(payload[payload.startIndex + 15])
        let available = max(0, (payload.count - 16) / 2)
        let count = min(declared, whoop4MaximumIntervals, available)
        var intervals = [Double]()
        intervals.reserveCapacity(count)
        for index in 0..<count {
            let value = readInt16(payload, at: 16 + index * 2)
            guard value > 0 else { continue }
            intervals.append(Double(value))
        }

        return BiometricSample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(unix)),
            heartRate: heartRate,
            rrIntervalsMs: intervals.isEmpty ? nil : intervals)
    }

    /// Decodes a live packet-40 notification, stamped with the arrival instant.
    ///
    /// **The arrival instant rather than the record's own `unix` field, deliberately.** That field sits
    /// at frame 10, which is the inner record's `cmd` byte — a live decoder can read it, and this one
    /// does not, because a live notification arrives as it is measured and the app's standing rule is
    /// that a sample row's timestamp is an arrival instant (see `CLAUDE.md`'s gotcha). Using it would
    /// give this producer a second time base that nothing else on the live path has.
    ///
    /// The interval count is clamped to the bytes actually present rather than trusted: packet 40's
    /// payload length is not fixed, and a count byte larger than its own record must not walk the
    /// decoder off the end.
    public static func decodeLive(frame: WhoopRawFrame, receivedAt: Date) -> BiometricSample? {
        guard frame.generation == .whoop5 || frame.generation == .whoop5MG else { return nil }
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation),
              let type = profile.packetTypes.realtimeHeartRate,
              frame.type == type,
              frame.payload.count >= 7
        else { return nil }

        let payload = frame.payload
        let heartRate = Int(payload[payload.startIndex + 5])
        guard heartRate > 0 else { return nil }

        let declared = Int(payload[payload.startIndex + 6])
        let available = (payload.count - 7) / 2
        var intervals = [Double]()
        intervals.reserveCapacity(min(declared, available))
        for index in 0..<min(declared, available) {
            let ticks = readUInt16(payload, at: 7 + index * 2)
            guard ticks > 0 else { continue }
            intervals.append(milliseconds(forTicks: ticks))
        }

        return BiometricSample(
            timestamp: receivedAt,
            heartRate: heartRate,
            rrIntervalsMs: intervals.isEmpty ? nil : intervals)
    }

    // MARK: - The readers

    /// A wire interval is in 1/1024 s; a stored one is in milliseconds.
    ///
    /// **Rounded to the nearest millisecond rather than carried as a fraction.** The extra precision is
    /// below the strap's own sampling resolution, and the integer form is what noop computes from this
    /// same field — so the two clients agree on every interval rather than differing in the seventh
    /// decimal. `+ 512` is half of 1024, which is what makes the division round rather than truncate.
    public static func milliseconds(forTicks ticks: UInt16) -> Double {
        Double((Int(ticks) * 1000 + 512) / 1024)
    }

    /// The 4.0's interval field is **signed**, so this is not `readUInt16` with a cast: a negative
    /// value is a field this app drops, and interpreting its high bit as magnitude would turn a small
    /// negative into a ~65-second interval.
    private static func readInt16(_ payload: Data, at offset: Int) -> Int16 {
        guard offset >= 0, offset + 1 < payload.count else { return 0 }
        let start = payload.startIndex + offset
        return Int16(bitPattern: UInt16(payload[start]) | (UInt16(payload[start + 1]) << 8))
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
