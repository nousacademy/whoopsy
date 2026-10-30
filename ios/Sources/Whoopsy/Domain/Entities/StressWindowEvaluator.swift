import Foundation

/// The personal baseline the stress model scores against: the previous fortnight's waking hours,
/// reduced to two means and two spreads.
///
/// **It is carried on `StressDay` because a live monitor cannot recompute it.** The model is defined
/// relative to these four numbers, and deriving them costs a read of fourteen days of samples — the
/// most expensive read in the app. A page that ticks every five minutes has to score a new window
/// against the baseline the day was already scored against, so the day hands it over rather than
/// making every tick pay for it again.
public struct StressBaseline: Equatable, Sendable {
    public let rmssd: BaselineStatistics
    public let heartRate: BaselineStatistics

    /// What the four numbers were drawn from, which the page states rather than leaving implicit.
    ///
    /// **The two references answer different questions.** Personal is the model's own definition —
    /// this five minutes against your previous fortnight — and it is what a stored day is scored on
    /// once three prior days carry still windows. Recent is the fallback that makes the monitor live
    /// from its first day: this five minutes against your last few hours. A number without its
    /// reference would be two different quantities wearing one label.
    public let scope: StressBaselineScope

    public init(
        rmssd: BaselineStatistics,
        heartRate: BaselineStatistics,
        scope: StressBaselineScope = .personal
    ) {
        self.rmssd = rmssd
        self.heartRate = heartRate
        self.scope = scope
    }
}

/// What a `StressBaseline` was built from. See `StressBaseline.scope`.
public enum StressBaselineScope: Equatable, Sendable {
    /// The previous fortnight's waking hours, one baseline point per day.
    case personal
    /// The trailing span of the **same day**, one baseline point per window.
    ///
    /// Carries the span so the page can name it ("your last 6 hours") without holding a second copy
    /// of `StressMath.recentBaselineSpan`.
    case recent(span: TimeInterval)
}

/// The three gates' refusals, as cases rather than a `nil`.
///
/// They are named because the day's diagnostic counts them: "the stress tile is a dash" has three
/// data-side causes that look identical on the glass.
public enum StressWindowRefusal: Equatable, Sendable {
    /// Fewer than `StressMath.minimumRRIntervals` R-R intervals — no RMSSD that means anything.
    case shortOfIntervals
    /// No measured motion, or a mean above `StressMath.motionCeiling`.
    case notResting
    case noHeartRate
}

/// What one candidate window turned out to be — a score, or the gate that refused it.
///
/// **One evaluator for the stored day and the live monitor**, so a window scored while the page is
/// open is scored by the same rule, in the same order, as one scored from a drain.
public enum StressWindowVerdict: Equatable, Sendable {
    case scored(Double)
    case refused(StressWindowRefusal)

    public var score: Double? {
        if case let .scored(value) = self { return value }
        return nil
    }
}

/// A window's raw features — what the gates let through, before a baseline is applied.
public struct StressWindowFeatures: Equatable, Sendable {
    public let meanRmssdMs: Double
    public let meanHeartRate: Double

    public init(meanRmssdMs: Double, meanHeartRate: Double) {
        self.meanRmssdMs = meanRmssdMs
        self.meanHeartRate = meanHeartRate
    }
}

/// The gates' answer: features, or the gate that refused.
///
/// **Two stages rather than one**, because the personal baseline is built *from* prior days' features
/// and cannot be known while those are being extracted. The analyzer uses `features` to build the
/// baseline and `score` for today; the live monitor uses `evaluate`, which is both.
public enum StressWindowExtraction: Equatable, Sendable {
    case features(StressWindowFeatures)
    case refused(StressWindowRefusal)
}

/// Scores one five-minute window, or says which gate refused it.
public enum StressWindowEvaluator {

