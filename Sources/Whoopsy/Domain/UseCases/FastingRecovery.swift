import Foundation

/// Which nights a fast covered, and what the body's readings did across them.
///
/// ## The substitution, stated plainly because it is the whole design
///
/// **There is no fasting score model here, and inventing one would be the mistake.** A fasting app can
/// publish a "fast recovery score" because it also measures glucose and ketones; this app has no
/// sensor for either — `biodata.json`'s `glucose_data` holds zero rows in every file on this machine —
/// so a fasting score would be a number with no ground truth anywhere and no way to falsify it.
///
/// What this app *does* have is the ordinary Recovery score it computes for every day, and a fast long
/// enough to contain whole nights is the one session whose page can group them. So the figure is **the
/// mean of the enclosed nights' own stored scores**: no new weights, no new scale, and no constant that
/// cannot be checked. It is documented as a substitution the way `SleepNeedMath` is, and it is a
/// *worse* claim than the reference's — it says "your recovery while fasting", not "your fast worked".
///
/// `RecoveryMetric.score` is uniformly `RecoveryScoring`'s output, which is what makes the mean
/// legitimate: `WhoopExportImporter` recomputes the score rather than storing WHOOP's own column, and
/// `CalculateRecoveryUseCase` writes the same function's answer, so every night in the mean is the
/// same quantity on the same scale as the ring on Home.
///
/// ## The history is handed in and never fetched
///
/// `AnalyzeSleepStressUseCase.execute(for:priorNights:)`'s precedent, and for its reason: a use case
/// that fetches its own history cannot be asserted without a database, and — worse — two callers can
/// come to describe two different sets of nights. The caller reads once and hands it over.
public enum FastingRecovery {

    /// Whether a fast **covered** the night that ended on the morning of `day`.
    ///
    /// ## The rule
    ///
    /// > A `recoveries` row dated `D` describes the night that ended on the morning of `D`. The fast
    /// > covered it when the fast was **already running when `D` began**:
    /// > `startedAt.startOfDay < D && D <= endedAt.startOfDay`.
    ///
    /// Both sides are snapped to the calendar day, and both halves of that are load-bearing. The
    /// right-hand side is snapped because the fast's own end instant is on a day the night of *that*
    /// morning belongs to — a fast ending 2024-10-10 11:01 covered the night that ended that morning,
    /// so `D = 2024-10-10` is enclosed. The left-hand side is snapped for the opposite reason: a fast
    /// that began at 21:00 on 2024-10-06 did **not** cover the night that ended that morning, since
    /// that night was over fifteen hours before it started.
    ///
    /// Measured against the flagship fixture — the 86-hour fast, 2024-10-06 21:00 → 2024-10-10 11:01 —
    /// this gives it exactly the four nights it really spanned, 10-07 through 10-10.
    ///
    /// ## Why not `WorkoutSession.covers(_:)`
    ///
    /// `covers(_:)` is the half-open **day overlap** and it is the right rule for Home's `ACTIVITIES`
    /// card, where the question is *which day was this session underway on*. As an enclosure test it
    /// credits the fast with **the night before it started**: `covers(2024-10-06)` is true for the
    /// 86-hour fast, so 10-06's row — from a night that had already ended — would land in the score's
    /// mean. The two rules answer different questions and only one of them is about nights.
    ///
    /// ## Its error direction, which is the safe one
    ///
    /// A fast that starts in the small hours of `D` and ends later the same day reads as covering
    /// nothing, though it ran through `D`'s morning reading. **The app cannot do better**: a
    /// `RecoveryMetric` stores a snapped day key and no wake instant, so "the night's wake onset falls
    /// inside the fast" is not expressible from what is on disk. Where a day key cannot distinguish,
    /// an absence is the honest answer — this app's standing rule — rather than a guess that would
    /// credit the fast with a night it may not have covered.
    ///
    /// One consequence to know rather than discover: two fasts on one day (a 04:00–08:00 and an
    /// 18:00–22:00) draw on the same single recovery row, so **one night can be covered by two fasts**
    /// and neither page can say which of them it was about.
    public static func encloses(_ day: Date, in session: WorkoutSession) -> Bool {
        let night = day.startOfDay
        return session.startedAt.startOfDay < night && night <= session.endedAt.startOfDay
    }

