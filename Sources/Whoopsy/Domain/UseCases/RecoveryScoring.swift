import Foundation

/// Turns one day's measurements plus a history window into a Recovery score.
///
/// This exists because two callers need the same arithmetic from different sources: the strap path
/// (`CalculateRecoveryUseCase`, RMSSD from R-R intervals) and the HealthKit import path (SDNN).
/// Duplicating the coefficients into both would reproduce exactly the drift that `ALGORITHMS.md` §3
/// already suffered, so both go through here.
///
/// It also owns the one rule that cannot be expressed by the formula itself: **history is filtered to
/// the metric being scored.** SDNN and RMSSD are different quantities, so a baseline pooled across
/// both is not a baseline of anything — it would compute a z-score against the midpoint between two
/// distributions and silently mis-score every day.
public enum RecoveryScoring {

    public struct Input: Sendable {
        /// Unfiltered history. Filtering to the right metric happens here, not at the call site.
        public let history: [RecoveryMetric]
        public let todayHrvValueMs: Double
        public let todayHrvMetric: HRVMetric
        public let todayRestingHeartRate: Int
        /// Actual / needed, as a fraction. See `SleepSession.sleepPerformancePercentage`.
        public let sleepPerformance: Double
        /// Cold-start values, used only when the history has nothing to learn from.
        public let fallbackRestingHeartRateBaseline: Double

        public init(
            history: [RecoveryMetric],
            todayHrvValueMs: Double,
            todayHrvMetric: HRVMetric,
            todayRestingHeartRate: Int,
            sleepPerformance: Double,
            fallbackRestingHeartRateBaseline: Double
        ) {
            self.history = history
            self.todayHrvValueMs = todayHrvValueMs
            self.todayHrvMetric = todayHrvMetric
            self.todayRestingHeartRate = todayRestingHeartRate
            self.sleepPerformance = sleepPerformance
            self.fallbackRestingHeartRateBaseline = fallbackRestingHeartRateBaseline
        }
    }

    public struct Output: Equatable, Sendable {
        public let score: Int
        public let hrvBaselineMeanMs: Double
        public let hrvBaselineDeltaMs: Double
        public let rhrBaselineMean: Double
        public let rhrBaselineDeltaBpm: Int
    }

    /// Cold-start spread for resting heart rate. Metric-independent, unlike the HRV pair.
    public static let coldStartRestingHeartRateStdDev = 3.5

    /// Cold-start resting heart rate mean, used only when the window holds no measured day.
    ///
    /// The same value `UserProfile` carries as its own default, and named here so that a caller which
    /// has no profile — a screen printing baselines rather than scoring a day — has something honest
    /// to hand the arithmetic instead of inventing one. It is never *printed*: a mean resting heart
    /// rate is a reading this app took, and `Baselines.displayed` withholds it unless the window
    /// actually held observations.
    public static let coldStartRestingHeartRateBaseline = 54.0

    /// How many days back the scoring window reaches.
    ///
    /// Thirty days is WHOOP's own published baseline window and the number this app has always used.
    /// See `baselineWindow(before:in:)` for what the window is a window *of*.
    public static let baselineWindowDays = 30

    /// How far back a reader has to fetch for `baselineWindow(before:in:)` to fill.
    ///
    /// The window is the last `baselineWindowDays` days that **have rows**, not the last thirty
    /// calendar days, so on a history with gaps it reaches further back than thirty days to fill.
    /// Measured over the bundled export: the worst case reaches 172 days, on the 420 of 910 days that
    /// have a gap somewhere in the prior thirty. 180 therefore covers every day this app has data
    /// for. A shorter read does not fail loudly — it silently prints a baseline built from fewer days
    /// than the score above it used, which is the reason this is a named, measured constant rather
    /// than a number at a call site.
    public static let baselineWindowLookbackDays = 180

    /// The days immediately before `day`, most recent last, capped at the scoring window.
    ///
    /// Strictly before, so a day never contributes to its own baseline — and the cap is applied after
    /// the filter, because slicing first would take the wrong thirty days. It lives here rather than
    /// in the importer that used to own it because a second caller now needs the *same* window: the
    /// recovery detail screen prints the baseline its score was computed against, and a screen that
    /// reached for a neighbouring definition would be explaining the ring with a number the ring
    /// never saw.
    public static func baselineWindow(before day: Date, in series: [RecoveryMetric]) -> [RecoveryMetric] {
        window(before: day, in: series, dated: \.date)
    }

