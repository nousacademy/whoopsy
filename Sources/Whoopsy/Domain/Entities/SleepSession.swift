import Foundation

public enum SleepStageType: String, CaseIterable, Identifiable, Sendable {
    case awake = "Awake"
    case light = "Light"
    case deep = "Deep / SWS"
    case rem = "REM"

    public var id: String { rawValue }
}

public struct SleepStageSegment: Identifiable, Equatable, Sendable {
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
    /// disturbance count only from the epochs it can read, and the strap has no respiratory sensor
    /// at all. A defaulted number here is a fabricated reading, not a convenience.
    public let disturbanceCount: Int?
    public let respiratoryRate: Double?
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
        self.sleepStages = sleepStages
    }

    public var totalTimeAsleepSeconds: TimeInterval {
        lightSleepSeconds + deepSleepSeconds + remSleepSeconds
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
    /// can be six hours apart. `TODO.md` carries the full table.
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
