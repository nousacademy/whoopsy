import Foundation

/// A running step count fed by motion batches, resumable from a stored figure.
///
/// `StepDetectionMath.Detector` is the peak rule; this is the bookkeeping around it. The split is
/// deliberate — the detector answers "was that a step", which is the part a fixture can drive
/// sample-by-sample, and this answers "how many so far today, and how much of the day does that
/// cover", which is the part that has to survive a relaunch.
///
/// ## Why the count is accumulated rather than computed
///
/// A day of 100 Hz motion is roughly **26 million samples**, so a step count cannot be derived on
/// read the way every other figure in this app is. There is no stored series to recompute from: the
/// samples are consumed as they arrive and are never persisted. That is the whole reason this type
/// exists and the reason `stepCounts` stores a number rather than a curve.
///
/// ## What a relaunch costs, stated plainly
///
/// The filter state — the gravity window and the adaptive threshold — lives in memory and **is not
/// persisted**, because persisting it would mean two seconds of raw samples in a table read by
/// nothing else. So a relaunch resumes the count from the stored figure with a **cold filter**: the
/// first `thresholdWindowSeconds` of motion after a launch are judged against a partially-filled
/// window and will under-count. That is a transient of about two seconds per launch, and it is a
/// deliberate trade rather than an oversight — the alternative is a schema for filter state.
///
/// `startingAt:` is what makes the resume work, and it is a parameter rather than something the
/// caller adds afterwards so that a resumed accumulator and a fresh one cannot be confused: the
/// detector's own `stepCount` always counts **this process's** steps, and the reported figure is
/// that plus the baseline.
public struct StepAccumulator: Sendable {

    /// What this process has counted, on top of whatever the day already had.
    private var detector: StepDetectionMath.Detector

    /// The day's count before this process started, read from `stepCounts`.
    private let baselineStepCount: Int

    /// How much motion this process has consumed, in seconds of sample time.
    ///
    /// **Distinct from wall time, and the distinction is load-bearing.** A strap that was disconnected
    /// for six hours and reconnects contributes batches whose sample spans are seconds long; counting
    /// wall time would claim the day was measured across the gap. This grows only by the batches'
    /// own declared spans, so a day the app watched for an hour reports an hour — which is what makes
    /// "0 steps" and "not measured" different answers.
    public private(set) var measuredSeconds: TimeInterval

    /// The day's step count: what was stored before this process, plus what it has counted.
    public var stepCount: Int { baselineStepCount + detector.stepCount }

    /// - Parameters:
    ///   - sampleRateHz: The rate the batches carry. Both generations deliver 100 Hz.
    ///   - baselineStepCount: The day's already-stored count, for a relaunch mid-day. Zero for a fresh
    ///     accumulator, which is the default and the correct value for the first batch of a new day.
    ///   - measuredSeconds: The already-stored measured span, on the same reasoning.
    public init(
        sampleRateHz: Double,
        baselineStepCount: Int = 0,
        measuredSeconds: TimeInterval = 0
    ) {
        self.detector = StepDetectionMath.Detector(sampleRateHz: sampleRateHz)
        self.baselineStepCount = baselineStepCount
        self.measuredSeconds = measuredSeconds
    }

    /// Consumes one batch and returns the day's count after it.
    ///
    /// Takes primitives — three sample arrays, an interval and a start — rather than a batch type,
    /// because `Core` holds the math and imports only `Foundation`: the wire type carrying a
    /// generation lives in `Data/BLE/`, one layer up. This is the same reason `SleepDebtMath` takes
    /// its own `Night` rather than a `SleepSession`.
    ///
    /// - Parameters:
    ///   - accelerometerXG: The batch's three axes, in g, each `sampleIntervalSeconds` apart.
    ///   - sampleIntervalSeconds: The spacing between consecutive samples, from the batch.
    ///   - startSeconds: The batch's first sample on the caller's monotonic scale. Only differences
    ///     matter, so any consistent origin will do — the refractory interval is the only reader.
    /// - Returns: The day's step count after the batch.
    @discardableResult
    public mutating func accept(
        accelerometerXG: [Double],
        accelerometerYG: [Double],
        accelerometerZG: [Double],
        sampleIntervalSeconds: Double,
        startSeconds: Double
    ) -> Int {
        // A batch whose axes disagree in length is not a batch, and pairing them by index is the
        // only reading that means anything. Rather than truncate to the shortest — which would count
        // a partial stride as a whole one and hide the defect — the batch is refused outright and
        // contributes no measured time either, so it is absent rather than half-present.
        let count = accelerometerXG.count
        guard count > 0,
              accelerometerYG.count == count,
              accelerometerZG.count == count,
              sampleIntervalSeconds > 0
        else { return stepCount }

        for index in 0..<count {
            detector.accept(
                xG: accelerometerXG[index],
                yG: accelerometerYG[index],
                zG: accelerometerZG[index],
                seconds: startSeconds + Double(index) * sampleIntervalSeconds)
        }

        measuredSeconds += Double(count) * sampleIntervalSeconds
        return stepCount
    }

    /// Starts a new day: the detector is cleared and **the baseline goes with it**.
    ///
    /// The baseline is a `let` read once at construction, so a rollover cannot be done by this type —
    /// a caller that has crossed midnight builds a new accumulator instead. `reset()` exists for the
    /// other case, a reconnect or a re-arm, where the day is unchanged and only the filter state is
    /// stale.
    public mutating func reset() {
        detector.reset()
    }
}
