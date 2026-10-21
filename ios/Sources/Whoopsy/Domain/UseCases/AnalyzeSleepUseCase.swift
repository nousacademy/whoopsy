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

    /// The span a night is read out of: **9 PM the previous evening to 10 AM**, which is *when the
    /// strap might have been worn* rather than the night itself — `SleepOnsetMath` is what trims it to
    /// the night inside that span.
    ///
    /// A pure function of its two arguments, and on the type for this repo's standing reason: the
    /// runner has no renderer and the window is a rule, so it is asserted rather than trusted.
    /// **Both ends are built from calendar components, never by adding hours to midnight.** Adding
    /// `-11 h` to `startOfDay` lands at 1 PM the previous day, which is what this used to do — a
    /// 21-hour window whose comment claimed 13, and the measured consequence was a real strap
    /// reporting a night from **3:33 PM to 8:38 AM**. Hour arithmetic is wrong across a DST boundary
    /// for the same reason it was wrong here: the clock time is the intent, so the clock time is what
    /// is set.
    public static func readWindow(
        for morningDate: Date, calendar: Calendar = .current
    ) -> (from: Date, to: Date) {
        let morning = calendar.startOfDay(for: morningDate)
        let previousEvening = calendar.date(byAdding: .day, value: -1, to: morning) ?? morning
        let ninePM = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: previousEvening)
            ?? previousEvening
        let tenAM = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: morning) ?? morning
        return (ninePM, tenAM)
    }

    /// A night with too few samples is `nil` — no session is invented and **nothing is written**.
    ///
    /// The previous behaviour built an eight-hour night out of literals and saved it, so a strap
    /// that never came off the charger produced a plausible-looking, permanently stored 8h session
    /// that every later reader (sleep debt, sleep performance, the importer's precedence check)
    /// treated as a measurement. An absent night has to stay absent.
    public func execute(for morningDate: Date = Date()) async throws -> SleepSession? {
        let profile = try await userProfileRepository.getUserProfile()

        // Window: 9:00 PM previous evening to 10:00 AM current day — see `readWindow`, which is where
        // the arithmetic lives because this line used to be `startOfDay − 11 h`, i.e. **1 PM the
        // previous day**, and nothing but a user's own afternoon could see it. A strap worn at 3:33 PM
        // on a quiet afternoon produced a night that began there, so the card read `3:33 PM → 8:38 AM`;
        // the window was 21 hours wide while its own comment claimed 13.
        let calendar = Calendar.current
        let window = Self.readWindow(for: morningDate, calendar: calendar)
        let prevEvening = window.from
        let morningEnd = window.to

        let samples = try await biometricRepository.getSamples(from: prevEvening, to: morningEnd)

        // **The two numbers that decide whether a night exists at all**, at `.notice` so they survive
        // into a log archive: how many samples the window holds and where the first and last of them
        // sit. A dash on the sleep card has three possible causes that look identical on the glass —
        // no samples in the window, fewer than an epoch, or no sustained run — and only this line
        // separates them.
        let firstSample = samples.first?.timestamp.description ?? "none"
        let lastSample = samples.last?.timestamp.description ?? "none"
        AppLogger.algorithms.notice("""
            Sleep analysis: window \(prevEvening.description, privacy: .public) → \
            \(morningEnd.description, privacy: .public), samples=\(samples.count, privacy: .public), \
            first=\(firstSample, privacy: .public), last=\(lastSample, privacy: .public)
            """)

        guard samples.count >= Self.minimumEpochSamples else {
            let minimum = Self.minimumEpochSamples
            AppLogger.algorithms.notice("""
                Sleep analysis: absent — \(samples.count, privacy: .public) samples in the window, below \
                the \(minimum, privacy: .public) an epoch needs.
                """)
            return nil
        }

        // Classify 30-second epochs. Stages are assigned here and **nothing is summed**: the sums are
        // taken below, over the epochs the night actually holds, so a trim cannot leave a duration
        // behind for an epoch it dropped.
        let epochDuration: TimeInterval = 30.0
        let strideSize = 30
        let restHR = Double(profile.restingHeartRate)

        var epochs: [(start: Date, end: Date, stage: SleepStageType)] = []

        // **One line an hour, and it is the instrument this model has never had.** Live samples from
        // the standard heart-rate characteristic carry no accelerometer, so staging here is heart rate
        // alone — and the one parameter deciding where a night starts is how far above resting an
        // epoch's rate may sit before it counts as awake. That number has never been checked against a
        // real wrist: on 2026-10-20 a strap reported a night beginning at **9:06 PM** for a wearer who
        // went to sleep at **1 AM**, and nothing could say whether the 9 PM epochs sat 2 bpm above
        // resting or 20. The curve is what the threshold gets chosen from.
        var hourlyRates: [Int: [Int]] = [:]
        var hourlyAccels: [Int: [Double]] = [:]

        for i in stride(from: 0, to: samples.count, by: strideSize) {
            let epochSamples = Array(samples[i..<min(i + strideSize, samples.count)])
            guard let firstEpochSample = epochSamples.first,
                  let lastEpochSample = epochSamples.last else { continue }

            let avgEpochHR = Double(epochSamples.map { $0.heartRate }.reduce(0, +)) / Double(epochSamples.count)

            // Motion, when the epoch measured any. `accelerationMagnitude` is `nil` on a notification
            // that carried no accelerometer, which is every sample the live `0x2A37` path produces —
            // so the two motion tests below are made only over the epochs that can make them.
            let motions = epochSamples.compactMap(\.accelerationMagnitude)
            let avgAccel: Double? =
                motions.isEmpty ? nil : motions.reduce(0, +) / Double(motions.count)

            // **An absent motion reading drops the motion test rather than failing it**, which is the
            // opposite of what `StressMath.isResting` does with the same absence, and deliberately
            // so. There the gate exists to assert stillness, so unmeasured cannot pass; here the two
            // tests sit *beside* a heart-rate band that can decide alone, and the substituted `0.0`
            // these fields used to carry was already satisfying both of them — a fabricated free-fall
            // reading classified as still, so every existing night staged on heart rate anyway. This
            // makes that behaviour explicit instead of accidental, and the heart rate keeps the vote.
            let motionIsElevated = avgAccel.map { $0 > StressMath.motionCeiling } ?? false
            let motionIsQuiet = avgAccel.map { $0 < 1.05 } ?? true

            let stage: SleepStageType
            if motionIsElevated || avgEpochHR > restHR * 1.25 {
                stage = .awake
            } else if avgEpochHR < restHR * 0.92 && motionIsQuiet {
                stage = .deep
            } else if avgEpochHR > restHR * 1.05 && motionIsQuiet {
                stage = .rem
            } else {
                stage = .light
            }

            epochs.append(
                (start: firstEpochSample.timestamp, end: lastEpochSample.timestamp, stage: stage))

            let hour = calendar.component(.hour, from: firstEpochSample.timestamp)
            hourlyRates[hour, default: []].append(Int(avgEpochHR.rounded()))
            if let avgAccel { hourlyAccels[hour, default: []].append(avgAccel) }
        }

        // The curve, one line an hour. `.notice` so it survives into a log archive read after the run;
        // the ratio against the profile's resting rate is the number the onset threshold is expressed
        // in, so it is printed beside the raw mean rather than left to be recomputed.
        for hour in hourlyRates.keys.sorted() {
            let rates = hourlyRates[hour]!.filter { $0 > 0 }
            guard !rates.isEmpty else { continue }
            let mean = rates.reduce(0, +) / rates.count
            let ratio = String(format: "%.2f", Double(mean) / max(1, Double(profile.restingHeartRate)))
            let accel = hourlyAccels[hour].map {
                String(format: "%.3f", $0.reduce(0, +) / Double($0.count))
            } ?? "none"
            AppLogger.algorithms.notice("""
                Sleep HR curve: \(hour, privacy: .public):00 mean=\(mean, privacy: .public) bpm \
                (\(ratio, privacy: .public)×resting), accel=\(accel, privacy: .public)
                """)
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
        }) else {
            let asleep = epochs.filter { $0.stage != .awake }.count
            AppLogger.algorithms.notice("""
                Sleep analysis: absent — \(epochs.count, privacy: .public) epochs, \
                \(asleep, privacy: .public) not awake, and no run reaching \
                \(Int(SleepOnsetMath.minimumSleepRunSeconds), privacy: .public) s.
                """)
            return nil
        }

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
