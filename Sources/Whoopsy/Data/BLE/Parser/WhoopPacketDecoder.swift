import Foundation

/// A proprietary frame whose envelope this app has validated and whose payload it does not decode.
///
/// **This replaces the three decoded payload types the decoder used to produce, and the replacement is
/// the point rather than a simplification.** `BLE_PROTOCOL.md` §2 documents the 4.0 packet types:
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
/// them comes after, which is the order `BLE_PROTOCOL.md` §6 sets out.
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
    /// 2. **Declared length.** `length` counts the whole inner record plus the four-byte CRC32
    ///    trailer, so the total frame is `length + 4`. A frame that declares fewer than the three
    ///    inner prefix bytes is rejected rather than sliced.
    /// 3. **Header checksum** — over the format's own bytes, which for 4.0 is the two length bytes and
    ///    nothing else.
    /// 4. **Payload checksum** — CRC32 over `frame[innerOrigin ..< length]`.
    ///
    /// Checks 3 and 4 are new, and they are what turn this from a parser that cannot fail into one
    /// that can. `CLAUDE.md` used to record that **no inbound CRC was verified anywhere**, which is
    /// why a wrong parser built from the references reads as plausible garbage rather than as an
    /// error. A frame that fails either check now produces nothing at all.
    public func decodeProprietaryFrame(data: Data, profile: WhoopProtocolProfile) -> WhoopRawFrame? {
        // 1. Start of frame.
        guard data.first == Self.startOfFrame else {
            AppLogger.decoder.debug("Rejected frame: bad SOF \(data.first ?? 0, privacy: .public)")
            return nil
        }

        // 2. The header runs to `innerOrigin`; the inner record needs its three prefix bytes.
        guard data.count >= profile.innerOrigin + profile.innerPrefixBytes else {
            AppLogger.decoder.debug("Rejected frame: \(data.count, privacy: .public) bytes is shorter than a header")
            return nil
        }

        let declaredLength = Int(data[1]) | (Int(data[2]) << 8)
        guard declaredLength >= profile.innerOrigin + profile.innerPrefixBytes,
              data.count >= declaredLength + 4
        else {
            AppLogger.decoder.debug("Rejected frame: declares \(declaredLength, privacy: .public) bytes, has \(data.count, privacy: .public)")
            return nil
        }

        // 3. Header checksum.
        switch profile.headerChecksum {
        case .crc8OverLengthBytes:
            let expected = CRCUtils.crc8(Data([data[1], data[2]]))
            guard data[3] == expected else {
                AppLogger.decoder.debug("Rejected frame: header crc8 \(data[3], privacy: .public) != \(expected, privacy: .public)")
                return nil
            }
        case .crc16ModbusOverHeader:
            // Not reachable through `WhoopProtocolProfile.profile(for:)` — no generation this build
            // speaks uses it. Refused rather than parsed, because the offsets below are 4.0's.
            return nil
        }

        // 4. Payload checksum, over the inner record.
        let inner = data.subdata(in: profile.innerOrigin..<declaredLength)
        let trailer = data.subdata(in: declaredLength..<(declaredLength + 4))
        let declaredCRC = UInt32(trailer[trailer.startIndex])
            | (UInt32(trailer[trailer.startIndex + 1]) << 8)
            | (UInt32(trailer[trailer.startIndex + 2]) << 16)
            | (UInt32(trailer[trailer.startIndex + 3]) << 24)
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
