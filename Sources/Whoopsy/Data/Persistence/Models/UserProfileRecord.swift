import Foundation
import GRDB

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

    public init(
        id: String = "primary",
        maxHeartRate: Int,
        restingHeartRate: Int,
        weightKg: Double? = nil
    ) {
        self.id = id
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
        self.weightKg = weightKg
    }
}