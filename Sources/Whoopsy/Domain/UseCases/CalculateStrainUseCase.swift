import Foundation

public final class CalculateStrainUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let strainRepository: any StrainRepository
    private let userProfileRepository: any UserProfileRepository

    public init(
        biometricRepository: any BiometricRepository,
        strainRepository: any StrainRepository,
        userProfileRepository: any UserProfileRepository
    ) {
        self.biometricRepository = biometricRepository
        self.strainRepository = strainRepository
        self.userProfileRepository = userProfileRepository
    }

    /// The day's strain, or `nil` when the strap recorded no samples for it.
    ///
    /// **A day with no measurement gets no row.** It used to store a placeholder — `score: 0.0` with
    /// `hasMeasurement` cleared — so a reader could tell a measured rest day from nothing at all.
    /// Nothing needed telling: every reader already tested the flag, so an absent row and a
    /// placeholder behaved identically wherever one was read, and the row's only other effect was to
    /// make an unmeasured day look like stored data. Absence is expressed the way
    /// `AnalyzeSleepUseCase` expresses an unclassifiable night — no row, and the optional is the
    /// answer.
    ///
    /// Two readers did *not* test the flag and were relying on the row, which is what `nil` fixes:
    /// `WhoopExportImporter` skipped a day whose strain row merely existed, so a placeholder blocked
    /// WHOOP's genuine `Day Strain` for that day from ever being imported, and `StrainViewModel`
    /// treated a stored placeholder as a settled day and never recomputed it.
    ///
    /// Rows written before this change are still on disk in the placeholder shape, which is why
    /// `StrainScore.hasMeasurement` and the `strains.hasMeasurement` column both stay.
    public func execute(for date: Date = Date()) async throws -> StrainScore? {
        let profile = try await userProfileRepository.getUserProfile()
        let startOfDay = date.startOfDay
        let endOfDay = date.endOfDay

        let samples = try await biometricRepository.getSamples(from: startOfDay, to: endOfDay)
        let zones = StrainAccumulatorMath.computeZones(maxHR: profile.maxHeartRate, restHR: profile.restingHeartRate)

        guard !samples.isEmpty else { return nil }

        var zoneDurations: [HeartRateZoneIndex: TimeInterval] = [
            .zone1: 0, .zone2: 0, .zone3: 0, .zone4: 0, .zone5: 0
        ]
        var totalAccumulatedLoad = 0.0
        var hrSum = 0
        var maxObservedHR = 0

        for i in 0..<samples.count {
            let sample = samples[i]
            let hr = sample.heartRate
            hrSum += hr
            if hr > maxObservedHR { maxObservedHR = hr }

            // Estimate duration between samples (default 1 second if continuous)
            let duration: TimeInterval = (i > 0) ? min(5.0, sample.timestamp.timeIntervalSince(samples[i - 1].timestamp)) : 1.0

            let (zoneIdx, load) = StrainAccumulatorMath.loadDelta(for: hr, zones: zones, durationSeconds: duration)
            if let zoneIdx = zoneIdx {
                zoneDurations[zoneIdx, default: 0] += duration
                totalAccumulatedLoad += load
            }
        }

        let avgHR = hrSum / samples.count
        let strainScoreVal = StrainAccumulatorMath.calculateStrainScore(from: totalAccumulatedLoad)

        let totalDurationMinutes = Double(samples.count) / 60.0
        let activeCalories = StrainAccumulatorMath.estimateCalories(
            heartRate: avgHR,
            durationMinutes: totalDurationMinutes,
            age: profile.age,
            weightKg: profile.weightKg,
            restingHR: profile.restingHeartRate
        )

        let updatedZones = zones.map { zone in
            HeartRateZone(
                index: zone.index,
                lowerBpm: zone.lowerBpm,
                upperBpm: zone.upperBpm,
                durationSeconds: zoneDurations[zone.index] ?? 0
            )
        }

        let finalStrain = StrainScore(
            date: date,
            score: strainScoreVal,
            // Measured, even when `strainScoreVal` comes out exactly `0.0` because no sample reached
            // zone 1: the strap recorded this day, so a zero here is a reading rather than the
            // absence of one. The guard above is the whole distinction.
            hasMeasurement: true,
            rawAccumulatedLoad: totalAccumulatedLoad,
            activeCalories: (activeCalories * 10).rounded() / 10,
            averageHeartRate: avgHR,
            maxHeartRate: maxObservedHR,
            zones: updatedZones
        )

        try await strainRepository.saveStrain(finalStrain)
        return finalStrain
    }
}
