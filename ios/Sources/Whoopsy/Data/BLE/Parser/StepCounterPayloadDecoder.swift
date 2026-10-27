import Foundation

/// Reads the step counter and activity class out of a drained **R18** record.
///
/// `HeartRatePayloadDecoder` walks the same record for its pulse and R-R intervals; this walks it for
/// the strap's own pedometer. They are two decoders over one layout because they answer unrelated
/// questions and have unrelated failure rules — a record with a zero heart rate is not a pulse, while
/// its counter is still perfectly good.
///
/// ## Where the offsets come from, and what that provenance is worth
///
/// **This is [reported 5.0], not [captured] here.** The field map is the community reference's
/// reverse-engineering of the `R18` layout, excerpted in `docs/noop/BLE_PROTOCOL.md`: frame
/// offset `57` is a `u16` "selected cumulative step/motion counter", `63` the activity class
/// (`0` still, `1` walk, `2` run), `61` the hardware counter while a software override is active, and
/// `64` is `0x10` when that override is on. This app has never decoded those bytes from its own strap,
/// so `docs/BLE_PROTOCOL.md` §6 carries them as an unvalidated candidate and §7's capture is what
/// would settle them.
///
/// ## Frame-absolute, like every other layout in this repo
///
/// The reference's offsets are measured from the record's **first byte**; `WhoopRawFrame.payload`
/// begins after the envelope and the three `[type][seq][cmd]` bytes, so the payload origin (`11` under
/// the 5.0/MG envelope) is subtracted once, in `decode`. The constants below are payload-relative and
/// record the frame figure they came from, so a reader can check them line by line.
public enum StepCounterPayloadDecoder {

    /// The cumulative counter, frame `57` → payload `46`.
    public static let counterOffset = 46

    /// The activity class, frame `63` → payload `52`.
    public static let activityClassOffset = 52

    /// The counter-source marker, frame `64` → payload `53`.
    public static let counterSourceOffset = 53

    /// The value byte 64 takes when `counterOffset` holds the software count rather than the hardware
    /// pedometer's.
    public static let softwareCounterSource: UInt8 = 0x10

    /// The earliest unix stamp this decoder will file a counter under.
    ///
    /// **2020-01-01, the same cutoff `v24` uses**, and it is deliberately impossible rather than
    /// tight: this app's own history begins in 2023, and a strap whose RTC was lost stamps history in
    /// 2000. A counter filed under that day is steps no screen can draw, and — unlike a live motion
    /// record — a banked one has no arrival instant to fall back on.
    public static let minimumPlausibleUnix: UInt32 = 1_577_836_800

    /// Decodes one record, or returns `nil` when it carries no counter this app may read.
    ///
    /// The guards are the record's identity — generation, packet type, layout selector, exact payload
    /// length — plus the stamp. **The exact length is a test rather than a truncation**: a short `R18`
    /// is a truncated record, and reading bytes past its end would invent a counter from whatever the
    /// frame happened to hold next.
    public static func decode(frame: WhoopRawFrame) -> StepCounterSample? {
        guard frame.generation == .whoop5 || frame.generation == .whoop5MG else { return nil }
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation),
              frame.type == profile.packetTypes.historicalData,
              frame.seq == HeartRatePayloadDecoder.historicalLayout,
              frame.payload.count == HeartRatePayloadDecoder.r18PayloadBytes
        else { return nil }

        let payload = frame.payload
        let unix = readUInt32(payload, at: 4)
        guard unix >= minimumPlausibleUnix else { return nil }

        let counter = readUInt16(payload, at: counterOffset)
        let rawClass = readUInt8(payload, at: activityClassOffset)
        let source = readUInt8(payload, at: counterSourceOffset)

        return StepCounterSample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(unix)),
            counter: counter,
            // A reserved code is not one of the three classes. NOOP's own note is that any other
            // input class is reported as `FF`, and passing it through as a number would let a caller
            // compare `3` against walk/run and silently reject it for the wrong reason.
            activityClass: rawClass <= 2 ? rawClass : nil,
            counterIsSoftware: source == softwareCounterSource,
            // The same body-24 triplet the heart-rate walk reads, through the same helper: the step
            // gate needs it to tell a walking wrist from one that merely moved in bed.
            acceleration: HeartRatePayloadDecoder.acceleration(inPayload: frame.payload))
    }

    private static func readUInt8(_ payload: Data, at offset: Int) -> UInt8 {
        guard offset >= 0, offset < payload.count else { return 0 }
        return payload[payload.startIndex + offset]
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
