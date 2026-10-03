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

    /// The night's stage timeline — one segment per 30-second epoch, in the order they occurred.
    ///
    /// **It is a JSON-encoded `.text` column, which is the only shape this repo stores an array in.**
    /// `Array` is not a `DatabaseValueConvertible`, so a `[SleepStageSegment]` can only ever be a
    /// record *property* — the same constraint `biometric_samples.rrIntervalsMs` documents, and the
    /// same reason `v12` declares the column `.text`.
    ///
    /// **Optional because the absence is real and common, not because the write may fail.** A night
    /// the strap classified has one; every night the export supplied does not and never can — the
    /// export reports stage *totals* and no timeline — and neither does any row written before `v12`
    /// existed. `AnalyzeSleepUseCase` is the only producer, and this column is what lets the timeline
    /// it builds outlive the moment it was built: until `v12` the segments were computed and then
    /// dropped at the write, so a night re-read from storage came back with `[]` however carefully it
    /// had been staged. An empty array is deliberately **not** written — see
    /// `GRDBSleepRepository.saveSleepSession`, which stores `nil` for one — because "the night had no
    /// stages" and "the night was never staged" are the same thing and only one of them should have a
    /// representation.
    public let sleepStages: [SleepStageSegment]?

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
        sleepStages: [SleepStageSegment]? = nil,
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
        self.sleepStages = sleepStages
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
        case sleepStages = "sleep_stages"
        case source
    }
}
