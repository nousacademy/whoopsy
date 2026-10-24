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

    /// The motion term's weighted seconds, from `StrainDayMath.Day.motionLoad`. **Local-only** — it is
    /// an audit component of this phone's computation, not a field the wire carries.
    public var motionLoad: Double?

    /// The newest input instant this row's score included, and therefore the refresh watermark. See
    /// `StrainScore.scoredThrough`. **Local-only**: it describes what this phone has read, not what
    /// the day holds.
    public var scoredThrough: Date?

    /// The formula that produced `strainScore`, as `StrainAlgorithm.rawValue`.
    ///
    /// **Synced**, unlike the two fields above: it is this app's statement about the row, and every
    /// consumer of a stored score needs to know what the number means. `nil` on a row synced from a
    /// client older than `v35`; preserved rather than cleared when one arrives.
    public var algorithm: String?

    public init(
        date: Date,
        strainScore: Double,
        kilojoules: Double,
        averageHeartRate: Int,
        maxHeartRate: Int,
        hasMeasurement: Bool,
        source: String? = nil,
        motionLoad: Double?,
        scoredThrough: Date?,
        algorithm: String?
    ) {
        self.date = date
        self.strainScore = strainScore
        self.kilojoules = kilojoules
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.hasMeasurement = hasMeasurement
        self.source = source
        self.motionLoad = motionLoad
        self.scoredThrough = scoredThrough
        self.algorithm = algorithm
    }
}