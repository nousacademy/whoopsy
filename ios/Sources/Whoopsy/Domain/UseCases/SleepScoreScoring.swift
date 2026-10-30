import Foundation

/// The ring's sleep score: a weighted composite of the four things a night can be read on.
///
/// The app used to print `asleep ÷ need` under the label "Sleep Performance", which is a statement
/// about duration and nothing else. This type is the replacement: sufficiency (45), efficiency (20),
/// restorative share (20) and timing (15). A night with a missing term is scored over the weights it
/// does have — a renormalized mean — and the `Coverage` says how many terms that was.
///
/// ## Why these four, and why these weights
///
/// WHOOP publishes the *components* of its post-2025 sleep score — sufficiency, efficiency, sleep
/// stress and consistency — and none of the weights. This app has no producer for sleep stress, so
/// the restorative share stands in for that term. The 45/20/20/15 split is **this app's calibration**,
/// not WHOOP's: it keeps duration the largest single term because the export's own pre-gap column is
/// the duration ratio, while giving the three quality terms half the score between them. The
/// `docs/ALGORITHMS.md` §4 records the distribution it produces over the bundled export.
///
/// ## Components are printed integers
///
/// Every component is an `Int` 0…100, rounded once. The breakdown card already prints the sufficiency,
/// efficiency and consistency figures at that precision; computing the composite from the same
/// integers means the ring cannot disagree with the rows by a point of floating-point drift.
/// Restorative is the one term with no row: the typical-range card shows its raw share, while the
/// score normalizes that share against a 50% target (`restorativeTargetPercent`).
///
/// ## Absence, and the zero-need trap
///
/// A component with no denominator is **absent**, never zero and never 100. That is why the
/// sufficiency here is computed from the raw durations rather than through
/// `SleepSession.sleepSufficiencyPercentage`, whose `need > 0` guard returns a hard `100`: a night
/// with no stored need has no sufficiency, and the composite must renormalize instead of awarding it
/// full marks. The legacy property keeps its behaviour for the rows and the Recovery input; the two
/// are pinned together in the tests.
///
/// Fewer than two available components is no score at all. A single term is not a composite, and a
/// number built from one of four would read as a verdict on the night rather than on the data.
///
/// ## Timing has two sources
///
/// A night with four priors uses `SleepConsistencyMath`'s fitted boundary-consistency score; that is
/// boundary **regularity**, not circadian phase. A night without four priors falls back to
/// `CircadianAgeMath`, which reads its midpoint against an age-typical free-day mid-sleep window. The
/// fallback is a population prior and is only used when there is no personal consistency to prefer;
/// `Score.timingSource` records which one produced the term.
public enum SleepScoreScoring {

    /// The four terms of the composite, in the order the card and the coverage read them.
    public enum Component: String, CaseIterable, Hashable, Sendable {
        case sufficiency
        case efficiency
        case restorative
        case timing
    }

    /// Which model produced the timing term.
    public enum TimingSource: String, Equatable, Hashable, Sendable {
        /// `SleepConsistencyMath` — four prior nights, fitted to WHOOP's consistency column.
        case consistency
        /// `CircadianAgeMath` — an age-typical mid-sleep window, used only when consistency is absent.
        case agePrior
    }

    /// The weights, in points out of 100. This app's calibration; see the type's doc comment.
    public static let weights: [Component: Double] = [
        .sufficiency: 45,
        .efficiency: 20,
        .restorative: 20,
        .timing: 15,
    ]

    /// The restorative share that earns full marks. WHOOP's published guidance is "about 40–50% of
    /// total sleep"; the top of that range is used so the term is not already full at its bottom.
    public static let restorativeTargetPercent: Double = 50

    /// The bottom of that published range, exposed so the sleep page's sentence grades a night against
    /// the same guidance the term is scored from.
    ///
    /// **It is a bound of a published range, not a threshold this app invented.** `SleepStageShareMessage`
    /// says "below/inside/above the 40–50 %" from these two values, which is what stops the page's copy
    /// and the ring's restorative term from disagreeing about what "optimal" means on the same screen.
    public static let restorativeGuidanceLowerPercent: Double = 40

    /// How many of the four terms a score was built from.
    public struct Coverage: Equatable, Sendable {
        /// The terms that had a denominator, in `Component.allCases` order.
        public let available: [Component]
        /// The terms that did not, in the same order.
        public let missing: [Component]
        /// The sum of the available terms' weights — the score's denominator.
        public let weightCovered: Double

        public init(available: [Component], missing: [Component], weightCovered: Double) {
            self.available = available
            self.missing = missing
            self.weightCovered = weightCovered
        }

        /// Whether all four terms were available.
        public var isComplete: Bool { missing.isEmpty }
    }

    /// One night's score, its components and what it was built from.
    public struct Score: Equatable, Sendable {
        /// 0…100, the weighted mean over the available terms.
        public let value: Int
        /// Each available term's own 0…100 value.
        public let components: [Component: Int]
        /// How many terms were available, and which were not.
        public let coverage: Coverage
        /// Whether timing came from consistency or the age prior; `nil` when neither could score it.
        public let timingSource: TimingSource?

