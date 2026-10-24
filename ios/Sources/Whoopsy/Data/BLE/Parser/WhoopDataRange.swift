import Foundation

/// The `0x22 GET_DATA_RANGE` reply, decoded far enough to answer one question: **is the strap
/// writing to its history store?**
///
/// The strap keeps a rolling type-47 history buffer. Its write cursor and its acknowledged/trim
/// boundary are two independent numbers, and the difference between them is the backlog — records
/// written but not yet reclaimed by an ACK. A strap whose write page does not move across a wear is
/// not storing anything, however plausible the live stream looks.
///
/// **The layout is a reported one and must stay log-only.** It is noop's #689 diagnostic: a 65-byte
/// body beginning `0x01`, followed by sixteen little-endian `u32` values, where `V(1)` is the read
/// cursor, `V(2)` the write page, `V(3)` the acknowledged/trim boundary and `V(5)` the ring capacity.
/// The reference states the current 5.0/MG layout is **not confirmed against real device
/// observations**, and that its backlog figure never gates sync. This type follows that: it decodes
/// for the log and changes no behaviour.
public struct WhoopDataRange: Sendable, Equatable {
    public let readPage: UInt32
    public let writePage: UInt32
    public let acknowledgedPage: UInt32
    public let capacity: UInt32

    /// Records written and not yet acknowledged, wrapping around the ring.
    ///
    /// `write < acknowledged` is the ordinary wrap case, not an error: the buffer is circular, so the
    /// backlog is `write + (capacity − acknowledged)`.
    public var backlog: Int {
        let write = Int(writePage)
        let acknowledged = Int(acknowledgedPage)
        let capacity = Int(capacity)
        guard capacity > 0 else { return 0 }
        return write < acknowledged
            ? write + (capacity - acknowledged)
            : write - acknowledged
    }

    public init(
        readPage: UInt32,
        writePage: UInt32,
        acknowledgedPage: UInt32,
        capacity: UInt32
    ) {
        self.readPage = readPage
        self.writePage = writePage
        self.acknowledgedPage = acknowledgedPage
        self.capacity = capacity
    }

    /// `nil` for any reply that is not the 65-byte layout, so a different firmware cannot be read as
    /// a plausible cursor by accident.
    public static func decode(payload: Data) -> WhoopDataRange? {
        guard payload.count >= 65 else { return nil }
        let base = payload.startIndex
        guard payload[base] == 0x01 else { return nil }

        func value(_ index: Int) -> UInt32? {
            let offset = base + 1 + index * 4
            guard offset + 3 < payload.endIndex else { return nil }
            return UInt32(payload[offset])
                | (UInt32(payload[offset + 1]) << 8)
                | (UInt32(payload[offset + 2]) << 16)
                | (UInt32(payload[offset + 3]) << 24)
        }

        guard let read = value(1), let write = value(2),
              let acknowledged = value(3), let capacity = value(5)
        else { return nil }
        return WhoopDataRange(
            readPage: read,
            writePage: write,
            acknowledgedPage: acknowledged,
            capacity: capacity)
    }
}
