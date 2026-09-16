import Foundation

/// One night's Sleep Consistency as the screen draws it: five nights as spans on a clock, the two
/// rules they are read against, and the figure that comparison produces.
///
/// It is the sleep detail screen's **consistency card** in value form, and it is the same shape
/// `SleepStageRangeScoring` gives the typical-range card and `RecoveryScoring` gives the Recovery
/// screen: a pure scoring helper rather than a use case, holding the arithmetic a screen would
/// otherwise spell out in its own `body` — where this repo's test runner, which has no renderer,
/// could not assert any of it.
///
/// ## What the chart is, and what it is not
///
/// The bars are **not** the score. Each one is a night drawn as the span from its onset to its wake on
/// a time-of-day axis, so a bar's height is how long the night was and where it sits is when it
/// happened. The score is the figure printed above the chart, and it comes from
/// `SleepConsistencyMath` — this type does not compute one, it carries the answer in.
///
/// That is also why the window is **five nights and not a week**: `SleepConsistencyMath` reads a night
/// against its four predecessors, so the four grey bars *are* the reference the fifth was scored
/// against, and the two dashed rules are their recency-weighted mean. A reader can check the rule
/// against the bars by eye, which no other arrangement of this chart allows.
///
/// ## The two rules are a construction, and the screen says so
///
/// WHOOP draws the pair as `OPTIMAL BED/WAKETIME`. Nothing in this app produces a recommendation —
/// there is no circadian-phase model and no sleep-need-derived target in any column — so what is
/// computed here is the **average** of the same four nights the score already reads, and
/// `SleepConsistencyMath.typicalBoundaries` carries the argument. The legend names it `AVG
/// BED/WAKETIME` rather than borrowing a word this app cannot honour.
///
/// The rules move when the day stepper does, because the window moves with the anchor. Measured over
/// the bundled export the derived rule has a p05–p95 spread of 2.6 hours, which is honest and visible
/// rather than a bug: the alternative — the 30-day window the card's own comparison uses — holds
/// stiller and then disagrees with the score printed directly above it.
public enum SleepConsistencyScoring {

    /// One night as a bar: its day, its two boundaries on the night clock, and whether it is the night
    /// the card is about.
    public struct Bar: Equatable, Sendable, Identifiable {
        /// The day the night is keyed on, which is what the column's weekday label prints.
        public var id: Date { date }
        public let date: Date

        /// Minutes on the night clock — see `SleepConsistencyMath.nightClockMinutes`. **Smaller is
        /// later in the evening**: the frame pivots at noon, so 7 PM is 420 and 11 AM is 1380.
        public let onsetMinutes: Double
        public let wakeMinutes: Double

        /// Whether this is the night the card describes, drawn in the accent colour. The other four
        /// are the reference it was scored against.
        public let isAnchor: Bool

        public init(
            date: Date, onsetMinutes: Double, wakeMinutes: Double, isAnchor: Bool
        ) {
            self.date = date
            self.onsetMinutes = onsetMinutes
            self.wakeMinutes = wakeMinutes
            self.isAnchor = isAnchor
        }
    }

    /// The card's whole content: the five nights, the two rules, and the figure over its window mean.
    ///
    /// `score` is not optional and the initialiser is not reachable without four priors, so a summary
    /// that exists always has a figure to head it. That is the card's absence rule stated once: a
    /// night this app cannot score draws **no card at all** rather than a chart with a dash over it,
    /// which is the same judgement the typical-range card makes one element up the page.
    public struct Summary: Equatable, Sendable {
        /// Oldest first, so the columns run left to right in time and the anchor is last — the order
        /// `MetricWeek.days` uses, and the order `WeekChartAxis` labels in.
        public let bars: [Bar]

        /// The average onset of the four priors, in night-clock minutes.
        public let typicalOnsetMinutes: Double

        /// The average wake of the four priors, in night-clock minutes.
        public let typicalWakeMinutes: Double

        /// The night's own consistency — WHOOP's stored figure on an imported night, this app's on a
        /// strap night. Resolved by the caller, because resolving it costs a repository read.
        public let score: Int

        /// The mean consistency over the window, or `nil` below `RecoveryScoring.minimumBaselineDays`
        /// scored nights.
        ///
        /// A `Double` rather than the `Int` a night's own score is, for
        /// `SleepStageRangeScoring.Summary.typicalPerformancePercent`'s reason: it is a mean of the
        /// window, and rounding each night before averaging would move the mean by up to half a point
        /// on every window. `MetricChange` then decides "these print alike" on the formatted pair,
        /// which is where the rounding belongs.
        public let typicalScore: Double?

        public init(
            bars: [Bar],
            typicalOnsetMinutes: Double,
            typicalWakeMinutes: Double,
            score: Int,
            typicalScore: Double?
        ) {
            self.bars = bars
            self.typicalOnsetMinutes = typicalOnsetMinutes
            self.typicalWakeMinutes = typicalWakeMinutes
            self.score = score
            self.typicalScore = typicalScore
        }
    }

