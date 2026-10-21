import Foundation

public final class CalculateRecoveryUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let recoveryRepository: any RecoveryRepository
    private let sleepRepository: any SleepRepository
    private let userProfileRepository: any UserProfileRepository

    public init(
        biometricRepository: any BiometricRepository,
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        userProfileRepository: any UserProfileRepository
    ) {
        self.biometricRepository = biometricRepository
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.userProfileRepository = userProfileRepository
    }

    /// The day's recovery, or `nil` when the night yielded no HRV to score it from.
    ///
    /// **A day with no measurement gets no row.** It used to store a placeholder of zeros rather than
    /// being scored from the profile's cold-start HRV as though the strap had measured it — that
    /// fallback was indistinguishable downstream from a real night, and it silently overwrote a
    /// HealthKit SDNN row for the same day. Absence is now expressed the way `AnalyzeSleepUseCase`
    /// expresses an unclassifiable night: no row, and the optional is the answer. Rows written before
    /// this change are still on disk in the placeholder shape, which is why
    /// `RecoveryMetric.hasMeasurement` stays.
    public func execute(for date: Date = Date()) async throws -> RecoveryMetric? {
        let profile = try await userProfileRepository.getUserProfile()
        let sleepSession = try await sleepRepository.getSleepSession(for: date)

        // Fetch sleep samples if session exists, else use last night (10 PM to 7 AM). These are the
        // **whole night's** samples, and they are what resting heart rate is read from.
        let sleepStart = sleepSession?.startTime ?? Calendar.current.date(byAdding: .hour, value: -8, to: date)!
        let sleepEnd = sleepSession?.endTime ?? date
        let overnightSamples = try await biometricRepository.getSamples(from: sleepStart, to: sleepEnd)

        // **HRV is read from the last deep-sleep run, not from the whole night.** WHOOP's Recovery HRV
        // is measured inside the last slow-wave episode before waking (`docs/PATENTS.md` §1), and this
        // app used to substitute a whole-night RMSSD — which is a *different quantity*: REM and brief
        // awakenings carry far more beat-to-beat variation, so a whole-night figure runs high, and the
        // imported rows store WHOOP's slow-wave number, so a 30-day baseline was mixing two
        // distributions under one metric. Measured on a real strap night: whole-night 105 ms against a
        // 910-night recorded median of 53.
        //
        // A night with no classified deep stage falls back to the whole session and says so in the log,
        // rather than reporting nothing: a night the stager could not resolve still has beats, and the
        // fallback is the previous behaviour stated rather than hidden.
        let hrvWindow = Self.deepestLastRun(in: sleepSession)
            ?? DateInterval(start: sleepStart, end: sleepEnd)
        let hrvSamples = if hrvWindow.start == sleepStart && hrvWindow.end == sleepEnd {
            overnightSamples
        } else {
            try await biometricRepository.getSamples(from: hrvWindow.start, to: hrvWindow.end)
        }
        AppLogger.algorithms.notice("""
            Recovery HRV window: \(hrvWindow.start.description, privacy: .public) →             \(hrvWindow.end.description, privacy: .public)             (\(Int(hrvWindow.duration), privacy: .public) s, \(hrvSamples.count, privacy: .public) samples)            \(Self.deepestLastRun(in: sleepSession) == nil ? " [no deep run — whole session]" : "")
            """)

        // Extract RR intervals and resting HR. Each notification's interval list is one contiguous
        // run of adjacent beats; `calculateRMSSD(fromRuns:)` differences **within** each run and pools
        // the squared differences, so two beats that were never adjacent (across two notifications)
        // are never differenced. Flattening one interval per sample — `$0.rrIntervalMs`, which is
        // `rrIntervalsMs.first` — and handing that to `calculateRMSSD(from:)` is the defect that
        // inflated every strap-computed HRV (measured ~288 ms where the same night's WHOOP figure is
        // ~50 ms), because it differences beats a whole notification apart.
        let rrRuns = hrvSamples.compactMap { $0.rrIntervalsMs }

        // The guard is the *measurement* test, not the interval count, and the difference is load
        // bearing. `calculateRMSSD(fromRuns:)` returns exactly `0.0` when no run survives cleaning
        // with two beats — the 300–2000 ms boundary check and the 20% ectopic rule both drop intervals —
        // while `RecoveryMetric.hasMeasurement` is `hrvValueMs > 0`. Guarding on `!rrRuns.isEmpty`
        // let one raw interval through to a row that this type's own readers call unmeasured, and
        // `RecoveryViewModel.shouldCompute` then re-scored and rewrote it on every load.
        //
        // The rounding is applied **before** the guard on purpose: the row stores
        // `calculatedRMSSD.rounded(toPlaces: 1)`, so testing the unrounded value would let a reading
        // below 0.05 ms pass here and still be written as `0.0` — unmeasured to every reader. The test
        // has to be made against the value that is actually stored, or the writer and the readers
        // disagree again by one rounding step.
        let hrvValueMs = HeartRateVariabilityMath.calculateRMSSD(fromRuns: rrRuns).rounded(toPlaces: 1)

        // **A second gate, and the one a real strap night made necessary.** `hrvValueMs > 0` asks
        // whether the estimator produced a number; it does not ask whether the beats behind it could
        // support one. A notification carries at most four intervals and at rest usually one, so most
        // runs contribute no successive difference and the few that do are dominated by single pairs
        // the ectopic rule cannot judge. Measured on a real 5.0: an overnight HRV came out at a value
        // no resting heart produces, from a night whose runs were almost all length 1.
        let differences = HeartRateVariabilityMath.differenceCount(fromRuns: rrRuns)
        // **The interval distribution, because a value can be wrong for two different reasons.** A
        // figure above the wearer's own historical maximum is either an ectopic pair the 20% rule
        // admits, or intervals that are not what the decoder thinks they are. Logging the raw
        // distribution and the same estimator at two stricter ratios separates those in one run:
        // if a 10% filter lands in the recorded range, the threshold was too loose; if it does not
        // move, the intervals themselves are the problem.
        let allIntervals = rrRuns.flatMap { $0 }.sorted()
        if !allIntervals.isEmpty {
            func pct(_ p: Double) -> Double {
                allIntervals[Int(p * Double(allIntervals.count - 1))]
            }
            AppLogger.algorithms.notice("""
                Recovery HRV intervals: n=\(allIntervals.count, privacy: .public) \
                p5=\(pct(0.05), privacy: .public) median=\(pct(0.5), privacy: .public) \
                p95=\(pct(0.95), privacy: .public) min=\(allIntervals[0], privacy: .public) \
                max=\(allIntervals[allIntervals.count - 1], privacy: .public) \
                rmssd@10%=\(HeartRateVariabilityMath.calculateRMSSD(fromRuns: rrRuns, ratio: 0.10).rounded(toPlaces: 1), privacy: .public) \
                rmssd@15%=\(HeartRateVariabilityMath.calculateRMSSD(fromRuns: rrRuns, ratio: 0.15).rounded(toPlaces: 1), privacy: .public) \
                rmssd@20%=\(HeartRateVariabilityMath.calculateRMSSD(fromRuns: rrRuns, ratio: 0.20).rounded(toPlaces: 1), privacy: .public)
                """)
        }
        AppLogger.algorithms.notice("""
            Recovery HRV: \(hrvValueMs, privacy: .public) ms from \(differences, privacy: .public) \
            successive difference(s) across \(rrRuns.count, privacy: .public) run(s)
            """)
        guard differences >= HeartRateVariabilityMath.minimumRMSSDDifferences else {
            AppLogger.algorithms.notice("""
                Recovery absent: \(differences, privacy: .public) differences is below the \
                \(HeartRateVariabilityMath.minimumRMSSDDifferences, privacy: .public) an RMSSD needs
                """)
            return nil
        }
        guard hrvValueMs > 0 else { return nil }

        let heartRates = overnightSamples.map { $0.heartRate }
        let lowestThirdCount = max(1, heartRates.count / 3)
        let sortedHRs = heartRates.sorted()
        let restingHR = Int(Double(sortedHRs.prefix(lowestThirdCount).reduce(0, +)) / Double(lowestThirdCount))

        // Historical baselines. The strap measures RMSSD, so that is the metric this path scores;
        // `RecoveryScoring` filters history to it so HealthKit-sourced SDNN days cannot leak in.
        let history = try await recoveryRepository.getRecoveryHistory(days: 30)
        // No sleep session is not an average night. The pivot is the only value for this term that
        // adds nothing to the score, which is what "unknown" should contribute.
        let sleepPerformance = sleepSession.map { Double($0.sleepPerformancePercentage) / 100.0 }
            ?? BaselineStatisticsMath.sleepPerformancePivot

        let scoring = RecoveryScoring.score(
            RecoveryScoring.Input(
                history: history,
                todayHrvValueMs: hrvValueMs,
                todayHrvMetric: .rmssd,
                todayRestingHeartRate: restingHR,
                sleepPerformance: sleepPerformance,
                fallbackRestingHeartRateBaseline: profile.baselineRhr))

        let skinTemps = overnightSamples.compactMap { $0.skinTemperatureCelsius }
        let avgSkinTemp = skinTemps.isEmpty ? nil : BaselineStatisticsMath.mean(skinTemps)
        let skinTempDelta = avgSkinTemp.map { $0 - 33.5 }

        // Nil, not a plausible 97.5. The column is nullable precisely so an absent reading can stay
        // absent; a substituted one is indistinguishable from a measured one downstream.
        let spO2Values = overnightSamples.compactMap { $0.spO2Percentage }
        let avgSpO2 = spO2Values.isEmpty ? nil : BaselineStatisticsMath.mean(spO2Values)

        let recovery = RecoveryMetric(
            date: date.startOfDay,
            score: scoring.score,
            hrvValueMs: hrvValueMs,
            hrvMetric: .rmssd,
            restingHeartRate: restingHR,
            skinTemperatureCelsius: avgSkinTemp.map { $0.rounded(toPlaces: 1) },
            skinTemperatureBaselineDelta: skinTempDelta.map { $0.rounded(toPlaces: 2) },
            spO2Percentage: avgSpO2?.rounded(toPlaces: 1),
            respiratoryRate: sleepSession?.respiratoryRate,
            hrvBaselineDeltaMs: scoring.hrvBaselineDeltaMs,
            rhrBaselineDeltaBpm: scoring.rhrBaselineDeltaBpm
        )

        try await recoveryRepository.saveRecovery(recovery)
        return recovery
    }

    /// The **last contiguous run of deep sleep** in a night, or `nil` when the night holds none.
    ///
    /// Adjacent deep segments are merged into one run — `AnalyzeSleepUseCase` writes one segment per
    /// 30-second epoch, so an unmerged read would return the final epoch and nothing else. The run is
    /// the window WHOOP measures Recovery HRV in (`docs/PATENTS.md` §1: "a short window inside the last
    /// slow-wave-sleep episode before waking"), and the whole run is used rather than a sub-window
    /// because the episode is already the shortest stable stretch the stager produces.
    ///
    /// A pure function of the session so §14 can assert the choice without a database — the runner has
    /// no strap, and a selection rule written into `execute` would be a rule nothing can check.
    public static func deepestLastRun(in session: SleepSession?) -> DateInterval? {
        guard let session else { return nil }
        let deep = session.sleepStages
            .filter { $0.stage == .deep }
            .sorted { $0.startTime < $1.startTime }
        guard let first = deep.first else { return nil }

        // Track the latest run as we go, so the return is the **last** one rather than the first: a
        // night has several deep episodes and WHOOP's window is the one nearest waking.
        var runStart = first.startTime
        var runEnd = first.endTime
        for segment in deep.dropFirst() {
            // A gap wider than one epoch (30 s, with a minute of slack) separates two runs.
            if segment.startTime.timeIntervalSince(runEnd) <= 60 {
                runEnd = max(runEnd, segment.endTime)
            } else {
                runStart = segment.startTime
                runEnd = segment.endTime
            }
        }
        return DateInterval(start: runStart, end: runEnd)
    }
}
