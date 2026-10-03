import Foundation

/// How one WHOOP generation frames a packet on the wire.
///
/// The generations do **not** share an envelope, and this type is where that stops being a comment in
/// a markdown file and becomes something the codec cannot ignore. `docs/BLE_PROTOCOL.md` §2 carries the
/// byte tables; what is recorded here is only what the codec needs in order to slice and dispatch.
///
/// **Reading and writing are separate capabilities, and this type carries both.** Every generation
/// this build models has an envelope it can validate an inbound frame against, and each of the three
/// straps has a command opcode set it can transmit under — **two sets between them, not one**:
/// `commandOpcodes` for the 4.0 and `syncOpcodes` for the 5.0 and the MG. So "this build can decode a
/// 5.0 strap's traffic" and "this build can send a 5.0 strap a command" remain separate questions;
/// what changed is that the second one is now *yes*, under its own table, rather than *no*.
///
/// **The command opcode set is the write-side choke point.** `WhoopBLEManager.sendCommand` and every
/// builder refuse when the generation's own table is `nil`. That is not defensive programming: writing
/// a 4.0-framed command to a 5.0 strap is not a rejected message — it is a *different message*, and one
/// of the documented 4.0 opcodes is a destructive flash erase (`0x19 FORCE_TRIM`). The two tables are
/// therefore never interchangeable, and a writer that reached for whichever was non-`nil` would be the
/// mistake rather than a convenience.
public struct WhoopProtocolProfile: Sendable, Equatable {
    /// Which checksum covers the header, and over which bytes.
    public enum HeaderChecksum: Sendable, Equatable {
        /// 4.0: CRC8, polynomial `0x07`, over **the two length bytes only**.
        case crc8OverLengthBytes

        /// 5.0 / MG: CRC16-Modbus, polynomial `0xA001`, init `0xFFFF`, over the first six header
        /// bytes — that is, over `frame[0 ..< headerChecksumOffset]`, which reaches back past the
        /// length field to include the start-of-frame byte and the format byte the 4.0 input excludes.
        case crc16ModbusOverHeader
    }

    /// The command opcodes this build transmits under the **4.0** envelope.
    ///
    /// A field rather than four literals in `WhoopPacketEncoder`, because a builder that types its own
    /// opcode is a builder that can disagree with the table the guard above it consults. It is the
    /// profile's own numbering, exactly as `packetTypes` is, and it lives beside it for that reason.
    ///
    /// **`nil` means this build holds no set for that envelope — and no generation answers `nil`
    /// today.** It is not a claim about what a strap accepts: the fields here are 4.0 opcodes, and a
    /// 5.0's are a different table (`SyncOpcodes`), a different builder (`WhoopPacketEncoder5`) and a
    /// different envelope. `buildPacket` constructs the 4.0 envelope only, so a generation whose frames
    /// this build writes gets a builder that pins that envelope rather than this table filled in.
    ///
    /// **The table is wider than what the app transmits today, deliberately.** Every field here is a
    /// documented 4.0 opcode, and several belong to the drain — which is implemented in pieces. A
    /// table that carried only the four opcodes a shipped code path happened to call would make each
    /// new command an edit to the *table* rather than to the builder that uses it, and the table is
    /// the one place a forbidden byte can be asserted absent from.
    public struct CommandOpcodes: Sendable, Equatable {
        public let liveTelemetry: UInt8
        public let hapticAlarm: UInt8
        public let ping: UInt8

