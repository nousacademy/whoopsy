import Foundation

/// The generation-agnostic command surface: **the one place a caller asks for a frame without knowing
/// which envelope will carry it.**
///
/// There are two builders — `WhoopPacketEncoder` for the 4.0 and `WhoopPacketEncoder5` for the 5.0 and
/// the MG — and the two are deliberately not merged: they build different envelopes, consult different
/// opcode tables and share almost no opcodes. What they do share is their **callers**: the BLE manager
/// enables motion on whatever strap connected, and the repository starts a drain on whatever strap the
/// user asked to sync. Those callers know the profile and not the byte layout, so the dispatch belongs
/// here rather than repeated at each call site.
///
/// **Dispatch is on the envelope, not on which table happens to be non-`nil`.** The envelope is what a
/// builder must match to produce a valid frame, so it is the field that decides — and it is also the
/// field the builders themselves guard on. A router reading `syncOpcodes != nil` would agree with the
/// envelope today and disagree the moment a generation carries both, and the failure is silent: a
/// frame with a valid envelope and another generation's opcode is a *different command*, which a strap
/// accepts and acts on.
///
/// **Every function here is total.** A generation this build cannot write to gets `nil` or an empty
/// array rather than a partial sequence, because half an enable sequence leaves a strap in a state
/// nothing describes.
public enum WhoopCommandFrames {
    /// The ordered frames that turn the connected generation's IMU on, or off.
    ///
    /// 4.0 is three frames (toggle, realtime motion, optical) and 5.0 is two (start raw data, toggle);
    /// stopping is one and two respectively. The arrays are all-or-nothing, and `[]` means "this build
    /// has no enable sequence for this strap" rather than "the strap needs none".
    public static func motionEnableSequence(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        enable: Bool = true
    ) -> [Data] {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return WhoopPacketEncoder.motionEnableSequence(profile: profile, seq: seq, enable: enable)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.motionEnableSequence(profile: profile, seq: seq, enable: enable)
        }
    }

    /// The frame that turns live heart rate on, or `nil` when this generation needs no such command.
    ///
    /// **The 4.0's answer is `nil` rather than a shared byte.** Its live heart rate is the standard
    /// `0x2A37` characteristic, and its proprietary enable (`0x05`) is already sent by
    /// `sendConnectCommands` through a different builder. The 5.0/MG gates everything behind the bond
    /// and sends nothing heart-rate-shaped until `0x03 TOGGLE_REALTIME_HR` arrives — which is why a
    /// bonded 5.0 that was never armed showed a live link and no pulse.
    ///
    /// A `nil` here is a refusal, not a failure: it is what keeps `0x03` from being written under the
    /// 4.0 envelope, where it is not an opcode at all.
    public static func realtimeHeartRate(
        profile: WhoopProtocolProfile,
        seq: UInt8
    ) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return nil
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.realtimeHeartRate(profile: profile, seq: seq)
        }
    }

    /// `0x1D REBOOT_STRAP` — restarts the strap's firmware.
    ///
    /// **The recovery the reference names for a sensor engine stuck on, and the one this app needs to
    /// test whether a strap will bank history again.** Measured on the owner's 5.0: its flash holds a
    /// recording from **2026-08-24** and nothing later, so it has not written to flash since long
    /// before its RTC was corrected — the state `docs/BLE_PROTOCOL.md` §4 describes, where a strap
    /// whose clock was lost stops banking entirely. A reboot is the documented way to re-initialise
    /// that path, and it is safe: unlike `0x19 FORCE_TRIM` it erases nothing, and unlike `0x9A` it does
    /// not leave an engine running.
    ///
    /// The payload is undocumented and the reference gives none, so none is sent — the same choice the
    /// motion enable makes, and the same one a capture would settle.
    public static func rebootStrap(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return WhoopPacketEncoder.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq, cmd: 0x1D)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq, cmd: 0x1D)
        }
    }

    /// `0x21 SET_READ_POINTER` — moves the flash read cursor, which is what makes a backlog readable.
    ///
    /// **The drain was missing this, and the measurement is why it exists.** `SEND_HISTORICAL_DATA`
    /// carries no window, so without a seek the strap reads from wherever its cursor already is. On a
    /// strap that has been streaming to the app, that cursor is at the live edge: every drain on
    /// 2026-10-20 and 2026-10-21 returned **~58 records, one batch** — about a minute, and roughly the
    /// time since connect — while a whole night sat unread behind it.
    ///
    /// The payload is a **u32 byte offset**: `0` is the rewind to the oldest record the strap holds,
    /// which is what a "sync everything since I last looked" wants. The strap's own cursor is not
    /// trusted across a disconnect (no reference says it survives one), and `SyncHistoricalDataUseCase`
    /// is content to re-receive records it already has — a sample stored twice is the same sample.
    public static func rewindReadPointer(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        offset: UInt32 = 0
    ) -> Data? {
        guard let opcode = profile.commandOpcodes?.setReadPointer
            ?? profile.syncOpcodes?.setReadPointer else { return nil }
        var payload = Data()
        var value = offset.littleEndian
        payload.append(Data(bytes: &value, count: 4))
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return WhoopPacketEncoder.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq,
                cmd: opcode, payload: payload)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq,
                cmd: opcode, payload: payload)
        }
    }

    /// `0x22 GET_DATA_RANGE` — the read-only question "how much history do you hold".
    ///
    /// **Sent before a drain instead of seeking, and the order is the safety.** A drain reads from the
    /// strap's cursor, and a strap that has been streaming has that cursor at the live edge — measured,
    /// every drain on 2026-10-20/21 returned ~58 records in one batch, about a minute. `0x21
    /// SET_READ_POINTER` would move it, but this app records that opcode as never sent because a
    /// reference groups it with forced trim as mutating history ownership, and moving the cursor of the
    /// only copy of a night is not something to do blind.
    ///
    /// This request mutates nothing: it asks, and the answer says whether a seek is worth making. The
    /// reply's layout is undocumented — noop records "command 22 returns state plus two zero bytes" and
    /// parses none of it — so it is logged raw rather than interpreted.
    public static func dataRangeRequest(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        guard let opcode = profile.commandOpcodes?.getDataRange
            ?? profile.syncOpcodes?.getDataRange else { return nil }
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return WhoopPacketEncoder.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcode)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq, cmd: opcode)
        }
    }

    /// The drain's request, in whichever envelope the profile uses.
    ///
    /// **It takes no window, because neither generation's request carries one.** Both send a single
    /// `00` body — see `WhoopPacketEncoder.requestHistoricalSync` for the sources — so a caller with a
    /// date range has nowhere to put it here. `0x21 SET_READ_POINTER` is what seeks, by byte offset.
    public static func historicalSyncRequest(
        profile: WhoopProtocolProfile,
        seq: UInt8
    ) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return WhoopPacketEncoder.requestHistoricalSync(profile: profile, seq: seq)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.historicalSyncRequest(profile: profile, seq: seq)
        }
    }

    /// The per-batch ACK, in whichever envelope the profile uses — the reply that stops the strap
    /// re-sending the same batch.
    public static func historicalDataAck(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        token: Data
    ) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            guard let opcodes = profile.commandOpcodes, token.count == 8 else { return nil }
            var payload = Data([0x01])
            payload.append(token)
            return WhoopPacketEncoder.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq,
                cmd: opcodes.historicalDataResult, payload: payload)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.historicalDataAck(profile: profile, seq: seq, token: token)
        }
    }

    /// Ends a drain in progress.
    ///
    /// **Both generations publish an abort and both use `0x14` for it**, which is what this returns —
    /// the same number under two envelopes, so the two branches differ in framing and not in byte. This
    /// used to send `0x52 STOP_RAW_DATA` to a 5.0, on the stated basis that this generation publishes no
    /// abort. That basis was false, and the substitution was worse than a missing command: `0x52` stops
    /// the raw-data producer and leaves the drain running, so the app would have reported a stopped
    /// sync to a strap still walking its flash. The distinction is the whole reason this function is
    /// named for the drain rather than for stopping: "the drain is stopped" is exactly the claim a
    /// stuck strap makes false.
    ///
    /// The reference warns beside this pair that **abort is not trim** — `0x19 FORCE_TRIM` is a flash
    /// erase, and this is not.
    public static func abortHistoricalTransmits(
        profile: WhoopProtocolProfile,
        seq: UInt8
    ) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            guard let opcodes = profile.commandOpcodes else { return nil }
            return WhoopPacketEncoder.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq,
                cmd: opcodes.abortHistoricalTransmits)
        case .crc16ModbusOverHeader:
            guard let opcodes = profile.syncOpcodes else { return nil }
            return WhoopPacketEncoder5.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq,
                cmd: opcodes.abortHistoricalTransmits)
        }
    }

    /// Sets the strap's clock, and returns **every** frame that has to be sent to do it.
    ///
    /// **The 4.0 takes two forms and both are sent, because a wrong-length set is acknowledged but not
    /// latched** (`docs/BLE_PROTOCOL.md` §7 Q7): the 8-byte `[u32 seconds][u32 subseconds]` newer firmware
    /// uses and the 9-byte legacy form that firmware 41.17.x requires and that ignores the 8-byte one
    /// outright. Published clients disagree on the length, so each is a no-op on the other's firmware —
    /// which is what makes sending both safer than choosing. The two bytes that differ are the only
    /// place the subsecond term appears; the legacy form spends five zeroes where the newer form spends
    /// four bytes of a unit this app never sets, because the app's epoch is whole seconds.
    ///
    /// The 5.0 takes one form (`0x0A`) and gets one frame.
    ///
    /// **A strap with an invalid RTC stops banking sensor data to flash entirely**, and reports nothing
    /// — so this is a prerequisite for the drain rather than a refinement of it, and it is sent
    /// immediately before the request rather than on a screen of its own.
    public static func setClockFrames(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        epochSeconds: UInt32
    ) -> [Data] {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            guard let opcodes = profile.commandOpcodes else { return [] }
            let type = profile.packetTypes.command

            var current = Data()
            var seconds = epochSeconds.littleEndian
            var zero: UInt32 = 0
            current.append(Data(bytes: &seconds, count: 4))
            current.append(Data(bytes: &zero, count: 4))

            var legacy = Data()
            legacy.append(Data(bytes: &seconds, count: 4))
            legacy.append(Data(repeating: 0, count: 5))

            let frames = [
                WhoopPacketEncoder.buildPacket(
                    profile: profile, type: type, seq: seq, cmd: opcodes.setClock, payload: current),
                WhoopPacketEncoder.buildPacket(
                    profile: profile, type: type, seq: seq &+ 1, cmd: opcodes.setClock,
                    payload: legacy),
            ]
            let built = frames.compactMap { $0 }
            return built.count == frames.count ? built : []

        case .crc16ModbusOverHeader:
            // **Both lengths, on the 5.0 too, and the measurement is why.** The documented rule is
            // that a wrong-length clock set is acknowledged but not latched, and the 4.0 has two
            // published forms for exactly that reason. Measured on the owner's 5.0 on 2026-10-20: the
            // 8-byte form is written confirmed, the strap acknowledges the write, and the RTC stays
            // at **2000-01-03 20:19** — read straight off the motion record's own clock field, so it
            // is the strap's value and not a decode artifact. The 9-byte legacy payload is the other
            // published length, and on the 4.0 each form is a no-op on the other's firmware, which is
            // what makes sending both safer than choosing.
            var current = Data()
            var seconds = epochSeconds.littleEndian
            var zero: UInt32 = 0
            current.append(Data(bytes: &seconds, count: 4))
            current.append(Data(bytes: &zero, count: 4))

            var legacy = Data()
            legacy.append(Data(bytes: &seconds, count: 4))
            legacy.append(Data(repeating: 0, count: 5))

            let frames = [
                WhoopPacketEncoder5.buildPacket(
                    profile: profile, type: profile.packetTypes.command,
                    seq: seq, cmd: profile.syncOpcodes?.setClock ?? 0x0A, payload: current),
                WhoopPacketEncoder5.buildPacket(
                    profile: profile, type: profile.packetTypes.command,
                    seq: seq &+ 1, cmd: profile.syncOpcodes?.setClock ?? 0x0A, payload: legacy),
            ]
            return frames.compactMap { $0 }
        }
    }

    /// Asks the strap what time it thinks it is — `0x0B GET_CLOCK` under **either** envelope.
    ///
    /// **The 4.0 branch used to return `nil` on the claim that neither reference publishes the
    /// command.** noop's command index carries IDs 10/11 for the pair and its connect sequence sends
    /// both, so that claim was a gap in what this repo had read rather than a fact about the protocol;
    /// both generations now get the frame.
    ///
    /// **Issuing this is not the same as checking it, and this build does not check it.** §7 Q7 asks for
    /// the clock to be read back rather than assumed latched, and the reply's layout is undocumented on
    /// both generations — so the frame is sent, its answer arrives as an ordinary inbound command
    /// response, the manager logs it raw, and **no path in this app decodes it or claims a clock
    /// latched.** What it buys today is that a capture sees both sides of the pair; the comparison is
    /// capture-gated with the rest of §7.
    public static func clockReadBack(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            guard let opcodes = profile.commandOpcodes else { return nil }
            return WhoopPacketEncoder.buildPacket(
                profile: profile, type: profile.packetTypes.command, seq: seq,
                cmd: opcodes.getClock)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.getClock(profile: profile, seq: seq)
        }
    }

    /// Plays a haptic pattern — the buzz — on whichever generation connected.
    ///
    /// **The two generations do not transmit the same thing, and `pattern` is the visible half of
    /// that.** The 4.0 sends command `0x4F` (catalog ID 79) with `[pattern, loops, 0, 0, 0]`. The
    /// 5.0/MG's catalog ID is the same 79, but a real-MG capture shows the strap rejecting it, and the
    /// working call is opcode `0x13` with a fixed twelve-byte notification preset — so there the
    /// argument is **ignored**, `loops` becomes `overallLoop = loops − 1`, and the effects are the
    /// captured ones (`WhoopPacketEncoder5.notificationHapticEffects`).
    ///
    /// A `nil` answer is a refusal for a generation this build cannot write, never a fallback to the
    /// other table: `0x4F` under the CRC16 envelope and `0x13` under the CRC8 one are both different
    /// commands rather than the same one in a different container.
    public static func hapticsPattern(
        profile: WhoopProtocolProfile,
        seq: UInt8,
        pattern: UInt8,
        loops: UInt8
    ) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return WhoopPacketEncoder.runHapticsPattern(
                profile: profile, seq: seq, pattern: pattern, loops: loops)
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.hapticsNotification(
                profile: profile, seq: seq, loops: loops)
        }
    }
}
