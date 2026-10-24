import Foundation
import Whoopsy

/// The 0–10 rating, its five words, and the one arithmetic on it.
enum WorkoutRPETests {
    static func run() async throws {
        // ---- The buckets ----
        let buckets = WorkoutRPE.Bucket.allCases
        assertTest(buckets.count == 5, "Five words, got \(buckets.count)")
        assertTest(
            buckets.map(\.value) == [2, 4, 6, 8, 10],
            "The words map to 2/4/6/8/10 — the scale's ends, so the hardest answer is 10")
        assertTest(
            buckets.map(\.shortLabel) == ["EASY", "MOD", "HARD", "V.HARD", "MAX"],
            "The control's abbreviations are distinct and short enough for five equal segments")
        assertTest(
            WorkoutRPE.Bucket.forValue(6) == .hard,
            "A stored 6 is the hard bucket")
        assertTest(
            WorkoutRPE.Bucket.forValue(7) == nil,
            "A value between buckets belongs to none, so the control draws no selection rather than "
                + "misreporting the answer")

        // ---- The clamp ----
        assertTest(WorkoutRPE.clamped(-3) == 0, "A negative rating clamps to 0")
        assertTest(WorkoutRPE.clamped(11) == 10, "A rating above the scale clamps to 10")
        assertTest(WorkoutRPE.clamped(6) == 6, "A value in range is unchanged")

        // ---- The training load ----
        assertTest(
            WorkoutRPE.perceivedLoad(rpe: 6, durationSeconds: 3_600) == 360,
            "RPE 6 for an hour is 360 AU, got \(WorkoutRPE.perceivedLoad(rpe: 6, durationSeconds: 3_600))")
        assertTest(
            WorkoutRPE.perceivedLoad(rpe: 4, durationSeconds: 0) == 0,
            "A zero-length session has no perceived load")
        assertTest(
            WorkoutRPE.perceivedLoad(rpe: 12, durationSeconds: 600) == 100,
            "The load clamps the rating rather than scaling past the scale")
    }
}