        /// **`0x16 SEND_HISTORICAL_DATA`, and the byte here was `0x30` until the ACK loop landed.**
        /// `0x30` is **Asynchronous Event / Heartbeat** in `docs/BLE_PROTOCOL.md` §2's own table, so an
        /// outbound `0x30` asked a strap for an event rather than for a drain — a command it ignores,
        /// which is the failure mode that made the mistake survivable. `0x16` is a drain it *starts*.
        ///
        /// **The byte waited for the loop, and that ordering was the point.** §4: records stream in
        /// batches, each `HISTORY_END` carries an eight-byte continuation token that must come back in
        /// a `0x17` reply, and **without a correct ACK the strap re-sends the same batch forever**. A
        /// build that sent `0x16` while holding no ACK loop would have left a strap in that loop, which
        /// is worse than a command it ignores — so the correction was applied where
        /// `HistoricalDrainSession` landed and not when the byte was noticed to be wrong.
        public let requestHistoricalSync: UInt8

        // MARK: The motion and drain set

        /// `0x6A TOGGLE_IMU_MODE` / `SEND_R10_R11`. Toggles the IMU on and off; `docs/BLE_PROTOCOL.md` §6
        /// gives the shared two-byte form `[1, 1]` to enable and `[1, 0]` to stop.
        ///
        /// The same byte is `106` in the noop catalog, which is the numbering the 5.0 profiles inherit —
        /// and the 5.0's IMU toggle is documented there as `0x69`/`0x6A` for its historical and live
        /// forms. **The role crosses generations; this table does not**, which is why the 5.0 profiles
        /// carry their own set rather than forwarding to this one.
        public let toggleIMUMode: UInt8

        /// `0x3F SEND_R10_R11_REALTIME` — starts the live 100 Hz motion record (type `0x2B`).
        ///
        /// **This is the 4.0's answer to the 5.0's `0x51 START_RAW_DATA`, and it is the opcode the
        /// whole live step path hangs on**: without it the strap sends no `R10`, and a 4.0 accrues no
        /// steps. Its payload is not documented — the reference names the opcode and stops — so the
        /// builder sends none, and a capture settles it (`docs/BLE_PROTOCOL.md` §7).
        public let sendRealtimeMotion: UInt8

        /// `0x6B ENABLE_OPTICAL_DATA`. Named rather than used by the step path — the optical engine is
        /// heart rate, not motion — but it belongs to the same documented enable group and is listed
        /// so the enable sequence is one table lookup rather than three bare literals.
        ///
        /// **It is not `0x9A TOGGLE_PERSISTENT_R21`**, which is the neighbouring-sounding opcode that
        /// must never be sent: that one forces the optical engine on across reboots and burns battery
        /// until the strap is rebooted. This one is the ordinary, session-scoped toggle.
        public let enableOpticalData: UInt8

        /// `0x0A SET_CLOCK`. **A prerequisite for trusting any drained record's timestamp rather than
        /// a refinement of it**: the strap's RTC is what stamps a record, and a strap whose battery
        /// went flat reports `RTC_LOST` (the reference's event type 13) with nothing in the record to
        /// show it — so history files onto a *wrong day*, which is the silent failure the day-key rule
        /// exists to prevent. §7 Q7 records that the payload is **firmware-specific**: a wrong-length
        /// set is acknowledged but not latched, and published clients use 4, 5, 8 and 9 bytes.
        public let setClock: UInt8

        /// `0x14 ABORT_HISTORICAL_TRANSMITS`. The drain's own stop. Named because a drain that can be
        /// started and not stopped is the one state a stuck strap cannot be talked out of.
        public let abortHistoricalTransmits: UInt8

        /// `0x21 SET_READ_POINTER` — moves the flash read cursor, which is what makes a partial drain
        /// resumable rather than restartable.
        public let setReadPointer: UInt8

        /// `0x22 GET_DATA_RANGE` — the range canary, and the only command that would answer "how far
        /// back does this strap's backlog actually reach". `docs/TODO.md` §5 records that figure as
        /// unmeasured and disputed by a factor of five across the references.
        public let getDataRange: UInt8

        /// `0x17 HISTORICAL_DATA_RESULT` — the per-batch ACK. §4's rule, and the reason the request
        /// byte above waits for it: **without a correct ACK the strap re-sends the same batch forever.**
        public let historicalDataResult: UInt8

