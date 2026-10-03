import Foundation

/// One workout read against the history of **that activity**, rather than against the user's last
/// thirty days.
///
/// It is the activity detail page's comparison model, and it exists because the app's other baseline —
/// `RecoveryScoring.baselineWindow(before:in:)` — is the wrong window for this question. That one is
/// *day*-keyed and caps at `baselineWindowDays` (30), which is right for a metric a body produces every
/// day and wrong for an activity a user does a few times a season. Measured over the bundled export,
/// a 30-day window leaves **20 of 28 `Basketball` sessions** with no baseline at all, where the last
/// ten sessions of that activity leave only 3. `SleepConsistencyMath`'s four-record window is this
/// repo's existing precedent for a sparse series, and this is the same answer for a sparser one.
///
/// The window is stated so it can be argued with: **the last `sessionWindowCount` sessions of the same
/// activity name, strictly before the session being described.**
///
/// **Every threshold here is this app's own.** WHOOP publishes a comparison against prior *activities*
/// on its activity page and publishes neither the window nor the statistic, so the ten-session window
/// and the 25th–75th percentile band are this app's, in the same bargain `SleepStageRangeScoring`,
/// `SleepBand` and `StressMath` each document: a figure this app computes will not match the WHOOP app's
/// on the same session.
public enum ActivityBaseline {

    /// How many prior sessions of one activity the comparison is taken over.
    ///
    /// Ten, and the number comes from a measurement rather than from the reference: over the bundled
    /// export this window beats a 30-calendar-day one on **every** activity that has any history at all
    /// and ties it on the dense ones (`Walking` 222 sessions: 219 banded either way; `Basketball` 28:
    /// 25 against 8; `Hiking` 17: 14 against 3; `Running` 10: 7 against 0). A calendar window is the
    /// wrong shape for an activity a user does occasionally, because a sparse series has to reach back
    /// far enough to find its own history and a calendar window refuses to.
    public static let sessionWindowCount = 10

    /// The band's ends — the middle half of prior sessions, the same quartile band
    /// `SleepStageRangeScoring` draws for a sleep stage, and the comparison WHOOP's own charts quote.
    /// Named rather than inlined so the suite can pin the definition the page is drawn from.
    public static let lowerPercentile = 0.25
    public static let upperPercentile = 0.75

    /// A band one quantity normally sits in, in that quantity's own unit.
    public struct Typical: Equatable, Sendable {
        /// The 25th percentile. Never greater than `high` — the initialiser orders the pair, so a
        /// caller holding two percentiles cannot produce an inverted band.
        public let low: Double
        /// The 75th percentile.
        public let high: Double

        public init(low: Double, high: Double) {
            self.low = min(low, high)
            self.high = max(low, high)
        }
    }

    /// The page's whole comparison content for one session.
    ///
    /// **Three independent floors, not one.** `sessionCount`, `stepSessionCount` and
    /// `strainSessionCount` are the counts their respective figures were taken over and are `0` exactly
    /// when those figures are `nil`, so `sessionCount == 0 ⟺ typicalDuration == nil`,
    /// `stepSessionCount == 0 ⟺ meanSteps == nil` and `strainSessionCount == 0 ⟺ meanStrain == nil`.
    /// They are separate rather than one condition because the populations are:
    ///
    /// - **duration** is non-optional on every session, so its population is the window itself — it and
    ///   `sessionCount` are the same number by construction;
    /// - **steps** are absent on every session this app did not record itself;
    /// - **strain** is absent on every session nothing measured — which until `v18` was no session at
    ///   all, and is now every fast.
    ///
    /// So a window of ten sessions can band its durations, have nothing to say about steps and have
    /// nothing to say about strain, and a page that conflated any two of them would draw a badge off a
    /// mean taken over no measurements.
    public struct Summary: Equatable, Sendable {

        /// How many sessions the bands were taken over. `0` when the window was too thin.
        public let sessionCount: Int

        /// The band this activity's duration normally sits in, or `nil` below the floor.
        ///
        /// **The one band the page draws**, because duration is the one quantity with a bar under it —
        /// `TYPICAL RANGE`'s track is a 0–100% scale of the session's own length. Strain and steps are
        /// compared against a mean on a badge and have no track, so a band for either would be a value
        /// with no reader.
        public let typicalDuration: Typical?

        /// The window's mean strain, or `nil` when fewer than the floor of prior sessions carried one.
        /// The strain badge's basis.
        public let meanStrain: Double?

        /// The window's mean step count, or `nil` when fewer than the floor of prior sessions carried
        /// one. The step badge's basis, and `nil` on every session this app can currently show.
        public let meanSteps: Double?

        /// How many prior sessions the step mean was taken over. `0` when there is no mean.
        public let stepSessionCount: Int

        /// How many prior sessions the strain mean was taken over. `0` when there is no mean.
        ///
        /// The third of the three populations. It is **not** `sessionCount`: a window of ten sessions
        /// of which three carry a strain has `sessionCount == 10` and `strainSessionCount == 3`, and
        /// the badge is drawn off the second.
        public let strainSessionCount: Int

        public init(
            sessionCount: Int,
            typicalDuration: Typical?,
            meanStrain: Double?,
            meanSteps: Double?,
            stepSessionCount: Int,
            strainSessionCount: Int
        ) {
            self.sessionCount = sessionCount
            self.typicalDuration = typicalDuration
            self.meanStrain = meanStrain
            self.meanSteps = meanSteps
            self.stepSessionCount = stepSessionCount
            self.strainSessionCount = strainSessionCount
        }
    }

