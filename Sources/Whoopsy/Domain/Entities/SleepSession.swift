import Foundation

/// `Codable` for one reason: a night's segments are persisted as a JSON `.text` column, which is how
/// this repo stores an array (see `SleepRecord.sleepStages` and `biometric_samples.rrIntervalsMs`).
/// The raw value is what is written, so a stored segment names its stage as `"Deep / SWS"` rather
/// than as an index — an index would silently re-point every stored night at a different stage the
/// moment a case is inserted into this enum.
public enum SleepStageType: String, Codable, CaseIterable, Identifiable, Sendable {
    case awake = "Awake"
    case light = "Light"
    case deep = "Deep / SWS"
    case rem = "REM"

    public var id: String { rawValue }
}

public struct SleepStageSegment: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public let stage: SleepStageType

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        stage: SleepStageType
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.stage = stage
    }

    public var durationSeconds: TimeInterval {
        max(0, endTime.timeIntervalSince(startTime))
    }
}

/// Represents an overnight sleep session with stages and performance score.
public struct SleepSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let startTime: Date
    public let endTime: Date
    public let targetSleepNeedSeconds: TimeInterval
    public let lightSleepSeconds: TimeInterval
    public let deepSleepSeconds: TimeInterval
    public let remSleepSeconds: TimeInterval
    public let awakeSeconds: TimeInterval
    /// Optional because the strap does not always yield them: the actigraphy classifier derives a
    /// disturbance count only from the epochs it can read, and the respiratory rate is derived from
    /// the R-R series, so it is absent on any night whose beats cannot support one — which is every
    /// imported night, since the export carries no R-R series at all. A defaulted number here is a
    /// fabricated reading, not a convenience.
    public let disturbanceCount: Int?
    public let respiratoryRate: Double?

    /// WHOOP's own Sleep Consistency for the night, when the night came from an import.
    ///
    /// Optional because two real states have no value: a strap night the app could not read four
    /// priors for, and any row written before `v9` added the column. The screen falls back to
    /// `SleepConsistencyMath` when this is `nil` — see `SleepViewModel.sleepConsistency` — so the
    /// field is the *stored* answer and never the only one.
    public let sleepConsistency: Int?

    /// The night's sleep deficit, in seconds. **Two producers, and they are not the same quantity.**
    ///
    /// It is optional where the stage durations are not, because the stage durations are a breakdown of
    /// this night and a deficit is a running total across nights that no single night's stages can
    /// produce. `nil` is a night with none — one before `v10` added the column — so the screen draws `—`
    /// rather than a `0`, which would be the claim that the user is in perfect sleep credit.
    ///
    /// **An imported night's is WHOOP's own accumulated deficit, stored verbatim, and it is an additive
    /// component of that night's need**: WHOOP publishes `sleep_needed` as a sum containing
    /// `need_from_sleep_debt`, and a fit over the export recovers that term at a coefficient of 0.98. A
    /// **strap** night's is this app's own — `SleepDebtMath`, over the nights before it — and the need
    /// above it is `SleepNeedMath`'s, which **deliberately omits any debt term** (`docs/ALGORITHMS.md` §4).
    ///
    /// So the debt is a part of the need on one producer's nights and not on the other's, and nothing
    /// about the two numbers shows it. `hasWhoopSleepNeed` is what carries the difference.
    public let sleepDebtSeconds: TimeInterval?

    /// Whether `targetSleepNeedSeconds` is **WHOOP's own** figure rather than one this app computed.
    ///
    /// `true` for a night `WhoopExportImporter` wrote — the export's `Sleep need (min)`, stored verbatim
    /// — and `false` for a night `AnalyzeSleepUseCase` classified, whose need is `SleepNeedMath`'s.
    /// It is set on read from `sleeps.source`, the column that is the only thing distinguishing the two
    /// producers, and it is `false` for a row written before that column existed: an unknown provenance
    /// may not be spent as a known one.
    ///
    /// **It exists because one published identity holds for one producer only.** WHOOP's need is a total
    /// that contains its debt term, so `need − debt` is the sum of the other two terms WHOOP names;
    /// this app's need contains no such term, so the same subtraction on a strap night would report a
    /// base requirement short by the whole deficit and then add that deficit back as a component the
    /// need never had. `SleepNeedBreakdown` is the only consumer and it withholds the split when this is
    /// `false`.
    public let hasWhoopSleepNeed: Bool

    public let sleepStages: [SleepStageSegment]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        startTime: Date,
        endTime: Date,
        targetSleepNeedSeconds: TimeInterval = 8.0 * 3600,
        lightSleepSeconds: TimeInterval = 0,
        deepSleepSeconds: TimeInterval = 0,
        remSleepSeconds: TimeInterval = 0,
        awakeSeconds: TimeInterval = 0,
        disturbanceCount: Int? = nil,
        respiratoryRate: Double? = nil,
        sleepConsistency: Int? = nil,
        sleepDebtSeconds: TimeInterval? = nil,
        hasWhoopSleepNeed: Bool = false,
        sleepStages: [SleepStageSegment] = []
    ) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.targetSleepNeedSeconds = targetSleepNeedSeconds
        self.lightSleepSeconds = lightSleepSeconds
        self.deepSleepSeconds = deepSleepSeconds
        self.remSleepSeconds = remSleepSeconds
        self.awakeSeconds = awakeSeconds
        self.disturbanceCount = disturbanceCount
        self.respiratoryRate = respiratoryRate
        self.sleepConsistency = sleepConsistency
        self.sleepDebtSeconds = sleepDebtSeconds
        self.hasWhoopSleepNeed = hasWhoopSleepNeed
        self.sleepStages = sleepStages
    }

    public var totalTimeAsleepSeconds: TimeInterval {
        lightSleepSeconds + deepSleepSeconds + remSleepSeconds
    }

    /// The duration this entity holds for one stage.
    ///
    /// **The one switch that maps a stage to its column.** Three callers need it — the typical-range
    /// card's four rows, the share each of those rows prints, and the window those shares are read
    /// against — and a `switch` repeated at each would be three answers to "which field is Deep",
    /// which is the question a stage enum exists to answer once.
    public func seconds(of stage: SleepStageType) -> TimeInterval {
        switch stage {
        case .awake: return awakeSeconds
        case .light: return lightSleepSeconds
        case .deep: return deepSleepSeconds
        case .rem: return remSleepSeconds
        }
    }

    /// WHOOP's own sum of the two stages it calls **restorative** — SWS and REM. Wake and light sleep
    /// are the other two and neither counts.
    ///
    /// It is a property rather than `deepSleepSeconds + remSleepSeconds` at the call site because the
    /// sleep detail screen prints it as a row *and* reads a window's mean of it, and those two have to
    /// be the same quantity to be comparable. Two spellings of the sum would let one of them drift.
    ///
    /// It carries no band and no target: WHOOP's published guidance is that restorative sleep is
    /// "about 40–50% of total sleep" for most people, which is a population figure and not this
    /// user's own range — so the card reads it against the user's own nights and never against that
    /// number.
    public var restorativeSleepSeconds: TimeInterval {
        deepSleepSeconds + remSleepSeconds
    }

    /// Sleep period time: total sleep plus the wake the classifier placed inside it.
    ///
    /// **This is not time in bed, and it used to be called that.** A night's real in-bed span is
    /// measured by neither path this app has: the strap's timestamps are the epoch window, and the
    /// export's `Sleep onset` is unreliable. What this property is is the sum of every minute the
    /// classifier accounted for — a *lower bound* on time in bed, which is why it takes the
    /// polysomnography name for exactly that quantity (sleep period time = total sleep time + wake)
    /// rather than a name claiming a measurement nobody took.
    ///
    /// Measured over the bundled export: it reproduces WHOOP's `In bed duration` column **exactly on
    /// 904 of 910 nights**, which is not a coincidence — that column is the same sum. On the other
    /// six the column is larger by 3–34 min, and that difference is unstaged time no derivation can
    /// recover, so storing the column was considered and rejected: it would move
    /// `sleepEfficiencyPercentage` on 2 of those 6 and in opposite directions.
    ///
    /// Do **not** replace this with `endTime − startTime`. That span is never shorter than the
    /// classified minutes and is longer on 295 of the same 910 nights, by as much as six hours — one
    /// export row's `Sleep onset` is literally `00:00:00`. The truth lies between the two and the two
    /// can be six hours apart. `docs/TODO.md` carries the full table.
    public var sleepPeriodSeconds: TimeInterval {
        totalTimeAsleepSeconds + awakeSeconds
    }

    public var sleepPerformancePercentage: Int {
        guard targetSleepNeedSeconds > 0 else { return 100 }
        let score = (totalTimeAsleepSeconds / targetSleepNeedSeconds) * 100.0
        return max(0, min(100, Int(score.rounded())))
    }

    public var sleepEfficiencyPercentage: Int {
        guard sleepPeriodSeconds > 0 else { return 100 }
        let eff = (totalTimeAsleepSeconds / sleepPeriodSeconds) * 100.0
        return max(0, min(100, Int(eff.rounded())))
    }
}
