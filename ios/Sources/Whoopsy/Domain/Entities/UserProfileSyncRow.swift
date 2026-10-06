import Foundation

/// The one row of `user_profiles`, in the shape the sync moves — a record, not an entity.
///
/// **It is the only row in this family with no day range and no batch**, and both absences come from the
/// table rather than from the feature. `user_profiles` holds one row keyed `"primary"`, so a read is
/// *the row* and a write is *the row*: there is no window to walk, no chunk to split and nothing for a
/// second resource to be confused with. It is therefore the one resource the engine sends in a single
/// call, and the one whose protocol declares no `from`/`to` parameters.
///
/// **`id` is a member here although the wire has no such field.** The server addresses a profile by
/// *path* — `PUT /v1/profile` is the whole surface, and `UserProfileWrite` carries seven fields and no
/// id — so this is the one row whose identity is a local fact with no wire counterpart. It is carried
/// anyway, on this family's rule that a row takes the record's own property names verbatim: a row that
/// dropped it would make row ↔ record a copy with a hole in it, and `GRDBUserProfileRepository` saves
/// the whole row, so an id reconstructed at the write would be a second answer to a settled question.
///
/// **Every body fact is optional and `nil` is a real value rather than "leave it alone".** `save` is
/// INSERT-or-UPDATE over the whole row, so a mapper that quietly preserved an old value would make the
/// field unclearable — and the app's own rule is the sharper one: `weightKg`, `name`, `birthDate`,
/// `gender` and `heightCm` were each *invented* by an earlier build before `v16`/`v20` made them absent,
/// which is why the app may not put a number back that the user never supplied.
///
/// **The two heart rates are non-optional and that is not an oversight.** They are the inputs a zone
/// table cannot be computed without, so an absent one is not a profile with a gap in it — it is no
/// profile at all. See the `UserProfile` gotcha: the eleven-field entity stores seven, and the two
/// rates are the pair that stayed required.
public struct UserProfileSyncRow: Equatable, Sendable {

    /// The local row's key. `"primary"` by the record's own default; the wire has no such field.
    public let id: String

    /// The two inputs a zone table is computed from. Required, on the record and on the wire alike.
    public let maxHeartRate: Int
    public let restingHeartRate: Int

    /// The body weight the calorie estimate divides by, or `nil` when the user has not supplied one.
    public let weightKg: Double?

    /// The user's first name, or `nil`.
    public let name: String?

    /// The user's date of birth, or `nil`.
    ///
    /// **A `Date` here and a bare `YYYY-MM-DD` on the wire**, which is the one conversion this
    /// resource adds: the column is `.datetime`, the entity reads it as an instant, and
    /// `UserProfileWireMapper` is where the local instant becomes a day key. The local value is not
    /// snapped — a birthday's clock time is meaningless but harmless, and snapping it here would be a
    /// second place the day rule is written down.
    public let birthDate: Date?

    /// `UserProfile.Gender`'s raw value, or `nil`.
    public let gender: String?

    /// The user's height in centimetres, or `nil`.
    public let heightCm: Double?

    public init(
        id: String = "primary",
        maxHeartRate: Int,
        restingHeartRate: Int,
        weightKg: Double? = nil,
        name: String? = nil,
        birthDate: Date? = nil,
        gender: String? = nil,
        heightCm: Double? = nil
    ) {
        self.id = id
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
        self.weightKg = weightKg
        self.name = name
        self.birthDate = birthDate
        self.gender = gender
        self.heightCm = heightCm
    }
}
