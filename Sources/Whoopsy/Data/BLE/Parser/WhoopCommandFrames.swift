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
    /// latched** (`BLE_PROTOCOL.md` §7 Q7): the 8-byte `[u32 seconds][u32 subseconds]` newer firmware
    /// uses and the 9-byte legacy form that firmware 41.17.x requires and that ignores the 8-byte one
    /// outright. Published clients disagree on the length, so each is a no-op on the other's firmware —
    /// which is what makes sending both safer than choosing. The two bytes that differ are the only
    /// place the subsecond term appears; the legacy form spends five zeroes where the newer form spends
    /// four bytes of a unit this app never sets, because the app's epoch is whole seconds.
    ///
    /// The 5.0 takes one form (`0x92`) and gets one frame.
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
            return WhoopPacketEncoder5.setClock(profile: profile, seq: seq, epochSeconds: epochSeconds)
                .map { [$0] } ?? []
        }
    }

    /// Asks the strap what time it thinks it is. **The 4.0 has no such command in either reference**, so
    /// this answers `nil` for it rather than sending something else.
    ///
    /// **Issuing this is not the same as checking it, and this build does not check it.** §7 Q7 asks for
    /// the clock to be read back rather than assumed latched, and the reply's layout is undocumented on
    /// this generation as well — so the frame is sent, its answer arrives as an ordinary inbound command
    /// response and is logged as one, and **no path in this app decodes it or claims a clock latched.**
    /// What it buys today is that a capture sees both sides of the pair; the comparison is capture-gated
    /// with the rest of §7.
    public static func clockReadBack(profile: WhoopProtocolProfile, seq: UInt8) -> Data? {
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            return nil
        case .crc16ModbusOverHeader:
            return WhoopPacketEncoder5.getClock(profile: profile, seq: seq)
        }
    }
}
