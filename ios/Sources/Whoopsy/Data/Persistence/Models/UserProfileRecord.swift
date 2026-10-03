import Foundation
import GRDB

/// The `user_profiles` row — one row, keyed `"primary"`, holding every fact the profile page collects.
///
/// **This record declares no `CodingKeys`, so its property names *are* its column names** — camelCase,
/// matching `maxHeartRate` and `weightKg`. A column named any other way writes nothing and reads `NULL`
/// forever, **with no error raised at any point**; §18 asserts the names against
/// `columnNames(in: "user_profiles")` for exactly that reason. (`RecoveryRecord` is the table that
/// spells it the other way, with an explicit snake_case mapping — check before naming a column.)
///
/// **Every body fact here is optional, and `nil` is a real value rather than "leave it alone".** A save
/// that quietly preserved an old value would make the field unclearable. The two are the same only
/// under `save`, which is INSERT-or-UPDATE over the **whole row** — see `GRDBUserProfileRepository`,
/// where a mapper left carrying fewer fields than this record declares would silently write `NULL` over
/// the rest on every save.
public struct UserProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "user_profiles"

    public var id: String
    public var maxHeartRate: Int
    public var restingHeartRate: Int

    /// The body weight the calorie estimate divides by, or `nil` when the user has not supplied one.
    ///
    /// Optional rather than defaulted, and `v16` adds the column nullable and undefaulted for the same
    /// reason: an absent weight must be an absence the app can see, not a number it invented. A row
    /// written before `v16` and a row the user has not filled in are the same thing here — `NULL` —
    /// because in both cases nobody supplied the fact. See `StrainAccumulatorMath.estimateCalories`
    /// for what the absence costs.
    public var weightKg: Double?

    /// The user's first name, or `nil` when they have not supplied one.
    ///
    /// `v20`. Was an `"Athlete"` initialiser default on `UserProfile` — a name this app typed on the
    /// user's behalf and then drew back inside a field labelled `FIRST NAME`.
    public var name: String?

    /// The user's date of birth, or `nil`.
    ///
    /// `v20`. Was a default of *28 years before `Date()`* — not merely invented but **unstable**,
    /// since it is relative to the moment of construction and would therefore move at every launch.
    /// `.datetime` rather than `.text`, matching how `recoveries.date` and its siblings are declared.
    public var birthDate: Date?

    /// The user's gender, as `UserProfile.Gender`'s raw value, or `nil`.
    ///
    /// `v20`. Stored as text rather than an integer because the raw value is what a reader can see in
    /// `sqlite3` and what survives a case being renamed into a different position. A string this build
    /// has no case for reads back as `nil` rather than being guessed into a neighbour — the rule
    /// `UserDefaultsStrapModelRepository` already follows for a strap generation.
    public var gender: String?

    /// The user's height in centimetres, or `nil`.
    ///
    /// `v20`. Was a `178.0` initialiser default — the exact analogue of the `75.0` weight `v16`
    /// deleted, and the one the mockup *collects*, which is precisely when an invented default becomes
    /// a figure reported back to the user as theirs.
    public var heightCm: Double?

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
