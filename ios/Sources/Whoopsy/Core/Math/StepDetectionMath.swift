import Foundation

/// Steps, counted from wrist acceleration.
///
/// **WHOOP publishes no step model, and this is not a recovery of one.** `docs/PATENTS.md` has no step
/// section, `docs/ALGORITHMS.md` has no step formula, and neither reference in `docs/BLE_PROTOCOL.md` describes
/// how the strap itself counts. So everything below is this app's own calibration — the same bargain
/// `StressMath`, `SleepNeedMath` and `SleepDebtMath` all document — and **this app's number will not
/// agree with the WHOOP app's**. What the strap gives is the raw material: three axes of acceleration
/// at 100 Hz, on both generations and at the same two scales (`docs/BLE_PROTOCOL.md` §6), which is what
/// lets one threshold mean the same thing on a 4.0 and a 5.0 MG.
///
/// ## The rule
///
///     gravity      = the trailing mean of each axis over `gravityWindowSeconds`
///     linear       = the vector (a − gravity), per axis
///     magnitude    = |linear|                                 the signal a step shows up in
///     threshold    = max(minimumPeakAmplitudeG,
///                        mean(magnitude) + thresholdSigmas · sd(magnitude))
///     step         = a local maximum of `magnitude` above `threshold`,
///                    at least `minimumStepIntervalSeconds` after the last accepted one
///
/// **Gravity is removed per axis before the magnitude is taken, and that ordering is the whole
/// method.** A wrist at rest reads ≈1.0 g on whichever axis is pointing down, so the magnitude of the
/// raw vector sits near 1.0 and varies with nothing but orientation; taking `|a| − 1` instead
/// measures how the arm is held, not how it is moving. Subtracting a per-axis mean first leaves the
/// *dynamic* acceleration, whose magnitude is near zero at rest and peaks once per footfall.
///
/// ## The constants, and which of them a capture would fit
///
/// `cadenceBandHz` is conventional and load-bearing rather than decorative: two other constants are
/// **derived** from it, so a cadence the band excludes is excluded in one place instead of three. The
/// lower edge sets the threshold window — one full period of the slowest stride the band admits, so
/// the window always spans at least one step — and the upper edge sets the refractory interval, so a
/// cadence above the band cannot be counted even if the signal were there.
///
/// `minimumPeakAmplitudeG` and `thresholdSigmas` are the two a capture would fit. Neither is
/// measured here, because nothing here has ever seen a wrist: `biometric_samples` holds 0 rows in
/// every database on this machine and no motion batch has ever been decoded from a strap. They are
/// reasoned rather than fitted — 0.05 g is above the noise floor of a resting accelerometer and below
/// the peak of a deliberate arm swing, and 1σ over a two-second window is the standard adaptive-peak
/// form.
///
/// ## What this cannot see
///
/// **A step and a hand gesture are the same signal at this level**, and no threshold separates them:
/// the magnitude peak a footfall makes and the one a wrist flick makes are both 1–3 Hz transients in
/// the same band. So a day spent gesturing counts steps it should not, and a day with the strap loose
/// counts fewer than it should. This is the low specificity every wrist-worn pedometer reports, and
/// it is the reason the number is a reading and not a measurement — it belongs on screen as a figure
/// this app computed, in the voice `MetricDay.vo2Max`'s `(EST.)` already uses.
public enum StepDetectionMath {

    /// One acceleration sample: three axes in g, and when it was measured.
    ///
    /// A plain value rather than a `MotionBatch` slice, because `Core` holds the math and does not
    /// reach into `Data`. The triple is carried raw — the gravity removal is the detector's, so a
    /// caller cannot remove it a second time or skip it.
    public struct Sample: Sendable, Equatable {
        public let seconds: Double
        public let xG: Double
        public let yG: Double
        public let zG: Double

        public init(seconds: Double, xG: Double, yG: Double, zG: Double) {
            self.seconds = seconds
            self.xG = xG
            self.yG = yG
            self.zG = zG
        }
    }

    /// The cadence band a step is counted in, in Hz: **0.5–3.0**, a slow shuffle to a run.
    ///
    /// Two constants are derived from it rather than written down beside it — see `minimumStepIntervalSeconds`
    /// and `thresholdWindowSeconds` — so the band is stated once and the three cannot disagree.
    public static let cadenceBandHz: ClosedRange<Double> = 0.5...3.0

