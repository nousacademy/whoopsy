import Foundation

/// The two conversions between the stored profile row and the shape a sync moves.
///
/// **This is the one member of the family where row ↔ record is the identity.** Every other resource
/// carries at least one field the wire spells differently but the record does not — `skinTemp` against
/// `skin_temperature`, `sleepStages` against a JSON string, a `UUID` against a `String`. A profile's
/// eight fields are spelled the same way in SQLite and in the row, because `UserProfileRecord` declares
/// no `CodingKeys` and this type takes the record's property names verbatim. So there is nothing to
/// convert in either direction and the two functions below are a copy — which is a fact about the
/// table rather than a sign that the file is unnecessary: it is what makes a ninth column a compile
/// error here instead of a field silently missing from every synced profile.
///
/// **`id` is carried and is the one field with no wire counterpart.** The server addresses a profile by
/// path, so the `"primary"` key never leaves this device; it rides along because the record declares it
/// and `GRDBUserProfileRepository` saves the whole row, and dropping it here would make the write side
/// of this pair an initialiser that has to invent a value.
///
/// **Hand-written and not reflective**, on its siblings' argument — and the reason it matters most here
/// is that `save` is INSERT-or-UPDATE over the *whole* row: a mapper carrying fewer fields than the
/// record declares silently writes NULL over the rest on every save, and the user sees a form they
/// filled in come back empty on the second launch.
extension UserProfileRecord {

    /// The row a sync sends for this record.
    var syncRow: UserProfileSyncRow {
        UserProfileSyncRow(
            id: id,
            maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate,
            weightKg: weightKg,
            name: name,
            birthDate: birthDate,
            gender: gender,
            heightCm: heightCm
        )
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// Nothing is defaulted and every optional stays optional: `nil` on this table is a real value
    /// rather than *leave it alone*, which is what makes a field clearable. The date is deliberately
    /// **not** snapped — a birthday is a day, but this column is `.datetime` and the app has never
    /// snapped it, so snapping it here would be a second answer to a question `saveUserProfile` already
    /// answers, and it would move an existing row's stored value on the first sync.
    init(_ row: UserProfileSyncRow) {
        self.init(
            id: row.id,
            maxHeartRate: row.maxHeartRate,
            restingHeartRate: row.restingHeartRate,
            weightKg: row.weightKg,
            name: row.name,
            birthDate: row.birthDate,
            gender: row.gender,
            heightCm: row.heightCm
        )
    }
}
