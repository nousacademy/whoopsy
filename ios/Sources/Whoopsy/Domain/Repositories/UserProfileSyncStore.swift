import Foundation

/// The one row of `user_profiles`, read and written — the only store in this family with no range.
///
/// **The absences are the protocol.** There is no `from`/`to` and no batch, because a profile is a
/// singleton: the table holds one row keyed `"primary"`, so a window over it would be a window over a
/// set of size one, and a chunk of one is not a batch. A read is *the row* and a save is *the row*, and
/// the engine sends it in a single call.
///
/// **`RecoverySyncStore`'s arguments carry over and are not restated**: its own protocol rather than two
/// methods on `LocalDatabaseManager`, and a second door into a table because `UserProfileRepository`
/// speaks the eleven-field `UserProfile` entity while `user_profiles` stores seven of them — a sync
/// built on the entity would have four fields with no column and no way to say which of them the user
/// actually supplied.
///
/// **The read is optional and the optional is the honest answer.** A profile the user has never filled
/// in is *no row* rather than a row of blanks, exactly as an unmeasured day is on every other table
/// here — and the app's own cold-start 190/60 pair is applied by the client when it merges that absence
/// with what it is drawing, never by a stored row. A read that substituted a default would make the
/// app's own placeholder indistinguishable from a fact the user typed, and the calorie estimate divides
/// by one of these fields.
public protocol UserProfileSyncStore: Sendable {

    /// The one stored profile, or `nil` when this database holds none.
    ///
    /// **No day and no range**: a profile is not filed under a date, and its one date-valued field —
    /// the birthday — is a fact about a person rather than a position in a history.
    func syncProfileRow() async throws -> UserProfileSyncRow?

    /// Insert or replace the profile, in **one** transaction.
    ///
    /// **A whole-row write rather than a patch, which is the shape the wire uses too.** Every column is
    /// written on every save, so a field arriving as `nil` is *cleared* rather than left alone — and
    /// that is the correct reading here rather than a hazard: `nil` on this table means the user has not
    /// supplied that fact, and the app's own rule is that it may not put back a number the user never
    /// gave it. `GRDBUserProfileRepository.save` writes the whole row for the same reason, so the two
    /// agree without either deferring to the other.
    ///
    /// The id is the record's own `"primary"` and is not this protocol's business: the wire has no such
    /// field, and the server addresses a profile by path.
    func saveSyncProfileRow(_ row: UserProfileSyncRow) async throws
}
