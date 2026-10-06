import Foundation

/// The wire's own shape for one entry on the `RECEPTIVE INACTIVITIES` card, and the two conversions
/// onto it.
///
/// **A day-keyed resource that is keyed on an id, which is why it has a `row(for:)` and a written-out
/// encoder.** Every other resource this app syncs is either addressed by its day or addressed by its
/// day *and* a parent session; an entry is addressed by `id`, and it still carries a `date` because the
/// screen that reads it reads by day. So the DTO has five fields and two of the five are keys.
///
/// **The two nullable fields reach the wire as JSON `null` and never as `""`, and that is what the
/// hand-written `encode(to:)` below is for.** `ReceptiveInactivityWriteSchema` marks both `.nullable()`
/// and gives each a `minLength: 1`, so an empty string is a `400` and a `null` is a value — the one
/// shape where *absent* and *empty* are different words. A synthesised encoder would omit the keys
/// entirely and earn the same `400` from `additionalProperties: false`'s sibling rule that every
/// declared field must be present.
///
/// **`startedAt` is an instant rather than a day**, and it is optional here for a reason the schema
/// cannot express: an entry the user typed in has a time and an entry an import derived does not, so
/// `nil` is a real state and not a missing value. It crosses to `WorkoutWireMapper.instantKey(for:)`
/// on the same argument the sleep mapper does — one instant spelling, written once.
public struct ReceptiveInactivityDTO: Codable, Equatable, Sendable {

    /// The entry's identity, a UUID string on both sides. `InactivityParser.identifier(date:type:note:)`
    /// derives it as a UUIDv5, which is what makes a re-import rewrite an entry rather than append a
    /// second one.
    public let id: String

    /// The day, `YYYY-MM-DD`.
    public let date: String

    /// What the entry is. The schema requires at least one character.
    public let name: String

    /// The user's own text, or `null`. Never `""`.
    public let note: String?

    /// The moment it began, in the canonical fixed-width UTC form, or `null`.
    public let startedAt: String?

    public init(id: String, date: String, name: String, note: String?, startedAt: String?) {
        self.id = id
        self.date = date
        self.name = name
        self.note = note
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case name
        case note
        case startedAt
    }

    /// Written by hand so `note` and `startedAt` reach the wire as `null` rather than as nothing.
    ///
    /// The decoding half stays synthesised, on `RecoveryDTO`'s argument: `decodeIfPresent` reads a
    /// `null` and a missing key alike, and being generous on the way in costs nothing while being
    /// generous on the way out is a body the server refuses.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(name, forKey: .name)
        try container.encode(note, forKey: .note)
        try container.encode(startedAt, forKey: .startedAt)
    }
}

/// Row ↔ wire for an entry, plus the one question the sync asks before sending one.
public enum ReceptiveInactivityWireMapper {

    // MARK: - The day key and the instant

