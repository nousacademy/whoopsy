import Foundation

public final class AnalyzeSleepUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let sleepRepository: any SleepRepository
    private let strainRepository: any StrainRepository
    private let userProfileRepository: any UserProfileRepository
    private let motionRepository: any MotionEpochRepository

    public init(
        biometricRepository: any BiometricRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        userProfileRepository: any UserProfileRepository,
        motionRepository: any MotionEpochRepository
    ) {
        self.biometricRepository = biometricRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
        self.userProfileRepository = userProfileRepository
        self.motionRepository = motionRepository
    }

    /// Samples needed before a night is classified at all: one full 30-second epoch. Below this
    /// there is nothing to average, so the night is reported as absent rather than guessed at.
    static let minimumEpochSamples = 30

    /// A 30-second window whose mean `|a|` is below this is **still**.
    ///
    /// `|a|` includes gravity, so a motionless strap reads ≈1.0 rather than 0 and a genuine movement
    /// clears 1.05 quickly. This is the number the onset decision thresholds, and it is deliberately
    /// the same one the stage bands use for their stillness requirement — one definition of "quiet".
    public static let motionQuietCeiling: Double = 1.05

    /// How far above the **measured sleeping rate** an epoch may sit and still count as asleep.
    ///
    /// **1.10, not the stage bands' 1.25, and the difference is which rate it multiplies.** The stage
    /// awake test multiplies the profile's *awake* baseline, where 1.25 is a reasonable band; the
    /// onset ceiling multiplies the lowest third of the night, which is already a sleeping rate. On a
    /// real night the measured rate was 51 bpm and the wearer's awake plateau before bed sat at
    /// 58–61: `× 1.25` put the ceiling at 63.75, inside that plateau, and reported a 21:27 onset for
    /// a 22:30 bedtime. `× 1.10` puts it at 56.1 and the same night's onset at 22:44 — and every
    /// ceiling from 1.04× to 1.18× lands in that same 22:44–22:47 window, so the choice is a plateau
    /// rather than a fit to one pair.
    public static let onsetRestingMultiple: Double = 1.10

    /// The same ceiling when the window is too thin to measure a sleeping rate.
    ///
    /// **The profile's rate is an *awake* baseline, so it keeps the stage bands' 1.25.** Applying
    /// 1.10 to it would be the scale error in the other direction: a fixture night at 67 bpm with a
    /// cold-start 60 on file is a plausible sleeping rate, and `60 × 1.10 = 66` would refuse it.
    public static let onsetFallbackMultiple: Double = 1.25

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

    /// The night's own resting heart rate, or `nil` when the window is too thin to estimate one.
    ///
    /// **The lowest third's mean**, which is the same estimator `CalculateRecoveryUseCase` applies to
    /// its overnight samples — one definition of resting heart rate rather than two. It is measured
    /// from the read window rather than read from the profile because the profile's cold start is a
    /// fixed 60 bpm and the classifier's awake test is `rest × 1.25`: with no profile row an awake
    /// evening at 69–75 bpm passed it as sleep and the night began at the 9 PM window edge.
    ///
    /// A pure function so §13 can assert the estimate without a database or a strap.
    public static func restingHeartRate(from samples: [BiometricSample]) -> Int? {
        // Thirty minutes at the live path's ~1 Hz is the floor: below it the lowest third is a
        // handful of beats, and a handful is a reading rather than a resting rate.
        guard samples.count >= 1_800 else { return nil }
        let rates = samples.map(\.heartRate).sorted()
        let lowestThird = max(1, rates.count / 3)
        let mean = Double(rates.prefix(lowestThird).reduce(0, +)) / Double(lowestThird)
        let estimate = Int(mean.rounded())
        // Outside this band the window never settled, and the profile is the safer answer.
        return (30...100).contains(estimate) ? estimate : nil
    }

    /// A night with too few samples is `nil` — no session is invented and **nothing is written**.
    ///
    /// The previous behaviour built an eight-hour night out of literals and saved it, so a strap
    /// that never came off the charger produced a plausible-looking, permanently stored 8h session
    /// that every later reader (sleep debt, sleep performance, the importer's precedence check)
    /// treated as a measurement. An absent night has to stay absent.
    /// The newest instant of input this app holds for a night's window, or `nil` with none.
    ///
    /// **The watermark the sleep page reads before deciding to re-classify**, and the reason it no
    /// longer recomputes on every open: a drain can deliver the rest of a night after its row was
    /// written, so "is there input the stored night has not seen?" is a question two indexed reads can
    /// answer. It is deliberately the same pair `RefreshStrainUseCase` asks of a day.
    public func inputEdge(for morningDate: Date = Date()) async throws -> Date? {
        let window = Self.readWindow(for: morningDate, calendar: Calendar.current)
        var edge: Date?
        if let sample = try await biometricRepository.getLatestSampleTimestamp(
            from: window.from, to: window.to) {
            edge = sample
        }
        if let epoch = try await motionRepository.getLatestMotionEpoch(
            from: window.from, to: window.to) {
            let end = epoch.start.addingTimeInterval(
                MotionLoadMath.coveredSeconds(sampleCount: epoch.sampleCount))
            if end > (edge ?? .distantPast) { edge = end }
        }
        return edge
    }

    /// The newest instant the classified arrays actually reach.
    ///
    /// Static and taking its two arrays so `execute` records what it *saw* rather than what a second
    /// read would say a moment later — the same reason `StrainDayMath` returns its own `scoredThrough`
    /// rather than letting the caller look one up.
    public static func inputEdge(samples: [BiometricSample], epochs: [MotionEpoch]) -> Date? {
        var edge = samples.last?.timestamp
        if let epochEnd = epochs.map(\.end).max(), epochEnd > (edge ?? .distantPast) {
            edge = epochEnd
        }
        return edge
    }

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

        // **No motion, no night.** The classifier used to decide that a night happened from a
        // heart-rate band, and a heart rate cannot separate sleep from lying still awake — the
        // stager's own note says a still, wakeful person classifies as asleep, so a night that never
        // happened would still become a session. The strap's motion is the independent signal: the
        // recorder writes one epoch per 30 seconds, and a window it never filled is reported as
        // absent rather than guessed at from heart rate alone.
        let motionEpochs = try await motionRepository.getMotionEpochs(
            from: prevEvening, to: morningEnd)
        guard !motionEpochs.isEmpty else {
            AppLogger.algorithms.notice("""
                Sleep analysis: absent — no motion epochs in the window. A heart-rate-only night is \
                not a measurement: motion is what separates sleep from lying still awake.
                """)
            return nil
        }

        // Classify 30-second epochs. Stages are assigned here and **nothing is summed**: the sums are
        // taken below, over the epochs the night actually holds, so a trim cannot leave a duration
        // behind for an epoch it dropped.
        //
        // **The epoch grid is the motion recorder's, not a count of samples.** A stride of 30 samples
        // is 30 seconds only if the samples arrived a second apart, and the sleep window is exactly
        // where that assumption is least safe — a gap in the live stream turns one "epoch" into
        // minutes. `RecordMotionUseCase` writes true 30-second windows, so the grid is wall time.
        //
        // **Two references, because the two questions are different.** "Is this person asleep?" is
        // decided by motion and, secondarily, by a heart rate below the night's own measured ceiling;
        // "which stage?" keeps the profile's resting rate. Using the measured rate for both was tried
        // on a real night and collapsed deep sleep to 0.04 h, while the profile's 60 left 4.8 h —
        // neither real. The profile is the stage bands' baseline and the ceiling's fallback.
        let measuredRest = Self.restingHeartRate(from: samples)
        let restHR = Double(profile.restingHeartRate)
        let onsetCeiling: Double = if let measuredRest {
            Double(measuredRest) * Self.onsetRestingMultiple
        } else {
            Double(profile.restingHeartRate) * Self.onsetFallbackMultiple
        }
        AppLogger.algorithms.notice("""
            Sleep staging: bands at \(restHR, privacy: .public) bpm (profile), onset ceiling \
            \(onsetCeiling, privacy: .public) bpm (measured \(measuredRest ?? -1, privacy: .public) bpm; -1 means the profile fallback)
            """)

        var epochs: [(
            start: Date, end: Date, stage: SleepStageType, avgHR: Double, motionMean: Double
        )] = []

        // The hourly curve carries **motion beside heart rate** — the two signals the onset decision
        // reads, printed together so a night where they disagree is visible in one line.
        var hourlyRates: [Int: [Int]] = [:]
        var hourlyAccels: [Int: [Double]] = [:]

        // One pass over the HR samples, bucketed into the recorder's 30-second windows. A pointer
        // rather than a filter per epoch: thirteen hours of 1 Hz samples against ~1,500 epochs is
        // otherwise tens of millions of comparisons.
        var sampleIndex = 0
        for motion in motionEpochs {
            var epochSamples: [BiometricSample] = []
            while sampleIndex < samples.count, samples[sampleIndex].timestamp < motion.end {
                if samples[sampleIndex].timestamp >= motion.start {
                    epochSamples.append(samples[sampleIndex])
                }
                sampleIndex += 1
            }
            guard !epochSamples.isEmpty else { continue }

            let avgEpochHR = Double(epochSamples.map { $0.heartRate }.reduce(0, +))
                / Double(epochSamples.count)
            let motionMean = motion.meanMagnitudeG
            let motionIsElevated = motionMean > StressMath.motionCeiling
            let motionIsQuiet = motionMean < Self.motionQuietCeiling

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
                (start: motion.start, end: motion.end, stage: stage, avgHR: avgEpochHR,
                 motionMean: motionMean))

            let hour = calendar.component(.hour, from: motion.start)
            hourlyRates[hour, default: []].append(Int(avgEpochHR.rounded()))
            hourlyAccels[hour, default: []].append(motionMean)
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
            // **Asleep means quiet and below the night's ceiling — motion first.** A heart rate alone
            // called an awake evening asleep; a still strap is what makes the claim a measurement. An
            // epoch that moved is awake even when its rate sat low, which is the case a no-sleep night
            // presents.
            SleepOnsetMath.Epoch(
                start: $0.start, end: $0.end,
                isAsleep: $0.motionMean < Self.motionQuietCeiling
                    && $0.avgHR < onsetCeiling)
        }) else {
            let asleep = epochs.filter {
                $0.motionMean < Self.motionQuietCeiling && $0.avgHR < onsetCeiling
            }.count
            AppLogger.algorithms.notice("""
                Sleep analysis: absent — \(epochs.count, privacy: .public) motion epochs, \
                \(asleep, privacy: .public) quiet and below the ceiling, and no quiet run reaching \
                \(Int(SleepOnsetMath.minimumSleepRunSeconds), privacy: .public) s. A night whose \
                motion never settles is not a night.
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
                awakeSec += epoch.end.timeIntervalSince(epoch.start)
                // A disturbance is a counted awake epoch, so a dropped one is not a disturbance — it
                // was never in the night to disturb it.
                disturbances += 1
            case .deep: deepSec += epoch.end.timeIntervalSince(epoch.start)
            case .rem: remSec += epoch.end.timeIntervalSince(epoch.start)
            case .light: lightSec += epoch.end.timeIntervalSince(epoch.start)
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

        // One wide read of both tables. The personal baseline needs 28 prior **nights**, which can
        // span more than 28 calendar days when the strap was not worn; the debt model keeps its own
        // 30-day read by narrowing this same result rather than issuing a second query.
        let historyDays = max(
            SleepNeedBaselineMath.baselineHistoryLookbackDays, SleepDebtMath.historyLookbackDays)
        let wideHistory = try await sleepRepository.getSleepHistory(
            days: historyDays, endingOn: morningDate.startOfDay)
        let strainHistory = try await strainRepository.getStrainHistory(
            days: historyDays, endingOn: morningDate.startOfDay)
        let strainByDay = Dictionary(
            strainHistory.map { ($0.date.startOfDay, $0) }, uniquingKeysWith: { _, last in last })
        let previousStrain = strainByDay[previousDay.startOfDay]

        // The individual's own baseline, learned from their prior stored needs with the strain term
        // removed. Age is population context only: it is the cold-start value below seven prior
        // nights, and the floor/ceiling around the learned median. The night being scored is
        // excluded, and so is any prior night without a strain row — its need is the bare baseline,
        // which this estimator cannot tell apart from an unmeasured day.
        let priorNights = wideHistory
            .filter { $0.date.startOfDay < morningDate.startOfDay }
            .sorted { $0.date < $1.date }
        let baselineSeconds = SleepNeedBaselineMath.personalBaselineSeconds(
            for: priorNights.map { prior in
                let priorDay = calendar.date(
                    byAdding: .day, value: -1, to: prior.date.startOfDay) ?? prior.date
                return SleepNeedBaselineMath.NeedNight(
                    needSeconds: prior.targetSleepNeedSeconds,
                    previousDayStrain: strainByDay[priorDay.startOfDay]?.score)
            },
            age: profile.age)

        // The fitted strain term is unchanged — see `SleepNeedMath`. Imported nights never reach
        // this path; they keep WHOOP's stored need.
        let targetSleepNeedSeconds = SleepNeedMath.sleepNeedSeconds(
            baselineSeconds: baselineSeconds,
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

        // The running deficit, narrowed from the same wide read to the model's own 30-day window. It
        // is anchored on the night being scored rather than on `Date()` — the night a strap recorded
        // an hour ago and the night it recorded a week ago must walk the same series, which a
        // `Date()` anchor would break for every night but today's.
        //
        // The anchor is `startOfDay`, matching the key `saveSleepSession` writes: the model compares
        // `night.day` against the priors' days, and a raw `Date()` on the day the night is keyed to
        // would be later than the night's own stored key — which is what made a day fall inside its
        // own baseline in `RecoveryScoring.baselineWindow(before:)`, so the same snap is applied here
        // rather than assumed of the caller.
        let debtCutoff = calendar.date(
            byAdding: .day, value: -SleepDebtMath.historyLookbackDays, to: morningDate.startOfDay)
            ?? morningDate
        let debtHistory = wideHistory.filter { $0.date >= debtCutoff }
        let sleepDebtSeconds = SleepDebtMath.sleepDebtSeconds(
            for: SleepDebtMath.Night(
                day: morningDate.startOfDay,
                needSeconds: targetSleepNeedSeconds,
                asleepSeconds: asleepSeconds),
            history: debtHistory.map {
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
            sleepStages: stages,
            // **The decision records itself.** The version is what the sleep page compares against to
            // decide whether a re-classification is owed, and the watermark is the newest input this
            // run actually saw — both taken from the arrays it just classified rather than re-read,
            // so they cannot describe a different window than the night does.
            algorithm: .current,
            scoredThrough: Self.inputEdge(samples: samples, epochs: motionEpochs)
        )

        try await sleepRepository.saveSleepSession(session)
        return session
    }
}