    /// The summary a fast's page draws, or `nil` when the fast covered no measured night.
    ///
    /// `nil` is the answer for a fast that ended before the recovery record begins, which on the
    /// bundled files is most of them — the record starts 2023-07-23 and 118 of the 170 fasts are from
    /// 2022. That is a fact about two fixture files' date ranges and not about the feature; every fast
    /// taken while wearing the strap covers its nights.
    ///
    /// - Parameters:
    ///   - session: the fast. Only its two instants are read, so an ordinary workout handed here is
    ///     answered rather than refused — but a caller should gate on `ActivityFigure.isFast(_:)`
    ///     first, because a workout's "covered nights" is not a question the app asks.
    ///   - history: the recovery rows, oldest-first as the repositories return them. Read over
    ///     `RecoveryScoring.baselineWindowLookbackDays` back by the caller, or the baseline below
    ///     silently fills from fewer days than the score above it used.
    public static func summary(
        for session: WorkoutSession,
        history: [RecoveryMetric]
    ) -> FastingRecoverySummary? {
        // A placeholder row is not a night. Rows written before the no-placeholder change store
        // `hrvValueMs == 0` beside a reserved `score: 0`, and averaging one in would drag the mean
        // toward zero and colour the tier red — the trap `CLAUDE.md` records for the Home ring.
        let nights = history
            .filter { $0.hasMeasurement && encloses($0.date, in: session) }
            .sorted { $0.date < $1.date }

        guard !nights.isEmpty else { return nil }

        // The metric in force is the newest enclosed night's — `MetricWeek.hrvBaselineMetric`'s rule.
        // SDNN and RMSSD are different quantities on different scales, so pooling them computes a
        // z-score between two distributions and pins the answer to the clamp. The failure is silent,
        // because a wrong z-score is still a number in range.
        let metricInForce = nights.last?.hrvMetric

        // One window for the whole fast, taken before it started: a single stated reference — "your
        // baseline as it stood before this fast" — so every column shares one denominator per metric.
        // A window per night would let two columns of one chart be drawn against two different scales
        // while looking identical.
        let window = RecoveryScoring.baselineWindow(before: session.startedAt, in: history)
            .filter(\.hasMeasurement)

        let baselines = FastingBaselines(window: window, hrvMetric: metricInForce)

        let meanScore = Int(
            (Double(nights.reduce(0) { $0 + $1.score }) / Double(nights.count)).rounded())

        return FastingRecoverySummary(
            nights: nights.map { night in
                FastingRecoverySummary.Night(
                    date: night.date,
                    score: night.score,
                    hrvValueMs: night.hrvValueMs,
                    hrvMetric: night.hrvMetric,
                    restingHeartRate: night.restingHeartRate,
                    respiratoryRate: night.respiratoryRate,
                    // **The nights are narrowed and not only the window** — the second half of the
                    // never-mix rule, and the half that is easy to miss. A night whose own HRV is SDNN
                    // has no reading on the RMSSD scale every other bar of this chart is drawn against,
                    // so plotting it against that window would put one column of one fast on a
                    // quantity the chart does not plot. It draws no HRV bar instead — the same answer
                    // the `nil` for an absent reading gives, so the chart needs no third state.
                    hrvZScore: night.hrvMetric == metricInForce
                        ? baselines.hrv.zScore(of: night.hrvValueMs)
                        : nil,
                    restingHeartRateZScore: baselines.restingHeartRate.zScore(
                        of: Double(night.restingHeartRate)),
                    respiratoryRateZScore: night.respiratoryRate.flatMap {
                        baselines.respiratoryRate.zScore(of: $0)
                    })
            },
            meanScore: meanScore,
            scoredNightCount: nights.count,
            hrvMetric: metricInForce,
            baselineObservationCount: window.count)
    }

    // MARK: - The three baselines

