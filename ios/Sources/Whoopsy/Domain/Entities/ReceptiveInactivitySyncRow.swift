import Foundation

/// One entry of `receptive_inactivities` in the shape the sync moves — a record, not an entity.
///
/// **The only row in this family that is keyed on an id and still read by a day.** A recovery, a strain
/// and a step count are keyed on their date; a session is keyed on its id and *filed* on a day. This one
/// is the third combination: keyed on a `String` id, filed on a day column, and read by range. So the
/// read is `syncReceptiveInactivityRows(from:to:)` — day-ranged, ascending — while the write is a plain
/// upsert by id, and the difference matters because a day holds several entries.
///
/// **The id is the record's spelling and not the entity's.** `ReceptiveInactivityRecord.id` is a
/// `String` holding what the entity mints as a `UUID`, and on this resource the string is load-bearing:
/// `InactivityParser.identifier(date:type:note:)` derives an imported row's id as a UUIDv5 from its own
/// date, type and prose, so re-importing rewrites the row rather than appending a second one. A sync
/// that re-minted identity would make every pass an append.
///
/// **`note` and `startedAt` are the two nullable fields and both must reach the wire as `null`.** The
/// user's own rule makes a time optional — an untimed entry is complete rather than waiting to be filled
/// in — and `note` was added after the table. The schema spells both `.min(1).nullable()`, so `""` is
/// refused and `null` is accepted, which is `RecoveryWireMapper`'s `encode` / never `encodeIfPresent`
/// rule arriving at its third resource.
public struct ReceptiveInactivitySyncRow: Equatable, Sendable {

    /// `ReceptiveInactivityRecord.id` as a string — the row's identity, not its day.
    public let id: String

    /// `startOfDay` of the day this is filed on.
    ///
    /// **Not derived from `startedAt`**, which is optional and therefore has no derivation to make for
    /// an untimed entry. The picker's hour and minute are rebuilt onto the selected day before the
    /// write, so the day comes from the screen and the instant is a detail of the row.
    public let date: Date

    /// The entry's name, from the picker's catalogue. Never empty — the server's `min(1)` says so.
    public let name: String

    /// The entry's own text, or `nil`. On an imported row it is also the third input to `id`.
    public let note: String?

    /// When the entry began, or `nil` for one recorded with no time.
    public let startedAt: Date?

    public init(id: String, date: Date, name: String, note: String?, startedAt: Date?) {
        self.id = id
        self.date = date
        self.name = name
        self.note = note
        self.startedAt = startedAt
    }
}
