import Foundation
import GRDB

public struct SleepRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "sleeps"

    public var date: Date
    public let startTime: Date
    public let endTime: Date
    public let sleepPerformance: Double
    public let totalSleepNeeded: Double
    public let lightSleep: Double
    public let deepSleep: Double
    public let remSleep: Double
    public let awakeTime: Double

    /// Both default to nil, and both are nullable in the schema, because this table records what the
    /// strap actually produced. The strap path has no respiratory sensor, and a disturbance count
    /// exists only for a night the actigraphy classifier could read — so "no value" is a real and
    /// expected state, not a hole to fill with a plausible number.
    public let respiratoryRate: Double?
    public let disturbanceCount: Int?

    /// Where the row came from, when that is worth recording — see `RecoveryRecord.source`.
    public let source: String?

    public init(
        date: Date,
        startTime: Date,
        endTime: Date,
        sleepPerformance: Double,
        totalSleepNeeded: Double,
        lightSleep: Double,
        deepSleep: Double,
        remSleep: Double,
        awakeTime: Double,
        respiratoryRate: Double? = nil,
        disturbanceCount: Int? = nil,
        source: String? = nil
    ) {
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.sleepPerformance = sleepPerformance
        self.totalSleepNeeded = totalSleepNeeded
        self.lightSleep = lightSleep
        self.deepSleep = deepSleep
        self.remSleep = remSleep
        self.awakeTime = awakeTime
        self.respiratoryRate = respiratoryRate
        self.disturbanceCount = disturbanceCount
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case date
        case startTime = "start_time"
        case endTime = "end_time"
        case sleepPerformance = "sleep_performance"
        case totalSleepNeeded = "total_sleep_needed"
        case lightSleep = "light_sleep"
        case deepSleep = "deep_sleep"
        case remSleep = "rem_sleep"
        case awakeTime = "awake_time"
        case respiratoryRate = "respiratory_rate"
        case disturbanceCount = "disturbance_count"
        case source
    }
}
