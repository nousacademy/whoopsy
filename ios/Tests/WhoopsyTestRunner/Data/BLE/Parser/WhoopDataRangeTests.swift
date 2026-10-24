import Foundation
import Whoopsy

// MARK: - 2. The data-range reply

/// The `GET_DATA_RANGE` reply is the one answer that separates "the strap has nothing to give" from
/// "the strap is not writing". Both look identical on the drain: `HISTORY_END` with no records.
///
/// The layout is noop's #689 diagnostic and is **not confirmed on 5.0/MG**, so the app logs it and
/// gates nothing. These assertions pin the decode itself — the field indices, the little-endian read
/// and the circular backlog — rather than any claim about what a particular strap returns.
enum WhoopDataRangeTests {
    static func run() {
        /// A 65-byte body: `0x01` then sixteen little-endian u32 values.
        func payload(_ values: [UInt32: UInt32]) -> Data {
            var bytes = Data([0x01])
            for index in 0..<16 {
                let value = values[UInt32(index)] ?? 0
                bytes.append(UInt8(value & 0xFF))
                bytes.append(UInt8((value >> 8) & 0xFF))
                bytes.append(UInt8((value >> 16) & 0xFF))
                bytes.append(UInt8((value >> 24) & 0xFF))
            }
            return bytes
        }

        let range = WhoopDataRange.decode(
            payload: payload([1: 10, 2: 20, 3: 15, 5: 100]))
        assertTest(
            range == WhoopDataRange(
                readPage: 10, writePage: 20, acknowledgedPage: 15, capacity: 100),
            "The reply decodes V(1) as the read cursor, V(2) as the write page, V(3) as the "
                + "acknowledged/trim boundary and V(5) as the ring capacity")
        assertTest(
            range?.backlog == 5,
            "…and the backlog is `write − acknowledged` when the write page is ahead (got "
                + "\(range?.backlog ?? -1))")

        // The ring wraps: a write page behind the acknowledged boundary is the ordinary case, not a
        // negative backlog.
        let wrapped = WhoopDataRange.decode(
            payload: payload([1: 2, 2: 5, 3: 95, 5: 100]))
        assertTest(
            wrapped?.backlog == 10,
            "…and `write + (capacity − acknowledged)` across the ring's wrap — 5 + (100 − 95) — "
                + "rather than a negative number (got \(wrapped?.backlog ?? -1))")

        // Anything that is not the 65-byte layout is refused, so an older firmware's shorter reply
        // cannot be read as a plausible cursor by accident.
        assertTest(
            WhoopDataRange.decode(payload: Data([0x01, 0, 0, 0])) == nil,
            "A reply shorter than 65 bytes is refused rather than partially decoded")
        var wrongLead = payload([1: 10, 2: 20, 3: 15, 5: 100])
        wrongLead[0] = 0x02
        assertTest(
            WhoopDataRange.decode(payload: wrongLead) == nil,
            "…and a body that does not begin `0x01` is refused")
    }
}
