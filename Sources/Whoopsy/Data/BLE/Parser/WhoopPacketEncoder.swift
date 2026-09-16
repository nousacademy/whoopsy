import Foundation

/// Binary packet encoder for constructing commands sent to the WHOOP strap.
///
/// **Every builder is a function of a `WhoopProtocolProfile`, and every one returns `nil` rather than
/// a frame when handed an envelope this build cannot construct.** That is not defensive programming.
/// The packet-type numberings do not overlap between generations — 4.0 uses `0x23`, 5.0 uses 35 — so a
/// 4.0-framed command written to a 5.0 strap is a *different message*, not a rejected one. Refusing to
/// build is the only way to make that unreachable.
public enum WhoopPacketEncoder {
    public static let startOfFrame: UInt8 = 0xAA

    /// Builds a framed command packet under `profile`'s envelope.
    ///
    /// The 4.0 envelope, from `BLE_PROTOCOL.md` §2:
    ///
    /// ```
    /// [0]        SOF = 0xAA
    /// [1..3]     length, u16 LE    (occupies bytes 1 and 2)
    /// [3]        crc8              over bytes 1 and 2 only
    /// [4]        inner type
    /// [5]        inner seq
    /// [6]        inner cmd
    /// [7..len)   payload
    /// [len..+4)  crc32, u32 LE     over frame[4 ..< length]
    /// ```
    ///
    /// `length` counts the whole inner record plus four, so the total frame size is `length + 4`.
    ///
    /// **The CRC8 input is the two length bytes and nothing else.** That is the expression this
    /// function used to get wrong: it hashed `[cmd, lengthLow, lengthHigh]`, so every command frame
    /// this app has ever sent carried a header checksum the format does not agree with — `0x43` where
    /// ping should write `0x00`, `0x0A` where the haptic alarm should write `0xA8`. The four vectors
    /// in `BLE_PROTOCOL.md` §2.1 pin it, and §1 of the suite asserts them.
    public static func buildPacket(
        profile: WhoopProtocolProfile,
        type: UInt8,
        seq: UInt8,
        cmd: UInt8,
        payload: Data = Data()
    ) -> Data? {
        // The only envelope this function builds. Written as a `guard` on the enum case rather than
        // as an assumption, so adding a second profile to the table is a compile-time question here
        // rather than a frame built with the wrong header checksum at runtime.
        guard profile.headerChecksum == .crc8OverLengthBytes else { return nil }

        var inner = Data([type, seq, cmd])
        inner.append(payload)

        let length = UInt16(inner.count + 4)
        let lengthLow = UInt8(length & 0xFF)
        let lengthHigh = UInt8((length >> 8) & 0xFF)

        var frame = Data()
        frame.append(startOfFrame)
        frame.append(lengthLow)
        frame.append(lengthHigh)
        frame.append(CRCUtils.crc8(Data([lengthLow, lengthHigh])))
        frame.append(inner)

        var crcLe = CRCUtils.crc32(inner).littleEndian
        frame.append(Data(bytes: &crcLe, count: MemoryLayout<UInt32>.size))

        return frame
    }

    /// Ping / keep-alive.
    public static func pingCommand(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        buildPacket(profile: profile, type: profile.packetTypes.command, seq: seq, cmd: 0x20)
    }

    /// Haptic vibration alert.
    public static func hapticAlarmCommand(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        durationSeconds: Int = 3,
        pattern: Int = 1
    ) -> Data? {
        var payload = Data()
        payload.append(UInt8(max(1, min(30, durationSeconds))))
        payload.append(UInt8(max(1, min(10, pattern))))
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: 0x10, payload: payload)
    }

    /// Real-time high-speed telemetry enable.
    public static func enableLiveTelemetry(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        enable: Bool = true
    ) -> Data? {
        buildPacket(
            profile: profile,
            type: profile.packetTypes.command,
            seq: seq,
            cmd: 0x05,
            payload: Data([enable ? 0x01 : 0x00]))
    }

    /// Flash-buffer historical sync request.
    ///
    /// **The opcode is documented as wrong and is deliberately left alone.** `BLE_PROTOCOL.md` §4
    /// gives `0x16 SEND_HISTORICAL_DATA` as the command that starts the drain, and `0x30` here is not
    /// it. Changing the byte is not the fix and would make things worse: the drain is a loop that
    /// needs the per-batch `0x17` ACK, and §4 records that **without a correct ACK the strap re-sends
    /// the same batch forever**. Starting a drain this app cannot acknowledge would be a worse outcome
    /// than sending a command a strap ignores — the first is a strap stuck in a loop, the second is
    /// silence. So the opcode moves when the ACK loop lands, not before it.
    public static func requestHistoricalSync(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        startEpoch: UInt32,
        endEpoch: UInt32
    ) -> Data? {
        var payload = Data()
        var s = startEpoch.littleEndian
        var e = endEpoch.littleEndian
        payload.append(Data(bytes: &s, count: 4))
        payload.append(Data(bytes: &e, count: 4))
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: 0x30, payload: payload)
    }
}

/// Monotonic inner-record sequence numbers for outgoing commands.
///
/// `seq` is a field of the inner record under every envelope, and the app had no source for it at all
/// until the framing was corrected — the old builder wrote a three-byte header with no inner record
/// and so never had to supply one. A constant zero would be a second invented value sitting where a
/// field is expected, so the counter is the reading that needs no assumption beyond "the field counts
/// something".
///
/// A class because `WhoopPacketEncoder` is a stateless `enum` and a `static var` counter is a Swift 6
/// concurrency error; the lock because this is called from whatever thread sends a command.
///
/// **Unverified as to semantics.** Neither reference says what a strap does with a repeated or
/// out-of-order sequence number; this increments, wraps at 256, and is not persisted across launches.
public final class WhoopCommandSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0

    public init() {}

    public func next() -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        value = value &+ 1
        return value
    }
}
