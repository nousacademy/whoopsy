import Foundation

/// A week's time in bed — seven nights as the span each one occupied on a clock.
///
/// A type rather than logic in `TimeInBedChartView`'s body for the reason `RestorativeSleepWeek` and
/// `HoursVsNeededWeek` are: the test runner has no renderer, so a rule written into a `View` is a rule
/// nothing can assert. Three rules live here, and one of them is a decision this chart takes
/// differently from the five-night chart beside it.
///
/// ## It is a clock chart, and the pair it plots is not a duration
///
/// Each column is one night placed by *when it happened*: a bar from its onset down to its wake on
/// `SleepClockAxis`. A bar's length is how long the night was and where it sits is when it was, which
/// is why the card labels **both of its ends** — the two figures on a column are a bedtime and a
/// waketime, and reading either as a duration is the mistake the labels exist to prevent. That is the
/// same distinction `SleepConsistencyChartView` draws for its five spans, on the same axis; what this
/// card adds is the seventh slot and the week's own frame.
///
/// ## A refused span costs its own column here, and the whole chart there
///
/// `SleepClockAxis.isDrawable` is the rule, and it refuses a night whose wake does not come after its
/// own onset on the night clock — a span containing noon, which the frame has no seam to cross. The
/// five-night card answers that by drawing nothing at all, because its five columns are one unit: an
/// anchor and the four nights it was scored against, where four of five would silently change what the
/// two rules over them mean. **This card answers it one column at a time**, and the difference is its
/// shape rather than a second opinion about the rule. Its seven columns are seven independent readings
/// on a frame that already draws "no night" as an empty column beneath a labelled day, so dropping one
/// costs a reader nothing they were not already told to expect — and refusing the week would hide six
/// good nights behind one bad row.
///
/// The refused night's boundaries are left out of the axis as well as off the plot, so a corrupt row
/// cannot move the scale the six honest ones are drawn against.
///
/// ## No nights, no chart
///
/// A week the read returned nothing for draws no card rather than an empty frame, which is the rule
/// every chart in this app follows. The same `SleepViewModel.week` the three cards above it read is the
/// input, so the four appear and disappear together rather than one drawing over a week another found
/// empty.
public struct TimeInBedWeek: Equatable, Sendable {

    /// One plotted night: which column it belongs to, and its two boundaries on the night clock.
    ///
    /// **Both are night-clock minutes, not minutes past midnight** — see
    /// `MetricDay.sleepOnsetMinutes`, which is where they are converted and where the twelve-hour trap
    /// is written down. The two labels a column prints come from `SleepClockAxis.clockText` and from
    /// nowhere else.
    ///
    /// The day is not carried: the column's weekday and day-of-month are the frame's
    /// (`WeekChartAxis.dateLabels`), and a second copy of a date here would be a second answer to which
    /// day a column is.
    public struct Point: Equatable, Sendable, Identifiable {
        public var id: Int { slot }

        /// The column, `0` oldest. The frame's own slot, so a bar and the day labelled under it cannot
        /// drift apart.
        public let slot: Int

        /// When the night began, on the night clock. Always less than `wakeMinutes`, which is the one
        /// thing this series refuses a night for.
        public let onsetMinutes: Double

        /// When it ended.
        public let wakeMinutes: Double

        /// Whether this is the night the page is showing — the week's own anchor.
        ///
        /// **Read by `spokenSentence` and by nothing on screen.** The drawing does not need it: the
        /// frame already tints the anchor's column behind the data (`WeekChartAxis.anchorColumn`), and
        /// the five-night card's second bar colour exists to separate an anchor from the four nights it
        /// was *scored against* — a comparison this card does not draw, so a second colour here would
        /// be a distinction with nothing behind it.
        ///
        /// It is carried rather than derived at the point of use because the only place that wants it
        /// has no `MetricWeek` to hand, and the alternative — the anchor being the last slot because
        /// the slots run oldest-first — is a property of `MetricWeek.init` that a reader here would
        /// have to go and confirm. Recorded at the join, where the dates are.
        public let isAnchor: Bool

