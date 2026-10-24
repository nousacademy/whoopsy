import Foundation
import Whoopsy

/// The day computation through its repository reads and its write — the I/O around `StrainDayMath`.
enum CalculateStrainUseCaseTests {
    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)
        let biometrics = GRDBBiometricRepository(db: db)
        let strains = GRDBStrainRepository(db: db)
        let profile = GRDBUserProfileRepository(db: db)
        let motion = GRDBMotionEpochRepository(db: db)
        let calculate = CalculateStrainUseCase(
            biometricRepository: biometrics,
            strainRepository: strains,
            userProfileRepository: profile,
            motionEpochRepository: motion)

        // ---- A heart-rate-only day, labelled with the algorithm that produced it ----
        let firstDay = StrainTests.day
        let firstStart = firstDay.addingTimeInterval(9 * 3600)
        let firstSamples = StrainTests.samples(from: firstStart, count: 600, heartRate: 120)
        try await biometrics.saveSamples(firstSamples)

        guard let score = try await calculate.execute(for: firstDay) else {
            assertTest(false, "A day with samples scores")
            return
        }
        assertTest(
            score.algorithm == .hrMotionV2,
            "The writer stamps the formula it ran, got \(score.algorithm?.rawValue ?? "nil")")
        assertTest(
            score.source == StrainScore.deviceSource,
            "…and labels the row as this phone's, got \(score.source ?? "nil")")
        assertTest(
            score.motionLoad == 0,
            "A day with no motion windows records a zero motion term, got \(score.motionLoad ?? -1)")
        assertTest(
            score.scoredThrough == firstSamples.last?.timestamp,
            "…and a watermark at the newest sample, so an unchanged day is not recomputed")
        assertTest(
            score.isDeviceScored,
            "…which together make the row repairable by the refresh")

        let stored = try await strains.getLocalStrain(for: firstDay)
        assertTest(
            stored?.algorithm == .hrMotionV2 && stored?.source == StrainScore.deviceSource,
            "The provenance survives the write and the read")

        // ---- A resting day with motion ----
        //
        // The heart rate never leaves baseline, so every bit of load is the wrist's. The score rounds
        // to 0.0 on this fixture — a handful of minutes cannot move a day curve — so the assertion is
        // the load and the stored motion component, not the rounded ring figure.
        let secondDay = Calendar.current.date(byAdding: .day, value: 1, to: firstDay) ?? firstDay
        let secondStart = secondDay.addingTimeInterval(9 * 3600)
        try await biometrics.saveSamples(
            StrainTests.samples(from: secondStart, count: 600, heartRate: 60))
        try await motion.saveMotionEpoch(
            StrainTests.epoch(at: secondStart, magnitude: 1.30))

        guard let resting = try await calculate.execute(for: secondDay) else {
            assertTest(false, "A resting day with a motion window scores")
            return
        }
        assertTest(
            resting.motionLoad == 120,
            "The motion term is stored on the row — 4 × 30 s of running-weight motion, got "
                + "\(resting.motionLoad ?? -1)")
        assertTest(
            resting.rawAccumulatedLoad == 120,
            "…and it is the whole day's load, because the heart rate added nothing, got "
                + "\(resting.rawAccumulatedLoad)")

        // ---- Motion alone is not a day ----
        let thirdDay = Calendar.current.date(byAdding: .day, value: 2, to: firstDay) ?? firstDay
        let thirdStart = thirdDay.addingTimeInterval(9 * 3600)
        try await motion.saveMotionEpoch(StrainTests.epoch(at: thirdStart, magnitude: 1.30))
        let motionOnly = try await calculate.execute(for: thirdDay)
        assertTest(
            motionOnly == nil,
            "A day with motion and no heart rate returns nil rather than a row with a zero rate")
        assertTest(
            try await strains.getLocalStrain(for: thirdDay) == nil,
            "…and writes nothing")
    }
}