    /// The same window over nights, for the sleep-performance mean the detail screen prints.
    ///
    /// A second overload rather than a caller-side `filter`, so the "strictly before, then cap"
    /// ordering cannot be got wrong at one of the two sites: slicing before filtering takes the wrong
    /// thirty, which is the error the recovery overload's own doc comment names.
    public static func baselineWindow(before day: Date, in nights: [SleepSession]) -> [SleepSession] {
        window(before: day, in: nights, dated: \.date)
    }

    private static func window<T>(before day: Date, in series: [T], dated: KeyPath<T, Date>) -> [T] {
        Array(series.filter { $0[keyPath: dated] < day }.suffix(baselineWindowDays))
    }

    /// What a day's figure is being read against: the trailing window's means, and how many
    /// observations each was taken over.
    ///
    /// The counts are not decoration. `BaselineStatisticsMath.baseline` substitutes a **cold-start
    /// constant** when it is handed nothing, which is the right thing for scoring a first day and the
    /// wrong thing to print — a screen showing `65 ms` as "your HRV baseline" on a day with no history
    /// at all would be presenting a constant as a measurement. `displayed` is where that distinction
    /// is made, once.
    public struct Baselines: Equatable, Sendable {
        /// Mean HRV in `todayHrvMetric`'s quantity. Equal to the cold-start mean when
        /// `hrvObservationCount` is zero.
        public let hrvMeanMs: Double
        /// Guarded spread — the 5% coefficient-of-variation floor is already applied.
        public let hrvStdDevMs: Double
        /// How many measured days the HRV mean was taken over, in that one metric.
        public let hrvObservationCount: Int

        /// Mean resting heart rate. Equal to the caller's fallback when
        /// `restingHeartRateObservationCount` is zero.
        public let restingHeartRateMean: Double
        public let restingHeartRateStdDev: Double
        public let restingHeartRateObservationCount: Int

        /// Mean overnight respiratory rate, or `nil` below `minimumBaselineDays`.
        public let respiratoryRateMean: Double?
        public let respiratoryRateObservationCount: Int

        /// Mean sleep performance as a fraction of need (0–1), or `nil` below
        /// `minimumBaselineDays`. Taken over the nights handed in, which are the same window's.
        public let sleepPerformanceMean: Double?
        public let sleepPerformanceObservationCount: Int

        /// The four means as a screen should print them: each `nil` unless its window held at least
        /// `minimumBaselineDays` observations.
        ///
        /// The HRV entry is in the same metric as the value above it — the never-mix narrowing is
        /// applied in `baselines(history:...)`, not here, so a screen cannot print a mean taken
        /// across SDNN and RMSSD days by forgetting a filter.
        public var displayed: Displayed {
            Displayed(
                hrvMs: hrvObservationCount >= minimumBaselineDays ? hrvMeanMs : nil,
                restingHeartRate: restingHeartRateObservationCount >= minimumBaselineDays
                    ? restingHeartRateMean : nil,
                respiratoryRate: respiratoryRateMean,
                sleepPerformance: sleepPerformanceMean)
        }
    }

    /// The trailing means a screen prints beneath a day's values, all `nil` when their window was too
    /// thin to be a baseline. Built by `Baselines.displayed`.
    public struct Displayed: Equatable, Sendable {
        public let hrvMs: Double?
        public let restingHeartRate: Double?
        public let respiratoryRate: Double?
        public let sleepPerformance: Double?
    }

    /// How few measured days is not a baseline.
    ///
    /// Forwarded from `MetricWeek` rather than restated, so the app keeps one answer to "how few days
    /// is not a baseline" — the same forwarding `MetricWeek` itself does to `StressMath`. Two measured
    /// days do have a mean; calling it a baseline is the judgement, and it is made in one place.
    public static let minimumBaselineDays = MetricWeek.minimumBaselineDays