        /// How long the night spanned, in minutes. Derived rather than stored, on
        /// `RestorativeSleepWeek.Point.totalSeconds`' rule: two stored numbers and their difference
        /// cannot disagree, and a third stored field can.
        public var spanMinutes: Double { wakeMinutes - onsetMinutes }

        /// The bedtime this column prints above its bar.
        public var onsetText: String { SleepClockAxis.clockText(forNightClockMinutes: onsetMinutes) }

        /// The waketime it prints below its bar.
        public var wakeText: String { SleepClockAxis.clockText(forNightClockMinutes: wakeMinutes) }

        public init(slot: Int, onsetMinutes: Double, wakeMinutes: Double, isAnchor: Bool = false) {
            self.slot = slot
            self.onsetMinutes = onsetMinutes
            self.wakeMinutes = wakeMinutes
            self.isAnchor = isAnchor
        }
    }

    /// The week's nights, in slot order. Only slots carrying a drawable night appear.
    public let nights: [Point]

    /// The clock the nights are drawn against, widened to hold every boundary a drawn night has.
    public let axis: SleepClockAxis

    /// The week's nights, or nil when there is no chart to draw.
    ///
    /// The per-slot absence is already decided upstream — `MetricDay.sleepOnsetMinutes` and
    /// `.sleepWakeMinutes` are nil together for a day with no classified night — so those optionals are
    /// the whole of the first rule and there is no second gate here to disagree with them. What is
    /// decided here is the second rule, `SleepClockAxis.isDrawable`, and the week-level one.
    public init?(week: MetricWeek) {
        let nights = week.days.enumerated().compactMap { slot, day -> Point? in
            // Both or neither, by construction — see `MetricDay`'s comment — so testing one is testing
            // the pair, and a slot is either plotted whole or not at all.
            guard let onset = day.sleepOnsetMinutes, let wake = day.sleepWakeMinutes else { return nil }
            // A span the frame cannot represent draws no column. See the type's comment for why this
            // costs one column here and the whole chart on the five-night card.
            guard SleepClockAxis.isDrawable(onset: onset, wake: wake) else { return nil }
            return Point(
                slot: slot,
                onsetMinutes: onset,
                wakeMinutes: wake,
                isAnchor: day.date == week.endingOn)
        }
        guard !nights.isEmpty else { return nil }

        // Only the nights that will be drawn widen the axis, so a refused row cannot move the scale
        // the others are read against.
        let boundaries = nights.flatMap { [$0.onsetMinutes, $0.wakeMinutes] }
        guard let axis = SleepClockAxis(boundaries: boundaries) else { return nil }

        self.nights = nights
        self.axis = axis
    }

    /// The week in one sentence: how many nights it draws, and the night the page is showing.
    ///
    /// A listener who cannot see the spans is told how complete the picture is, on
    /// `RestorativeSleepWeek.spokenSentence`'s rule — that type's sentence exists for the same reason
    /// and is worded the same way. **The one night named is the anchor**, because that is the night the
    /// page is about and the only column a listener has any other figure for; reading out seven pairs
    /// of times would be a listener's version of counting the bars.
    ///
    /// **The anchor's own two times and not a range over the week**, which is the one place this
    /// sentence parts from its two siblings: a week's earliest bedtime and latest waketime are two
    /// clock times with no relation to each other, and `"from 10:41 PM to 8:03 AM"` would read as one
    /// long night. `HoursVsNeededWeek` can speak a range because its two ends are durations.
    ///
    /// A week whose anchor day carries no night — a fresh install's first day, which is exactly the
    /// case this card's gate is built for — says so rather than borrowing a neighbouring column's
    /// times.
    public var spokenSentence: String {
        let measured = "Time in bed for the last seven days, "
            + "\(nights.count) of \(MetricWeek.dayCount) nights measured"
        guard let anchor = nights.first(where: \.isAnchor) else {
            return measured + ", no night on the day shown"
        }
        return measured + ", last night \(anchor.onsetText) to \(anchor.wakeText)"
    }
}