        public init(
            liveTelemetry: UInt8,
            hapticAlarm: UInt8,
            ping: UInt8,
            requestHistoricalSync: UInt8,
            toggleIMUMode: UInt8,
            sendRealtimeMotion: UInt8,
            enableOpticalData: UInt8,
            setClock: UInt8,
            abortHistoricalTransmits: UInt8,
            setReadPointer: UInt8,
            getDataRange: UInt8,
            historicalDataResult: UInt8
        ) {
            self.liveTelemetry = liveTelemetry
            self.hapticAlarm = hapticAlarm
            self.ping = ping
            self.requestHistoricalSync = requestHistoricalSync
            self.toggleIMUMode = toggleIMUMode
            self.sendRealtimeMotion = sendRealtimeMotion
            self.enableOpticalData = enableOpticalData
            self.setClock = setClock
            self.abortHistoricalTransmits = abortHistoricalTransmits
            self.setReadPointer = setReadPointer
            self.getDataRange = getDataRange
            self.historicalDataResult = historicalDataResult
        }
    }

    /// The command opcodes this build transmits under the **5.0 / MG** envelope.
    ///
    /// **A second type rather than the same fields with different numbers, because the two sets do not
    /// have the same shape.** `CommandOpcodes` carries twelve roles; the references name nine for
    /// MAVERICK, and the other six — live telemetry, the haptic alarm, ping, abort, the read pointer
    /// and the optical enable — have **no published 5.0 byte at all**. Forcing them into that struct
    /// would mean six invented literals sitting in a table whose entire purpose is to be the place a
    /// forbidden byte can be asserted absent from, which is worse than a shorter table: an invented
    /// opcode is a byte this app might one day transmit, and one of the two opcodes that must never be
    /// sent (`0x19 FORCE_TRIM`) is a flash erase.
    ///
    /// So this type carries the roles the 5.0 references actually establish, and it is **not a subset of
    /// `CommandOpcodes`** — the numbering crosses over in both directions. `0x6A`'s IMU toggle and the
    /// drain group (`22`/`23`/`34`) are shared numbering written in different radixes; the hello
    /// (`0x91`), the clock pair (`0x92`/`0x93`), the config writes (`0x77`/`0x78`) and raw data's start
    /// and stop (`0x51`/`0x52`) exist on this generation and not on the 4.0's table. **The numbers are
    /// decimal in the noop catalog the 5.0 set comes from and hex everywhere in this build**, which is
    /// how `docs/BLE_PROTOCOL.md` §2's eight correspondences are recorded; the fields below are written in
    /// hex with the decimal in the comment, so neither reader has to convert.
    public struct SyncOpcodes: Sendable, Equatable {
        /// `0x91` / 145. The 5.0's static hello. §2.1 carries the published sixteen-byte frame, so this
        /// one has a byte-for-byte vector rather than only a name.
        public let hello: UInt8

        /// `0x16` / 22 `SEND_HISTORICAL_DATA` — the drain's request. Shared numbering with the 4.0.
        public let requestHistoricalSync: UInt8

        /// `0x17` / 23 `HISTORICAL_DATA_RESULT` — the per-batch ACK, whose 5.0 payload is
        /// `[0x01] + end_data(8)`. Same rule as the 4.0's: **without a correct ACK the strap re-sends
        /// the same batch forever.**
        public let historicalDataResult: UInt8

        /// `0x22` / 34 `GET_DATA_RANGE` — the range canary. Shared numbering with the 4.0.
        public let getDataRange: UInt8

        /// `0x52` / 82 `STOP_RAW_DATA`. §6's stop is this then the IMU toggle with `[1,0]`.
        ///
        /// **This stops the producer the enable started, and it is not the drain's abort** — that is
        /// `abortHistoricalTransmits` below, which this generation publishes under the same number the
        /// 4.0 uses. The reference names `96`/`97` beside the drain as a high-frequency-sync pair; they
        /// are not carried here, because a name is not an opcode this build may send and nothing in
        /// this app transmits them.
        public let stopRawData: UInt8

