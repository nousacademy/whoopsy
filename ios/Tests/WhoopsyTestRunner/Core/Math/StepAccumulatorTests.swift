import Foundation
import Whoopsy

// MARK: - 16. The accumulator

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum StepAccumulatorTests {
    static func run() async throws {
        // MARK: The accumulator

        // The same waveform the pedometer block walked, rebuilt from the shared builder.
        let walking = StepTests.bumpTrain(bumps: 20, amplitudeG: 0.3)
        let xs = walking.map(\.xG)
        let ys = walking.map(\.yG)
        let zs = walking.map(\.zG)

        var whole = StepAccumulator(sampleRateHz: 100)
        whole.accept(
            accelerometerXG: xs, accelerometerYG: ys, accelerometerZG: zs,
            sampleIntervalSeconds: 0.01, startSeconds: 0)
        assertTest(whole.stepCount == 20, "The accumulator counts the same twenty steps the detector does")
        assertTest(
            whole.stepCount == StepDetectionMath.countSteps(in: walking, sampleRateHz: 100),
            "…and its count equals the whole-array convenience's, because that convenience drives this "
                + "same state machine — a second implementation is what this assertion would catch")
        assertTest(
            whole.measuredSeconds == Double(xs.count) * 0.01,
            "The measured span is the batch's own sample time — \(xs.count) samples 0.01 s apart")

        // The same samples in two batches, the second's clock continuing the first's. An accumulator that
        // reset its filter per batch, or ignored `startSeconds`, would differ here and nowhere else.
        var split = StepAccumulator(sampleRateHz: 100)
        let half = xs.count / 2
        split.accept(
            accelerometerXG: Array(xs[0..<half]), accelerometerYG: Array(ys[0..<half]),
            accelerometerZG: Array(zs[0..<half]), sampleIntervalSeconds: 0.01, startSeconds: 0)
        split.accept(
            accelerometerXG: Array(xs[half...]), accelerometerYG: Array(ys[half...]),
            accelerometerZG: Array(zs[half...]), sampleIntervalSeconds: 0.01,
            startSeconds: Double(half) * 0.01)
        assertTest(
            split.stepCount == whole.stepCount,
            "Two batches carrying one waveform count what one batch of it counts: the filter state is the "
                + "accumulator's and survives the batch boundary, and `startSeconds` is what places the "
                + "second batch on the same clock as the first")
        assertTest(
            abs(split.measuredSeconds - whole.measuredSeconds) < 1e-9,
            "…and the two spans sum to the one — within a nanosecond, because each batch's span is its "
                + "own rounded product and the sum of two rounded products need not be the rounded sum")

        var resumed = StepAccumulator(sampleRateHz: 100, baselineStepCount: 5049, measuredSeconds: 3600)
        assertTest(
            resumed.stepCount == 5049,
            "A resumed accumulator reports the stored day's count before any motion arrives — which is "
                + "what makes a relaunch mid-day continue the count rather than restart it")
        resumed.accept(
            accelerometerXG: xs, accelerometerYG: ys, accelerometerZG: zs,
            sampleIntervalSeconds: 0.01, startSeconds: 0)
        assertTest(
            resumed.stepCount == 5049 + 20,
            "…and adds this process's steps on top of it rather than replacing them")
        assertTest(
            resumed.measuredSeconds == 3600 + Double(xs.count) * 0.01,
            "…and its measured span likewise, so the day's coverage is the stored figure plus what this "
                + "process watched — a day the app saw for an hour reports an hour")

        var refusing = StepAccumulator(sampleRateHz: 100, baselineStepCount: 100, measuredSeconds: 60)
        refusing.accept(
            accelerometerXG: [1, 1, 1], accelerometerYG: [1, 1], accelerometerZG: [1, 1, 1],
            sampleIntervalSeconds: 0.01, startSeconds: 0)
        assertTest(
            refusing.stepCount == 100 && refusing.measuredSeconds == 60,
            "A batch whose axes disagree in length is refused outright — no steps and no measured time, "
                + "so it is absent rather than half-present, where truncating to the shortest axis would "
                + "count a partial stride as a whole one and hide the defect")
        refusing.accept(
            accelerometerXG: [], accelerometerYG: [], accelerometerZG: [],
            sampleIntervalSeconds: 0.01, startSeconds: 0)
        assertTest(
            refusing.measuredSeconds == 60,
            "An empty batch contributes nothing, including no measured time")
        refusing.accept(
            accelerometerXG: [1], accelerometerYG: [1], accelerometerZG: [1],
            sampleIntervalSeconds: 0, startSeconds: 0)
        assertTest(
            refusing.measuredSeconds == 60,
            "A batch whose spacing is zero is refused as well: it cannot be placed on a clock, and "
                + "counting its samples at any assumed rate would invent the time they cover")

        var resetting = StepAccumulator(sampleRateHz: 100, baselineStepCount: 42, measuredSeconds: 600)
        resetting.accept(
            accelerometerXG: xs, accelerometerYG: ys, accelerometerZG: zs,
            sampleIntervalSeconds: 0.01, startSeconds: 0)
        assertTest(resetting.stepCount == 42 + 20, "A reset fixture counts on top of its baseline")
        resetting.reset()
        assertTest(
            resetting.stepCount == 42,
            "`reset()` clears the detector and keeps the baseline: the day's stored count is not this "
                + "process's to drop, and a day boundary needs a new accumulator — which is what makes the "
                + "baseline a `let` rather than something a rollover could zero by accident")
        assertTest(
            resetting.measuredSeconds == 600 + Double(xs.count) * 0.01,
            "…and the measured span is untouched by it, because the span is the day's coverage and not "
                + "filter state")
    }
}
