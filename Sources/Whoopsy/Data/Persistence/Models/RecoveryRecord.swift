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

    public init(
        date: Date,
        recoveryScore: Int,
        restingHeartRate: Int,
        hrvValueMs: Double,
        hrvMetric: HRVMetric = .rmssd,
        skinTemp: Double? = nil,
        spo2: Double? = nil,
        respiratoryRate: Double? = nil,
        source: String? = nil
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
    }
}

/// Storage conformance lives in the Data layer so `HRVMetric` itself stays free of GRDB — the
/// domain type has no business knowing how it is persisted. GRDB derives this from the `String`
/// raw value; the extension is empty on purpose.
extension HRVMetric: DatabaseValueConvertible {}
