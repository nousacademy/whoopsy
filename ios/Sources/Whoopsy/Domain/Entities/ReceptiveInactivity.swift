import Foundation

/// One thing that was **received** rather than done: a dream, a meditation, a sound bath.
///
/// ## It has no span, and that is the whole of the type
///
/// `WorkoutSession` is built on two instants, and everything it offers hangs off them. `covers(_:)`
/// asks which days a session was underway on, `durationSeconds` is their difference,
/// `elapsedSeconds(byEndOf:)` is the cumulative form of it, and `zoneSeconds(_:)` scales WHOOP's zone
/// share by it. **A receptive inactivity has no end time**, so it has none of those: it cannot overlap a
/// day, it cannot be in progress, and it has no duration to print, band or compare against a history.
///
/// That absence is a decision rather than an omission — the user's own words are *"just start time is
/// needed no need for end time"* — and it is why this is a type of its own rather than a row in
/// `workouts`. A row there would mean relaxing `started_at` and `ended_at` from `NOT NULL`, which is
/// the pair the half-open overlap read behind Home's ACTIVITIES card is built on: an untimed row would
/// have no instants for `getWorkouts(covering:)` to compare, and the fast that draws on all five of
/// its days stops drawing on any.
///
/// **Nothing here measures anything.** There is no strain, no heart rate, no zone block, no step count
/// and no route — not as an absence to be drawn as a dash, but as a field that does not exist. A
/// receptive inactivity is the state where conscious exertion drops to zero, so a figure describing
/// exertion is not merely unmeasured on one, it is the wrong question. That is why this type stores
/// four things and derives nothing.
///
/// ## `date` is the day it is filed on, and it is snapped at construction
///
/// The `+` menu offers this on **every** day rather than only today, so the day an entry belongs to
/// comes from the screen in front of the user rather than from the entry: filing yesterday's
/// meditation onto yesterday is the point. `date` is therefore an ordinary indexed column keyed on
/// `startOfDay`, exactly as `naps.date` is.
///
/// **It is snapped here, in the initialiser, and not only at the write.** The standing rule for this
/// schema is that a day-keyed write must reach `startOfDay`, because GRDB's `save` is INSERT-or-UPDATE
/// *by primary key* — an unsnapped row is inserted, and no keyed read can find it. Snapping at
/// construction is the stronger form of that rule: there is no way to build a value that stores a day
/// it cannot be read back on. `LocalDatabaseManager.saveReceptiveInactivity` snaps as well, on
/// `saveNap`'s precedent, so a record arriving from anywhere else is covered too. Both are cheap and
/// neither is load-bearing for the other.
///
/// ## `startedAt` is a time of day on `date`'s own day, not a second day key
///
/// The user's rule is *"time is optional"*, so the field is optional and a row without one is an
/// ordinary row rather than an incomplete one. When it is present, the invariant is —
///
/// > **the start time is a time-of-day on the day being viewed**, so `date == startOfDay(startedAt)`.
///
/// `ReceptiveInactivityDraft.applying(to:)` is the single owner of that invariant: it holds the picked
/// hour and minute and rebuilds them onto the day the form is for, so the pair cannot come apart.
///
/// **This type deliberately does not derive `date` from `startedAt`, and that is the one place it
/// departs from `saveNap`.** A nap's day is recoverable from its onset; here `date` is mandatory and
/// `startedAt` is not, so a derivation would have to answer what day an untimed entry belongs to — and
/// the honest answer is the day the user was looking at, which is not something this value can see.
///
/// ## `note` is the entry's own text, and it is `nil` far more often than not
///
/// A dream's prose, an imported record's note, a meditation's own words if the user types any. It is
/// **nullable and undefaulted**, and the absence is an ordinary answer rather than a gap: a meditation
/// is complete without one, and `""` would be a value nobody supplied.
///
/// **The two writers agree about that, and the agreement is the rule.** `ReceptiveInactivityDraft`
/// stores `nil` for a blank or whitespace-only field rather than an empty string — its own stated rule
/// that *"`""` is not a name"*, applied to the second field that needed it — so there is one word for
/// *no text* from the field to the column.
///
/// **It is both a value and an identity input, and that is deliberate rather than a smell.** The
/// imported records carry no producer id — `dreams.json` gives a date, a type and a note and nothing
/// else — so `InactivityParser.identifier(date:type:note:)` derives one by hashing the prose along
/// with the day and the type. An entry's identity *is* its text on its day, which is why the same
/// value is allowed to serve both roles. The consequence is recorded on the importer and in the
/// `LOGS` caption rather than hidden: editing a dream's wording moves its id, so a re-import of a
/// since-changed notes file adds a row beside the old one rather than replacing it.
public struct ReceptiveInactivity: Identifiable, Equatable, Hashable, Sendable {

