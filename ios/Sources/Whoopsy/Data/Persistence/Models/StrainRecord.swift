import Foundation
import GRDB

public struct StrainRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "strains"

    public var date: Date
    public var strainScore: Double
    public var kilojoules: Double
    public var averageHeartRate: Int
    public var maxHeartRate: Int

    /// Whether `strainScore` came from samples the strap recorded. Added by migration
    /// `v7_strain_measurement_marker`; see `StrainScore.hasMeasurement` for why a score alone cannot
    /// carry this.
    public var hasMeasurement: Bool

    /// Where the row came from, when that is worth recording — see `RecoveryRecord.source`. This
    /// model has no `CodingKeys` because every other property's name is already its column name, and
    /// `source` is a single word that maps identically either way.
    public var source: String?

    public init(
        date: Date,
        strainScore: Double,
        kilojoules: Double,
        averageHeartRate: Int,
        maxHeartRate: Int,
        hasMeasurement: Bool,
        source: String? = nil
    ) {
        self.date = date
        self.strainScore = strainScore
        self.kilojoules = kilojoules
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.hasMeasurement = hasMeasurement
        self.source = source
    }
}