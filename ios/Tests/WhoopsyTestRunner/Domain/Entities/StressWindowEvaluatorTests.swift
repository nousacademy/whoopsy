import Foundation
import Whoopsy

// MARK: - 14. The stress window's gates and its score

/// One evaluator, two callers: the stored day and the live monitor.
///
/// The stored day is asserted through `AnalyzeStressUseCase` in `HomeStressMonitorTests`; what is
/// asserted here is the shared rule itself, because **the live page scores windows without the use
/// case** and a second copy of the gate order there would be a second definition of "a scorable
/// window". The fallback is the reason the live path exists at all: the live heart-rate record has no
/// accelerometer lane, so without `motionMagnitudes` every window built from live samples would be
/// refused as unmeasured.
enum StressWindowEvaluatorTests {
    static func run() async throws {
        let baseline = StressBaseline(
            rmssd: BaselineStatisticsMath.baseline(
                [44, 47, 50, 53, 56], fallbackMean: 0, fallbackStdDev: 0),
            heartRate: BaselineStatisticsMath.baseline(
                [58, 59, 60, 61, 62], fallbackMean: 0, fallbackStdDev: 0))

        let start = Date(timeIntervalSince1970: 1_700_000_000)

        /// A window of `count` one-second samples whose successive differences are `rmssd` exactly.
        ///
        /// `accelerometerZ` is what decides the stillness gate from the samples; passing `nil` leaves
        /// the whole triplet absent, which is the live record's permanent shape.
        func samples(
            count: Int = 40,
            rmssd: Double = 50,
            heartRate: Int? = 60,
            magnitude: Double? = 1.0
        ) -> [BiometricSample] {
            let low = 800 - rmssd / 2
            let high = 800 + rmssd / 2
            return (0..<count).map { index in
                BiometricSample(
                    timestamp: start.addingTimeInterval(Double(index)),
                    heartRate: heartRate ?? 0,
                    rrIntervalMs: index.isMultiple(of: 2) ? low : high,
                    accelerometerX: magnitude.map { _ in 0 },
                    accelerometerY: magnitude.map { _ in 0 },
                    accelerometerZ: magnitude)
            }
        }

        // ---- The three gates, and the order they are asked in ----

        assertTest(
            StressWindowEvaluator.features(samples: [])
                == .refused(.shortOfIntervals),
            "An empty window is refused for its beat count before any other gate is consulted — the "
                + "order matters because a window that fails two gates must be counted once, and the "
                + "capture's `short=` counter is what a person reads when the tile is a dash")

        assertTest(
            StressWindowEvaluator.features(samples: samples(count: 19))
                == .refused(.shortOfIntervals),
            "…and \(StressMath.minimumRRIntervals - 1) intervals is below the floor, whatever else the "
                + "window holds")

        // A short window that is *also* moving: still short, because the first gate answers first.
        assertTest(
            StressWindowEvaluator.features(
                samples: samples(count: 5, magnitude: 3.0), motionMagnitudes: [3.0])
                == .refused(.shortOfIntervals),
            "…including one that is moving: the gates are ordered, not weighed")

        assertTest(
            StressWindowEvaluator.features(samples: samples(magnitude: 2.0))
                == .refused(.notResting),
            "A window whose own samples measured movement is refused at the stillness gate")

        assertTest(
            StressWindowEvaluator.features(samples: samples(heartRate: nil))
                == .refused(.noHeartRate),
            "A still window with enough intervals but no heart rate is refused — RMSSD alone is not "
                + "activation, and the model's second term would otherwise be a zero")

        // ---- The motion fallback, which is the live path's only stillness source ----

        assertTest(
            StressWindowEvaluator.features(
                samples: samples(magnitude: nil), motionMagnitudes: [1.0])
                == .features(StressWindowFeatures(meanRmssdMs: 50, meanHeartRate: 60)),
            "A window with no accelerometer on any sample is still **when the motion epochs say so** — "
                + "the fallback, without which a window built from the live heart-rate record could "
                + "never be scored")

        assertTest(
            StressWindowEvaluator.features(
                samples: samples(magnitude: nil), motionMagnitudes: [2.0])
                == .refused(.notResting),
            "…and refused when the epochs report movement above the ceiling")

        assertTest(
            StressWindowEvaluator.features(samples: samples(magnitude: nil), motionMagnitudes: [])
                == .refused(.notResting),
            "…and refused when there is neither source: an unmeasured window is not a resting one, "
                + "which is the same rule the samples-only path states")

        // ---- The samples win when they measured motion ----

        assertTest(
            StressWindowEvaluator.features(
                samples: samples(magnitude: 2.0), motionMagnitudes: [0.5])
                == .refused(.notResting),
            "A moving sample window is not rescued by still motion epochs — the epochs are a fallback, "
                + "not a second vote")

        assertTest(
            StressWindowEvaluator.features(
                samples: samples(magnitude: 1.0), motionMagnitudes: [3.0])
                != .refused(.notResting),
            "…and a still sample window is not overturned by moving epochs, for the same reason")

        // A partial accelerometer reading is a reading: the mean is over the samples that measured.
        assertTest(
            StressWindowEvaluator.features(
                samples: samples(magnitude: 1.0) + samples(magnitude: nil).map {
                    BiometricSample(
                        timestamp: $0.timestamp.addingTimeInterval(100),
                        heartRate: $0.heartRate,
                        rrIntervalMs: $0.rrIntervalMs)
                },
                motionMagnitudes: [3.0])
                != .refused(.notResting),
            "One measured sample is enough to consult the samples rather than the epochs, so a partial "
                + "reading is not silently handed to the fallback")

        // ---- The score is the activation, and it is the evaluator's in both halves ----

        let atBaseline = StressWindowFeatures(
            meanRmssdMs: baseline.rmssd.mean, meanHeartRate: baseline.heartRate.mean)
        assertTest(
            StressWindowEvaluator.score(atBaseline, baseline: baseline)
                == StressMath.activationOffset,
            "A window sitting exactly on the baseline lands on the activation offset, which is the "
                + "low/medium edge — the model's zero is not a zero")

        let activated = StressWindowFeatures(meanRmssdMs: 30, meanHeartRate: 68)
        assertTest(
            StressWindowEvaluator.score(activated, baseline: baseline)
                == StressMath.score(fromActivation: StressMath.activation(
                    rmssdMs: 30, meanHeartRate: 68,
                    rmssdBaseline: baseline.rmssd, heartRateBaseline: baseline.heartRate)),
            "The score is `StressMath.activation` then `StressMath.score`, with no second formula "
                + "between them")

        // `evaluate` is `features` followed by `score`, and the pair is what keeps the live monitor
        // from drifting from the stored day.
        assertTest(
            StressWindowEvaluator.evaluate(
                samples: samples(rmssd: 30, heartRate: 68, magnitude: 1.0),
                baseline: baseline)
                == .scored(StressWindowEvaluator.score(
                    StressWindowFeatures(meanRmssdMs: 30, meanHeartRate: 68), baseline: baseline)),
            "`evaluate` is exactly `features` then `score`, so the two stages cannot disagree")

        assertTest(
            StressWindowEvaluator.evaluate(
                samples: samples(magnitude: nil), motionMagnitudes: [1.0], baseline: baseline)
                .score != nil,
            "…and it scores a sample-less-of-accelerometer window through the fallback — the live "
                + "page's own input shape")
        assertTest(
            StressWindowEvaluator.evaluate(samples: [], baseline: baseline)
                == .refused(.shortOfIntervals),
            "…and refuses what `features` refuses, rather than scoring an absent window as calm")

        // ---- The recent baseline: the live reference when there is no personal one ----
        //
        // The personal baseline takes three days of daytime stillness. A live monitor cannot wait
        // that long, so a day with no personal baseline is scored against its own preceding hours —
        // and *this* is the rule that makes that a measurement rather than a fallback number.

        /// `count` windows five minutes apart from `start`, each carrying plausible features.
        func priors(_ count: Int, from start: Date, rmssd: (Int) -> Double = { _ in 50 },
                    heartRate: (Int) -> Double = { _ in 60 }) -> [StressWindow] {
            (0..<count).map { index in
                StressWindow(
                    start: start.addingTimeInterval(Double(index) * StressMath.windowSeconds),
                    score: 0,
                    features: StressWindowFeatures(
                        meanRmssdMs: rmssd(index), meanHeartRate: heartRate(index)))
            }
        }

        let noon = start.startOfDay.addingTimeInterval(12 * 3600)
        let oneHourOfPriors = priors(StressMath.minimumRecentWindows, from: noon)

        assertTest(
            StressWindowEvaluator.recentBaseline(
                before: noon.addingTimeInterval(Double(StressMath.minimumRecentWindows)
                    * StressMath.windowSeconds),
                windows: priors(StressMath.minimumRecentWindows - 1, from: noon)) == nil,
            "One window short of \(StressMath.minimumRecentWindows) priors is no recent baseline — "
                + "the same 'no measurement, no score' answer the personal path gives, rather than a "
                + "baseline of zeroes")

        let recent = StressWindowEvaluator.recentBaseline(
            before: noon.addingTimeInterval(3600), windows: oneHourOfPriors)
        assertTest(recent != nil, "An hour of priors is a recent baseline")
        assertTest(
            (recent?.rmssd.mean ?? -1) == 50 && (recent?.heartRate.mean ?? -1) == 60,
            "…and it is the priors' mean, taken over the windows that carry features")

        assertTest(
            recent?.scope == .recent(span: StressMath.recentBaselineSpan),
            "…labelled with the span it reached back over, which is what the page names rather than "
                + "guessing a word for")

        // The exclusion that stops a window scoring itself: a baseline built *at* a window's start
        // sees only what came before it.
        assertTest(
            StressWindowEvaluator.recentBaseline(
                before: noon, windows: oneHourOfPriors) == nil,
            "A window whose own start is the evaluation instant has no priors at all, so a series' "
                + "first window is never scored against itself")

        // The span is a wall-clock window, so the same day's data always reproduces the same scores
        // and a later full evaluation agrees with what the live page drew.
        let stale = priors(StressMath.minimumRecentWindows + 2, from: noon)
            .map { window in
                StressWindow(
                    start: window.start.addingTimeInterval(
                        -StressMath.recentBaselineSpan - 3600),
                    score: window.score,
                    features: window.features)
            }
        assertTest(
            StressWindowEvaluator.recentBaseline(
                before: noon.addingTimeInterval(3600), windows: stale) == nil,
            "…and priors older than the span are outside the recent baseline, so yesterday's "
                + "afternoon cannot describe this morning")

        assertTest(
            StressWindowEvaluator.recentBaseline(
                before: noon.addingTimeInterval(3600),
                windows: oneHourOfPriors.map {
                    StressWindow(start: $0.start, score: $0.score)
                }) == nil,
            "A window carrying no features is not a baseline point — a baseline is a fact about "
                + "inputs, and a hand-built window has only an output")

        // Two different days' features must not be pooled into one reference: the recent baseline is
        // about *this* day, and pooling would quietly rebuild the fortnight it exists to replace.
        let yesterday = priors(StressMath.minimumRecentWindows, from: noon.addingTimeInterval(-86_400))
        assertTest(
            StressWindowEvaluator.recentBaseline(
                before: noon.addingTimeInterval(3600), windows: yesterday) == nil,
            "…and a previous day's windows are not this day's recent baseline")

        if let recent {
            assertTest(
                abs(StressWindowEvaluator.score(
                    StressWindowFeatures(
                        meanRmssdMs: recent.rmssd.mean - recent.rmssd.stdDev,
                        meanHeartRate: recent.heartRate.mean + recent.heartRate.stdDev),
                    baseline: recent) - (StressMath.activationOffset + 1)) < 0.0000001,
                "A window one sigma low on HRV and one sigma high on heart rate scores one point "
                    + "above the offset — the same one-point-per-sigma reading the personal "
                    + "baseline gives, on a reference built an hour ago instead of a fortnight")
        } else {
            assertTest(false, "The hour-long recent baseline was not built")
        }

        // ---- The baseline rides on the day ----

        let dayStart = start.startOfDay
        let plain = StressDay(
            date: dayStart,
            windows: [StressWindow(start: dayStart.addingTimeInterval(9 * 3600), score: 1.4)])
        assertTest(plain.baseline == nil, "A day built without a baseline holds none, not a default")

        let carried = StressDay(date: dayStart, windows: plain.windows, baseline: baseline)
        assertTest(
            carried.baseline == baseline,
            "A scored day carries the baseline it was scored against, which is what lets a live window "
                + "be scored on the same scale without re-reading a fortnight")
        assertTest(
            carried.score == plain.score,
            "…and carrying it moves no figure: the aggregate is still the windows' mean")
    }
}
