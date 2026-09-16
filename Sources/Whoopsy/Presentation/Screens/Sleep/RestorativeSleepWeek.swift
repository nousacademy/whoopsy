import Foundation

/// A week's restorative sleep — slow-wave and REM — as seven stacked columns.
///
/// It is a type rather than logic in `RestorativeSleepChartView`'s body for the reason
/// `HoursVsNeededWeek` and `WeekBarSeries` are: the test runner has no renderer, so a rule written
/// into a `View` is a rule nothing can assert. Three rules live here.
///
/// ## The axis is fitted to the totals *and to zero*
///
/// This is the one place this card parts from the two fitted-axis charts beside it, and it is forced
/// by the drawing rather than chosen. `HoursVsNeededChartView` plots points, so its axis can sit
/// wherever the week's readings do and every point still states its own value — that is what makes
/// `FittedAxis`'s refusal to force zero honest. A stacked column is the opposite case: **a bar's
/// height *is* its value**, so the foot of every bar has to be the axis' zero or the picture is a
/// proportion of a range nobody named.
///
/// The fix is to hand zero to the fit as one of the values rather than to override a bound
/// afterwards: `FittedAxis` snaps its foot down to a multiple of its step, and `0` is a multiple of
/// every step on the ladder, so including it in the values puts the foot at exactly `0` and lets the
/// ladder pick a step that holds the week's tallest night. Forcing `lowerBound = 0` after the fact
/// would instead leave a step chosen for a range the plot no longer has.
///
/// The cost is a coarser grid than a line chart on the same week — half the plot's bands are spent on
/// the empty space between the axis' foot and the shortest night — and that is the honest trade for a
/// bar. Every column carries its own total above it, so the axis is a guide and not the evidence.
///
/// ## The total is a sum taken here, not a third stored field
///
/// The figure over each column is `deep + rem` — `SleepSession.restorativeSleepSeconds`, the same
/// quantity the typical-range card's footer prints for one night. It is deliberately not carried as a
/// field of its own on `MetricDay` beside the two parts: three stored numbers can disagree, and two
/// parts with a derived total cannot.
///
/// ## No nights, no chart — and no zero foot, no chart either
///
/// A week the read returned nothing for draws no card rather than an empty frame, which is the rule
/// every chart in this app follows. The narrower case is a week whose every night slept *some* but
/// carried no deep and no REM in it: that is a real reading rather than an absence, but it is not a
/// drawing — seven zero-height columns are not a picture of anything, and `FittedAxis` would have to
/// invent a band around a single value to frame them. So the guard here is "at least one night has
/// something to stack", and a week with a *single* such night beside six empty ones is drawn, with the
/// empty ones as labelled columns carrying no bar.
///
/// **The second guard is on the fitted foot rather than on the input**, and it exists because of a
/// property of `FittedAxis` this chart is the first to be exposed to. That type widens a range
/// narrower than half a unit to `value ± 1` so a line chart of one repeated reading still has a band
/// to draw in — which, once zero is one of the values, means a week whose *tallest* night is under
/// half an hour comes back with its foot an hour **below** zero. A bar drawn against that axis has a
/// height that is not its value: a two-minute night and a twenty-minute one would take nearly the
/// same stub, because most of both bars is the hour of empty range underneath them. So the axis is
/// required to have its foot on zero, and a week that cannot produce one draws no card — the same
/// answer as a week with nothing to stack, for the same reason: no frame is better than a frame whose
/// scale is a fiction. The figure is not lost; the typical-range card above prints the night's own
/// restorative total.
public struct RestorativeSleepWeek: Equatable, Sendable {

    /// One plotted night: which column it belongs to, and the two stages in it.
    ///
    /// **The two stages are carried in seconds, and the total is computed from them.** The label is a
    /// clock reading — `formattedCompactHoursMinutes()` is defined on seconds — while the axis is
    /// fitted in hours, so carrying seconds and dividing at the two places that want a number keeps
    /// `7:31` from being rounded to `7.5` before it is printed. Same reasoning, same shape, as
    /// `HoursVsNeededWeek.Point`.
    ///
    /// **A night with no restorative sleep is a zero here, not an absence.** The two fields on
    /// `MetricDay` are nil for a day with no classified night and non-nil for a night the classifier
    /// read, so a night of unbroken light sleep really does arrive as `0 + 0`. One such night is in the
    /// bundled export — 2024-12-10, 15 hours 40 minutes of light sleep and no deep and no REM — and the
    /// chart draws it as a column with a `0:00` label over no bar, which is what it is.
    public struct Point: Equatable, Sendable {
        public let slot: Int
        public let deepSeconds: TimeInterval
        public let remSeconds: TimeInterval