    /// The shortest gap between two accepted peaks, in seconds: one period of the band's **upper**
    /// edge, so 1/3.0 s and a ceiling of 180 steps per minute.
    ///
    /// Derived rather than chosen. Written as a literal it would be free to sit outside the band the
    /// detector claims to read, which is how a refractory interval ends up rejecting the cadence it
    /// was set to admit.
    public static let minimumStepIntervalSeconds: TimeInterval = 1.0 / cadenceBandHz.upperBound

    /// How long a trailing window the gravity estimate is taken over, in seconds.
    ///
    /// One second. Gravity changes only as the wrist reorients, which is far slower than a stride, so
    /// the window is long enough to average it out and short enough to follow a turning arm.
    public static let gravityWindowSeconds: TimeInterval = 1.0

    /// How long a trailing window the adaptive threshold is measured over, in seconds.
    ///
    /// One period of the band's **lower** edge — 2 s — so the window spans at least one complete
    /// stride at any cadence the band admits. Derived for the same reason as the interval above.
    public static let thresholdWindowSeconds: TimeInterval = 1.0 / cadenceBandHz.lowerBound

    /// How many standard deviations above the local mean a peak must reach.
    ///
    /// **This app's own, and the first of the two a capture would fit.** See the type's comment.
    public static let thresholdSigmas: Double = 1.0

    /// The smallest peak the detector will accept, in g, whatever the local spread says.
    ///
    /// **This app's own, and the second of the two a capture would fit.** It exists because a
    /// perfectly still strap has a standard deviation near zero, and `mean + 1σ` of numerical noise is
    /// still noise — without a floor, a strap on a table would count steps from its own quantisation.
    public static let minimumPeakAmplitudeG: Double = 0.05

    /// Counts the steps in a whole series, for a caller that has one.
    ///
    /// A convenience over `Detector` and **not a second implementation** — it drives the same state
    /// machine the incremental path does, one sample at a time, so a whole-array count and a streamed
    /// one cannot disagree. `StepAccumulator` is the streaming caller.
    public static func countSteps(in samples: [Sample], sampleRateHz: Double) -> Int {
        var detector = Detector(sampleRateHz: sampleRateHz)
        for sample in samples {
            _ = detector.accept(xG: sample.xG, yG: sample.yG, zG: sample.zG, seconds: sample.seconds)
        }
        return detector.stepCount
    }

    /// The peak detector, as a state machine.
    ///
    /// A `Sendable` struct with a `mutating func` rather than a free function over an array, for the
    /// reason `WhoopFrameReassembler` is one: the motion arrives as a 100 Hz stream that never ends,
    /// and a day of it is ~26M samples, so the count **cannot** be recomputed on read — it has to be
    /// accumulated as the frames arrive. One sample in, one verdict out.
    ///
    /// The peak test is a one-sample lookahead: a maximum at `t` is only known once `t+1` has arrived.
    /// At 100 Hz that is 10 ms of latency, which is why this can be a state machine at all — a
    /// centred window would need the future.
    public struct Detector: Sendable {
        private let sampleRateHz: Double
        private let gravityWindowSamples: Int
        private let thresholdWindowSamples: Int

        /// A trailing mean over a fixed number of samples, carrying its own running sums so a window
        /// shift is O(1) rather than a re-sum. Four of these per detector, at 100 Hz.
        ///
        /// **Gravity is three windows and not one**, because gravity is a *vector*: the mean has to be
        /// taken per axis and subtracted per axis, since a wrist at rest reads ≈1.0 g on whichever
        /// axis is pointing down. A single window over the three axes' magnitudes would remove a
        /// scalar and leave the orientation in the residual — which is the whole failure the method
        /// exists to avoid.
        private var gravityX: TrailingWindow
        private var gravityY: TrailingWindow
        private var gravityZ: TrailingWindow

        /// The adaptive threshold, over the linear magnitude.
        private var threshold: TrailingWindow

        /// The last two linear magnitudes, because the peak test needs both.
        private var previousMagnitude: Double?
        private var priorMagnitude: Double?

        private var lastStepSeconds: Double = -.infinity

        public private(set) var stepCount: Int = 0

