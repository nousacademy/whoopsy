import Foundation

public final class AnalyzeSleepUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let sleepRepository: any SleepRepository
    private let strainRepository: any StrainRepository
    private let userProfileRepository: any UserProfileRepository

    public init(
        biometricRepository: any BiometricRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        userProfileRepository: any UserProfileRepository
    ) {
        self.biometricRepository = biometricRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
        self.userProfileRepository = userProfileRepository
    }

    /// Samples needed before a night is classified at all: one full 30-second epoch. Below this
    /// there is nothing to average, so the night is reported as absent rather than guessed at.
    static let minimumEpochSamples = 30

    /// A night with too few samples is `nil` — no session is invented and **nothing is written**.
    ///
    /// The previous behaviour built an eight-hour night out of literals and saved it, so a strap
    /// that never came off the charger produced a plausible-looking, permanently stored 8h session
    /// that every later reader (sleep debt, sleep performance, the importer's precedence check)
    /// treated as a measurement. An absent night has to stay absent.
    public func execute(for morningDate: Date = Date()) async throws -> SleepSession? {
        let profile = try await userProfileRepository.getUserProfile()

        // Window: 9:00 PM previous evening to 10:00 AM current day
        let calendar = Calendar.current
        let prevEvening = calendar.date(byAdding: .hour, value: -11, to: morningDate.startOfDay) ?? morningDate
        let morningEnd = calendar.date(byAdding: .hour, value: 10, to: morningDate.startOfDay) ?? morningDate

        let samples = try await biometricRepository.getSamples(from: prevEvening, to: morningEnd)

        guard samples.count >= Self.minimumEpochSamples else { return nil }

        // Classify 30-second epochs. Stages are assigned here and **nothing is summed**: the sums are
        // taken below, over the epochs the night actually holds, so a trim cannot leave a duration
        // behind for an epoch it dropped.
        let epochDuration: TimeInterval = 30.0
        let strideSize = 30
        let restHR = Double(profile.restingHeartRate)

        var epochs: [(start: Date, end: Date, stage: SleepStageType)] = []

        for i in stride(from: 0, to: samples.count, by: strideSize) {
            let epochSamples = Array(samples[i..<min(i + strideSize, samples.count)])
            guard let firstEpochSample = epochSamples.first,
                  let lastEpochSample = epochSamples.last else { continue }

            let avgEpochHR = Double(epochSamples.map { $0.heartRate }.reduce(0, +)) / Double(epochSamples.count)
            let avgAccel = Double(epochSamples.map { $0.accelerationMagnitude }.reduce(0, +)) / Double(epochSamples.count)

            let stage: SleepStageType
            if avgAccel > 1.25 || avgEpochHR > restHR * 1.25 {
                stage = .awake
            } else if avgEpochHR < restHR * 0.92 && avgAccel < 1.05 {
                stage = .deep
            } else if avgEpochHR > restHR * 1.05 && avgAccel < 1.05 {
                stage = .rem
            } else {
                stage = .light
            }

            epochs.append(
                (start: firstEpochSample.timestamp, end: lastEpochSample.timestamp, stage: stage))
        }

        // ── Where the night begins and ends ──────────────────────────────────────────────────────
        //
        // The window read above is 9 PM → 10 AM, which is *when the strap might have been worn* and not
        // the night. A session's boundaries used to be its first and last sample, so a strap put on at
        // 7 PM reported a night beginning at 7 PM — and the `TIME IN BED` card plots exactly this pair,
        // which the export path supplies for real. `SleepOnsetMath` is what makes the strap a producer
        // of the same quantity rather than a second kind of thing.
        //
        // A night whose epochs never hold a sustained run is **absent**: no session is invented and
        // nothing is written. That is the same discipline as `minimumEpochSamples` above, and a
        // separate guard because it answers a different question — that one asks whether there is
        // enough to average, this one whether there is a night here at all.
        guard let period = SleepOnsetMath.sleepPeriod(of: epochs.map {
            SleepOnsetMath.Epoch(start: $0.start, end: $0.end, isAsleep: $0.stage != .awake)
        }) else { return nil }

        // The epochs the detected span contains. Awake epochs **between** the two ends are kept — that
        // is wake inside the sleep period, not edge time — and only what falls outside the span goes.
        let night = epochs.filter { $0.start < period.wake && $0.end > period.onset }
        guard let firstEpoch = night.first, let lastEpoch = night.last else { return nil }

        var lightSec: TimeInterval = 0
        var deepSec: TimeInterval = 0
        var remSec: TimeInterval = 0
        var awakeSec: TimeInterval = 0
        var disturbances = 0
        var stages: [SleepStageSegment] = []

        for epoch in night {
            switch epoch.stage {
            case .awake:
                awakeSec += epochDuration
                // A disturbance is a counted awake epoch, so a dropped one is not a disturbance — it
                // was never in the night to disturb it.
                disturbances += 1
            case .deep: deepSec += epochDuration
            case .rem: remSec += epochDuration
            case .light: lightSec += epochDuration
            }

            stages.append(
                SleepStageSegment(startTime: epoch.start, endTime: epoch.end, stage: epoch.stage))
        }

        // The cycle that ran into this night. `strains` is keyed on `startOfDay(wakeOnset)`, and the
        // cycle ending on morning D is keyed D — so a night keyed D+1 follows the strain row keyed D.
        // That is WHOOP's "previous day's Strain", and the export agrees it is the right lag: on the
        // 909 nights that carry one, previous-day strain fits at R²=0.366 against same-day's 0.161.
        //
        // `.startOfDay` is explicit rather than assumed: `execute(for:)` defaults to a raw `Date()`,
        // and `SleepViewModel` passes exactly that on a first load, so the subtraction would land
        // mid-day and miss the row the keyed lookup needs.
        let previousDay = calendar.date(byAdding: .day, value: -1, to: morningDate.startOfDay) ?? morningDate
        let previousStrain = try await strainRepository.getStrain(for: previousDay)

        // A flat `targetSleepHours` stood here, which reported every night against the same
        // denominator while WHOOP's own need for the same nights ranged 321–650 min. See
        // `SleepNeedMath` for the fit and for what is deliberately left out.
        let targetSleepNeedSeconds = SleepNeedMath.sleepNeedSeconds(
            baselineSeconds: profile.targetSleepHours * 3600,
            previousDayStrain: previousStrain?.score)

        let asleepSeconds = lightSec + deepSec + remSec

        // The strap path's respiratory rate, read off the R-R series by respiratory sinus
        // arrhythmia — WHOOP's own mechanism. The literal `14.4` that once stood here reached the
        // Recovery screen as a measured "14.4 rpm"; what replaced it is a measurement rather than a
        // constant, and `nil` when the beats cannot support one. The export carries no R-R series at
        // all, so a night from the import keeps WHOOP's own stored figure and never comes here.
        let respiratoryRate = RespiratoryRateMath.respiratoryRate(
            from: samples.compactMap { sample in
                guard let intervals = sample.rrIntervalsMs, !intervals.isEmpty else { return nil }
                return RespiratoryRateMath.BeatPacket(
                    arrival: sample.timestamp, rrIntervalsMs: intervals)
            },
            asleepIntervals: stages
                .filter { $0.stage != .awake }
                .map { DateInterval(start: $0.startTime, end: $0.endTime) })

        // The running deficit. This is the only history read on this path, and it is anchored on the
        // night being scored rather than on `Date()` — the night a strap recorded an hour ago and the
        // night it recorded a week ago must walk the same series, which a `Date()` anchor would break
        // for every night but today's.
        //
        // The anchor is `startOfDay`, matching the key `saveSleepSession` writes: the model compares
        // `night.day` against the priors' days, and a raw `Date()` on the day the night is keyed to
        // would be later than the night's own stored key — which is what made a day fall inside its
        // own baseline in `RecoveryScoring.baselineWindow(before:)`, so the same snap is applied here
        // rather than assumed of the caller.
        let history = try await sleepRepository.getSleepHistory(
            days: SleepDebtMath.historyLookbackDays, endingOn: morningDate.startOfDay)
        let sleepDebtSeconds = SleepDebtMath.sleepDebtSeconds(
            for: SleepDebtMath.Night(
                day: morningDate.startOfDay,
                needSeconds: targetSleepNeedSeconds,
                asleepSeconds: asleepSeconds),
            history: history.map {
                SleepDebtMath.Night(
                    day: $0.date,
                    needSeconds: $0.targetSleepNeedSeconds,
                    asleepSeconds: $0.totalTimeAsleepSeconds)
            })

        let session = SleepSession(
            date: morningDate,
            // The detected span, not the window's edges. These are the retaining epochs' own
            // boundaries, which by construction are `period.onset` and `period.wake`.
            startTime: firstEpoch.start,
            endTime: lastEpoch.end,
            targetSleepNeedSeconds: targetSleepNeedSeconds,
            lightSleepSeconds: lightSec,
            deepSleepSeconds: deepSec,
            remSleepSeconds: remSec,
            awakeSeconds: awakeSec,
            // Both derived from the epochs above: a disturbance is a counted awake epoch.
            disturbanceCount: disturbances,
            respiratoryRate: respiratoryRate,
            sleepDebtSeconds: sleepDebtSeconds,
            sleepStages: stages
        )

        try await sleepRepository.saveSleepSession(session)
        return session
    }
}