        /// `0x51` / 81 `START_RAW_DATA`. §6's enable sequence is this then the IMU toggle.
        ///
        /// **The 4.0's counterpart is `0x3F`, and the two are not the same byte** — which is why a
        /// generation this build writes to must have its own table rather than a fallback to the other.
        /// The payload is not documented; the builder sends none, and a capture settles it (§7).
        public let startRawData: UInt8

        /// `0x6A` / 106 `TOGGLE_IMU_MODE`, the live form, and `0x69` / 105 its historical form — the
        /// pair the references name as this generation's IMU toggle. `0x6A` is the one opcode whose
        /// *number* is shared with the 4.0's table, and the parameter bytes are where the two are told
        /// apart: §2.1's published frame carries five (`01 01 00 00 00`) where §6's shorthand for the
        /// 4.0 is two.
        public let toggleIMUModeLive: UInt8

        /// See `toggleIMUModeLive`. Named and not transmitted: this build's enable uses the live form,
        /// and the historical form is what a drain would toggle if a capture shows the banked records
        /// need asking for separately.
        public let toggleIMUModeHistorical: UInt8

        /// `0x92` / 146 `SET_CLOCK`. **A prerequisite for trusting a drained record's timestamp**, for
        /// §7 Q7's reason carried on the 4.0's `setClock`: a wrong-length set is acknowledged but not
        /// latched, and a strap with an invalid RTC stops banking sensor data to flash entirely — a
        /// strap that looks connected and healthy while writing nothing.
        public let setClock: UInt8

        /// `0x93` / 147 `GET_CLOCK`. The read-back, which §7 Q7 notes is cheap and needs no drain — so
        /// the clock is read after being set rather than assumed to have latched. There is no 4.0
        /// counterpart in either reference, so this is the only generation whose clock can be checked.
        public let getClock: UInt8

        /// `0x14` / 20 `ABORT_HISTORICAL_TRANSMITS` — ends a drain, and **shared numbering with the
        /// 4.0**, which is the correction that put this field here. The table used to omit it on the
        /// stated basis that this generation publishes no abort byte, and that basis is false: the
        /// command index the 5.0 set comes from carries every ID from 1 to 159 once, bounds its 5/MG
        /// column to firmware 50.42.1.0, and marks ID 20 **supported** under this same name.
        ///
        /// **Omitting a published opcode is its own error rather than a safe default.** It left the
        /// drain's only stop with no byte to send, so `0x52 STOP_RAW_DATA` was standing in for it — a
        /// command that stops the producer and does not touch the drain, presented as an abort. The
        /// reference records this generation's history request and abort together, each with a single
        /// explicit `00`, and says beside them that **abort is not trim** — which is the distinction
        /// that matters, since `0x19 FORCE_TRIM` is a flash erase and this is not.
        public let abortHistoricalTransmits: UInt8

        /// `0x21` / 33 `SET_READ_POINTER` — moves the flash cursor. Shared numbering with the 4.0, and
        /// carried for the same reason the 4.0's table carries its five builder-less drain opcodes:
        /// **the table is the one place a forbidden byte can be asserted absent from**, and a role left
        /// out of it is a byte the sweep cannot see.
        ///
        /// Nothing in this app sends it. The reference groups it with forced trim as an operation that
        /// mutates history ownership and "cannot substitute for committed-chunk acknowledgement" —
        /// which is this drain's own rule stated from the other side.
        public let setReadPointer: UInt8

