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

        // Fetch sleep samples if session exists, else use last night (10 PM to 7 AM)
        let sleepStart = sleepSession?.startTime ?? Calendar.current.date(byAdding: .hour, value: -8, to: date)!
        let sleepEnd = sleepSession?.endTime ?? date
        let overnightSamples = try await biometricRepository.getSamples(from: sleepStart, to: sleepEnd)

        // Extract RR intervals and resting HR
        let rrIntervals = overnightSamples.compactMap { $0.rrIntervalMs }

        // The guard is the *measurement* test, not the interval count, and the difference is load
        // bearing. `calculateRMSSD` returns exactly `0.0` when `filterRRIntervals` leaves fewer than
        // two beats — the 300–2000 ms boundary check and the 20% ectopic rule both drop intervals —
        // while `RecoveryMetric.hasMeasurement` is `hrvValueMs > 0`. Guarding on `!rrIntervals.isEmpty`
        // let one raw interval through to a row that this type's own readers call unmeasured, and
        // `RecoveryViewModel.shouldCompute` then re-scored and rewrote it on every load.
        //
        // The rounding is applied **before** the guard on purpose: the row stores
        // `calculatedRMSSD.rounded(toPlaces: 1)`, so testing the unrounded value would let a reading
        // below 0.05 ms pass here and still be written as `0.0` — unmeasured to every reader. The test
        // has to be made against the value that is actually stored, or the writer and the readers
        // disagree again by one rounding step.
        let hrvValueMs = HeartRateVariabilityMath.calculateRMSSD(from: rrIntervals).rounded(toPlaces: 1)
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
}