    /// The night as the consistency model reads it: the two boundaries and the day key.
    ///
    /// Public because `SleepConsistencyMath.Night` is a `Core` type built from a `Domain` entity, and
    /// both the view model's two resolutions and the scorer below need the same mapping. Two copies of
    /// it would be two answers to "which field is the onset".
    public static func night(from session: SleepSession) -> SleepConsistencyMath.Night {
        SleepConsistencyMath.Night(
            day: session.date, onset: session.startTime, wake: session.endTime)
    }

    /// The five nights, the two rules and the figure, or `nil` when there is nothing to draw.
    ///
    /// `nil` in exactly one case: fewer than four prior nights in `history`, which is
    /// `SleepConsistencyMath`'s own gate forwarded rather than restated — the score cannot exist
    /// without them, and neither can the rule. The caller has therefore already resolved `score` by
    /// the same four records; a caller that has not is a caller that has not established the thing
    /// this summary is.
    ///
    /// - Parameters:
    ///   - session: The night the card describes.
    ///   - history: Other nights, in any order — the same array the score was resolved against. A
    ///     night's own day must sort before the target's to count, so a forward-dated row cannot be
    ///     drawn as a prior.
    ///   - score: The night's resolved consistency, printed above the chart.
    ///   - typicalScore: The window mean, or `nil` below the count floor.
    ///   - calendar: The calendar the clock times are read in.
    public static func summary(
        for session: SleepSession,
        history: [SleepSession],
        score: Int,
        typicalScore: Double?,
        calendar: Calendar = .current
    ) -> Summary? {
        let target = night(from: session)
        let others = history.map(night(from:))

        let priors = SleepConsistencyMath.priorNights(for: target, history: others)
        guard priors.count == SleepConsistencyMath.priorNightCount,
              let typical = SleepConsistencyMath.typicalBoundaries(
                for: target, history: others, calendar: calendar)
        else {
            return nil
        }

        // Oldest first, so the last column is the anchor. `priorNights` is newest-first because the
        // weights are read off it in that order; the chart reads left to right in time, so it is
        // reversed once here rather than at each of the drawing's two callers.
        let bars = priors.reversed().map { bar(for: $0, isAnchor: false, calendar: calendar) }
            + [bar(for: target, isAnchor: true, calendar: calendar)]

        return Summary(
            bars: bars,
            typicalOnsetMinutes: typical.onsetMinutes,
            typicalWakeMinutes: typical.wakeMinutes,
            score: score,
            typicalScore: typicalScore)
    }

    /// The window's mean consistency, **resolved night by night and stored first**.
    ///
    /// The stored-first rule is `SleepViewModel.sleepConsistency`'s, applied to a whole window: an
    /// imported night carries WHOOP's own figure in `sleeps.sleep_consistency` and that is what is
    /// averaged, because this app does not overwrite a measurement with its own estimate. A strap
    /// night carries none and is computed from the same `history`.
    ///
    /// **A night neither path can score is left out of the mean rather than counted as a zero**, which
    /// is the whole reason this is a helper and not three lines on a view: a window of thirty nights
    /// whose first four have no priors would otherwise average four zeroes into the figure printed
    /// under the headline, and a `0%` consistency is a claim about a night rather than an absence.
    ///
    /// `history` must be the **wide** read — `RecoveryScoring.baselineWindowLookbackDays` back, not
    /// `SleepConsistencyMath.historyLookbackDays` — because a night inside `window` computes its own
    /// score from its own four predecessors, and the oldest nights in a 30-day window need records
    /// from before it. A read of twelve days would score the window's oldest nights against a history
    /// that stops at their own edge.
    ///
    /// - Parameters:
    ///   - window: The nights to average, already narrowed by
    ///     `RecoveryScoring.baselineWindow(before:in:)` at the caller — this type does not re-window,
    ///     on `SleepStageRangeScoring.summary`'s reasoning, so the card and the page's other
    ///     "typical" figures cannot come to describe different histories.
    ///   - history: Nights to read each window night's own score against.
    public static func typicalScore(
        in window: [SleepSession],
        history: [SleepSession],
        calendar: Calendar = .current
    ) -> Double? {
        let others = history.map(night(from:))
        let scores = window.compactMap { session -> Int? in
            if let stored = session.sleepConsistency { return stored }
            return SleepConsistencyMath.consistency(
                for: night(from: session), history: others, calendar: calendar)
        }
        guard scores.count >= RecoveryScoring.minimumBaselineDays else { return nil }
        return Double(scores.reduce(0, +)) / Double(scores.count)
    }

    private static func bar(
        for night: SleepConsistencyMath.Night, isAnchor: Bool, calendar: Calendar
    ) -> Bar {
        Bar(
            date: night.day,
            onsetMinutes: SleepConsistencyMath.nightClockMinutes(night.onset, calendar: calendar),
            wakeMinutes: SleepConsistencyMath.nightClockMinutes(night.wake, calendar: calendar),
            isAnchor: isAnchor)
    }
}
