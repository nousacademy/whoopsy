import Foundation
import Whoopsy

// MARK: - 15. Which spine made the night

/// The block that keeps a weaker night from looking like a stronger one.
///
/// **Two signals can evidence the same stillness.** A connected phone records `R21` motion epochs; a
/// phone-away night can only offer the accelerometer carried by `R18`. The stage model is the same
/// either way, so `SleepAlgorithm` stays one value — but a row that did not say which evidence backed
/// it would make a night of per-second means indistinguishable from one of 100 Hz epochs.
enum SleepStillnessSpineTests {
    static func run() async throws {
        assertTest(
            SleepStillnessSpine.allCases == [.motion, .samples, .merged]
                && SleepStillnessSpine.motion.rawValue == "motion"
                && SleepStillnessSpine.samples.rawValue == "samples"
                && SleepStillnessSpine.merged.rawValue == "merged",
            "The spine names every answer it can have — the two sources and the night that needed "
                + "both — with the strings the column stores")

        assertTest(
            SleepStillnessSpine(stored: "samples") == .samples
                && SleepStillnessSpine(stored: "motion") == .motion
                && SleepStillnessSpine(stored: "merged") == .merged
                && SleepStillnessSpine(stored: nil) == nil
                && SleepStillnessSpine(stored: "something-else") == nil,
            "…and reads back only what it wrote: an unrecognised string — a build that no longer "
                + "exists here — resolves to `nil` rather than to a guess")

        // A round trip through the real table, because the column name is decided by `CodingKeys`
        // rather than by the property name (`stillness_spine`), and a mismatch there fails at the
        // insert rather than at the read.
        let db = LocalDatabaseManager(inMemory: true)
        let repository = GRDBSleepRepository(db: db)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))

        func session(_ spine: SleepStillnessSpine?) -> SleepSession {
            SleepSession(
                date: day,
                startTime: day.addingTimeInterval(-8 * 3600),
                endTime: day,
                lightSleepSeconds: 4 * 3600,
                deepSleepSeconds: 2 * 3600,
                remSleepSeconds: 3600,
                awakeSeconds: 600,
                stillnessSpine: spine,
                algorithm: .current)
        }

        try await repository.saveSleepSession(session(.samples))
        let fromSamples = try await repository.getSleepSession(for: day)
        assertTest(
            fromSamples?.stillnessSpine == .samples,
            "A night saved from the **sample spine** reads back as one — the column stores the "
                + "string and the entity returns the type "
                + "(\(String(describing: fromSamples?.stillnessSpine)))")

        try await repository.saveSleepSession(session(.motion))
        let fromMotion = try await repository.getSleepSession(for: day)
        assertTest(
            fromMotion?.stillnessSpine == .motion && fromMotion?.algorithm == .current,
            "…and re-saving the same day from the motion spine flips only that field: the algorithm "
                + "version is unchanged, because both spines run the same stager and only the "
                + "evidence differs")

        try await repository.saveSleepSession(session(.merged))
        let fromBoth = try await repository.getSleepSession(for: day)
        assertTest(
            fromBoth?.stillnessSpine == .merged,
            "…and a night that needed both sources round-trips as `merged` — the value that exists "
                + "because a phone connected for part of a night and away for the rest is one night, "
                + "not two kinds of evidence ("
                + "\(String(describing: fromBoth?.stillnessSpine)))")

        try await repository.saveSleepSession(session(nil))
        let imported = try await repository.getSleepSession(for: day)
        assertTest(
            imported?.stillnessSpine == nil,
            "A row with no spine — every imported night, and every row older than `v38` — reports "
                + "**no spine** rather than claiming the strongest one")
    }
}
