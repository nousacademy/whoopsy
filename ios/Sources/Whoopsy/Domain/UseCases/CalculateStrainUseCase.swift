import Foundation

public final class CalculateStrainUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let strainRepository: any StrainRepository
    private let userProfileRepository: any UserProfileRepository
    private let motionEpochRepository: any MotionEpochRepository

    public init(
        biometricRepository: any BiometricRepository,
        strainRepository: any StrainRepository,
        userProfileRepository: any UserProfileRepository,
        motionEpochRepository: any MotionEpochRepository
    ) {
        self.biometricRepository = biometricRepository
        self.strainRepository = strainRepository
        self.userProfileRepository = userProfileRepository
        self.motionEpochRepository = motionEpochRepository
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
    /// **The arithmetic is `StrainDayMath`; this type is the I/O around it.** It reads the day's heart
    /// rate and its motion windows, asks the pure model for a result, and writes a row labelled with
    /// the formula that produced it. The motion read is over `[startOfDay, startOfNextDay)` — a
    /// half-open bound, because a window *starting* at midnight belongs to the next day while the
    /// samples read above is inclusive at `endOfDay` and has always been.
    ///
    /// **`scoredThrough` is what makes the row refreshable.** It records the newest input this score
    /// included, so `RefreshStrainUseCase` can tell a day with something new to read from one it has
    /// already scored — without that, every tick would either rewrite every day or none.
    public func execute(for date: Date = Date()) async throws -> StrainScore? {
        let profile = try await userProfileRepository.getUserProfile()
        let startOfDay = date.startOfDay
        let endOfDay = date.endOfDay

        let samples = try await biometricRepository.getSamples(from: startOfDay, to: endOfDay)
        guard !samples.isEmpty else { return nil }

        // A throw is not swallowed. Losing the motion term on a database error would write a row that
        // names `hr-motion-v2` while holding only the heart-rate half — a score confidently labelled
        // with an algorithm it did not run.
        let epochs = try await motionEpochRepository.getMotionEpochs(
            from: startOfDay, to: date.startOfNextDay)

        guard let day = StrainDayMath.compute(
            samples: samples,
            epochs: epochs,
            maxHeartRate: profile.maxHeartRate,
            restingHeartRate: profile.restingHeartRate
        ) else { return nil }

        let totalDurationMinutes = Double(samples.count) / 60.0
        // `nil` when the user has supplied no body weight — see `estimateCalories`, which refuses to
        // substitute one. Note the default 1-second-per-sample assumption folded into the line above:
        // it is a count, not a measured span, and it is kept because changing it would move every
        // stored calorie figure this app has already written.
        let calorieEstimate = StrainAccumulatorMath.estimateCalories(
            heartRate: day.averageHeartRate,
            durationMinutes: totalDurationMinutes,
            weightKg: profile.weightKg,
            restingHR: profile.restingHeartRate
        )

        let finalStrain = StrainScore(
            date: date,
            score: day.score,
            // Measured, even when `day.score` comes out exactly `0.0` because no sample rose above
            // resting: the strap recorded this day, so a zero here is a reading rather than the absence
            // of one. The guard above is the whole distinction.
            hasMeasurement: true,
            rawAccumulatedLoad: day.rawAccumulatedLoad,
            // **The one place in this app where an absence is stored as a `0`.** `strains.kilojoules` is
            // `NOT NULL` and has no readers — no screen draws it, so this figure reaches nothing — and
            // relaxing it to nullable needs a table rebuild rather than an `ALTER`, which is a
            // different and riskier change than the one this arrived with. So when no weight is on file
            // the day row stores `0.0` and *that is a gap rather than a reading*. The live session
            // screen does not inherit it: `LiveSessionAccumulator` carries the `nil` through to the
            // tile, so the figure a user actually sees is absent rather than zero. Recorded in
            // `docs/TODO.md`; do not copy this pattern to a column anything reads.
            activeCalories: ((calorieEstimate ?? 0.0) * 10).rounded() / 10,
            averageHeartRate: day.averageHeartRate,
            maxHeartRate: day.maxHeartRate,
            zones: day.zones,
            motionLoad: day.motionLoad,
            source: Self.deviceSource,
            algorithm: .current,
            scoredThrough: day.scoredThrough
        )

        try await strainRepository.saveStrain(finalStrain, source: Self.deviceSource)
        return finalStrain
    }

    /// The `strains.source` label this type writes — forwarded from `StrainScore`, where a reader uses
    /// it to decide whether a day may be recomputed.
    public static let deviceSource = StrainScore.deviceSource
}