    /// The sessions a comparison for `session` is taken over, oldest first.
    ///
    /// Three filters and a cap, in that order:
    ///
    /// 1. **The session is not its own baseline.** Excluded by identity as well as by instant, because
    ///    `startedAt` alone would admit a second copy of the same session that a caller had re-read
    ///    with a shifted start — and a session compared against itself draws a badge reading zero.
    /// 2. **The same activity name**, by `ActivityName.matches` — the rule `ActivityGlyph` keys its
    ///    drawing table by, so the page cannot group sessions one way and draw them another. **WHOOP's
    ///    abstention words are matched like any other name**: `Activity` and `Other` are names it
    ///    writes rather than absences it leaves, and 208 of the export's 673 rows carry one of them —
    ///    a group of that size is a history, not a hole.
    /// 3. **Strictly before the session's own `startedAt`.** An instant, not a calendar day: two
    ///    sessions on one day do not share a baseline, and the later of them can legitimately be
    ///    compared against the earlier. That is the whole reason this is not
    ///    `RecoveryScoring.baselineWindow`, whose `before:` is snapped to `startOfDay` on both sides
    ///    and whose rows are day-keyed — a `WorkoutSession` has no `date` to snap.
    ///
    /// The cap is applied **after** the filters, on `.suffix`, so it takes the ten most recent *matching*
    /// sessions rather than the most recent ten sessions of which some happen to match — the same
    /// ordering mistake `RecoveryScoring.window`'s doc comment names. `sessions` must therefore be
    /// oldest-first, which is what `WorkoutRepository.getWorkoutHistory(days:endingOn:)` returns.
    public static func window(
        for session: WorkoutSession, in sessions: [WorkoutSession]
    ) -> [WorkoutSession] {
        Array(
            sessions
                .filter { $0.id != session.id }
                .filter { ActivityName.matches($0.activityName, session.activityName) }
                .filter { $0.startedAt < session.startedAt }
                .suffix(sessionWindowCount))
    }

    /// One session's comparison against the window a caller has already taken.
    ///
    /// **`priorSessions` is trusted to be the window and is not re-filtered by date**, exactly as
    /// `SleepStageRangeScoring.summary(for:priorNights:)` trusts its own — `window(for:in:)` above is the
    /// one definition of it. The only filter applied here is the one belonging to these quantities.
    ///
    /// **A non-optional return, unlike its sleep sibling.** A `SleepSession` with no sleep period has
    /// nothing to describe and the card is then absent; a `WorkoutSession` always has a span and a name,
    /// so the page is always drawn and it is the *comparisons* that are withheld below the floor. (Since
    /// `v18` a session need not have a strain either — a fast has none — but that withholds the strain
    /// badge rather than the page, which is the third population below.)
    /// `RecoveryScoring.minimumBaselineDays` (3) is forwarded rather than restated, so this page
    /// and the Recovery screen cannot come to disagree about how much history a baseline needs.
    public static func summary(
        for session: WorkoutSession, priorSessions: [WorkoutSession]
    ) -> Summary {
        let window = priorSessions
        let banded = window.count >= RecoveryScoring.minimumBaselineDays

        let typicalDuration = banded ? band(window.map(\.durationSeconds)) : nil

        // The strain mean is a **third population**, and it was not one until `v18`. While every
        // session had a strain, the window and the strain population were the same set and taking the
        // mean over the window was right by construction. A fast has no strain, so they part company —
        // and averaging `?? 0` over one is worse than withholding the figure twice over: a window of
        // ten fasts reports a **fabricated** `meanStrain` of `0.0`, and a mixed window dilutes the true
        // mean with zeroes (three measured priors at `7.0` beside seven fasts would report `2.1`).
        //
        // So this is the step mean's own rule applied to strain, and it is the same second-population
        // gate one block below for the same reason.
        let strains = window.compactMap(\.strain)
        let strainBanded = strains.count >= RecoveryScoring.minimumBaselineDays
        let meanStrain = strainBanded ? BaselineStatisticsMath.mean(strains) : nil

        // The step mean is taken over a **second population**: the priors that carry a step count at
        // all. `nil` steps is the ordinary state of an imported session and of every row written before
        // `v17`, so averaging `?? 0` over them would report a mean step count of nearly zero for an
        // activity whose history this app simply has not measured — a fabricated comparison of exactly
        // the kind the reader gates on `StepCount.hasMeasurement` exist to prevent.
        let stepCounts = window.compactMap(\.steps).map(Double.init)
        let stepBanded = stepCounts.count >= RecoveryScoring.minimumBaselineDays
        let meanSteps = stepBanded ? BaselineStatisticsMath.mean(stepCounts) : nil

        return Summary(
            sessionCount: typicalDuration == nil ? 0 : window.count,
            typicalDuration: typicalDuration,
            meanStrain: meanStrain,
            meanSteps: meanSteps,
            stepSessionCount: meanSteps == nil ? 0 : stepCounts.count,
            strainSessionCount: meanStrain == nil ? 0 : strains.count)
    }

    /// The middle half of `values`, or `nil` when there is nothing to take a percentile of.
    ///
    /// `BaselineStatisticsMath.percentile` is R's `quantile(type = 7)` and NumPy's default, so the
    /// literals the suite pins are reproducible outside this codebase — the same reason
    /// `SleepStageRangeScoring` reads through it rather than carrying its own interpolation.
    private static func band(_ values: [Double]) -> Typical? {
        guard let low = BaselineStatisticsMath.percentile(values, at: lowerPercentile),
              let high = BaselineStatisticsMath.percentile(values, at: upperPercentile)
        else { return nil }
        return Typical(low: low, high: high)
    }
}