        public init(
            hello: UInt8,
            requestHistoricalSync: UInt8,
            historicalDataResult: UInt8,
            getDataRange: UInt8,
            stopRawData: UInt8,
            startRawData: UInt8,
            toggleIMUModeLive: UInt8,
            toggleIMUModeHistorical: UInt8,
            setClock: UInt8,
            getClock: UInt8,
            abortHistoricalTransmits: UInt8,
            setReadPointer: UInt8
        ) {
            self.hello = hello
            self.requestHistoricalSync = requestHistoricalSync
            self.historicalDataResult = historicalDataResult
            self.getDataRange = getDataRange
            self.stopRawData = stopRawData
            self.startRawData = startRawData
            self.toggleIMUModeLive = toggleIMUModeLive
            self.toggleIMUModeHistorical = toggleIMUModeHistorical
            self.setClock = setClock
            self.getClock = getClock
            self.abortHistoricalTransmits = abortHistoricalTransmits
            self.setReadPointer = setReadPointer
        }
    }

    /// The packet-type numbering.
    ///
    /// **Both profiles carry the same values, and that is a finding rather than an oversight.** It was
    /// believed the two references disagreed here — the 4.0 reference writes its types in hex, the 5.0
    /// reference in decimal — and `docs/BLE_PROTOCOL.md` §2 records the eight exact correspondences that
    /// falsify it (`0x23`=35, `0x2F`=47, …). The numbering is shared; the **envelope** is the
    /// discriminator. The field is kept per-profile anyway, because the moment a capture shows one
    /// generation numbering a role differently this is where it goes, and because a literal in a
    /// `switch` is a decision nothing can assert.
    public struct PacketTypes: Sendable, Equatable {
        public let command: UInt8
        public let commandResponse: UInt8
        public let realtimeRawData: UInt8
        public let historicalData: UInt8
        public let event: UInt8
        public let metadata: UInt8

        /// **`realtimeRawData` is `0x2B` on the 4.0 and `43` on the 5.0 / MG, and those are the same
        /// byte.** It was the one role this table did not carry, so the 100 Hz motion record had no
        /// name anywhere in the codebase and `docs/BLE_PROTOCOL.md` §6's two layouts had nothing to be
        /// dispatched from. The shared numbering is the whole reason one `switch` can route both
        /// generations to their own layout rather than each generation needing its own type check.
        public init(
            command: UInt8, commandResponse: UInt8, realtimeRawData: UInt8, historicalData: UInt8,
            event: UInt8, metadata: UInt8
        ) {
            self.command = command
            self.commandResponse = commandResponse
            self.realtimeRawData = realtimeRawData
            self.historicalData = historicalData
            self.event = event
            self.metadata = metadata
        }
    }

    /// The CRC32 trailer every frame ends with: four bytes, little-endian, under both envelopes.
    ///
    /// A property of the format rather than of a generation, which is why it is a static and not a
    /// field — and it is named because the declared length is defined in terms of it, so the two
    /// offsets below and this constant are read together or not at all.
    public static let checksumTrailerBytes = 4

    public let generation: WhoopHardwareGeneration
    public let headerChecksum: HeaderChecksum

    /// Offset of the `u16` LE declared length. **1** for 4.0, **2** for 5.0 / MG — 5.0 spends byte 1
    /// on a format byte, so everything from the length onward is one byte later than 4.0's table
    /// reads, and a decoder that reads `data[1]` is correct for exactly one generation.
    public let lengthFieldOffset: Int

    /// Offset of the header checksum. **3** for 4.0 (one byte, immediately after the length), **6**
    /// for 5.0 / MG (two bytes, after the two reserved header bytes).
    ///
    /// Read together with `headerChecksum`, this is both where the checksum sits and, for the CRC16
    /// case, where its coverage ends: the 5.0 checksum covers `frame[0 ..< 6]`, which is everything
    /// before it. The 4.0 CRC8 covers the two length bytes instead, which is why that case names its
    /// own input rather than deriving one from this offset.
    public let headerChecksumOffset: Int

    /// Offset of the inner record's first byte, the `type`. **4** for 4.0, **8** for 5.0 / MG — a
    /// four-byte shift, and the reason a decoder that reads `cmd` at a fixed offset is correct for
    /// exactly one generation.
    public let innerOrigin: Int

