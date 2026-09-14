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
    /// strap actually produced. The strap has no respiratory *sensor* — its rate is derived from the
    /// R-R series, so it exists only for a night whose beats can support one — and a disturbance count
    /// exists only for a night the actigraphy classifier could read. So "no value" is a real and
    /// expected state, not a hole to fill with a plausible number.
    public let respiratoryRate: Double?
    public let disturbanceCount: Int?

    /// WHOOP's own Sleep Consistency for the night, on imported rows.
    ///
    /// Nullable for two separate reasons, and both are real states rather than holes to fill: a row
    /// written before `v9` existed has none, and a strap night the app could not read four priors for
    /// has none either. A `0` here would be a claim — a night maximally inconsistent with its own
    /// history — which is why the column is undefaulted and this property is optional.
    public let sleepConsistency: Int?

    /// WHOOP's accumulated Sleep Debt for the night, in seconds — see `v10_sleep_debt`.
    ///
    /// Optional for two real states rather than one: a row written before `v10` has none, and a strap
    /// night has none either, because the deficit is WHOOP's own accumulation across nights and no
    /// single night's stages produce it. A `0` here would be a claim — a night in perfect credit —
    /// which is why the column is undefaulted.
    public let sleepDebt: Double?

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
        sleepConsistency: Int? = nil,
        sleepDebt: Double? = nil,
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
        self.sleepConsistency = sleepConsistency
        self.sleepDebt = sleepDebt
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
        case sleepConsistency = "sleep_consistency"
        case sleepDebt = "sleep_debt"
        case source
    }
}