    /// One quantity's baseline, or the absence of one.
    ///
    /// ## A z-score is drawn only against a baseline that was measured
    ///
    /// `BaselineStatisticsMath.baseline` substitutes a **cold-start constant** when it is handed
    /// nothing — 65 ms RMSSD, 54 bpm — which is the right thing for scoring a first day and the wrong
    /// thing to draw: a bar computed against a constant would be a confident statement about the
    /// user's own physiology made from a number nobody measured. `nil` is the word for that, and each
    /// metric gets its own answer, because the three windows differ in size: a month of HRV readings
    /// routinely comes with four respiratory rates.
    ///
    /// The floor is `RecoveryScoring.minimumBaselineDays`, the same one `Baselines.displayed` uses to
    /// withhold a mean, so this page and the Recovery ring cannot come to disagree about how much
    /// history a baseline needs.
    ///
    /// ## The 5% coefficient-of-variation floor, recorded rather than worked around
    ///
    /// `BaselineStatisticsMath.baseline` returns `max(observedStdDev, |mean| × 0.05)`, and measured
    /// over the bundled export that floor **binds on 91% of respiratory-rate windows** — median
    /// within-window CV 3.1% — against 15% of resting-heart-rate windows and 0.1% of HRV windows. So
    /// RR's denominator is usually `0.05 × mean` rather than its own observed spread.
    ///
    /// The direction is the safe one and worth stating: the floor *raises* the denominator, so a given
    /// respiratory-rate move draws a **smaller** bar than its own raw spread would give. RR reads
    /// conservatively. The alternative — dividing by the raw spread — would draw a 4σ bar off a
    /// three-breath difference on a thin window, which is the fabrication class this app forbids. And
    /// because all three metrics share the one window above, the floor cannot put two columns of one
    /// fast on two different scales.
    private struct FastingBaselines {
        let hrv: BaselineStatistics?
        let restingHeartRate: BaselineStatistics?
        let respiratoryRate: BaselineStatistics?

        init(window: [RecoveryMetric], hrvMetric: HRVMetric?) {
            // HRV is narrowed to the quantity in force — the never-mix rule. With no metric in force
            // there is no night to plot either, so the filter is unreachable with a `nil` metric and
            // `[]` is the honest empty.
            let hrvValues = hrvMetric.map { metric in
                window.filter { $0.hrvMetric == metric }.map(\.hrvValueMs)
            } ?? []

            // Resting heart rate does not depend on which HRV quantity was recorded, so it
            // legitimately draws on the whole window rather than the filtered subset —
            // `RecoveryScoring.baselines`' own reasoning, kept.
            let restingHeartRates = window.map { Double($0.restingHeartRate) }

            let respiratoryRates = window.compactMap(\.respiratoryRate)

            hrv = Self.baseline(hrvValues, fallbackMean: hrvMetric?.coldStartMeanMs ?? 0,
                                fallbackStdDev: hrvMetric?.coldStartStdDevMs ?? 0)
            restingHeartRate = Self.baseline(
                restingHeartRates,
                fallbackMean: RecoveryScoring.coldStartRestingHeartRateBaseline,
                fallbackStdDev: RecoveryScoring.coldStartRestingHeartRateStdDev)
            // No cold-start pair exists for respiratory rate anywhere in this app, which is a second
            // reason the count gate is not optional here.
            respiratoryRate = Self.baseline(respiratoryRates, fallbackMean: 0, fallbackStdDev: 0)
        }

        /// A baseline, or `nil` below the observation floor.
        ///
        /// The fallbacks are never read: the guard is what decides, and it fires at or above
        /// `minimumBaselineDays`, which is non-zero. They are passed because `baseline` requires them
        /// and because a `0` is the honest placeholder for "a constant this call is not allowed to
        /// reach for" — the alternative is a call site that looks like it wants the cold start.
        private static func baseline(
            _ values: [Double],
            fallbackMean: Double,
            fallbackStdDev: Double
        ) -> BaselineStatistics? {
            guard values.count >= RecoveryScoring.minimumBaselineDays else { return nil }
            return BaselineStatisticsMath.baseline(
                values, fallbackMean: fallbackMean, fallbackStdDev: fallbackStdDev)
        }
    }
}

private extension Optional where Wrapped == BaselineStatistics {
    /// The z-score of `value` against this baseline, or `nil` when there is no baseline to draw one
    /// against.
    ///
    /// **Every z on this page goes through here and therefore through
    /// `BaselineStatisticsMath.zScore`**, never an inline division. The clamp to
    /// `±maximumAbsoluteZScore` (4.0) lives only in that function, and `RecoveryMetric.restingHeartRate`
    /// is a non-optional `Int` carrying a reserved `0` on a placeholder row — an inline
    /// `(0 − 54) / 3.5` is `−15.4`, a bar fifteen σ long off a four-σ axis.
    func zScore(of value: Double) -> Double? {
        guard let baseline = self else { return nil }
        return BaselineStatisticsMath.zScore(
            value: value, mean: baseline.mean, stdDev: baseline.stdDev)
    }
}