    /// Bytes of the inner record that precede the payload: `type`, `seq`, `cmd`.
    ///
    /// Both generations use three. It is a field rather than a literal because the declared length is
    /// defined in terms of it — the declared length counts the whole inner record plus the four-byte
    /// trailer, so a frame builder that hardcodes the three gets a length that is right until the
    /// record shape changes.
    public let innerPrefixBytes: Int

    /// The opcodes this build transmits for this generation, or `nil` when it has no established set.
    /// See `CommandOpcodes`. Non-`nil` for the 4.0 only.
    public let commandOpcodes: CommandOpcodes?

    /// The 5.0 / MG opcodes this build transmits, or `nil` for a generation whose set is that of
    /// `commandOpcodes` instead. See `SyncOpcodes`. Non-`nil` for the 5.0 and the MG only.
    ///
    /// **Two optional fields rather than one, and neither is a fallback for the other.** They answer
    /// the same question — what may this build transmit — about two different tables, and a writer
    /// consults the one its own envelope belongs to. A builder that reached for whichever was non-`nil`
    /// would write 4.0 opcodes under a 5.0 envelope, which is the single mistake this whole arrangement
    /// exists to prevent.
    public let syncOpcodes: SyncOpcodes?

    public let packetTypes: PacketTypes

    public init(
        generation: WhoopHardwareGeneration,
        headerChecksum: HeaderChecksum,
        lengthFieldOffset: Int,
        headerChecksumOffset: Int,
        innerOrigin: Int,
        innerPrefixBytes: Int,
        commandOpcodes: CommandOpcodes?,
        syncOpcodes: SyncOpcodes?,
        packetTypes: PacketTypes
    ) {
        self.generation = generation
        self.headerChecksum = headerChecksum
        self.lengthFieldOffset = lengthFieldOffset
        self.headerChecksumOffset = headerChecksumOffset
        self.innerOrigin = innerOrigin
        self.innerPrefixBytes = innerPrefixBytes
        self.commandOpcodes = commandOpcodes
        self.syncOpcodes = syncOpcodes
        self.packetTypes = packetTypes
    }

    /// Whether this build may transmit a frame under this envelope — either table, since each is the
    /// write-side answer for its own generation.
    public var canTransmitCommands: Bool { commandOpcodes != nil || syncOpcodes != nil }

    // MARK: - The length arithmetic

    /// How many bytes the inner record occupies, given the frame's declared length.
    ///
    /// **`declaredLength - 4` under both envelopes, and it is worth knowing why that is not a
    /// coincidence.** The declared length counts the inner record *plus* the four-byte CRC32 trailer,
    /// so subtracting the trailer gives the record — `1247 - 4 = 1243` for a 4.0 type-24 frame, and
    /// `8 - 4 = 4` for the 5.0 `CLIENT_HELLO`, which is exactly its `type seq cmd payload` of four
    /// bytes. The relationship the two references *appear* to disagree about is the one below.
    public func innerByteCount(declaredLength: Int) -> Int {
        declaredLength - Self.checksumTrailerBytes
    }

    /// How many bytes the whole frame occupies, given its declared length.
    ///
    /// **`innerOrigin + declaredLength` under both envelopes** — which is 4.0's documented
    /// `length + 4` and 5.0's documented `declLength + 8`, the same rule written two ways. Working it
    /// through once, because this is the single fact that lets one decoder serve both: the frame is a
    /// header of `innerOrigin` bytes, an inner record of `declaredLength - 4`, and a four-byte
    /// trailer — `innerOrigin + (declaredLength - 4) + 4`.
    ///
    /// The earlier framing in this repo recorded the two forms separately and only ever implemented
    /// the first, so the 5.0 form had no expression at all outside a markdown table.
    public func frameByteCount(declaredLength: Int) -> Int {
        innerOrigin + declaredLength
    }

    // MARK: - The profiles