    /// The window's baselines. `score(_:)` is built on this, so a screen printing what it returns is
    /// printing the numbers the score in the ring was computed from.
    ///
    /// - Parameters:
    ///   - history: the scoring window — `baselineWindow(before:in:)` of a wide enough read.
    ///   - todayHrvMetric: which HRV quantity the day being described recorded. The HRV mean is
    ///     narrowed to it, which is the never-mix rule.
    ///   - fallbackRestingHeartRateBaseline: cold start, used only when the window holds no measured
    ///     day. The default is the profile's own documented default; a caller with a profile passes
    ///     that instead.
    ///   - sleepingNights: the same window's nights, for the sleep-performance mean. Omitted by the
    ///     scoring path, which is handed its day's performance directly and has no opinion about the
    ///     window's.
    public static func baselines(
        history: [RecoveryMetric],
        todayHrvMetric: HRVMetric,
        fallbackRestingHeartRateBaseline: Double = coldStartRestingHeartRateBaseline,
        sleepingNights: [SleepSession] = []
    ) -> Baselines {
        // Placeholder days are not observations. A day with no measurement stores zeros, so letting
        // them through would put a 0 ms HRV and a 0 bpm resting heart rate into the window and drag
        // every baseline toward it — the exact failure the zeros were meant to make visible.
        let measured = history.filter(\.hasMeasurement)

        // The metric filter. Everything HRV-related below must use `sameMetricHrv`.
        let sameMetricHrv = measured
            .filter { $0.hrvMetric == todayHrvMetric }
            .map(\.hrvValueMs)

        // Resting heart rate does not depend on which HRV quantity was recorded, so its baseline
        // legitimately draws on the whole window rather than the filtered subset.
        let restingHeartRates = measured.map { Double($0.restingHeartRate) }

        let hrvBaseline = BaselineStatisticsMath.baseline(
            sameMetricHrv,
            fallbackMean: todayHrvMetric.coldStartMeanMs,
            fallbackStdDev: todayHrvMetric.coldStartStdDevMs)

        let rhrBaseline = BaselineStatisticsMath.baseline(
            restingHeartRates,
            fallbackMean: fallbackRestingHeartRateBaseline,
            fallbackStdDev: coldStartRestingHeartRateStdDev)

        // Respiratory rate is the export's own measured column and the strap has no sensor for it, so
        // a window can hold plenty of days and no rate at all. A mean over the days that carry one,
        // or nothing.
        let respiratoryRates = measured.compactMap(\.respiratoryRate)

        // Sleep performance is derived on read from a night's own asleep-over-need, so the nights
        // handed in are already the nights the classifier could read — no separate absence rule.
        let sleepPerformances = sleepingNights.map { Double($0.sleepPerformancePercentage) / 100.0 }

        func displayMean(_ values: [Double]) -> Double? {
            values.count >= minimumBaselineDays ? BaselineStatisticsMath.mean(values) : nil
        }

        return Baselines(
            hrvMeanMs: hrvBaseline.mean,
            hrvStdDevMs: hrvBaseline.stdDev,
            hrvObservationCount: sameMetricHrv.count,
            restingHeartRateMean: rhrBaseline.mean,
            restingHeartRateStdDev: rhrBaseline.stdDev,
            restingHeartRateObservationCount: restingHeartRates.count,
            respiratoryRateMean: displayMean(respiratoryRates),
            respiratoryRateObservationCount: respiratoryRates.count,
            sleepPerformanceMean: displayMean(sleepPerformances),
            sleepPerformanceObservationCount: sleepPerformances.count)
    }

    public static func score(_ input: Input) -> Output {
        let baselines = baselines(
            history: input.history,
            todayHrvMetric: input.todayHrvMetric,
            fallbackRestingHeartRateBaseline: input.fallbackRestingHeartRateBaseline)

        let score = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: input.todayHrvValueMs,
            baselineHrvMean: baselines.hrvMeanMs,
            baselineHrvStd: baselines.hrvStdDevMs,
            todayRhr: Double(input.todayRestingHeartRate),
            baselineRhrMean: baselines.restingHeartRateMean,
            baselineRhrStd: baselines.restingHeartRateStdDev,
            sleepPerformance: input.sleepPerformance)

        // Millisecond deltas are rounded to 0.1 ms here rather than at each call site, so the
        // strap path and the HealthKit path cannot round differently.
        return Output(
            score: score,
            hrvBaselineMeanMs: baselines.hrvMeanMs,
            hrvBaselineDeltaMs: (input.todayHrvValueMs - baselines.hrvMeanMs).rounded(toPlaces: 1),
            rhrBaselineMean: baselines.restingHeartRateMean,
            rhrBaselineDeltaBpm: input.todayRestingHeartRate - Int(baselines.restingHeartRateMean.rounded()))
    }
}