        public init(sampleRateHz: Double) {
            self.sampleRateHz = sampleRateHz
            self.gravityWindowSamples = max(1, Int((gravityWindowSeconds * sampleRateHz).rounded()))
            self.thresholdWindowSamples = max(1, Int((thresholdWindowSeconds * sampleRateHz).rounded()))
            self.gravityX = TrailingWindow(capacity: gravityWindowSamples)
            self.gravityY = TrailingWindow(capacity: gravityWindowSamples)
            self.gravityZ = TrailingWindow(capacity: gravityWindowSamples)
            self.threshold = TrailingWindow(capacity: thresholdWindowSamples)
        }

        /// Accepts one sample and reports whether it completed a step.
        ///
        /// `seconds` is the sample's own time on a monotonic scale — the caller's, not this type's —
        /// because two batches have to be able to arrive with a gap between them and still have that
        /// gap respected by the refractory interval.
        @discardableResult
        public mutating func accept(xG: Double, yG: Double, zG: Double, seconds: Double) -> Bool {
            let lx = xG - gravityX.meanIncluding(xG)
            let ly = yG - gravityY.meanIncluding(yG)
            let lz = zG - gravityZ.meanIncluding(zG)
            let magnitude = (lx * lx + ly * ly + lz * lz).squareRoot()

            let mean = threshold.meanIncluding(magnitude)
            let standardDeviation = threshold.standardDeviationIncluding(magnitude)
            let level = max(
                minimumPeakAmplitudeG,
                mean + thresholdSigmas * standardDeviation)

            defer {
                gravityX.append(xG)
                gravityY.append(yG)
                gravityZ.append(zG)
                threshold.append(magnitude)
                priorMagnitude = previousMagnitude
                previousMagnitude = magnitude
            }

            // The peak is at `previousMagnitude`, and it is only a peak now that this sample has
            // arrived below it. A tie is not a peak: `>` rather than `>=` on both sides, so a flat
            // plateau at the top counts once rather than once per sample.
            guard let peak = previousMagnitude, let before = priorMagnitude,
                  peak > before, peak > magnitude,
                  peak > level,
                  seconds - lastStepSeconds >= minimumStepIntervalSeconds
            else { return false }

            lastStepSeconds = seconds
            stepCount += 1
            return true
        }

        /// Drops the filter state and the count, for a day boundary or a reconnect.
        public mutating func reset() {
            gravityX = TrailingWindow(capacity: gravityWindowSamples)
            gravityY = TrailingWindow(capacity: gravityWindowSamples)
            gravityZ = TrailingWindow(capacity: gravityWindowSamples)
            threshold = TrailingWindow(capacity: thresholdWindowSamples)
            previousMagnitude = nil
            priorMagnitude = nil
            lastStepSeconds = -.infinity
            stepCount = 0
        }
    }

    /// A fixed-capacity trailing window over scalar samples, keeping its own sum and sum of squares.
    ///
    /// Private to this type because it is an implementation detail of the detector rather than a
    /// quantity anything else wants. `meanIncluding(_:)` and `standardDeviationIncluding(_:)` answer
    /// **what the window would be if this sample were in it**, which is what lets a sample be judged
    /// against the window it belongs to rather than the one before it — and lets the append happen
    /// after the verdict, so the peak being tested has not yet been smoothed by itself.
    private struct TrailingWindow: Sendable {
        private let capacity: Int
        private var values: [Double]
        private var nextIndex = 0
        private var count = 0
        private var sum = 0.0
        private var sumOfSquares = 0.0

        init(capacity: Int) {
            self.capacity = capacity
            self.values = Array(repeating: 0, count: capacity)
        }

        func meanIncluding(_ value: Double) -> Double {
            let n = Double(count + 1)
            return (sum + value) / n
        }

        func standardDeviationIncluding(_ value: Double) -> Double {
            let n = Double(count + 1)
            let total = sum + value
            let totalSquares = sumOfSquares + value * value
            // The population form, and clamped at zero because the identity can return a small
            // negative number for a window of identical values — a negative variance would make the
            // standard deviation `NaN` and the threshold with it, which silences the detector for the
            // rest of the day rather than for one sample.
            let variance = max(0, totalSquares / n - (total / n) * (total / n))
            return variance.squareRoot()
        }

        mutating func append(_ value: Double) {
            if count == capacity {
                let evicted = values[nextIndex]
                sum -= evicted
                sumOfSquares -= evicted * evicted
            } else {
                count += 1
            }
            values[nextIndex] = value
            sum += value
            sumOfSquares += value * value
            nextIndex = (nextIndex + 1) % capacity
        }
    }
}
