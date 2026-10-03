import Foundation

/// Binary packet encoder for the **5.0 / MG** envelope.
///
/// **A second builder rather than a parameter on the first**, which is what `WhoopPacketEncoder`'s own
/// doc comment said would happen: the two envelopes differ in the length field's offset, in the header
/// checksum's polynomial *and input*, in where the inner record starts, in the two header bytes nobody
/// has explained, and in every opcode they transmit. A single builder handling both would be a builder
/// whose every line is a `switch`, and the one thing a wrong guess costs is a frame that is not
/// rejected by the strap but is a **different message**.
///
/// **Every builder here is a function of a `WhoopProtocolProfile` and refuses one whose envelope or
/// whose opcode table is not this generation's.** `fiveEnvelopeOpcodes` is the gate, and it is the
/// counterpart of `WhoopPacketEncoder.fourEnvelopeOpcodes`: each builder consults its own table, so a
/// 4.0 profile handed to this file gets `nil` rather than 4.0 opcodes under a 5.0 envelope.
///
/// **Nothing here is captured on this project's own hardware.** What grounds it is
/// `docs/BLE_PROTOCOL.md` §2's envelope, §2.1's two published frames — one of which the suite reproduces
/// byte-for-byte — and §6's enable sequence. Whether a 5.0 accepts any of it is a question about the
/// command characteristic's authenticated SMP bond (§7 Q6) and about the firmware, and neither is
/// answered by a green build.
public enum WhoopPacketEncoder5 {
    public static let startOfFrame: UInt8 = 0xAA

    /// `frame[1]`, the format byte. `0x01` in every 5.0 frame in hand, and not an opcode.
    public static let format: UInt8 = 0x01

    /// `frame[4..<6)`, and **the one field in either envelope this build does not understand.**
    ///
    /// `docs/BLE_PROTOCOL.md` §2 names the two bytes and does not specify them: they hold `00 01` in both
    /// published 5.0 frames — the static `CLIENT_HELLO` and the command frame — and the CRC16 covers
    /// them, so they are part of the header rather than padding the checksum skips. They are therefore
    /// **pinned as literals copied from those frames and never computed**, because the alternatives
    /// are worse in a specific way: a zero constant would be this app asserting the field is empty, and
    /// a derived value would be this app asserting it knows what the field means. Neither is true, and
    /// a wrong guess here produces a frame whose CRC16 is *valid* over a header the strap may read as
    /// something else entirely.
    ///
    /// A capture that varies this field is what would say what it is. Until then it is two bytes
    /// copied from a frame someone else captured, which is the strongest claim available.
    public static let reservedHeaderBytes: [UInt8] = [0x00, 0x01]

    /// Builds a framed command packet under `profile`'s envelope.
    ///
    /// The 5.0 envelope, from `docs/BLE_PROTOCOL.md` §2:
    ///
    /// ```
    /// [0]        SOF = 0xAA
    /// [1]        format = 0x01
    /// [2..4)     declLength, u16 LE
    /// [4..6)     two header bytes, meaning unspecified — pinned, see above
    /// [6..8)     crc16, u16 LE, Modbus, over frame[0..<6)
    /// [8]        inner type
    /// [9]        inner seq
    /// [10]       inner cmd
    /// [11..)     payload
    /// [8+declLength-4 ..< 8+declLength)  crc32, u32 LE, over frame[8 ..< 8+declLength-4)
    /// ```
    ///
    /// `declLength` counts the whole inner record — `[type][seq][cmd][payload…]` — plus the four-byte
    /// trailer, which is `innerPrefixBytes + payload.count + checksumTrailerBytes` and is exactly the
    /// arithmetic the decoder inverts. The lengths are read off the profile rather than typed, so this
    /// builder and `WhoopFrameReassembler`'s framing cannot come to disagree about where a frame ends.
    ///
    /// **The CRC16's input reaches back to byte 0**, including the start-of-frame and format bytes
    /// — which is the 4.0's CRC8 turned inside out: that one covers the two length bytes and nothing
    /// else. §1 of the suite proves the coverage by tampering with byte 0 and byte 1 and requiring the
    /// checksum to move, so a builder that fed it `frame[2..<6)` would fail there rather than silently
    /// agreeing with itself.
    public static func buildPacket(
        profile: WhoopProtocolProfile,
        type: UInt8,
        seq: UInt8,
        cmd: UInt8,
        payload: Data = Data()
    ) -> Data? {
        guard profile.headerChecksum == .crc16ModbusOverHeader else { return nil }

        var inner = Data([type, seq, cmd])
        inner.append(payload)

        let declaredLength = profile.innerPrefixBytes + payload.count
            + WhoopProtocolProfile.checksumTrailerBytes
        let frameByteCount = profile.frameByteCount(declaredLength: declaredLength)

        var frame = Data()
        frame.append(startOfFrame)
        frame.append(format)
        frame.append(UInt8(declaredLength & 0xFF))
        frame.append(UInt8((declaredLength >> 8) & 0xFF))
        frame.append(contentsOf: reservedHeaderBytes)

        // The coverage is `frame[0..<headerChecksumOffset)` — everything before the checksum — which
        // is the same expression the decoder validates against, and not a second statement of it.
        let headerChecksum = CRCUtils.crc16Modbus(frame.prefix(profile.headerChecksumOffset))
        frame.append(UInt8(headerChecksum & 0xFF))
        frame.append(UInt8((headerChecksum >> 8) & 0xFF))

        frame.append(inner)

        var crcLe = CRCUtils.crc32(inner).littleEndian
        frame.append(Data(bytes: &crcLe, count: MemoryLayout<UInt32>.size))

        // A frame whose arithmetic disagrees with the profile's own two rules is not a frame this
        // builder should hand back, and the check is free: it is the identity the decoder relies on.
        guard frame.count == frameByteCount else { return nil }
        return frame
    }