    /// Stable across an edit, so `save` rewrites the row rather than appending a second one.
    public let id: UUID

    /// The day this is filed on — `startOfDay`, always. See the type comment.
    public let date: Date

    /// What was received. One of `ReceptiveInactivityCatalog.names` for anything recorded through the
    /// sheet.
    ///
    /// A plain `String` rather than an enum, on `WorkoutSession.activityName`'s rule: this is a label
    /// rather than a measurement, and a catalogue is a list of what may be *chosen* rather than a
    /// constraint on what may be *read back*. Narrowing it would make a stored row this catalogue does
    /// not hold unreadable — and the sensible reading of such a row is that it is a receptive inactivity
    /// whose name has since been trimmed from the list, not that it should vanish from the day.
    public let name: String

    /// The entry's own text — or `nil` for an entry that has none, which is the ordinary case. See the
    /// type comment for why it is nullable, why `""` is never stored, and what else the value is used
    /// for. `note` is declared **between `name` and `startedAt`** so that the field order, and
    /// therefore the `Mirror` assertion §14 makes about this type, is predictable.
    public let note: String?

    /// When it began, as a time of day on `date`'s day — or `nil` when the user gave no time, which
    /// their own rule makes an ordinary answer rather than a gap waiting to be filled in.
    public let startedAt: Date?

    public init(id: UUID = UUID(), date: Date, name: String, note: String? = nil, startedAt: Date? = nil) {
        self.id = id
        self.date = date.startOfDay
        self.name = name
        self.note = note
        self.startedAt = startedAt
    }

    /// The order a day's entries are drawn in: `started_at` ascending with the untimed ones last, ties
    /// broken by name.
    ///
    /// **This is the Domain statement of `LocalDatabaseManager.getReceptiveInactivities(on:)`'s
    /// `ORDER BY`, and the two must agree.** The read is `started_at ASC NULLS LAST, name ASC`; this is
    /// that rule written as a comparison. It exists because `HomeViewModel` sorts its own list after a
    /// save — a write must not make the card's order differ from the order a fresh read of the same
    /// day would produce, and it stays wrong until the day is reloaded otherwise. That is the same
    /// shape `WorkoutSession.covers(_:)` has: a storage predicate with a Domain statement beside it,
    /// so the rule does not live only in a query string. The suite asserts the two agree over a
    /// fixture day rather than trusting them to.
    ///
    /// **The name clause is compared as Swift compares `String`s and the column as SQLite compares
    /// TEXT** — byte-wise over UTF-8. Those agree on every name `ReceptiveInactivityCatalog` holds,
    /// which is all ASCII; they could differ for a name mixing scripts, and that is recorded rather
    /// than guarded, because the alternative is a comparison no reader could check.
    ///
    /// `nil` sorts last because SQLite sorts NULL *first* in an ascending order, and an untimed entry
    /// above the day's timed ones reads as an afterthought rather than as the entry that gave no time.
    public static func isOrderedBefore(_ lhs: ReceptiveInactivity, _ rhs: ReceptiveInactivity) -> Bool {
        switch (lhs.startedAt, rhs.startedAt) {
        case let (left?, right?):
            return left == right ? lhs.name < rhs.name : left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return lhs.name < rhs.name
        }
    }
}
