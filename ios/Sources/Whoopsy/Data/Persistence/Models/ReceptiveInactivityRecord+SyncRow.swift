import Foundation

/// The two conversions between a stored entry and the shape a sync moves.
///
/// **The one row in this family whose id is a `String` on both sides**, which is what makes this file
/// the shortest of the four: a session's id crosses a `UUID`/`String` boundary and takes a policy with
/// it (`WorkoutSyncStore`'s drop-the-parent/keep-the-child rule), while a strain's identity is its day
/// and is a `Date` everywhere. Here the record's `id` is already a `String` and the wire's is
/// `ReceptiveInactivityIdSchema`, so the copy is exact and there is no policy to state.
///
/// **Hand-written and not reflective**, on its siblings' argument. The stakes are a little different
/// here and worth saying: this table is the one the *import* writes through a derived UUIDv5
/// (`InactivityParser.identifier(date:type:note:)`), so a copy that dropped `note` would not merely
/// lose a field — it would change the identity a later re-import computes, and every pass would append
/// instead of rewriting.
extension ReceptiveInactivityRecord {

    /// The row a sync sends for this record.
    var syncRow: ReceptiveInactivitySyncRow {
        ReceptiveInactivitySyncRow(
            id: id,
            date: date,
            name: name,
            note: note,
            startedAt: startedAt
        )
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// Nothing is defaulted: an entry that arrives with no note and no time stores two NULLs, which is
    /// this schema's word for *nobody supplied one* and a different answer from an empty string. The
    /// date is left as the mapper handed it over and `LocalDatabaseManager.saveSyncReceptiveInactivityRows`
    /// snaps it again on the way in, for the reason every other writer in this app snaps it there.
    init(_ row: ReceptiveInactivitySyncRow) {
        self.init(
            id: row.id,
            date: row.date,
            name: row.name,
            note: row.note,
            startedAt: row.startedAt
        )
    }
}
