import Foundation
import GRDB

public struct RecoveryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "recoveries"

    public var date: Date
    public var recoveryScore: Int
    public var restingHeartRate: Int
    /// The HRV reading, in milliseconds. The column is named for the value, not the metric, because
    /// more than one metric reaches this table — `hrvMetric` says which one.
    public var hrvValueMs: Double
    public var hrvMetric: HRVMetric
    public var skinTemp: Double?
    public var spo2: Double?
    public var respiratoryRate: Double?

    /// Where the row came from, when that is worth recording. NULL means the app measured it — the
    /// strap path and the HealthKit importer both leave it unset. Only a bulk import labels itself,
    /// so that hundreds of historical rows stay identifiable. Nothing reads this column yet.
    public var source: String?

    /// Which formula produced the row, as `RecoveryAlgorithm`'s raw value. NULL on every row written
    /// before `v39`, which is why a read resolves it to an optional rather than defaulting to the
    /// current version — an unknown provenance may not be spent as a known one.
    public var algorithm: String?

    /// The newest input instant this row included. **`scored_through`, snake_case, unlike
    /// `strains`' camelCase** — this record declares its `CodingKeys`, so the column name is decided
    /// there, and writing `scoredThrough` here would create a different column and leave the
    /// migration's one unread. Local-only: it never leaves the phone, because it describes what this
    /// installation has read rather than a field of the record.
    public var scoredThrough: Date?

    public init(
        date: Date,
        recoveryScore: Int,
        restingHeartRate: Int,
        hrvValueMs: Double,
        hrvMetric: HRVMetric = .rmssd,
        skinTemp: Double? = nil,
        spo2: Double? = nil,
        respiratoryRate: Double? = nil,
        source: String? = nil,
        algorithm: String? = nil,
        scoredThrough: Date? = nil
    ) {
        self.date = date
        self.recoveryScore = recoveryScore
        self.restingHeartRate = restingHeartRate
        self.hrvValueMs = hrvValueMs
        self.hrvMetric = hrvMetric
        self.skinTemp = skinTemp
        self.spo2 = spo2
        self.respiratoryRate = respiratoryRate
        self.source = source
        self.algorithm = algorithm
        self.scoredThrough = scoredThrough
    }

    enum CodingKeys: String, CodingKey {
        case date
        case recoveryScore = "recovery_score"
        case restingHeartRate = "resting_heart_rate"
        case hrvValueMs = "hrv_value_ms"
        case hrvMetric = "hrv_metric"
        case skinTemp = "skin_temperature"
        case spo2 = "spo2_percentage"
        case respiratoryRate = "respiratory_rate"
        case source
        case algorithm
        case scoredThrough = "scored_through"
    }
}

/// Storage conformance lives in the Data layer so `HRVMetric` itself stays free of GRDB — the
/// domain type has no business knowing how it is persisted. GRDB derives this from the `String`
/// raw value; the extension is empty on purpose.
extension HRVMetric: DatabaseValueConvertible {}
