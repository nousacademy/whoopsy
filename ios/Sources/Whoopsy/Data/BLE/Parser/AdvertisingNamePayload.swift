import Foundation

/// The strap's answer to `GET_ADVERTISING_NAME` — **the name it has stored**, as opposed to the name a
/// phone prints, which may be CoreBluetooth's cache of an older advertisement.
///
/// ## The layout, and the byte the reference omits
///
/// noop documents a fixed 19-byte body: revision, source, a NUL-inclusive name length, then a 16-byte
/// storage field. **The captured reply is twenty-one bytes and carries two more fields than that** —
/// the envelope's own length byte in front, and the operation's result byte after the revision:
///
/// ```
/// 14 01 01 01 0C 57 68 6F 6F 70 73 79 20 35 2E 30 00 00 00 00 00
/// │  │  │  │  └ 0x0C = 12 bytes of name, NUL included
/// │  │  │  └ source 1 = the custom name was stored
/// │  │  └ result 1 = the operation succeeded
/// │  └ revision 1
/// └ 0x14 = the body length, 20 against a 21-byte payload
/// ```
///
/// so the parse tolerates a leading length byte rather than assuming the body starts at `0`. Anything
/// that does not fit the shape answers `nil`: a name is a string the app prints back to its owner, and
/// a plausible-looking value decoded from the wrong offset is worse than a dash.
public enum AdvertisingNamePayload {

    /// Where the source byte says the name came from.
    ///
    /// `custom` is the only state with a name worth printing. The reference's `2` is
    /// "fallback/empty storage or a storage-read failure" — three situations the strap does not
    /// separate, and none of them a name.
    public enum Source: UInt8, Sendable {
        case custom = 1
        case fallback = 2
    }

    public struct Name: Equatable, Sendable {
        public let value: String
        public let source: Source

        public init(value: String, source: Source) {
            self.value = value
            self.source = source
        }
    }

    /// The stored name, or `nil` for a reply that is malformed or holds no custom name.
    public static func decode(payload: Data) -> Name? {
        // The envelope's own length byte, when it is there. `payload[0] == count - 1` is the body
        // length; the capture's `0x14` is 20 against a 21-byte payload, which is that relationship.
        var body = [UInt8](payload)
        if let first = body.first, Int(first) == body.count - 1 {
            body.removeFirst()
        }
        guard body.count >= 4 + 1 else { return nil }

        guard body[0] == 1, body[1] == 1, let source = Source(rawValue: body[2]) else { return nil }
        let length = Int(body[3])
        // 1…16, NUL included — a zero length is "no name" and anything above the field cannot be one.
        guard length >= 1, length <= 16, body.count >= 4 + length else { return nil }

        let nameBytes = body[4..<(4 + length - 1)]
        guard let name = String(bytes: nameBytes, encoding: .utf8),
              !name.isEmpty,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        return Name(value: name, source: source)
    }
}