    /// The 4.0 envelope, and the only one whose writers predate the second builder.
    ///
    /// Every field is from `docs/BLE_PROTOCOL.md` §2, and the checksum arithmetic behind it was checked
    /// against both references' published frames — see §2.1, where all four vectors reproduce. **None
    /// of it is captured on this project's own hardware**, so "correct" here means "matches both
    /// reverse-engineering references and is internally consistent", not "a strap accepts it".
    public static let whoop4 = WhoopProtocolProfile(
        generation: .whoop4,
        headerChecksum: .crc8OverLengthBytes,
        lengthFieldOffset: 1,
        headerChecksumOffset: 3,
        innerOrigin: 4,
        innerPrefixBytes: 3,
        commandOpcodes: CommandOpcodes(
            liveTelemetry: 0x05,
            hapticAlarm: 0x10,
            ping: 0x20,
            requestHistoricalSync: 0x16,
            toggleIMUMode: 0x6A,
            sendRealtimeMotion: 0x3F,
            enableOpticalData: 0x6B,
            setClock: 0x0A,
            abortHistoricalTransmits: 0x14,
            setReadPointer: 0x21,
            getDataRange: 0x22,
            historicalDataResult: 0x17
        ),
        syncOpcodes: nil,
        packetTypes: PacketTypes(
            command: 0x23,
            commandResponse: 0x24,
            realtimeRawData: 0x2B,
            historicalData: 0x2F,
            event: 0x30,
            metadata: 0x31
        )
    )

    /// The 5.0 envelope. `docs/BLE_PROTOCOL.md` §2 gives one envelope for the 5.0 and the MG, so these two
    /// differ only in the `generation` they report back on a decoded frame.
    public static let whoop5 = fiveEnvelope(.whoop5)

    /// The 5.0 MG envelope. See `whoop5`.
    public static let whoop5MG = fiveEnvelope(.whoop5MG)

    /// The 5.0 / MG envelope, built per generation so a decoded frame names the strap it came from.
    ///
    /// **This profile now writes as well as reads, and the reason is that the drain landed rather than
    /// that the barrier went away.** Three things were true when this value carried no opcodes, and two
    /// of them still are:
    ///
    /// * The opcode set is established — §2.1's published command frame, §6's enable sequence and the
    ///   noop catalog — and it is **not** the 4.0's numbering. It is carried in `SyncOpcodes` above,
    ///   which is short because six of the 4.0 table's twelve roles have no published 5.0 byte.
    /// * §2's `[4..6]` header bytes are **still** unspecified, and the builder still does not compute
    ///   them: `WhoopPacketEncoder5` pins `00 01` as literals copied from the one published frame, and
    ///   says so where it does it. That is a claim about a two-byte field whose meaning the reference
    ///   does not give, and a capture is what would settle it.
    /// * The command characteristic still needs **an authenticated SMP bond**, which §7 Q6 records noop
    ///   reporting that macOS CoreBluetooth cannot complete and which nothing establishes that iOS can.
    ///   Carrying opcodes does not answer that question; it is what makes the question askable, because
    ///   before this there was no frame to send either way.
    ///
    /// So a 5.0 whose bond completes now drains, and one whose bond does not gets no traffic at all —
    /// where before this it was the second case by construction. The bond remains an open question and
    /// is **not** resolved by this table; §7 Q6 stays capture-gated.
    private static func fiveEnvelope(_ generation: WhoopHardwareGeneration) -> WhoopProtocolProfile {
        WhoopProtocolProfile(
            generation: generation,
            headerChecksum: .crc16ModbusOverHeader,
            lengthFieldOffset: 2,
            headerChecksumOffset: 6,
            innerOrigin: 8,
            innerPrefixBytes: 3,
            commandOpcodes: nil,
            syncOpcodes: SyncOpcodes(
                hello: 0x91,
                requestHistoricalSync: 0x16,
                historicalDataResult: 0x17,
                getDataRange: 0x22,
                stopRawData: 0x52,
                startRawData: 0x51,
                toggleIMUModeLive: 0x6A,
                toggleIMUModeHistorical: 0x69,
                setClock: 0x92,
                getClock: 0x93,
                abortHistoricalTransmits: 0x14,
                setReadPointer: 0x21
            ),
            packetTypes: PacketTypes(
                command: 35,
                commandResponse: 36,
                realtimeRawData: 43,
                historicalData: 47,
                event: 48,
                metadata: 49
            )
        )
    }

