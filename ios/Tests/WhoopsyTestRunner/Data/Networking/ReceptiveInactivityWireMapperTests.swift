import Foundation
import Whoopsy

// MARK: - 22.2 One entry on the wire, and the one rule that has no other instance

/// **The nullable-not-optional rule, which has no fixture anywhere else in this suite.**
/// `ReceptiveInactivityWriteSchema` marks `note` and `startedAt` `.nullable()` — a key that must be
/// *present*, carrying `null` — and gives each a `minLength: 1`, so `""` is a `400` while `null` is a
/// value. Every other mapper in `Data/Networking/` has the same *encoder* problem and this is the only
/// resource where the two spellings of "no value" are genuinely different words, because the field is
/// handed back to the user as their own text in an editable box.
///
/// **The two failures are therefore opposite and both are asserted.** A synthesised encoder would omit
/// the keys and earn a `400`; an encoder that wrote `""` would earn a different `400`. And the read half
/// is the mirror: a `null` coming back must become `nil` and never an empty string, or the app would
/// show the user a note they never typed.
///
/// Nothing here opens a database or a socket. The day key and the instant are *forwarded* rather than
/// re-derived — `RecoveryWireMapper` owns the first spelling and `WorkoutWireMapper` the second — so the
/// last block asserts the forwarding one against the other rather than against a literal, which is the
/// only form of that claim that can catch a local copy drifting from the original.
enum ReceptiveInactivityWireMapperTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        /// A whole-second instant, so it survives the wire's milliseconds exactly. A `Date()` carries
        /// sub-millisecond precision that `instantKey` floors away, and a round trip built on one would
        /// fail for a reason that has nothing to do with the mapping.
        let instant: (Int) -> Date = { offset in Date(timeIntervalSince1970: 1_755_000_000 + Double(offset)) }

        // MARK: The five fields, round-tripped through both conversions

        // Every field carries a value no other field shares, so a mapping that swapped two of them
        // cannot cancel itself out. The id is a real `UUID` string because that is the one field the
        // server validates as a pattern, and this row is meant to be one the server would take.
        let entry = ReceptiveInactivitySyncRow(
            id: UUID().uuidString,
            date: day(-2),
            name: "Meditation",
            note: "Twenty minutes, no phone",
            startedAt: instant(-3_600))

        let dto = ReceptiveInactivityWireMapper.dto(for: entry)
        assertTest(dto.id == entry.id, "The id crosses unchanged — it is this table's primary key on both sides")
        assertTest(dto.date == RecoveryWireMapper.dayKey(for: day(-2)),
                   "…the day becomes the wire's bare key, read off the mapper that owns that spelling")
        assertTest(dto.name == "Meditation", "…the name crosses unchanged")
        assertTest(dto.note == "Twenty minutes, no phone", "…and the note")
        assertTest(dto.startedAt == WorkoutWireMapper.instantKey(for: instant(-3_600)),
                   "…and the onset, in the one canonical instant form this app writes down")

        let back = try ReceptiveInactivityWireMapper.row(for: dto)
        assertTest(back == entry, "All five fields survive row → wire → row")

        // The onset is an instant rather than a day, and the day is not derived from it: an entry whose
        // onset is late in the evening is filed on the day the screen is showing, which is the picker's
        // business and never a recomputation here.
        let lateEvening = ReceptiveInactivitySyncRow(
            id: UUID().uuidString, date: day(-4), name: "Journal", note: nil,
            startedAt: day(-4) + 22 * 3600)
        let lateBack = try ReceptiveInactivityWireMapper.row(
            for: ReceptiveInactivityWireMapper.dto(for: lateEvening))
        assertTest(lateBack.date == day(-4),
                   "An entry that began at ten at night keeps the day it was filed on")
        assertTest(lateBack.startedAt == day(-4) + 22 * 3600, "…and its own onset, unmoved")

        // MARK: The wire's own JSON — the half a synthesised encoder gets wrong

        let encoded = try JSONEncoder().encode(dto)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            assertTest(false, "The wire's body encodes to a JSON object")
            return
        }
        assertTest(Set(object.keys) == ["id", "date", "name", "note", "startedAt"],
                   "The body's keys are the wire's five, spelled as the server declares them")

        // The shape the whole file exists for: **both nullable fields present, both `null`, neither
        // omitted.** An imported entry has neither, so this is the common case rather than a corner.
        let bare = ReceptiveInactivityDTO(id: UUID().uuidString, date: "2026-08-21", name: "Dream",
                                          note: nil, startedAt: nil)
        let bareEncoded = try JSONEncoder().encode(bare)
        guard let bareObject = try JSONSerialization.jsonObject(with: bareEncoded) as? [String: Any] else {
            assertTest(false, "A body with both optionals absent still encodes")
            return
        }
        for key in ["note", "startedAt"] {
            assertTest(bareObject.keys.contains(key),
                       "The body carries '\(key)' as a key even when the entry has none")
            assertTest(bareObject[key] is NSNull, "…and carries it as null, which is a value the schema accepts")
        }

        // MARK: Nothing fills an absent value in

        // The read half of the same rule, and the one with a user-visible consequence: an empty string
        // here would be handed back to the user as their own words in an editable field.
        let readBack = try ReceptiveInactivityWireMapper.row(for: bare)
        assertTest(readBack.note == nil, "A note that came back null is absent here, not an empty string")
        assertTest(readBack.startedAt == nil, "…and so is an onset, for a different reason: an import has none")
        assertTest(readBack.id == bare.id, "…while the id, which the schema requires, is a string like any other")

        // MARK: What the database will take

        let sendable = ReceptiveInactivitySyncRow(id: UUID().uuidString, date: day(-1), name: "Meditation",
                                                  note: nil, startedAt: nil)
        assertTest(ReceptiveInactivityWireMapper.isSendable(sendable),
                   "An imported entry with no note and no onset is sendable, which is the common case")
        assertTest(ReceptiveInactivityWireMapper.isSendable(
            ReceptiveInactivitySyncRow(id: sendable.id, date: day(-1), name: "Meditation",
                                       note: "a real note", startedAt: instant(0))),
            "…and so is a typed one carrying both")

        assertTest(!ReceptiveInactivityWireMapper.isSendable(
            ReceptiveInactivitySyncRow(id: sendable.id, date: day(-1), name: "Meditation",
                                       note: "", startedAt: nil)),
            "An empty note is refused where an absent one is accepted — `.min(1)` is what makes '' a "
                + "different answer from null, and the two must not be collapsed")
        assertTest(!ReceptiveInactivityWireMapper.isSendable(
            ReceptiveInactivitySyncRow(id: sendable.id, date: day(-1), name: "", note: nil, startedAt: nil)),
            "An empty name is refused: the schema requires at least one character")

        // The id is the one field here whose *format* the server validates, and it is this table's
        // primary key — an entry the server cannot parse an id for is one it could never store or find.
        assertTest(!ReceptiveInactivityWireMapper.isSendable(
            ReceptiveInactivitySyncRow(id: "not-a-uuid", date: day(-1), name: "Meditation",
                                       note: nil, startedAt: nil)),
            "An id that is not a UUID is refused rather than sent and stored under a key nothing can read")
        assertTest(ReceptiveInactivityWireMapper.isSendable(
            ReceptiveInactivitySyncRow(id: UUID().uuidString.uppercased(), date: day(-1), name: "Meditation",
                                       note: nil, startedAt: nil)),
            "…while an upper-case UUID is the same id, because the parser's own derived ids are not "
                + "case-sensitive values")

        // MARK: A body this app cannot read

        do {
            _ = try ReceptiveInactivityWireMapper.row(
                for: ReceptiveInactivityDTO(id: UUID().uuidString, date: "not-a-day", name: "Dream",
                                            note: nil, startedAt: nil))
            assertTest(false, "A day this app cannot read is refused rather than guessed at")
        } catch let error as CloudSyncError {
            guard case let .malformed(message) = error else {
                assertTest(false, "…with the malformed case, not another one")
                return
            }
            assertTest(message.contains("not-a-day"), "…and the message names the day it could not read")
        }

        // The onset is the other checked field, and its refusal names *it* — a sentence that said only
        // "something was unreadable" would leave a caller guessing which of the two strings it was.
        do {
            _ = try ReceptiveInactivityWireMapper.row(
                for: ReceptiveInactivityDTO(id: UUID().uuidString, date: "2026-08-21", name: "Dream",
                                            note: nil, startedAt: "2026-08-21T00:00:00"))
        } catch let error as CloudSyncError {
            guard case let .malformed(message) = error else {
                assertTest(false, "…with the malformed case")
                return
            }
            assertTest(message.contains("2026-08-21T00:00:00"),
                       "An onset the schema's own form does not describe is refused, and the message names it")
        }

        // MARK: The two spellings are forwarded, not re-derived

        // A local copy of either would keep parsing and stop agreeing — the day key with the calendar
        // about which day an entry is filed on, the instant with the millisecond boundary — and neither
        // failure would show anywhere else. Asserted against the owner rather than against a literal,
        // because a literal here would be the second copy this block exists to forbid.
        for offset in [-400, -7, -1, 0] {
            assertTest(ReceptiveInactivityWireMapper.dayKey(for: day(offset))
                           == RecoveryWireMapper.dayKey(for: day(offset)),
                       "The day key is `RecoveryWireMapper`'s, on a day \(offset) days out")
            assertTest(ReceptiveInactivityWireMapper.day(fromDayKey: RecoveryWireMapper.dayKey(for: day(offset)))
                           == day(offset),
                       "…and reads back to the same day")
        }
        assertTest(ReceptiveInactivityWireMapper.instantKey(for: instant(0))
                       == WorkoutWireMapper.instantKey(for: instant(0)),
                   "The onset's spelling is `WorkoutWireMapper`'s, which is the one place it is written")
        assertTest(ReceptiveInactivityWireMapper.instant(fromInstantKey: WorkoutWireMapper.instantKey(for: instant(0)))
                       == instant(0),
                   "…and reads back to the same instant")
        assertTest(ReceptiveInactivityWireMapper.instant(fromInstantKey: "2026-08-21T00:00:00Z") == nil,
                   "…and refuses a form that is not the canonical one, rather than a lenient second parser")
    }
}
