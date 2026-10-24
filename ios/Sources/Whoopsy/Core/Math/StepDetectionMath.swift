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
///     smoothed     = the trailing mean of `magnitude` over `smoothingWindowSeconds`
///     threshold    = max(minimumPeakAmplitudeG,
///                        mean(smoothed) + thresholdSigmas · sd(smoothed))
///     candidate    = a local maximum of `smoothed` above `threshold`,
///                    at least `minimumStepIntervalSeconds` after the last candidate
///     step         = a candidate counted once it belongs to a train of
///                    `minimumRhythmicPeaks` candidates within `rhythmWindowSeconds`
///                    whose consecutive intervals do not differ by more than
///                    `intervalRatioTolerance`
///
/// **Gravity is removed per axis before the magnitude is taken, and that ordering is the whole
/// method.** A wrist at rest reads ≈1.0 g on whichever axis is pointing down, so the magnitude of the
/// raw vector sits near 1.0 and varies with nothing but orientation; taking `|a| − 1` instead
/// measures how the arm is held, not how it is moving. Subtracting a per-axis mean first leaves the
/// *dynamic* acceleration, whose magnitude is near zero at rest and peaks once per footfall.
///
/// **Two gates sit after the amplitude test, and neither is optional.** The smoothing removes the
/// sample-scale ripple that turns one lobe into several maxima. The rhythm gate is what separates a
/// footfall from a gesture: the magnitude peak of a single reach and the peak of a step are the same
/// shape at this level, and only their *sequence* differs. A candidate is not counted when it is
/// found — a lone peak, or a pair, is a wrist being moved — it is counted when the detector can see
/// it was one of a regular train, and the earlier candidates in that train are counted at the same
/// moment. The cost is the first two steps of every train, which is what a wrist-worn pedometer has
/// to pay for not counting its wearer's hands.
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
/// **A single step and a single hand gesture are the same signal at this level**, and no amplitude
/// threshold separates them: the magnitude peak a footfall makes and the one a wrist flick makes are
/// both 1–3 Hz transients. The rhythm gate is what buys back most of the difference — a gesture is
/// isolated, a walk is a train — but the gate is a shape test, not a measurement. A repeated gesture
/// at walking cadence (chopping, drumming, scrubbing) still counts, and a walk with a long pause
/// every third step can fail to establish a train. So the number is a reading and not a measurement:
/// it belongs on screen as a figure this app computed, in the voice `MetricDay.vo2Max`'s `(EST.)`
/// already uses.
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

    /// How long a trailing window the magnitude is smoothed over before it is judged, in seconds.
    ///
    /// **The first of the two gates that stop one stride counting several times.** At 100 Hz a
    /// one-sample peak test sees the sensor's own ripple, and a single lobe of a stride can carry
    /// several such maxima. A ten-sample mean is 0.1 s, which removes the sample-scale wiggle while
    /// leaving a genuine bump's amplitude intact — the convolution takes a σ = 0.04 s bump to ≈ 79 %
    /// of its peak, and the floor has 34 % of margin below the 0.1 g fixture's smoothed 0.067 g.
    ///
    /// **The window shifts the reported peak later by about half its width.** The peak of a smoothed
    /// signal is not the peak of the raw one, and nothing here depends on the instant — the count is
    /// the product — but a caller reading step times would have to subtract that delay.
    public static let smoothingWindowSeconds: TimeInterval = 0.1

    /// How long a train of peaks may span and still count as a rhythm, in seconds.
    ///
    /// Three seconds is two periods of the band's lower edge plus a margin, so a shuffle at the
    /// slowest admitted cadence can still establish a train, while an isolated gesture never does.
    public static let rhythmWindowSeconds: TimeInterval = 3.0

    /// The longest interval a rhythm may contain, in seconds.
    ///
    /// One period of the band's **lower** edge — 2 s — derived for the same reason as the other two:
    /// a cadence the band excludes is excluded by the band, not by a second literal. A gap longer
    /// than this ends the train rather than stretching it.
    public static let maximumIntervalSeconds: TimeInterval = 1.0 / cadenceBandHz.lowerBound

    /// How many candidate peaks a train needs before any of them is counted.
    ///
    /// Three, not two: a pair of transients is what a wrist does when it is moved once and put down
    /// — the count would begin on every reach. Three peaks also give two intervals, which is the
    /// smallest number from which a rhythm can be distinguished from an accident.
    public static let minimumRhythmicPeaks: Int = 3

    /// How far apart two consecutive intervals of a train may be, as a ratio.
    ///
    /// `max / min <= 2.0`. A walk's intervals wander — a step over a kerb is longer — but not by a
    /// factor of two; a hand tapping a table can be just as regular, which is the specificity no
    /// wrist-worn pedometer has and is why the number is a reading rather than a measurement.
    public static let intervalRatioTolerance: Double = 2.0

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
        private let smoothingWindowSamples: Int

        /// A trailing mean over a fixed number of samples, carrying its own running sums so a window
        /// shift is O(1) rather than a re-sum. Five of these per detector, at 100 Hz.
        ///
        /// **Gravity is three windows and not one**, because gravity is a *vector*: the mean has to be
        /// taken per axis and subtracted per axis, since a wrist at rest reads ≈1.0 g on whichever
        /// axis is pointing down. A single window over the three axes' magnitudes would remove a
        /// scalar and leave the orientation in the residual — which is the whole failure the method
        /// exists to avoid.
        private var gravityX: TrailingWindow
        private var gravityY: TrailingWindow
        private var gravityZ: TrailingWindow

        /// The low-pass over the linear magnitude, and the adaptive threshold over its output.
        private var smoothing: TrailingWindow
        private var threshold: TrailingWindow

        /// The last two **smoothed** magnitudes, because the peak test needs both.
        private var previousMagnitude: Double?
        private var priorMagnitude: Double?

        /// Candidate peaks held while a train is being established, oldest first.
        ///
        /// At most `minimumRhythmicPeaks` of them: a failed confirmation keeps the newest two, so a
        /// rough patch in a walk can start the next train without losing the peaks that might belong
        /// to it. A candidate here has cleared the amplitude and refractory tests; it is a step only
        /// once the train is known.
        private var pending: [Double] = []

        /// The mean interval of the train currently open.
        ///
        /// Used to test the next interval, so a train that opens in a walk stays open through the
        /// small variation of a real gait. Blended rather than replaced, which lets a walk's cadence
        /// drift without every drift closing the train.
        private var referenceInterval: Double?

        /// Whether a train has been established. While true, each candidate counts immediately.
        private var isOpen = false

        /// The last **candidate's** instant, for the refractory.
        ///
        /// **Not the last counted step's**, which is what it used to be: a candidate is deferred
        /// until its train is known, and a refractory measured against counted steps would let two
        /// candidates 0.2 s apart into the queue before either was counted.
        private var lastCandidateSeconds: Double = -.infinity

        public private(set) var stepCount: Int = 0

        public init(sampleRateHz: Double) {
            self.sampleRateHz = sampleRateHz
            self.gravityWindowSamples = max(1, Int((gravityWindowSeconds * sampleRateHz).rounded()))
            self.thresholdWindowSamples = max(1, Int((thresholdWindowSeconds * sampleRateHz).rounded()))
            self.smoothingWindowSamples = max(1, Int((smoothingWindowSeconds * sampleRateHz).rounded()))
            self.gravityX = TrailingWindow(capacity: gravityWindowSamples)
            self.gravityY = TrailingWindow(capacity: gravityWindowSamples)
            self.gravityZ = TrailingWindow(capacity: gravityWindowSamples)
            self.smoothing = TrailingWindow(capacity: smoothingWindowSamples)
            self.threshold = TrailingWindow(capacity: thresholdWindowSamples)
        }

        /// Accepts one sample and reports whether it completed a step.
        ///
        /// `seconds` is the sample's own time on a monotonic scale — the caller's, not this type's —
        /// because two batches have to be able to arrive with a gap between them and still have that
        /// gap respected by the refractory interval.
        ///
        /// **`true` means at least one step was counted on this sample, not exactly one.** A train
        /// that establishes on its third candidate counts all three at once, so the first `true` of
        /// a walk can carry three steps. Callers read `stepCount`; the Bool is for a caller that only
        /// wants to know whether anything changed.
        @discardableResult
        public mutating func accept(xG: Double, yG: Double, zG: Double, seconds: Double) -> Bool {
            let lx = xG - gravityX.meanIncluding(xG)
            let ly = yG - gravityY.meanIncluding(yG)
            let lz = zG - gravityZ.meanIncluding(zG)
            let magnitude = (lx * lx + ly * ly + lz * lz).squareRoot()

            // Smooth first, and judge only the smoothed series below: the threshold, the peak test and
            // the window it is compared against must all describe the same signal.
            let smoothed = smoothing.meanIncluding(magnitude)
            let mean = threshold.meanIncluding(smoothed)
            let standardDeviation = threshold.standardDeviationIncluding(smoothed)
            let level = max(
                minimumPeakAmplitudeG,
                mean + thresholdSigmas * standardDeviation)

            defer {
                gravityX.append(xG)
                gravityY.append(yG)
                gravityZ.append(zG)
                smoothing.append(magnitude)
                threshold.append(smoothed)
                priorMagnitude = previousMagnitude
                previousMagnitude = smoothed
            }

            // The peak is at `previousMagnitude`, and it is only a peak now that this sample has
            // arrived below it. A tie is not a peak: `>` rather than `>=` on both sides, so a flat
            // plateau at the top counts once rather than once per sample.
            guard let peak = previousMagnitude, let before = priorMagnitude,
                  peak > before, peak > smoothed,
                  peak > level,
                  seconds - lastCandidateSeconds >= minimumStepIntervalSeconds
            else { return false }

            lastCandidateSeconds = seconds
            let counted = offer(seconds)
            stepCount += counted
            return counted > 0
        }

        /// Feeds one candidate peak to the rhythm gate and returns how many steps it released.
        ///
        /// The gate is a small state machine rather than a windowed function because it has to run
        /// forever on a stream. Its states are: **nothing** (no candidate yet), **pending** (one or
        /// two candidates, not yet enough to call a train) and **open** (a train has been confirmed,
        /// so each new candidate is the next step).
        ///
        /// A gap longer than `maximumIntervalSeconds` closes the train, which is what keeps two
        /// isolated gestures a minute apart from ever pairing up. Two intervals that disagree by more
        /// than `intervalRatioTolerance` close it too: that is the shape of a hand moving to a task
        /// and back, not of a stride.
        private mutating func offer(_ seconds: Double) -> Int {
            if let last = pending.last, seconds - last > maximumIntervalSeconds {
                pending.removeAll()
                referenceInterval = nil
                isOpen = false
            }

            if let last = pending.last {
                let interval = seconds - last
                guard interval >= minimumStepIntervalSeconds,
                      interval <= maximumIntervalSeconds
                else {
                    pending = [seconds]
                    referenceInterval = nil
                    isOpen = false
                    return 0
                }

                if isOpen, let reference = referenceInterval,
                   !isConsistent(interval, reference) {
                    // The train broke. This peak starts the next one rather than joining a rhythm
                    // it no longer fits.
                    pending = [seconds]
                    referenceInterval = nil
                    isOpen = false
                    return 0
                }
            }

            pending.append(seconds)

            // An open train: the peak is the next step, counted now.
            if isOpen {
                if let reference = referenceInterval, pending.count >= 2 {
                    let interval = pending[pending.count - 1] - pending[pending.count - 2]
                    referenceInterval = (reference + interval) / 2
                }
                pending = [seconds]
                return 1
            }

            guard pending.count >= minimumRhythmicPeaks else { return 0 }

            let first = pending[0]
            let second = pending[1]
            let third = pending[2]
            let firstInterval = second - first
            let secondInterval = third - second

            guard third - first <= rhythmWindowSeconds,
                  isConsistent(firstInterval, secondInterval)
            else {
                // Keep the newest two: they may be the start of the next train, and dropping all
                // three would make a burst of irregular peaks unable to ever settle.
                pending = Array(pending.suffix(2))
                return 0
            }

            referenceInterval = (firstInterval + secondInterval) / 2
            pending = [third]
            isOpen = true
            return minimumRhythmicPeaks
        }

        /// Whether two intervals are close enough to be the same rhythm.
        private func isConsistent(_ first: Double, _ second: Double) -> Bool {
            guard first > 0, second > 0 else { return false }
            return max(first, second) <= min(first, second) * intervalRatioTolerance
        }

        /// Drops the filter state and the count, for a day boundary or a reconnect.
        public mutating func reset() {
            gravityX = TrailingWindow(capacity: gravityWindowSamples)
            gravityY = TrailingWindow(capacity: gravityWindowSamples)
            gravityZ = TrailingWindow(capacity: gravityWindowSamples)
            smoothing = TrailingWindow(capacity: smoothingWindowSamples)
            threshold = TrailingWindow(capacity: thresholdWindowSamples)
            previousMagnitude = nil
            priorMagnitude = nil
            pending.removeAll()
            referenceInterval = nil
            isOpen = false
            lastCandidateSeconds = -.infinity
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
