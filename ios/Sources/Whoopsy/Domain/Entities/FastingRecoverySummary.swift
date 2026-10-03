import Foundation

/// What a fast's own page prints: the nights it covered, the Recovery score they average to, and each
/// night's position against the user's own baseline.
///
/// ## Why a fast gets this and a workout does not
///
/// A fast is the one session in this app that is **long enough to contain whole nights**. An 86-hour
/// fast spans four of them, and each of those nights has a `recoveries` row with an HRV reading, a
/// resting heart rate and a respiratory rate that the fast itself is the only activity page able to
/// group. That grouping is the whole feature: the page states what the body did while it was fasting,
/// which is the one question a fast is taken to answer.
///
/// ## Nothing here is computed by this type
///
/// The score is the mean of the nights' own stored `RecoveryMetric.score` values and the z-scores are
/// `BaselineStatisticsMath`'s against a window `RecoveryScoring` handed over. There is no fasting
/// score model, no weight, and no scale invented here — see `FastingRecovery`'s doc for why that is
/// the design rather than a shortcut.
public struct FastingRecoverySummary: Equatable, Sendable {

    /// One night the fast covered, with its readings and their positions against the baseline.
    ///
    /// Every z-score is optional and `nil` means **the baseline for that quantity was too thin to
    /// draw one against**, which is per-metric rather than per-night: a window can hold thirty HRV
    /// readings and four respiratory rates, so the same night legitimately has an HRV bar and no
    /// respiratory-rate bar. A caller that treated `nil` as `0` would draw every such night sitting
    /// exactly on the baseline — the strongest available claim that nothing changed, made about a
    /// quantity nothing measured.
    public struct Night: Equatable, Sendable, Identifiable {
        /// The day key the row is filed under — `startOfDay(wakeOnset)`, so the morning this night
        /// ended on. It is the chart's column label as well as the identity.
        public let date: Date

        /// The night's own stored Recovery score, `1...99` as the formula's clamp produces it.
        public let score: Int

        /// The raw reading the `hrv` z-score is computed from, in milliseconds.
        public let hrvValueMs: Double

        /// Which quantity `hrvValueMs` holds. Carried through so the legend can name it: the app's
        /// own screens print `HRV (RMSSD)` and a bare `HRV` would be a second name for one quantity.
        public let hrvMetric: HRVMetric

        /// The raw reading the `restingHeartRate` z-score is computed from, in bpm.
        public let restingHeartRate: Int

        /// The raw reading the `respiratoryRate` z-score is computed from, in rpm — or `nil` on a row
        /// that carries none.
        public let respiratoryRate: Double?

        /// Deviation from the baseline mean, in standard deviations of the user's own window.
        public let hrvZScore: Double?
        public let restingHeartRateZScore: Double?
        public let respiratoryRateZScore: Double?

        /// The three z-scores as one dictionary, for a chart that draws a column per night.
        public var zScores: [FastingMetric: Double] {
            var scores: [FastingMetric: Double] = [:]
            scores[.hrv] = hrvZScore
            scores[.restingHeartRate] = restingHeartRateZScore
            scores[.respiratoryRate] = respiratoryRateZScore
            return scores.compactMapValues { $0 }
        }

        public var id: Date { date }

        /// The night's raw reading for `metric`, with its unit, or `nil` when it has none.
        ///
        /// The chart draws z-scores, which are dimensionless and say nothing about magnitude — so this
        /// is where the actual millisecond, beat and breath figures reach a reader, through the
        /// legend and the spoken sentence. It is a static-shaped rule on the value for this repo's
        /// standing reason: a string composed inside a `body` is a string the runner cannot assert.
        public func rawText(for metric: FastingMetric) -> String? {
            switch metric {
            case .hrv:
                return "\(hrvValueMs.formattedOneDecimal()) \(metric.rawUnit)"
            case .restingHeartRate:
                return "\(restingHeartRate) \(metric.rawUnit)"
            case .respiratoryRate:
                guard let respiratoryRate else { return nil }
                return "\(respiratoryRate.formattedOneDecimal()) \(metric.rawUnit)"
            }
        }
    }

    /// The nights the fast covered, **oldest first**, which is the order the chart draws them in.
    ///
    /// Only nights that hold a measurement. A row written before the no-placeholder change carries
    /// `hrvValueMs == 0` and a reserved `score: 0`, and a column drawn for one would be a column of
    /// nothing under a chart claiming the fast had a reading there.
    public let nights: [Night]

    /// The mean of the nights' own stored scores, rounded — or `nil` when there is no night to
    /// average.
    ///
    /// **This is the app's ordinary Recovery score, not a fasting score.** `RecoveryMetric.score` is
    /// uniformly `RecoveryScoring`'s output — `WhoopExportImporter` recomputes it rather than storing
    /// WHOOP's column, and `CalculateRecoveryUseCase` writes the same function's answer — so the mean
    /// needs no recomputation, no weights and no ground truth this app lacks. See `FastingRecovery`.
    ///
    /// Optional so that the badge and the figure can never disagree: `scoredNightCount` is the count
    /// this was taken over, and a caller with one prints the other.
    public let meanScore: Int?

    /// How many nights `meanScore` was averaged over. Equal to `nights.count`, and named separately
    /// because it is what the page's badge reads — `OVER 4 NIGHTS` is a statement about the basis and
    /// not about the figure above it.
    public let scoredNightCount: Int

    /// Which HRV quantity the window and the nights were narrowed to — **the newest enclosed night's**,
    /// or `nil` when there are no nights.
    ///
    /// SDNN and RMSSD are different quantities on different scales and never share a baseline, so this
    /// is the one thing that makes the pooled z-score meaningful. It is the same "the metric in force"
    /// rule `MetricWeek.hrvBaselineMetric` follows.
    public let hrvMetric: HRVMetric?

    /// How many measured days the baseline window held, **before** per-metric narrowing.
    ///
    /// The window is `RecoveryScoring.baselineWindow(before:)` — the last thirty days that have rows —
    /// so this is that window's own size. It is not the denominator of anything; it is carried so a
    /// caller can state what the comparison was made against, and so §19 can pin it.
    public let baselineObservationCount: Int

    public init(
        nights: [Night],
        meanScore: Int?,
        scoredNightCount: Int,
        hrvMetric: HRVMetric?,
        baselineObservationCount: Int
    ) {
        self.nights = nights
        self.meanScore = meanScore
        self.scoredNightCount = scoredNightCount
        self.hrvMetric = hrvMetric
        self.baselineObservationCount = baselineObservationCount
    }
}
