import Foundation

/// How one WHOOP generation frames a packet on the wire.
///
/// The generations do **not** share an envelope, and this type is where that stops being a comment in
/// a markdown file and becomes something the codec cannot ignore. `BLE_PROTOCOL.md` §2 carries the
/// byte tables; what is recorded here is only what the codec needs in order to slice and dispatch.
///
/// **`profile(for:)` is the choke point, and it returns `nil` for every envelope this build has not
/// implemented.** That is deliberate and is the safety property the whole type exists for: sending a
/// 4.0-framed command to a 5.0 strap is not a harmless no-op, because the packet-type numbering does
/// not overlap between generations — the same byte is a different message — so an unverified frame
/// must never reach the characteristic. `WhoopBLEManager.sendCommand` is the one caller that can
/// write to it and is the one place that enforces this.
public struct WhoopProtocolProfile: Sendable, Equatable {
    /// Which checksum covers the header, and over which bytes.
    public enum HeaderChecksum: Sendable, Equatable {
        /// 4.0: CRC8, polynomial `0x07`, over **the two length bytes only**.
        case crc8OverLengthBytes

        /// 5.0 / MG: CRC16-Modbus, polynomial `0xA001`, init `0xFFFF`, over the first six header
        /// bytes. No profile this build can construct uses it — see `profile(for:)` — but the case
        /// exists so the codec's `switch` has to name it rather than fall through to the 4.0 builder.
        case crc16ModbusOverHeader
    }

    /// The packet-type numbering.
    ///
    /// 4.0 uses `0x23` / `0x24` / `0x30` / `0x2F` / `0x31`; 5.0 / MG uses 35 / 36 / 48 / 47 / 49. The
    /// sets do not overlap, which is why a single `switch` on the type byte cannot serve both
    /// generations and why dispatch is a function of this table rather than of a literal.
    public struct PacketTypes: Sendable, Equatable {
        public let command: UInt8
        public let commandResponse: UInt8
        public let historicalData: UInt8
        public let event: UInt8
        public let metadata: UInt8

        public init(
            command: UInt8, commandResponse: UInt8, historicalData: UInt8, event: UInt8, metadata: UInt8
        ) {
            self.command = command
            self.commandResponse = commandResponse
            self.historicalData = historicalData
            self.event = event
            self.metadata = metadata
        }
    }

    public let generation: WhoopHardwareGeneration
    public let headerChecksum: HeaderChecksum

    /// Offset of the inner record's first byte, the `type`. **4** for 4.0, **8** for 5.0 / MG — a
    /// four-byte shift, and the reason a decoder that reads `cmd` at a fixed offset is correct for
    /// exactly one generation.
    public let innerOrigin: Int

    /// Bytes of the inner record that precede the payload: `type`, `seq`, `cmd`.
    ///
    /// Both generations use three. It is a field rather than a literal because the declared length is
    /// defined in terms of it — the 4.0 header's `length` counts the whole inner record plus four, so
    /// a frame builder that hardcodes the three gets a length that is right until the record shape
    /// changes.
    public let innerPrefixBytes: Int

    public let packetTypes: PacketTypes

    public init(
        generation: WhoopHardwareGeneration,
        headerChecksum: HeaderChecksum,
        innerOrigin: Int,
        innerPrefixBytes: Int,
        packetTypes: PacketTypes
    ) {
        self.generation = generation
        self.headerChecksum = headerChecksum
        self.innerOrigin = innerOrigin
        self.innerPrefixBytes = innerPrefixBytes
        self.packetTypes = packetTypes
    }

    /// The only envelope this build implements.
    ///
    /// Every field is from `BLE_PROTOCOL.md` §2, and the checksum arithmetic behind it was checked
    /// against both references' published frames — see §2.1, where all four vectors reproduce. **None
    /// of it is captured on this project's own hardware**, so "correct" here means "matches both
    /// reverse-engineering references and is internally consistent", not "a strap accepts it".
    public static let whoop4 = WhoopProtocolProfile(
        generation: .whoop4,
        headerChecksum: .crc8OverLengthBytes,
        innerOrigin: 4,
        innerPrefixBytes: 3,
        packetTypes: PacketTypes(
            command: 0x23,
            commandResponse: 0x24,
            historicalData: 0x2F,
            event: 0x30,
            metadata: 0x31
        )
    )

    /// The profile for a generation, or `nil` when this build cannot speak its envelope.
    ///
    /// The four `nil` cases are not the same kind of absence and are grouped for that reason rather
    /// than by accident:
    ///
    /// * `.whoop5` and `.whoop5MG` — a documented envelope (CRC16-Modbus, inner origin 8, a
    ///   non-overlapping type numbering) that is **implemented nowhere**. Returning `nil` keeps the
    ///   codec from silently framing 5.0 traffic as 4.0. §6 lists the two questions that gate it: what
    ///   record size each strap uses, and whether the 5.0/MG record even carries its own timestamp.
    /// * `.standardBleHR` — not a WHOOP strap at all. Its heart rate arrives on the standard `0x2A37`
    ///   characteristic, which is decoded by `WhoopPacketDecoder.decodeStandardHeartRate` and needs no
    ///   proprietary envelope.
    /// * `.simulator` — the mock manager generates samples directly and frames nothing.
    public static func profile(for generation: WhoopHardwareGeneration) -> WhoopProtocolProfile? {
        switch generation {
        case .whoop4:
            return .whoop4
        case .whoop5, .whoop5MG, .standardBleHR, .simulator:
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

    public func supportsProprietarySync(_ generation: WhoopHardwareGeneration) -> Bool {
        WhoopProtocolProfile.profile(for: generation) != nil
    }
}