    /// The day key, forwarded to the one place this app writes that rule down.
    ///
    /// The API declares a single `DayKeySchema` and every resource's `date` references it, so a local
    /// copy would be a second answer to a question that has one.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        RecoveryWireMapper.dayKey(for: day, in: calendar)
    }

    /// The inverse, forwarded for `dayKey(for:in:)`'s reason.
    public static func day(fromDayKey key: String, in calendar: Calendar = .current) -> Date? {
        RecoveryWireMapper.day(fromDayKey: key, in: calendar)
    }

    /// The canonical instant, forwarded to `WorkoutWireMapper`, which owns that spelling.
    public static func instantKey(for instant: Date) -> String {
        WorkoutWireMapper.instantKey(for: instant)
    }

    /// The instant `key` names, or `nil` for any spelling but the canonical one.
    public static func instant(fromInstantKey key: String) -> Date? {
        WorkoutWireMapper.instant(fromInstantKey: key)
    }

    // MARK: - Row ↔ wire

    /// The body this entry is sent as.
    ///
    /// Total, on `StepCountWireMapper.dto(for:)`'s argument: the one structured field that would have
    /// to be serialised — `startedAt` — is rendered by a function that returns a `String`, not a
    /// `throws`, so there is nothing here that can fail.
    public static func dto(
        for row: ReceptiveInactivitySyncRow,
        in calendar: Calendar = .current
    ) -> ReceptiveInactivityDTO {
        ReceptiveInactivityDTO(
            id: row.id,
            date: dayKey(for: row.date, in: calendar),
            name: row.name,
            note: row.note,
            startedAt: row.startedAt.map(instantKey(for:))
        )
    }

    /// The row a body arriving from the server is stored as.
    ///
    /// Two fields are structured types here and strings on the wire — the day and the optional onset —
    /// and each is checked rather than force-unwrapped, naming itself in the refusal so the sentence a
    /// caller logs says which field was unreadable.
    ///
    /// **A missing `note` and a missing `startedAt` are `nil` and not `""`, and nothing here fills one
    /// in.** That is this resource's version of the whole family's rule: a value this app invented is
    /// indistinguishable downstream from one the user supplied, and on this table the invented value
    /// would be handed back to the user as their own words in an editable field.
    ///
    /// `.malformed` and never `.unreachable`, on `WorkoutWireMapper.row(for:)`'s argument: this is a
    /// server that answered, so a caller must not degrade to local storage over it.
    public static func row(
        for dto: ReceptiveInactivityDTO,
        in calendar: Calendar = .current
    ) throws -> ReceptiveInactivitySyncRow {
        guard let day = day(fromDayKey: dto.date, in: calendar) else {
            throw CloudSyncError.malformed(message: "the answer carried a day this app cannot read: \(dto.date)")
        }

        var startedAt: Date?
        if let key = dto.startedAt {
            guard let instant = instant(fromInstantKey: key) else {
                throw CloudSyncError.malformed(
                    message: "the answer carried a start this app cannot read: \(key)"
                )
            }
            startedAt = instant
        }

        return ReceptiveInactivitySyncRow(
            id: dto.id,
            date: day,
            name: dto.name,
            note: dto.note,
            startedAt: startedAt
        )
    }

    // MARK: - What the database will accept

    /// Whether this entry is one the server can be given.
    ///
    /// **This is the family's widest `isSendable`, because this is its only resource with a wire schema
    /// that constrains a *string* rather than a number.** `ReceptiveInactivityIdSchema` is a UUID
    /// pattern, `name` is `minLength: 1`, and `note` is `minLength: 1` when present. All three are
    /// refusals the server would answer with a `400` naming a field, so all three are decided here
    /// instead — and the id one matters most, because the id is this table's primary key and an entry
    /// with an id the server cannot parse is an entry that could never be stored or found again.
    ///
    /// **`InactivityParser.identifier(date:type:note:)` is why the UUID test is not an over-restriction.**
    /// Every entry this app writes is either a UUIDv5 the parser derived or a `UUID()` the sheet minted,
    /// so the pattern is satisfied by construction; an id that fails it is a row this app did not write,
    /// and refusing it is the honest answer rather than a guess at what it meant.
    ///
    /// **The `note`'s emptiness is checked rather than its absence**, and that is the trap the wire's
    /// `.min(1)` sets: `nil` is a legal and common value — an entry the import derived has no note at
    /// all — while `""` is exactly what the schema refuses. So `nil` passes, a non-empty string passes,
    /// and `""` alone is refused.
    ///
    /// The day's own key needs no test: `dayKey(for:)` renders a `Date` and cannot fail. `startedAt`,
    /// when present, must round-trip — an instant that renders and does not parse back is one the server
    /// would store and this app could never read, which is the single worst outcome on this table, since
    /// the value is a user-visible time.
    public static func isSendable(_ row: ReceptiveInactivitySyncRow) -> Bool {
        guard UUID(uuidString: row.id) != nil else { return false }
        guard !row.name.isEmpty else { return false }
        if let note = row.note, note.isEmpty { return false }

        if let startedAt = row.startedAt {
            guard instant(fromInstantKey: instantKey(for: startedAt)) != nil else { return false }
        }

        return true
    }
}
