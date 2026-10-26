import Foundation

/// The strap's `STRAP_CONDITION_REPORT` — event **29** on packet 48 — and the one field in it that
/// answers a question this app has never been able to answer from the phone: **how much history the
/// strap is holding.**
///
/// ## The layout, and why the offsets are what they are
///
/// [reported] OpenStrap's Gen 5 reference documents the event body as:
///
/// ```
/// u32 page backlog          // pages of history written but not yet trimmed
/// u16 backlog tenths        // hours of backlog, in tenths — 456 is 45.6 h
/// u16 state-of-charge tenths
/// u8  flash state
/// u8  charging
/// u8  wrist tri-state
/// ```
///
/// The event's own header is `[0x30][seq][u16 id][u32 unix][u16 subsec][u16 body length]`, and
/// `WhoopRawFrame.payload` begins after the first three of those bytes — so the body starts at
/// **payload 9** and is eleven bytes. That also places the timestamp at payload 1, which is where
/// `StrapEventDecoder` already reads it, so the two decoders agree about the same frame rather than
/// each carrying its own arithmetic.
///
/// ## This is a log line and not a measurement
///
/// **Nothing reads `batteryPercentage` for the badge.** `WhoopDevice.batteryIsMeasured` exists
/// exactly to stop a figure the strap never sent from being drawn, and this figure arrives on an
/// event whose layout one reference describes and no capture here has confirmed. The same applies to
/// `backlogHours`: it is the answer to "does this strap hold two days or fourteen", and until a
/// capture confirms the offsets it is a *reported* value that belongs in `capture.txt` and nowhere on
/// a screen. Contrast `HeartRatePayloadDecoder`, whose offsets are checked against records this
/// project has actually read.
///
/// The tri-state wrist byte is kept raw rather than mapped to a `Bool`: the reference does not name
/// its three values, and `WRIST_ON`/`WRIST_OFF` already arrive as their own events (9 and 10), which
/// is what `WhoopDevice.isOnBody` is allowed to follow.
public struct StrapConditionReport: Equatable, Sendable {

    /// The event number, as it appears in the inner `cmd` — `inner[2]`, the low byte of the u16 id.
    public static let eventNumber: UInt8 = 29

    /// Where the body begins in `WhoopRawFrame.payload` — the eleven bytes after the event header.
    public static let bodyOffset = 9

    /// `u32` + `u16` + `u16` + `u8` + `u8` + `u8`.
    public static let bodyBytes = 11

    public let pageBacklog: UInt32
    /// Hours of untrimmed history, in tenths as the strap reports them.
    public let backlogHours: Double
    /// State of charge, in tenths of a percent. **Log-only** — see the type's note.
    public let batteryPercentage: Double
    public let flashState: UInt8
    public let isCharging: Bool
    public let wristState: UInt8

    public init(
        pageBacklog: UInt32,
        backlogHours: Double,
        batteryPercentage: Double,
        flashState: UInt8,
        isCharging: Bool,
        wristState: UInt8
    ) {
        self.pageBacklog = pageBacklog
        self.backlogHours = backlogHours
        self.batteryPercentage = batteryPercentage
        self.flashState = flashState
        self.isCharging = isCharging
        self.wristState = wristState
    }

    /// `nil` for any frame that is not this event — a different type, a different number, a
    /// generation the reference does not cover, or a payload too short to hold the body.
    ///
    /// **Gen 5 only.** The reference scopes these event bodies to the 5.0/MG; the 4.0's event shape is
    /// published no further than its number and timestamp, so reading this layout there would be
    /// inventing an answer from a field the generation puts somewhere else.
    public static func decode(_ frame: WhoopRawFrame) -> StrapConditionReport? {
        guard frame.generation == .whoop5 || frame.generation == .whoop5MG,
              let profile = WhoopProtocolProfile.profile(for: frame.generation),
              frame.type == profile.packetTypes.event,
              frame.cmd == eventNumber,
              frame.payload.count >= bodyOffset + bodyBytes
        else { return nil }

        let bytes = [UInt8](frame.payload)

        // The declared body length sits at payload 7, and a value that cannot hold eleven bytes means
        // this is some other event wearing the same number — refused rather than read off the end.
        let declared = Int(bytes[7]) | (Int(bytes[8]) << 8)
        guard declared == 0 || declared >= bodyBytes else { return nil }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        let body = bodyOffset
        return StrapConditionReport(
            pageBacklog: u32(body),
            backlogHours: Double(u16(body + 4)) / 10,
            batteryPercentage: Double(u16(body + 6)) / 10,
            flashState: bytes[body + 8],
            isCharging: bytes[body + 9] != 0,
            wristState: bytes[body + 10])
    }
}
