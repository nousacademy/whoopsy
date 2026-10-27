import Foundation
import Whoopsy

// MARK: - 15. Stillness from the samples a drain already wrote

/// The block that makes a phone-away night classifiable.
///
/// **The signal is stillness, not movement**, and the strap does not bank `R21` motion records in
/// flash — measured 2026-10-26, where a night with 54,869 samples produced no epoch and therefore no
/// night. `R18` carries mean acceleration X/Y/Z on every record, so the evidence was in the drain all
/// along; these assertions fix the fold from those per-second means onto the classifier's 30-second
/// grid and its magnitude scale.
enum SampleStillnessMathTests {
    static func run() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)   // an exact 30-s boundary

        func sample(_ second: Int, x: Double) -> BiometricSample {
            BiometricSample(
                timestamp: start.addingTimeInterval(TimeInterval(second)),
                heartRate: 60,
                accelerometerX: x,
                accelerometerY: 0.2,
                accelerometerZ: 0.97)
        }

        // A wrist that never moves: every delta is zero, so every window reads exactly 1.0 — the
        // gravity magnitude a motionless strap has, and the still side of every ceiling.
        let still = SampleStillnessMath.epochs(from: (0..<60).map { sample($0, x: 0.1) })
        assertTest(
            still.count == 2 && still.allSatisfy { abs($0.meanMagnitudeG - 1.0) < 1e-9 },
            "A minute of unmoving samples yields two 30-second windows at **1.0 G** — still, because "
                + "gravity is in the magnitude and the second-to-second change is zero "
                + "(\(still.map { $0.meanMagnitudeG }))")

        // A wrist turning over every second: 0.6 g of change each time, which lands well past the
        // 1.25 ceiling the classifier calls "elevated".
        let moving = SampleStillnessMath.epochs(
            from: (0..<60).map { sample($0, x: $0.isMultiple(of: 2) ? 0.0 : 0.6) })
        assertTest(
            moving.allSatisfy { $0.meanMagnitudeG > StressMath.motionCeiling },
            "…while an alternating wrist reads past the elevated ceiling on every window, so the "
                + "same statistic separates the two states the classifier has to tell apart "
                + "(\(moving.map { $0.meanMagnitudeG }))")

        // Four deltas in a window is a gap in the drain, not evidence of stillness.
        let sparse = SampleStillnessMath.epochs(from: (0..<5).map { sample($0 * 5, x: 0.1) })
        assertTest(
            sparse.isEmpty,
            "A window holding fewer than ten deltas yields **no epoch**: missing evidence must not "
                + "arrive as a 1.0 G reading, which every ceiling would call asleep")

        let noAcceleration = SampleStillnessMath.epochs(
            from: (0..<60).map { second in
                BiometricSample(
                    timestamp: start.addingTimeInterval(TimeInterval(second)), heartRate: 60)
            })
        assertTest(
            noAcceleration.isEmpty,
            "…and samples with no acceleration at all yield nothing, which is the truth: heart rate "
                + "is not a stillness signal")

        assertTest(
            SampleStillnessMath.quietDeltaG == 0.05,
            "The mapping constant is one number in one place — `mean |Δa|` 0.05 corresponds to the "
                + "classifier's 1.05 quiet ceiling — so a re-calibration is a single edit rather than "
                + "a second threshold set")

        // ── The merge with the recorder's own epochs ─────────────────────────────────────────────
        //
        // **The choice belongs to the window, not to the night.** These are the two properties the
        // 2026-10-27 overnight run needs: a motion epoch wins its own thirty seconds, and a window
        // only the samples cover still reaches the classifier.
        let sampleWindows = SampleStillnessMath.epochs(from: (0..<180).map { sample($0, x: 0.1) })
        assertTest(
            sampleWindows.count == 6,
            "Three minutes of one-per-second samples is six windows on the recorder's grid "
                + "(got \(sampleWindows.count))")

        let overlapping = MotionEpoch(
            start: sampleWindows[1].start,
            end: sampleWindows[1].end,
            meanMagnitudeG: 1.5,
            maxMagnitudeG: 1.6,
            sampleCount: 3_000)
        let merged = AnalyzeSleepUseCase.stillnessWindows(
            motionEpochs: [overlapping], sampleEpochs: sampleWindows)
        assertTest(
            merged.count == 6 && merged[1].source == .motion && merged[1].meanMagnitudeG == 1.5,
            "…and where both sources hold the same window the **motion** epoch wins it — a 100 Hz "
                + "buffer is stronger evidence than one averaged vector per second "
                + "(\(merged.map { $0.source.rawValue }))")
        assertTest(
            merged.filter { $0.source == .samples }.count == 5,
            "…while every window the recorder did not fill keeps its sample epoch, so an evening of "
                + "`R21` cannot delete the night's `R18`")

        assertTest(
            AnalyzeSleepUseCase.spine(of: [.motion, .motion]) == .motion
                && AnalyzeSleepUseCase.spine(of: [.samples, .samples]) == .samples
                && AnalyzeSleepUseCase.spine(of: [.motion, .samples]) == .merged,
            "The stored spine is drawn from the night's own windows: one source stays itself, and a "
                + "night that needed both says `merged` rather than picking whichever came first")
    }
}
