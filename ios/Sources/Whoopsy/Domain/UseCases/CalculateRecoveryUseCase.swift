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

        // **No classified night is no recovery.** The HRV window is the night, and the resting rate
        // is read from the night's own samples; an arbitrary "last eight hours" is a default window
        // wearing the same metric tag, and it mixes a different quantity into the same baseline. A day
        // whose night the classifier never saw — no motion, no span, no session — is absent, exactly
        // as `AnalyzeSleepUseCase` leaves that night absent.
        guard let sleepSession else {
            AppLogger.algorithms.notice("""
                Recovery absent: no classified night for \(date.description, privacy: .public). The \
                HRV window is the night, not a default eight hours.
                """)
            return nil
        }

        // The **whole night's** samples, and they are what resting heart rate is read from.
        let sleepStart = sleepSession.startTime
        let sleepEnd = sleepSession.endTime
        let overnightSamples = try await biometricRepository.getSamples(from: sleepStart, to: sleepEnd)

        // **HRV is read from the last deep-sleep run, and the window grows backward when that run
        // cannot support an estimate.** WHOOP's Recovery HRV is measured inside the last slow-wave
        // episode before waking (`docs/PATENTS.md` §1), and this app used to substitute a whole-night
        // RMSSD — a *different quantity*: REM and brief awakenings carry far more beat-to-beat
        // variation, so a whole-night figure runs high, and imported rows store WHOOP's slow-wave
        // number, so a 30-day baseline was mixing two distributions under one metric.
        //
        // **The run alone is not always measurable, and the reason is the strap rather than the
        // stager.** A notification carries at most four R-R intervals and at rest usually one, so a
        // deep run can hold no successive difference at all: measured on a real night, a 28-minute run
        // held zero, and the last run was a single 30-second epoch. Selecting it and then failing the
        // difference gate would report no HRV for a night that had plenty — so the window keeps the
        // anchor's end and moves its start backward until the estimate has support. A night with no
        // classified deep stage still falls back to the whole session and says so in the log.
        let selection = Self.selectHRVWindow(
            anchor: Self.deepestLastRun(in: sleepSession),
            session: DateInterval(start: sleepStart, end: sleepEnd),
            samples: overnightSamples)
        let hrvSamples = selection.samples
        let windowNote = if !selection.hasDeepRun {
            " [no deep run — whole session]"
        } else if selection.expandedBy > 0 {
            " [last deep run + \(Int((selection.expandedBy / 60).rounded())) min earlier]"
        } else {
            " [last deep run]"
        }
        AppLogger.algorithms.notice("""
            Recovery HRV window: \(selection.window.start.description, privacy: .public) →             \(selection.window.end.description, privacy: .public)             (\(Int(selection.window.duration), privacy: .public) s, \(hrvSamples.count, privacy: .public) samples)            \(windowNote, privacy: .public)
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
        //
        // **The day being scored is not its own baseline**, so the window is taken strictly before
        // it — `baselineWindow` is the same function the screen uses for the comparison it prints.
        let wideHistory = try await recoveryRepository.getRecoveryHistory(days: 30, endingOn: date)
        let history = RecoveryScoring.baselineWindow(before: date, in: wideHistory)

        // **A score needs a measured baseline, and there is no substitute for one.** A z-score
        // against a cold-start constant is a default dressed as a measurement: it says today is
        // average against a number the app invented. Below the minimum the day is still a
        // measurement — HRV, resting rate and the rest are real — so it is stored **unscored**, and
        // `RecoveryMetric.hasScore` keeps every ring and trend from drawing the reserved `0` as a
        // result. Storing it is what lets the baseline build: three of these are the three
        // observations that make the fourth day scorable, and without them the rule could never
        // bootstrap. `minimumBaselineDays` is the same threshold the screen's comparison uses.
        let measuredDays = history.filter(\.hasMeasurement).count
        let hasBaseline = measuredDays >= RecoveryScoring.minimumBaselineDays
        if !hasBaseline {
            AppLogger.algorithms.notice("""
                Recovery unscored: \(measuredDays, privacy: .public) measured day(s) before \
                \(date.description, privacy: .public), below the \
                \(RecoveryScoring.minimumBaselineDays, privacy: .public) a baseline needs. HRV and \
                resting rate are stored as a measurement; no score is invented from a cold start.
                """)
        }

        // No sleep session is not an average night. The pivot is the only value for this term that
        // adds nothing to the score, which is what "unknown" should contribute.
        let sleepPerformance = Double(sleepSession.sleepSufficiencyPercentage) / 100.0

        let scoring: RecoveryScoring.Output? = hasBaseline
            ? RecoveryScoring.score(
                RecoveryScoring.Input(
                    history: history,
                    todayHrvValueMs: hrvValueMs,
                    todayHrvMetric: .rmssd,
                    todayRestingHeartRate: restingHR,
                    sleepPerformance: sleepPerformance,
                    fallbackRestingHeartRateBaseline: profile.baselineRhr))
            : nil

        let skinTemps = overnightSamples.compactMap { $0.skinTemperatureCelsius }
        let avgSkinTemp = skinTemps.isEmpty ? nil : BaselineStatisticsMath.mean(skinTemps)
        let skinTempDelta = avgSkinTemp.map { $0 - 33.5 }

        // Nil, not a plausible 97.5. The column is nullable precisely so an absent reading can stay
        // absent; a substituted one is indistinguishable from a measured one downstream.
        let spO2Values = overnightSamples.compactMap { $0.spO2Percentage }
        let avgSpO2 = spO2Values.isEmpty ? nil : BaselineStatisticsMath.mean(spO2Values)

        // **The score's own arithmetic, in the file a phone capture can read.** A "why is my recovery
        // 60%?" question is unanswerable from the figure: the composite is a pair of z-scores plus the
        // sleep term, and the two spreads are what turn today's readings into them. This line prints
        // every input that `BaselineStatisticsMath.computeRecoveryScore` was handed, computed with
        // the same `zScore` it uses — so the answer is a lookup rather than a re-derivation.
        if let scoring {
            let zHRV = BaselineStatisticsMath.zScore(
                value: hrvValueMs, mean: scoring.hrvBaselineMeanMs,
                stdDev: scoring.hrvBaselineStdDevMs)
            let zRHR = BaselineStatisticsMath.zScore(
                value: Double(restingHR), mean: scoring.rhrBaselineMean,
                stdDev: scoring.rhrBaselineStdDev)
            CaptureLog.shared.append(
                "RECOVERY score day=\(date.startOfDay.ISO8601Format()) score=\(scoring.score) "
                    + "hrv=\(hrvValueMs) base=\(String(format: "%.1f", scoring.hrvBaselineMeanMs))"
                    + "±\(String(format: "%.1f", scoring.hrvBaselineStdDevMs)) "
                    + "z=\(String(format: "%.2f", zHRV)) "
                    + "rhr=\(restingHR) base=\(String(format: "%.1f", scoring.rhrBaselineMean))"
                    + "±\(String(format: "%.1f", scoring.rhrBaselineStdDev)) "
                    + "z=\(String(format: "%.2f", zRHR)) "
                    + "sleep=\(String(format: "%.2f", sleepPerformance)) "
                    + "baselineDays=\(measuredDays)")
        }

        let source = hasBaseline ? RecoveryMetric.strapSource : RecoveryMetric.measurementSource
        // **The two audit fields, stamped at the one place a row is built.** The algorithm is the
        // formula this file is applying; the watermark is the newest input it actually read. The
        // night is the whole of this day's input — the HRV window, the resting rate, the spO2 and
        // skin temperature all come from its samples — so the night's own `scoredThrough` is the
        // honest edge, and its end is the fallback for a night that carries none (an imported one,
        // which `RefreshRecoveryUseCase` never re-scores anyway).
        //
        // **It is the same edge the refresher compares against**, which is what makes a stored row
        // self-describing: a launch reads this value and can say whether anything newer has arrived
        // without folding the night to find out.
        let inputEdge = sleepSession.scoredThrough ?? sleepSession.endTime
        let recovery = RecoveryMetric(
            date: date.startOfDay,
            // The reserved `0` on an unscored day. `hasScore` is false for it, so nothing draws it.
            score: scoring?.score ?? 0,
            hrvValueMs: hrvValueMs,
            hrvMetric: .rmssd,
            restingHeartRate: restingHR,
            skinTemperatureCelsius: avgSkinTemp.map { $0.rounded(toPlaces: 1) },
            skinTemperatureBaselineDelta: skinTempDelta.map { $0.rounded(toPlaces: 2) },
            spO2Percentage: avgSpO2?.rounded(toPlaces: 1),
            respiratoryRate: sleepSession.respiratoryRate,
            hrvBaselineDeltaMs: scoring?.hrvBaselineDeltaMs,
            rhrBaselineDeltaBpm: scoring?.rhrBaselineDeltaBpm,
            source: source,
            algorithm: .current,
            scoredThrough: inputEdge
        )

        try await recoveryRepository.saveRecovery(recovery, source: source)
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

    /// Which stretch of the night Recovery HRV is measured over, and the samples inside it.
    ///
    /// **The last deep run is the anchor, and not always the window.** The strap's R-R notifications
    /// are sparse at rest — at most four intervals, usually one — so a deep run can contain no
    /// successive difference at all. A window that cannot clear `minimumRMSSDDifferences` is not a
    /// measurement, so this keeps the anchor's **end** (the instant the patent names) and moves its
    /// **start** backward in `step` increments until the estimator has support. Bounded by the
    /// session: if even the whole session cannot clear the gate, the session is returned and the
    /// caller's guard refuses the row.
    ///
    /// A pure function so §10 can assert the selection with no database and no strap — the reason
    /// `deepestLastRun` is one too.
    public struct HRVWindowSelection: Sendable {
        public let window: DateInterval
        public let samples: [BiometricSample]
        /// How far before the anchor the window had to start. Zero when the anchor itself cleared the
        /// gate, and zero for a night with no deep run (nothing was expanded).
        public let expandedBy: TimeInterval
        /// Whether a classified deep run existed to anchor on. False selects the whole session.
        public let hasDeepRun: Bool
    }

    public static func selectHRVWindow(
        anchor: DateInterval?,
        session: DateInterval,
        samples: [BiometricSample],
        step: TimeInterval = 15 * 60,
        minimumDifferences: Int = HeartRateVariabilityMath.minimumRMSSDDifferences
    ) -> HRVWindowSelection {
        let pool = samples.filter { $0.timestamp >= session.start && $0.timestamp <= session.end }

        func differences(in window: DateInterval) -> Int {
            let runs = pool
                .filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
                .compactMap(\.rrIntervalsMs)
            return HeartRateVariabilityMath.differenceCount(fromRuns: runs)
        }

        func selected(_ window: DateInterval, expandedBy: TimeInterval) -> HRVWindowSelection {
            HRVWindowSelection(
                window: window,
                samples: pool.filter {
                    $0.timestamp >= window.start && $0.timestamp <= window.end
                },
                expandedBy: expandedBy,
                hasDeepRun: anchor != nil)
        }

        guard let anchor else {
            return selected(session, expandedBy: 0)
        }

        let anchored = DateInterval(start: anchor.start, end: anchor.end)
        if differences(in: anchored) >= minimumDifferences {
            return selected(anchored, expandedBy: 0)
        }

        var start = anchor.start
        while start > session.start {
            start = max(session.start, start - step)
            let candidate = DateInterval(start: start, end: anchor.end)
            if differences(in: candidate) >= minimumDifferences {
                return selected(candidate, expandedBy: anchor.start.timeIntervalSince(start))
            }
        }

        // Even the anchor-to-session-start stretch was short. The whole session is the last window
        // with a chance of support, and the caller's guard still has the final word.
        return selected(session, expandedBy: anchor.start.timeIntervalSince(session.start))
    }
}
