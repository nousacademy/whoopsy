import Foundation

/// One packet-48 (5.0/MG) or `0x30` (4.0) event — the strap's own report that something changed on it.
///
/// **The event number lands in the inner `cmd` byte on both generations, and that is a property of the
/// record shape rather than a coincidence.** `WhoopRawFrame` splits the inner record at `inner[0]` =
/// type, `inner[1]` = seq, `inner[2]` = cmd, so the event field is `frame.cmd` — frame byte 10 under the
/// 5.0 envelope and 6 under the 4.0's. The timestamp then sits at payload offset **1** on both, which is
/// frame byte 12 on 5.0 and frame byte 8 on the 4.0: the payload origin differs by four, and reading a
/// fixed frame offset would be correct for exactly one generation.
///
/// **Only four events change state in this app, and none of them is the battery event.** Charging on/off
/// and wrist on/off are the two facts `WhoopDevice` carries a field for; battery level arrives on the
/// standard `0x2A19` characteristic and the event's own layout is undocumented (noop's event schema has
/// only the number and the timestamp), so decoding a level byte from it would be an invention. Every
/// other number, battery included, is reported as `.other` and logged.
public enum StrapEventDecoder {

    /// What one event asks the app to believe. The four state events are the only ones with a
    /// `WhoopDevice` field behind them; everything the references name but this app does not store is
    /// still mapped rather than folded into `.other`, because a log line that says `boot` is worth more
    /// than `other(15)` to whoever reads a capture.
    public enum Kind: Equatable, Sendable {
        /// 3 `BATTERY_LEVEL` — payload layout undocumented; log only.
        case batteryLevel
        /// 7 `CHARGING_ON`.
        case chargingOn
        /// 8 `CHARGING_OFF`.
        case chargingOff
        /// 9 `WRIST_ON` — the strap was put on.
        case wristOn
        /// 10 `WRIST_OFF` — the strap was taken off.
        case wristOff
        /// 13 `RTC_LOST` — the RTC was reset; drained records cannot be trusted to a day until it is set.
        case rtcLost
        /// 15 `BOOT`.
        case boot
        /// 16 `SET_RTC`.
        case setRTC
        /// Any number this build does not name.
        case other(UInt8)
    }

    public static func decode(frame: WhoopRawFrame) -> StrapEvent? {
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation),
              frame.type == profile.packetTypes.event,
              frame.payload.count >= 5
        else { return nil }

        let number = frame.cmd
        let unix = readUInt32(frame.payload, at: 1)

        return StrapEvent(
            rawEvent: number,
            kind: kind(for: number),
            timestamp: unix == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(unix)),
            payload: frame.payload)
    }

    private static func kind(for number: UInt8) -> Kind {
        switch number {
        case 3: return .batteryLevel
        case 7: return .chargingOn
        case 8: return .chargingOff
        case 9: return .wristOn
        case 10: return .wristOff
        case 13: return .rtcLost
        case 15: return .boot
        case 16: return .setRTC
        default: return .other(number)
        }
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

/// A decoded strap event. `payload` is the full record body so a log line can show the bytes this build
/// did not read — the battery event is the one that matters, and its layout is exactly the thing a
/// capture would settle.
public struct StrapEvent: Equatable, Sendable {
    public let rawEvent: UInt8
    public let kind: StrapEventDecoder.Kind

    /// `nil` when the record's timestamp is zero — a strap whose RTC was never set still reports its
    /// wrist and charger, and dropping the event would lose state that is still true.
    public let timestamp: Date?

    public let payload: Data

    public init(rawEvent: UInt8, kind: StrapEventDecoder.Kind, timestamp: Date?, payload: Data) {
        self.rawEvent = rawEvent
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
    }
}