    /// The gate every builder here opens with: the profile's **5.0** opcode table, and the envelope
    /// those opcodes are written for.
    ///
    /// The counterpart of `WhoopPacketEncoder.fourEnvelopeOpcodes`, and deliberately not shared with
    /// it: the two return different types, because the two tables have different fields. A helper that
    /// returned "some opcode table" would be the fallback this arrangement exists to prevent.
    private static func fiveEnvelopeOpcodes(
        _ profile: WhoopProtocolProfile
    ) -> WhoopProtocolProfile.SyncOpcodes? {
        guard profile.headerChecksum == .crc16ModbusOverHeader else { return nil }
        return profile.syncOpcodes
    }

    /// `0x91` / 145 — the hello, and the second of §2.1's two published frames.
    ///
    /// **The payload is one byte, `0x01`, copied from that frame rather than chosen**, on the same
    /// footing as the two reserved header bytes: the reference publishes the frame and not its meaning.
    /// Nothing in this app sends it yet — the drain currently starts at the request — but it is the
    /// handshake's first step (§3 step 1) and it is the only frame in this file whose bytes can be
    /// checked against a capture someone else took, so the builder exists and the suite pins it.
    public static func hello(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcodes.hello,
            payload: Data([0x01]))
    }

    // MARK: - Motion

    /// The ordered frames that turn the strap's IMU on, or off.
    ///
    /// **Each direction is the raw-data verb then the toggle.** `0x51 START_RAW_DATA` starts the
    /// producer and `0x52 STOP_RAW_DATA` stops it; `0x6A TOGGLE_IMU_MODE` is the shared toggle,
    /// `[1, enable, 0, 0, 0]` here against the 4.0's `[1, enable]`, which is §6's shorthand written out
    /// to the five bytes §2.1's published frame actually carries. So enable is start-then-toggle and
    /// stop is stop-then-toggle-off, and the reading is the same in both: **the record is asked for, or
    /// released, before the sensor it reads is switched** — rather than a direction that leaves the IMU
    /// running with nothing consuming it.
    ///
    /// **That ordering is this app's, not a reference's.** §6 names all four opcodes and orders none of
    /// them, so each direction is one plausible arrangement of bytes a capture is what settles
    /// (`docs/BLE_PROTOCOL.md` §7). The suite asserts the order as read off the built bytes rather than as a
    /// claim about the wire.
    ///
    /// **Both bytes that vary are the reference's, and byte 0 is the one that does not.** §2.1's frame
    /// is `01 01 00 00 00` for an enable: byte 0 is `01` in that frame and byte 1 is the flag §6 writes
    /// as `[1, 1]` to enable and `[1, 0]` to stop. So the stop form below changes byte 1 and leaves
    /// byte 0 alone, rather than being a second invented payload. The three trailing zeroes are carried
    /// because the published frame has five bytes and a four-byte payload would be a different record.
    ///
    /// `seq` is the **base**: the frames take `seq`, `seq + 1`, because each is its own inner record and
    /// a shared sequence number would say two frames were one. Returns an **empty** array rather than a
    /// partial one under a profile this build does not write, because a partially-applied enable is a
    /// strap with its IMU in an unknown state.
    public static func motionEnableSequence(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        enable: Bool = true
    ) -> [Data] {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return [] }
        let commandType = profile.packetTypes.command

        func frame(_ offset: UInt8, _ cmd: UInt8, _ payload: Data = Data()) -> Data? {
            buildPacket(
                profile: profile, type: commandType, seq: seq &+ offset, cmd: cmd, payload: payload)
        }

        let frames: [Data?] = enable
            ? [
                frame(0, opcodes.startRawData),
                // `[1, enable, 0, 0, 0]` is §2.1's published payload written once, so the stop form
                // below cannot drift from it.
                frame(1, opcodes.toggleIMUModeLive, Data([0x01, 0x01, 0x00, 0x00, 0x00])),
            ]
            : [
                frame(0, opcodes.stopRawData),
                // The toggle's stop form is the same five bytes with the flag cleared, so the two
                // directions cannot drift into different payload shapes.
                frame(1, opcodes.toggleIMUModeLive, Data([0x01, 0x00, 0x00, 0x00, 0x00])),
            ]

        let built = frames.compactMap { $0 }
        guard built.count == frames.count else { return [] }
        return built
    }

    // MARK: - Clock

    /// `0x92` / 146 `SET_CLOCK`, payload `[u32 epoch LE][u32 0]`.
    ///
    /// **The prerequisite for trusting any drained record rather than a refinement of it.** A record is
    /// stamped by the strap's own RTC, and a strap whose battery went flat reports `RTC_LOST` with
    /// nothing in the record to show it — so the history files onto a *wrong day* rather than onto no
    /// day, which is the silent half of the failure §4's window check exists to catch.
    ///
    /// The eight-byte form is the one §4 records for this shape of clock set (`0x0A` on the 4.0 takes
    /// `[u32 epoch LE][u32 0]` and is the form the 5.0/MG's hardware validated), and unlike the 4.0
    /// there is no second legacy length in hand for this generation — published clients disagree on the
    /// 4.0's, which is why `WhoopPacketEncoder` sends both forms there. Here the one form is sent.
    ///
    /// **A wrong-length set is acknowledged but not latched**, per §7 Q7, so "the command was written"
    /// is not evidence the clock moved. `getClock` is what turns that into a question with an answer.
    public static func setClock(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        epochSeconds: UInt32
    ) -> Data? {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return nil }
        var payload = Data()
        var seconds = epochSeconds.littleEndian
        var zero: UInt32 = 0
        payload.append(Data(bytes: &seconds, count: 4))
        payload.append(Data(bytes: &zero, count: 4))
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcodes.setClock,
            payload: payload)
    }

    /// `0x93` / 147 `GET_CLOCK` — and **there is no 4.0 counterpart in either reference.**
    ///
    /// §7 Q7 is the reason it exists: the clock's read-back is cheap and needs no drain, so the app can
    /// check the RTC it just set instead of assuming it latched. This is the only generation whose
    /// clock can be checked at all, and the check is what keeps "we sent a clock set" from being
    /// presented as "the timestamps are trustworthy".
    ///
    /// The payload and the reply's layout are **both undocumented here** — the reference names the
    /// opcode — so this sends it bare and §7's capture is what fills either in. Reading the reply is not
    /// implemented on any path, which is recorded rather than implied by this builder existing.
    public static func getClock(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcodes.getClock)
    }

    // MARK: - The drain

    /// `0x16` / 22 `SEND_HISTORICAL_DATA` — starts the flash drain.
    ///
    /// **The body is one `00` byte, and it used to be the 4.0 builder's eight-byte
    /// `[u32 start][u32 end]` window carried across.** That carry was a choice between two unknowns and
    /// it guessed wrong: noop's 5/MG row says command 22's older requests "use explicit `00` for each
    /// operation" and that "Command 22 returns state plus two zero bytes", and the 4.0's implemented
    /// clients agree on the same single byte — see `WhoopPacketEncoder.requestHistoricalSync` for the
    /// three implementations and the captured vector behind it.
    ///
    /// **This is the command that must not be sent without an ACK loop.** §4: each `HISTORY_END`
    /// carries a continuation token that has to come back in a `0x17` reply, and **without a correct ACK
    /// the strap re-sends the same batch forever.** A build holding no loop is better off sending
    /// nothing at all, which is why the 4.0's request byte waited in the table until this phase.
    public static func historicalSyncRequest(
        profile: WhoopProtocolProfile,
        seq: UInt8
    ) -> Data? {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq,
            cmd: opcodes.requestHistoricalSync, payload: Data([0x00]))
    }

    /// `0x17` / 23 `HISTORICAL_DATA_RESULT` — the per-batch ACK, payload `[0x01] + end_data(8)`.
    ///
    /// The status byte is `0x01` success, which is the only status this app sends: `0` failure, `2`
    /// pending and `3` unsupported all exist, and nothing in this app has a case for any of them.
    ///
    /// **The eight bytes are the drain's continuation token, and they come from the `HISTORY_END`
    /// marker rather than from the records.** `HistoricalDrainSession` is what reads them out of the
    /// right offsets for the generation in hand; this builder's only job is to refuse a token that is
    /// not eight bytes, because a short one would be a *different record* rather than a rejected ACK.
    public static func historicalDataAck(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        token: Data
    ) -> Data? {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return nil }
        guard token.count == 8 else { return nil }
        var payload = Data([0x01])
        payload.append(token)
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq,
            cmd: opcodes.historicalDataResult, payload: payload)
    }

    /// `0x22` / 34 `GET_DATA_RANGE` — the range canary.
    ///
    /// The one command that would answer "how far back does this strap's backlog actually reach",
    /// which `docs/TODO.md` §5 and §7 Q10 both record as unmeasured and disputed by a factor of five across
    /// the references. The payload is undocumented, so this sends none, and the reply is not read on
    /// any path.
    public static func getDataRange(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        guard let opcodes = fiveEnvelopeOpcodes(profile) else { return nil }
        return buildPacket(
            profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcodes.getDataRange)
    }
}
