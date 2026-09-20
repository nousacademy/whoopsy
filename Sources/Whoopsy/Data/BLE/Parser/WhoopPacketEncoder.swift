import Foundation

/// Binary packet encoder for constructing commands sent to the **4.0** strap.
///
/// **Every builder is a function of a `WhoopProtocolProfile`, and every one returns `nil` rather than
/// a frame when handed an envelope this build cannot construct.** That is not defensive programming.
/// Writing a 4.0-framed command to a 5.0 strap is not a command the strap rejects — it is a *different
/// command*, and one of the documented 4.0 opcodes is a destructive flash erase (`0x19 FORCE_TRIM`).
/// Refusing to build is the only way to make that unreachable.
///
/// **This file builds one envelope and there is now a second file for the other.** The 5.0 / MG has its
/// own builder, `WhoopPacketEncoder5`, its own opcode table (`WhoopProtocolProfile.SyncOpcodes`) and
/// its own gate; `WhoopCommandFrames` is the one place a caller asks for a frame without knowing which
/// envelope will carry it. None of the three is a fallback for another: each builder consults **its
/// own** generation's table, because a builder that reached for whichever table was non-`nil` would
/// write the wrong opcodes under the right envelope — a message a strap would accept and act on.
///
/// **The gate is `fourEnvelopeOpcodes`, and it used to be the envelope alone.** It read
/// `headerChecksum == .crc8OverLengthBytes`, which refused the 5.0 correctly and for a reason that had
/// nothing to do with why refusing was right: the 5.0 profile now exists — the app validates inbound
/// 5.0 frames — so a guard on its *envelope* would have started building 5.0 frames the moment the
/// decoder learned to read them. What separates the two is that this build's 4.0 opcodes are not the
/// 5.0's, so a builder here checks the envelope **and** its own opcode table, and a builder must go
/// through the helper rather than restating either clause.
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
    /// `length` counts the whole inner record plus four, so the total frame size is `length + 4` —
    /// which, as `WhoopProtocolProfile.frameByteCount` records, is `innerOrigin + length` and is the
    /// same rule the 5.0 envelope states as `declLength + 8`.
    ///
    /// **The offsets below are written as literals because this builder knows exactly one layout**, and
    /// that is what the guard says. It is not a general builder that happens to be handed 4.0: it
    /// builds 4.0 and refuses everything else, including the 5.0 envelope whose `[4..6]` header bytes
    /// the reference does not specify. A second generation would be a second builder, not a parameter
    /// on this one.
    ///
    /// **The CRC8 input is the two length bytes and nothing else.** That is the expression this
    /// function used to get wrong: it hashed `[cmd, lengthLow, lengthHigh]`, folding the command byte
    /// into a header the strap reads *before* it reaches that command. The input is now
    /// `Data([lengthLow, lengthHigh])` — ping declares length **7** and writes `0x6B`, the haptic
    /// alarm declares length **9** and writes `0xBD`, and both are the length bytes' own checksum
    /// rather than the command's. The four vectors in `BLE_PROTOCOL.md` §2.1 pin it and §1 of the
    /// suite asserts them, but mind which vector is which: `0xA8` is the checksum of declared length
    /// **8**, which neither frame declares, so a builder that fed the algorithm the right two bytes of
    /// the *wrong* length would still agree with it.
    public static func buildPacket(
        profile: WhoopProtocolProfile,
        type: UInt8,
        seq: UInt8,
        cmd: UInt8,
        payload: Data = Data()
    ) -> Data? {
        // The only envelope this function builds, and now the **only** thing it tests. It used to
        // also require `commandOpcodes != nil`, which was doing no work even then: the opcode table is
        // read by the *builders*, not here, so a caller with a table and a 5.0 envelope reached this
        // line with both clauses satisfied by different facts. The envelope is what this function
        // knows and all it should assert — see `fourEnvelopeOpcodes` for the write-side gate, which
        // every builder applies before it gets here.
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

    /// The gate every 4.0 builder opens with: this build's opcode table, **and** the envelope those
    /// opcodes are written for.
    ///
    /// Both halves are checked here rather than in `buildPacket` because they are a claim about the
    /// *message* and not about the container: a 5.0 profile now carries a real envelope this build can
    /// slice, so an envelope test alone would let a builder assemble 4.0-framed commands under it the
    /// moment the 5.0 opcode set exists — and writing a 4.0-framed command to a 5.0 strap is not a
    /// rejected message but a *different* one.
    ///
    /// One helper rather than the same two clauses copied into every builder, on the rule that a
    /// repeated guard is a guard that can disagree with itself. The 5.0 builders have now arrived and
    /// are a second type with their own gate (`WhoopPacketEncoder5.fiveEnvelopeOpcodes`), which returns
    /// a different type because the two tables have different fields — so this one stays 4.0's, and
    /// neither can be reached by a profile belonging to the other.
    private static func fourEnvelopeOpcodes(
        _ profile: WhoopProtocolProfile
    ) -> WhoopProtocolProfile.CommandOpcodes? {
        guard profile.headerChecksum == .crc8OverLengthBytes else { return nil }
        return profile.commandOpcodes
    }

    /// Ping / keep-alive.
    public static func pingCommand(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        guard let opcodes = fourEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcodes.ping)
    }

    /// Haptic vibration alert.
    public static func hapticAlarmCommand(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        durationSeconds: Int = 3,
        pattern: Int = 1
    ) -> Data? {
        guard let opcodes = fourEnvelopeOpcodes(profile) else { return nil }
        var payload = Data()
        payload.append(UInt8(max(1, min(30, durationSeconds))))
        payload.append(UInt8(max(1, min(10, pattern))))
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcodes.hapticAlarm,
            payload: payload)
    }

    /// Real-time high-speed telemetry enable.
    public static func enableLiveTelemetry(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        enable: Bool = true
    ) -> Data? {
        guard let opcodes = fourEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile,
            type: profile.packetTypes.command,
            seq: seq,
            cmd: opcodes.liveTelemetry,
            payload: Data([enable ? 0x01 : 0x00]))
    }

    /// Flash-buffer historical sync request — **`0x16 SEND_HISTORICAL_DATA` since the ACK loop landed.**
    ///
    /// The byte here was `0x30` for as long as no drain could be acknowledged. `0x30` is Asynchronous
    /// Event / Heartbeat in `BLE_PROTOCOL.md` §2's own table, so that form asked a strap for an event
    /// rather than for a drain — a command it ignores, which is the failure mode that made the mistake
    /// survivable. `0x16` is a drain it *starts*, and §4's rule is that it must not be sent without a
    /// loop that can answer it: each `HISTORY_END` carries an eight-byte token that has to come back in
    /// a `0x17` reply, and **without a correct ACK the strap re-sends the same batch forever**. A strap
    /// stuck in a loop is worse than a strap that ignores a heartbeat, so the correction waited for
    /// `HistoricalDrainSession` rather than being made when the byte was noticed to be wrong.
    ///
    /// **The body is one `00` byte, and it used to be an eight-byte `[u32 startEpoch][u32 endEpoch]`
    /// window this app composed.** Three implemented clients and one hardware capture agree on the bare
    /// byte: noop's `BLEManager` sends `send(.sendHistoricalData, payload: [0x00])`, noop's command doc
    /// gives ID 22 the body `00` as "observed working in device captures on 41.17.6.0", OpenStrap's
    /// `research_playground.py` builds the frame with `b"\x00"`, and that same file carries the captured
    /// vector `aa0800a823041600c7c25288` annotated `0x16 [00]`. No start/end body appears in either
    /// reference, so the window was this app's own invention rather than a documented form.
    ///
    /// The eight-byte shape it was copied from belongs to the **reply**: ID 23's body is `01` plus the
    /// exact eight-byte `HISTORY_END` block, which noop calls opaque and warns against reconstructing
    /// ("never reconstruct the opaque second word"). The widths coincided and the provenance did not —
    /// the request had been built out of the reply's token.
    ///
    /// A time window is not what selects a range in any case: `0x21 SET_READ_POINTER` seeks the read
    /// cursor, and it takes a **u32 offset** rather than an epoch pair.
    public static func requestHistoricalSync(
        profile: WhoopProtocolProfile,
        seq: UInt8
    ) -> Data? {
        guard let opcodes = fourEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq,
            cmd: opcodes.requestHistoricalSync, payload: Data([0x00]))
    }

    // MARK: - Motion

    /// The ordered frames that turn the strap's IMU on, or off.
    ///
    /// **Enable is three opcodes and disable is one, and the asymmetry is the references' rather than
    /// a preference.** `0x6A TOGGLE_IMU_MODE` toggles the IMU itself. `0x3F SEND_R10_R11_REALTIME` is
    /// what makes the strap emit the live 100 Hz record this app's step counter reads, and
    /// `0x6B ENABLE_OPTICAL_DATA` belongs to the same documented enable group. Both of those two are
    /// *enable* verbs with no documented counterpart, so stopping is the IMU toggle alone — the
    /// documented way to stop the IMU — rather than an invented "stop" byte for each.
    ///
    /// **`0x6A` takes ONE byte on the 4.0, and this builder used to send two.** The two-byte form is
    /// real but it belongs to a different set of opcodes, and the source that defines that set says so
    /// in as many words: OpenStrap's `TWO_BYTE_TOGGLES` is "opcodes that take the special TWO-byte
    /// `[REVISION_1=0x01, enable]` payload", it names `ENABLE_OPTICAL_DATA`, `TOGGLE_OPTICAL_MODE` and
    /// the two persistent toggles, and **`0x6A` is deliberately not in it** — its `cmd_toggle_imu`
    /// builds `bytes([0x01 if on else 0x00])`, one byte, everywhere it is called. noop's 4.0 branch
    /// agrees: the payload is `[0x01]` on the `else` side of `deviceFamily == .whoop5`, and the comment
    /// beside it attributes the two-byte form to the 5/MG ("the two-byte realtime IMU selector"). Only
    /// noop's *doc* gives the 4.0 a two-byte `[01, state]`, and its own code contradicts it.
    ///
    /// **The other two payloads come from the same running clients.** `0x3F` takes `[0x01]`: noop's
    /// `BLEManager` documents its `sendR10R11Realtime` as "payload `[0x01]`=on / `[0x00]`=off",
    /// verified on-device, and OpenStrap's `cmd_send_r10_r11` builds the same byte. `0x6B` takes
    /// `[0x01, 0x01]`: OpenStrap's `cmd_enable_optical` sends `[REVISION_1, enable]`, and its own header
    /// records the convention ("Optical toggles need a TWO-byte `[revision=0x01, enable=0x01]`
    /// payload"). Neither opcode is documented *with a body* in `BLE_PROTOCOL.md` §6, which is why this
    /// builder had them bare — but a bodyless frame is the one form **no** source uses, and on a 4.0 a
    /// bodyless `0x3F` starts no live record, which is the stream the step counter reads.
    ///
    /// `seq` is the **base**: the frames take `seq`, `seq + 1`, `seq + 2`, because each is its own inner
    /// record and a shared sequence number would say three frames were one.
    ///
    /// Returns an ordered array so a caller cannot send `0x3F` before the IMU is on — and an **empty**
    /// array rather than a partial one under an envelope this build does not write. All or nothing for
    /// the same reason: a partially-applied enable is a strap with its IMU on and no record being
    /// emitted, which drains battery and produces nothing.
    ///
    /// **A 5.0 strap is enabled by the other builder, not by this one going quiet.** This returns `[]`
    /// for a 5.0 profile, and `WhoopCommandFrames.motionEnableSequence` is what routes that profile to
    /// `WhoopPacketEncoder5` — `0x51` then the toggle with §2.1's five-byte payload. The two sequences
    /// are not variants of one another: the opcodes do not overlap except for the toggle.
    public static func motionEnableSequence(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        enable: Bool = true
    ) -> [Data] {
        guard let opcodes = fourEnvelopeOpcodes(profile) else { return [] }
        let commandType = profile.packetTypes.command

        func frame(_ offset: UInt8, _ cmd: UInt8, _ payload: Data = Data()) -> Data? {
            buildPacket(
                profile: profile, type: commandType, seq: seq &+ offset, cmd: cmd, payload: payload)
        }

        let frames: [Data?] = enable
            ? [
                // One byte, not §6's `[1, 1]` — see the doc comment. `0x6A` is an IMU verb and the
                // two-byte convention belongs to the optical and persistent toggles.
                frame(0, opcodes.toggleIMUMode, Data([0x01])),
                frame(1, opcodes.sendRealtimeMotion, Data([0x01])),
                frame(2, opcodes.enableOpticalData, Data([0x01, 0x01])),
            ]
            : [frame(0, opcodes.toggleIMUMode, Data([0x00]))]

        let built = frames.compactMap { $0 }
        // `buildPacket` cannot fail once the gate above has passed, so a short array would mean a
        // builder changed underneath this one — and sending two thirds of an enable sequence is worse
        // than sending none.
        guard built.count == frames.count else { return [] }
        return built
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
