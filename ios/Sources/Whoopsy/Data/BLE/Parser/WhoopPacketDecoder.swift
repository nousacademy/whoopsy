import Foundation

/// A proprietary frame whose envelope this app has validated and whose payload it does not decode.
///
/// **This replaces the three decoded payload types the decoder used to produce, and the replacement is
/// the point rather than a simplification.** `docs/BLE_PROTOCOL.md` §2 documents the 4.0 packet types:
/// `0x23` command, `0x24` command-response, `0x2F` historical data, `0x30` event, `0x31` metadata. It
/// documents no live-telemetry packet type and no battery packet type. The app's `0x01` and
/// `0x02` / `0x20` cases were its own invention, and because dispatch was keyed on a byte that is
/// really the low half of a length, they were not reachable on hardware in the first place.
///
/// Two of the three were also redundant. Battery arrives on the standard `0x2A19` characteristic and
/// live heart rate on `0x2A37`; `WhoopBLEManager` handles both on their own branches and always has.
/// The third — the historical record — is the one payload that **is** documented and **is** the
/// deliverable, and it was being walked as sixteen-byte chunks through the live layout when §4 gives a
/// 96-byte header with heart rate at `[17]`. On a real drain that walk reads a byte of the record
/// counter as a heart rate and writes it to `biometric_samples` — a fabricated reading of exactly the
/// kind this app's absence rule exists to forbid.
///
/// So the decoder does the half it can do and says so plainly: start-of-frame, declared length, header
/// checksum and payload checksum are all verified, and the bytes are handed up undecoded. That is also
/// the shape the pending capture needs — raw frames are the evidence, and a parser written against
/// them comes after, which is the order `docs/BLE_PROTOCOL.md` §7 sets out.
public struct WhoopRawFrame: Sendable, Equatable {
    public let generation: WhoopHardwareGeneration

    /// The inner record's packet type — `0x23` command, `0x2F` historical data, … See
    /// `WhoopProtocolProfile.PacketTypes`.
    public let type: UInt8

    public let seq: UInt8

    /// The command opcode, `inner[2]`. Meaningful when `type` is a command or a command-response.
    public let cmd: UInt8

    /// The inner record's bytes after `type` / `seq` / `cmd`.
    public let payload: Data

    public init(
        generation: WhoopHardwareGeneration, type: UInt8, seq: UInt8, cmd: UInt8, payload: Data
    ) {
        self.generation = generation
        self.type = type
        self.seq = seq
        self.cmd = cmd
        self.payload = payload
    }
}

/// Binary packet decoder for WHOOP proprietary 0xAA frames & standard BLE SIG GATT packets.
///
/// Stateless by construction: the envelope is a parameter rather than a property, because the decoder
/// is built before a strap has been discovered and the generation is not known until it has been. A
/// stored profile would have to be mutated from the BLE queue after construction, which is a race for
/// no benefit — and it keeps this class at zero stored properties, which is what makes it `Sendable`
/// without a lock.
public final class WhoopPacketDecoder: Sendable {
    public static let startOfFrame: UInt8 = 0xAA

    public init() {}