        /// The night's restorative sleep: WHOOP's own sum of the two stages it calls restorative,
        /// taken here rather than stored beside them. See the type's comment.
        public var totalSeconds: TimeInterval { deepSeconds + remSeconds }

        /// The same duration in hours, which is the unit the axis is fitted and drawn in.
        public var totalHours: Double { totalSeconds / 3600 }

        public init(slot: Int, deepSeconds: TimeInterval, remSeconds: TimeInterval) {
            self.slot = slot
            self.deepSeconds = deepSeconds
            self.remSeconds = remSeconds
        }
    }

    /// The week's nights, in slot order. Only slots carrying a classified night appear.
    public let nights: [Point]

    /// The scale the columns are drawn against — fitted to the totals **and to zero**, so the foot of
    /// every bar is the axis' own zero. See the type's comment.
    public let axis: FittedAxis

    /// The week's nights, or nil when there is nothing to stack.
    ///
    /// The per-slot absence is already decided upstream — `MetricDay.deepSleepSeconds` and
    /// `.remSleepSeconds` are nil together for a day with no classified night — so the optionals are
    /// the whole rule and there is no second gate here to disagree with them. What is decided here is
    /// only the week-level one.
    public init?(week: MetricWeek) {
        let nights = week.days.enumerated().compactMap { slot, day -> Point? in
            // Both or neither, by construction — see `MetricDay`'s comment — so testing one is
            // testing the pair, and a slot is either plotted whole or not at all.
            guard let deep = day.deepSleepSeconds, let rem = day.remSleepSeconds else { return nil }
            return Point(slot: slot, deepSeconds: deep, remSeconds: rem)
        }
        guard !nights.isEmpty else { return nil }

        // At least one column with a stack in it, so the axis has a positive bound to fit. See the
        // type's comment for why this is not the same condition as "a week with no nights".
        let totals = nights.map(\.totalHours)
        guard totals.contains(where: { $0 > 0 }) else { return nil }

        // Zero is one of the values, not a bound forced afterwards: `FittedAxis` snaps its foot down
        // to a step multiple and every step is a multiple of zero, so this is what puts the bars'
        // foot on the axis' zero.
        //
        // The second half of the condition is the one that is easy to read as redundant and is not:
        // with zero in the values the foot can only miss zero by the degenerate-range expansion, and
        // an axis whose foot is below zero draws bars whose heights are not their values. See the
        // type's comment.
        guard let axis = FittedAxis(values: totals + [0]), axis.lowerBound == 0 else { return nil }

        self.nights = nights
        self.axis = axis
    }

    /// The week in one sentence: how many nights carry a night's restorative sleep, and the span they
    /// cover.
    ///
    /// A listener who cannot see the stack is told how complete the picture is, on
    /// `HoursVsNeededWeek.spokenSentence`'s rule — that type's sentence exists for the same reason and
    /// is worded the same way. The durations are spoken through `formattedHoursMinutes()` rather than
    /// the compact form the columns print, because `4:02` on screen is a clock reading to a listener
    /// and `4h 2m` is a duration.
    ///
    /// **The split is not spoken**, deliberately: it is carried by the two colours in the stack and by
    /// the legend, and it is the one thing on this card the drawing states and no figure does. A
    /// sentence reciting two numbers per night for seven nights would be a worse account of the week
    /// than the total it already gives.
    public var spokenSentence: String {
        let totals = nights.map(\.totalSeconds)
        guard let lowest = totals.min(), let highest = totals.max() else {
            return "Restorative sleep for the last seven days, no measurement"
        }
        return "Restorative sleep for the last seven days, "
            + "\(nights.count) of \(MetricWeek.dayCount) nights measured, "
            + "from \(lowest.formattedHoursMinutes()) to \(highest.formattedHoursMinutes())"
    }
}
