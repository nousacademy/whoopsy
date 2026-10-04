import Foundation
import GRDB

/// A receptive inactivity, in its own table — see `v21_receptive_inactivities` for why it is not a row
/// of `workouts`.
///
/// ## `databaseTableName` is set explicitly, and the reason is the record suffix
///
/// The type, the card, the table and the migration all carry the same word — **`INACTIVITY`** on the
/// row and **`INACTIVITIES`** on the set (`ReceptiveInactivity`, `RECEPTIVE INACTIVITIES`,
/// `receptive_inactivities`). Left to GRDB's own derivation the table would be
/// `receptiveInactivityRecords`: the plural applies to the *record* and not to the inactivity, so a
/// name assembled from the type reads as a table of one. There is exactly one spelling of this thing
/// and the table's name is a second place to write it, which is what this line pins.
///
/// **It was not always one word.** The card's word was `INACTIVITIES` while the row type's was
/// `ACTIVITY` — a row being one activity within the set — and the user has since asked for the row to
/// take the set's word too (*"rename occurences of receptive activity to receptive inactivity"*).
/// The rename touched every identifier, both user-visible strings (the menu row `ADD RECEPTIVE
/// INACTIVITY` and the picker's `Receptive Inactivity` title) and these eight filenames. **The table
/// name and the migration id were already `INACTIVITIES` and did not move** — which is the fact that
/// makes this a pure rename: no database on any machine is re-keyed, and `v21` is untouched.
///
/// ## `CodingKeys` is declared because the columns are snake_case
///
/// `started_at` rather than `startedAt`, mirroring `NapRecord` and `WorkoutRecord`. This is the
/// mismatch `CLAUDE.md` warns about and the reason it is written down rather than inferred: a record
/// declaring no `CodingKeys` would silently make its property names the column names, as
/// `StrainRecord` and `BiometricSampleRecord` do on purpose — so a missing case here is
/// `SQLite error 1: no such column` at runtime and not a compile error.
public struct ReceptiveInactivityRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "receptive_inactivities"

    /// `ReceptiveInactivity.id` as a string. A `UUID` value and the column the entity's initialiser
    /// mints are the same identity, so an edit rewrites the row rather than appending a second one.
    public let id: String

    /// `startOfDay` of the day this is filed on. See the entity for why the day is not derived from
    /// `startedAt`: that field is optional and this one is not, so an untimed entry would have no
    /// derivation to make. `LocalDatabaseManager.saveReceptiveInactivity` snaps it centrally, exactly
    /// as `saveNap` does.
    public var date: Date

    public let name: String

    /// The entry's own text, or NULL. See `ReceptiveInactivity.note` for what it is and why the
    /// column is nullable; see `v22_receptive_inactivity_note` for why it was added after the table.
    /// It is read by the sheet's text field and, for an imported row, is the third input to the id
    /// above — the parser derives that id from the record's own date, type and prose.
    public let note: String?

    /// NULL is the honest value for an entry recorded with no time — the user's own rule makes the
    /// time optional, so an untimed row is complete rather than waiting to be filled in. See
    /// `ReceptiveInactivity.startedAt`.
    public let startedAt: Date?

    public init(id: String, date: Date, name: String, note: String?, startedAt: Date?) {
        self.id = id
        self.date = date
        self.name = name
        self.note = note
        self.startedAt = startedAt
    }

    /// Declared because these columns are snake_case while `StrainRecord`'s are camelCase — the
    /// mismatch `CLAUDE.md` warns about. A missing case here is `no such column` at runtime, not a
    /// compile error.
    ///
    /// `note` needs no rename string, being one word — but it needs the case, and that is the trap:
    /// with `CodingKeys` declared, a property that is missing here is not a compile error, it is a
    /// column this record cannot see.
    enum CodingKeys: String, CodingKey {
        case id
        case date
        case name
        case note
        case startedAt = "started_at"
    }
}