    /// Reads a little-endian `u32` from the first four bytes of `data`.
    ///
    /// A loop rather than the four-term shift-and-or this replaces: that expression is the one the
    /// Swift type checker gave up on once the surrounding offsets stopped being literals, and the loop
    /// also states the byte order instead of implying it through the width of each shift. It reads
    /// from `data.startIndex` and tolerates a short buffer by treating the missing bytes as zero,
    /// which no caller can reach — every one of them has already checked the length — but which keeps
    /// a truncation from being a crash rather than a checksum failure.
    static func littleEndianUInt32(in data: Data) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 where data.startIndex + offset < data.endIndex {
            value |= UInt32(data[data.startIndex + offset]) << (8 * offset)
        }
        return value
    }

    /// Decodes standard Bluetooth SIG Heart Rate Measurement (Characteristic 0x2A37).
    ///
    /// Unaffected by any of this: the standard profile is not a WHOOP envelope, and this is the one
    /// heart-rate producer on the BLE path that is implemented end to end.
    public func decodeStandardHeartRate(data: Data) -> (heartRate: Int, rrIntervalsMs: [Double])? {
        guard !data.isEmpty else { return nil }

        let flags = data[0]
        let is16BitHR = (flags & 0x01) != 0
        let hasRRIntervals = (flags & 0x10) != 0

        var offset = 1
        let heartRate: Int
        if is16BitHR {
            guard data.count >= offset + 2 else { return nil }
            heartRate = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
        } else {
            guard data.count >= offset + 1 else { return nil }
            heartRate = Int(data[offset])
            offset += 1
        }

        // Check for energy expended field (bit 3)
        if (flags & 0x08) != 0 {
            offset += 2
        }

        var rrIntervals: [Double] = []
        if hasRRIntervals {
            while offset + 1 < data.count {
                let rawRR = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                let rrMs = (Double(rawRR) / 1024.0) * 1000.0
                rrIntervals.append(rrMs)
                offset += 2
            }
        }

        return (heartRate, rrIntervals)
    }

    /// Validates a proprietary frame under `profile`'s envelope and returns it undecoded.
    ///
    /// Returns `nil` — and logs why — for anything that does not validate. **A rejected frame is
    /// silence, not an error the caller can act on**: the strap may send a shape this build has never
    /// seen, and the correct response to that is to write nothing rather than to write a guess.
    ///
    /// Four checks, in the order that lets each one trust the indices the previous one established:
    ///
    /// 1. **Start of frame.** Without it there is no frame boundary to trust, and a payload byte that
    ///    happens to be `0xAA` is otherwise indistinguishable from one.
    /// 2. **Declared length**, read at the profile's own `lengthFieldOffset` — byte 1 under 4.0, byte 2
    ///    under 5.0, because 5.0 spends byte 1 on a format byte. It counts the whole inner record plus
    ///    the four-byte CRC32 trailer, so a frame that declares fewer than the three inner prefix bytes
    ///    is rejected rather than sliced, and the whole frame is `innerOrigin + declaredLength`.
    /// 3. **Header checksum** — CRC8 over the two length bytes under 4.0, CRC16-Modbus over the first
    ///    six header bytes under 5.0. The profile selects which.
    /// 4. **Payload checksum** — CRC32 over the inner record, `innerOrigin + declaredLength - 4` bytes
    ///    of it, which is the same span under both envelopes.
    ///
    /// Checks 3 and 4 are what turn this from a parser that cannot fail into one that can. `CLAUDE.md`
    /// used to record that **no inbound CRC was verified anywhere**, which is why a wrong parser built
    /// from the references reads as plausible garbage rather than as an error. A frame that fails
    /// either check produces nothing at all.
    ///
    /// **Both envelopes reach this function now, and the second one is read-only.** A 5.0 / MG frame
    /// validates and is handed up exactly as a 4.0 one is, which is what makes a capture of a 5.0
    /// strap's traffic legible; nothing in this app can *send* one, because those profiles carry no
    /// command opcodes.
    public func decodeProprietaryFrame(data: Data, profile: WhoopProtocolProfile) -> WhoopRawFrame? {
        // 1. Start of frame.
        guard data.first == Self.startOfFrame else {
            AppLogger.decoder.debug("Rejected frame: bad SOF \(data.first ?? 0, privacy: .public)")
            return nil
        }

        // 2. The declared length, at the offset this envelope puts it.
        guard data.count >= profile.lengthFieldOffset + 2 else {
            AppLogger.decoder.debug("Rejected frame: \(data.count, privacy: .public) bytes is shorter than a header")
            return nil
        }
        let declaredLength = Int(data[profile.lengthFieldOffset])
            | (Int(data[profile.lengthFieldOffset + 1]) << 8)

        let frameBytes = profile.frameByteCount(declaredLength: declaredLength)
        guard declaredLength >= WhoopProtocolProfile.checksumTrailerBytes + profile.innerPrefixBytes,
              data.count >= frameBytes
        else {
            AppLogger.decoder.debug("Rejected frame: declares \(declaredLength, privacy: .public) bytes, has \(data.count, privacy: .public)")
            return nil
        }

        // 3. Header checksum.
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            // The input is the two length bytes and nothing else — not the start of frame, and not the
            // command. `docs/BLE_PROTOCOL.md` §2.1 records what computing it over `[cmd, length…]` cost.
            let covered = data.subdata(
                in: profile.lengthFieldOffset..<(profile.lengthFieldOffset + 2))
            let expected = CRCUtils.crc8(covered)
            guard data[profile.headerChecksumOffset] == expected else {
                AppLogger.decoder.debug("Rejected frame: header crc8 \(data[profile.headerChecksumOffset], privacy: .public) != \(expected, privacy: .public)")
                return nil
            }
        case .crc16ModbusOverHeader:
            // Over everything before the checksum, which includes the start-of-frame byte and the
            // format byte — a wider input than the 4.0 case, and the reason the two are separate cases
            // rather than one algorithm behind a boolean.
            let covered = data.subdata(in: 0..<profile.headerChecksumOffset)
            let expected = CRCUtils.crc16Modbus(covered)
            let declared = UInt16(data[profile.headerChecksumOffset])
                | (UInt16(data[profile.headerChecksumOffset + 1]) << 8)
            guard declared == expected else {
                AppLogger.decoder.debug("Rejected frame: header crc16 \(declared, privacy: .public) != \(expected, privacy: .public)")
                return nil
            }
        }

        // 4. Payload checksum, over the inner record.
        let innerEnd = profile.innerOrigin + profile.innerByteCount(declaredLength: declaredLength)
        let inner = data.subdata(in: profile.innerOrigin..<innerEnd)
        let trailer = data.subdata(in: innerEnd..<frameBytes)
        let declaredCRC = Self.littleEndianUInt32(in: trailer)
        let computedCRC = CRCUtils.crc32(inner)
        guard computedCRC == declaredCRC else {
            AppLogger.decoder.debug("Rejected frame: payload crc32 \(declaredCRC, privacy: .public) != \(computedCRC, privacy: .public)")
            return nil
        }

        return WhoopRawFrame(
            generation: profile.generation,
            type: inner[inner.startIndex],
            seq: inner[inner.startIndex + 1],
            cmd: inner[inner.startIndex + 2],
            payload: inner.subdata(in: profile.innerPrefixBytes..<inner.count)
        )
    }
}