        public init(
            value: Int,
            components: [Component: Int],
            coverage: Coverage,
            timingSource: TimingSource?
        ) {
            self.value = value
            self.components = components
            self.coverage = coverage
            self.timingSource = timingSource
        }
    }

    /// The night's resolved consistency: the stored WHOOP figure first, else this app's model.
    ///
    /// Stored-first is `SleepViewModel.sleepConsistency`'s rule, lifted here so the consistency card,
    /// the composite and the week chart cannot each hold their own copy of it. A stored `0` is a
    /// measurement and is returned as one; only a missing value falls through to the model.
    public static func resolveConsistency(
        for session: SleepSession,
        history: [SleepSession],
        calendar: Calendar = .current
    ) -> Int? {
        if let stored = session.sleepConsistency { return stored }

        // The model takes the four most recent prior records from whatever it is handed, so the
        // caller's read width is the only thing that keeps a score from spanning a long recording
        // gap. `SleepConsistencyMath.historyLookbackDays` is that width: the score the anchor used
        // to get came from a twelve-day read, and the wide history the week is built from must not
        // silently widen it. The filter reproduces that read from the array already in hand.
        let cutoff = calendar.date(
            byAdding: .day, value: -SleepConsistencyMath.historyLookbackDays, to: session.date)
        let window = cutoff.map { day in history.filter { $0.date >= day } } ?? history

        return SleepConsistencyMath.consistency(
            for: SleepConsistencyScoring.night(from: session),
            history: window.map(SleepConsistencyScoring.night(from:)),
            calendar: calendar)
    }

    /// The components a night can produce, and which model supplied timing.
    ///
    /// `consistency` is passed in rather than read here because resolving it costs a history read at
    /// the caller's layer; the scorer is pure and must not reach for one.
    public static func components(
        for session: SleepSession,
        consistency: Int?,
        age: Int?,
        calendar: Calendar = .current
    ) -> (components: [Component: Int], timingSource: TimingSource?) {
        var components: [Component: Int] = [:]
        let asleep = session.totalTimeAsleepSeconds

        if session.targetSleepNeedSeconds > 0 {
            components[.sufficiency] = clamp(
                Int((asleep / session.targetSleepNeedSeconds * 100).rounded()))
        }

        if session.sleepPeriodSeconds > 0 {
            components[.efficiency] = clamp(
                Int((asleep / session.sleepPeriodSeconds * 100).rounded()))
        }

        if asleep > 0 {
            let sharePercent = session.restorativeSleepSeconds / asleep * 100
            components[.restorative] = clamp(
                Int((sharePercent / restorativeTargetPercent * 100).rounded()))
        }

        var timingSource: TimingSource?
        if let consistency {
            components[.timing] = clamp(consistency)
            timingSource = .consistency
        } else if let age,
            let timing = CircadianAgeMath.timingScore(
                for: SleepConsistencyScoring.night(from: session), age: age, calendar: calendar)
        {
            components[.timing] = clamp(timing)
            timingSource = .agePrior
        }

        return (components, timingSource)
    }

    /// The composite, or `nil` when fewer than two terms have a denominator.
    public static func score(
        for session: SleepSession,
        consistency: Int?,
        age: Int?,
        calendar: Calendar = .current
    ) -> Score? {
        let built = components(
            for: session, consistency: consistency, age: age, calendar: calendar)

        let available = Component.allCases.filter { built.components[$0] != nil }
        guard available.count >= 2 else { return nil }

        let weightCovered = available.reduce(0.0) { sum, component in
            sum + (weights[component] ?? 0)
        }
        guard weightCovered > 0 else { return nil }

        let weighted = available.reduce(0.0) { sum, component in
            sum + (weights[component] ?? 0) * Double(built.components[component] ?? 0)
        }

        return Score(
            value: clamp(Int((weighted / weightCovered).rounded())),
            components: built.components,
            coverage: Coverage(
                available: available,
                missing: Component.allCases.filter { built.components[$0] == nil },
                weightCovered: weightCovered),
            timingSource: built.timingSource)
    }

    /// Every night's score in a history, keyed by `startOfDay`.
    ///
    /// This is the one per-day entry point: `MetricWeek`, the Home ring, the sleep page's ring and the
    /// weekly chart all read it, so no screen can compute a different composite for the same night.
    /// `nights` is used both as the list being scored and as the history each night's consistency is
    /// read against; `SleepConsistencyMath.priorNights` filters to records before the night and
    /// truncates to four itself.
    public static func scores(
        for nights: [SleepSession],
        age: Int?,
        calendar: Calendar = .current
    ) -> [Date: Score] {
        var scores: [Date: Score] = [:]
        for session in nights {
            let consistency = resolveConsistency(
                for: session, history: nights, calendar: calendar)
            guard let score = score(
                for: session, consistency: consistency, age: age, calendar: calendar)
            else { continue }
            scores[calendar.startOfDay(for: session.date)] = score
        }
        return scores
    }

    private static func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}