    /// The profile for a generation, or `nil` when this build has no envelope for it at all.
    ///
    /// **A non-`nil` answer is still not by itself permission to transmit.** Every generation this
    /// build can slice except `.standardBleHR` and `.simulator` now carries a command table, but they
    /// carry **different** ones — `commandOpcodes` for the 4.0, `syncOpcodes` for the 5.0 and the MG —
    /// and a writer consults the table its own envelope belongs to rather than whichever is non-`nil`.
    /// Read `canTransmitCommands` for the write-side question; asking this function is asking whether
    /// the bytes can be *sliced*.
    ///
    /// The two `nil` cases are not the same kind of absence and are grouped for that reason rather
    /// than by accident:
    ///
    /// * `.standardBleHR` — not a WHOOP strap at all. Its heart rate arrives on the standard `0x2A37`
    ///   characteristic, which is decoded by `WhoopPacketDecoder.decodeStandardHeartRate` and needs no
    ///   proprietary envelope.
    /// * `.simulator` — the mock manager generates samples directly and frames nothing.
    public static func profile(for generation: WhoopHardwareGeneration) -> WhoopProtocolProfile? {
        switch generation {
        case .whoop4:
            return .whoop4
        case .whoop5:
            return .whoop5
        case .whoop5MG:
            return .whoop5MG
        case .standardBleHR, .simulator:
            return nil
        }
    }
}

/// `WhoopProtocolProviding` answered from the profile table.
///
/// A value type with no state, so the Domain protocol can be handed to a screen without the screen
/// importing anything from `Data/BLE/`.
public struct WhoopProtocolCatalog: WhoopProtocolProviding {
    public init() {}

    /// Whether this build can run a **sync** against a generation — which is a question about writing,
    /// not about decoding.
    ///
    /// A drain is a loop of commands: the request and the per-batch ACK. So the answer is whether the
    /// generation has a command opcode set, and all three straps now do — the 4.0 through
    /// `commandOpcodes`, the 5.0 and the MG through `syncOpcodes`. The two that answer `false` are the
    /// two that are not WHOOP straps at all.
    ///
    /// **`true` here is a statement about this build, not about the user's strap.** A 5.0's command
    /// characteristic still needs an authenticated SMP bond that nothing in this project establishes is
    /// completable from a third-party iOS app (§7 Q6), so the screen's caption for a 5.0 says sync is
    /// implemented and the bond is the open question — rather than the earlier caption's "no sync can
    /// happen", which was true when there was no 5.0 frame to send and is now wrong.
    public func supportsProprietarySync(_ generation: WhoopHardwareGeneration) -> Bool {
        WhoopProtocolProfile.profile(for: generation)?.canTransmitCommands == true
    }

    /// The envelope's name, **derived from the profile rather than listed per generation.**
    ///
    /// The two envelopes are what `headerChecksum` discriminates, so this reads that field: a third
    /// envelope would come back `nil` here rather than being mislabelled as one of the two, and a
    /// profile whose opcode set is missing gets `nil` because no command is framed under it — which is
    /// the same condition `supportsProprietarySync` tests, reached from the same place.
    public func protocolEnvelopeName(_ generation: WhoopHardwareGeneration) -> String? {
        guard let profile = WhoopProtocolProfile.profile(for: generation),
              profile.canTransmitCommands else { return nil }
        switch profile.headerChecksum {
        case .crc8OverLengthBytes: return "4.0"
        case .crc16ModbusOverHeader: return "5.0"
        }
    }
}