    /// - Parameters:
    ///   - samples: the window's samples. Their R-R intervals and heart rates are its inputs.
    ///   - motionMagnitudes: mean magnitudes from `motionEpochs` overlapping the window — the fallback
    ///     stillness source, used **only when no sample carries an accelerometer**. The live
    ///     heart-rate record has no motion lane, so without this fallback every window built from
    ///     live data is refused; with it, a drained window still prefers its own samples.
    public static func features(
        samples: [BiometricSample],
        motionMagnitudes: [Double] = []
    ) -> StressWindowExtraction {
        let rrIntervals = samples.compactMap(\.rrIntervalMs)
        guard rrIntervals.count >= StressMath.minimumRRIntervals else {
            return .refused(.shortOfIntervals)
        }

        let sampleMagnitudes = samples.map(\.accelerationMagnitude)
        let stillness: Bool
        if sampleMagnitudes.contains(where: { $0 != nil }) {
            // The samples measured motion: they answer the question, and the fallback is not consulted.
            stillness = StressMath.isResting(magnitudes: sampleMagnitudes)
        } else {
            stillness = StressMath.isResting(magnitudes: motionMagnitudes.map { Optional($0) })
        }
        guard stillness else { return .refused(.notResting) }

        let rates = samples.map(\.heartRate).filter { $0 > 0 }
        guard !rates.isEmpty else { return .refused(.noHeartRate) }

        let rmssd = HeartRateVariabilityMath.calculateRMSSD(from: rrIntervals)
        let meanHeartRate = Double(rates.reduce(0, +)) / Double(rates.count)
        return .features(
            StressWindowFeatures(meanRmssdMs: rmssd, meanHeartRate: meanHeartRate))
    }

    /// A window's activation against the personal baseline, on WHOOP's 0–3 scale.
    public static func score(
        _ features: StressWindowFeatures,
        baseline: StressBaseline
    ) -> Double {
        let activation = StressMath.activation(
            rmssdMs: features.meanRmssdMs,
            meanHeartRate: features.meanHeartRate,
            rmssdBaseline: baseline.rmssd,
            heartRateBaseline: baseline.heartRate)
        return StressMath.score(fromActivation: activation)
    }

    /// The **recent** baseline: the same day's own windows in the span before `start`.
    ///
    /// This is the fallback a live monitor needs. A personal baseline takes three days of daytime
    /// stillness to exist, and a page that showed nothing until then would be reporting the *absence
    /// of history* as an absence of stress — while the afternoon in front of the user is a perfectly
    /// good measurement. So a day with no personal baseline is scored against its own preceding
    /// hours: the mean and spread of the window features inside `span`, one point per window.
    ///
    /// **Three details are the rule.** The priors are strictly **before** `start`, so a window never
    /// contributes to the baseline it is scored against; the span is a **wall-clock** window, not a
    /// count, so the same day's data always reproduces the same scores and a live tick agrees with a
    /// later full evaluation; and the floor is `minimumRecentWindows` (an hour at this cadence),
    /// because fewer priors would describe the minute being scored more than the hours before it.
    ///
    /// Windows without `features` are skipped rather than counted: a hand-built window carries a score
    /// and no inputs, and a baseline is a fact about inputs.
    ///
    /// - Returns: `nil` when the span holds fewer than `minimumWindows` measurable priors — the same
    ///   "no measurement, no score" answer the personal path gives, not a baseline of zeroes.
    public static func recentBaseline(
        before start: Date,
        windows: [StressWindow],
        span: TimeInterval = StressMath.recentBaselineSpan,
        minimumWindows: Int = StressMath.minimumRecentWindows
    ) -> StressBaseline? {
        let priors = windows.filter { window in
            guard window.features != nil else { return false }
            return window.start < start && window.start >= start.addingTimeInterval(-span)
        }
        guard priors.count >= minimumWindows else { return nil }

        let features = priors.compactMap(\.features)
        return StressBaseline(
            rmssd: BaselineStatisticsMath.baseline(
                features.map(\.meanRmssdMs), fallbackMean: 0, fallbackStdDev: 0),
            heartRate: BaselineStatisticsMath.baseline(
                features.map(\.meanHeartRate), fallbackMean: 0, fallbackStdDev: 0),
            scope: .recent(span: span))
    }

    /// Both stages at once, for a caller that already holds its baseline.
    public static func evaluate(
        samples: [BiometricSample],
        motionMagnitudes: [Double] = [],
        baseline: StressBaseline
    ) -> StressWindowVerdict {
        switch features(samples: samples, motionMagnitudes: motionMagnitudes) {
        case let .features(features): return .scored(score(features, baseline: baseline))
        case let .refused(refusal): return .refused(refusal)
        }
    }
}
