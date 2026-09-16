import Foundation

/// The clock a night is plotted against: a window of the evening and morning, five ticks down it, and
/// the one conversion from the model's own frame back to a wall clock.
///
/// ## Why this is a type of its own
///
/// Two charts on the sleep detail screen plot a night by **when it happened** rather than by how much
/// of it there was: the consistency card's five spans and the time-in-bed card's seven. They ask the
/// same three questions of the scale — where does the window start, how wide does it have to be, and
/// what time is this position — and until the second chart existed those answers were written down
/// once, inside `SleepConsistencyChartLayout`. A second copy of them is a second clock: the two charts
/// would drift on the first re-measurement of the default window, and the failure would be one card
/// drawing a night an hour from where the other draws it, on the same page, about the same week.
///
/// So the scale moved here and the layout kept its own surface, forwarding. That refactor is visible to
/// the suite — §15 pins this axis' default labels, its anchor fractions and the fixture that widens it —
/// which is the test of whether a shared extraction is safe in this repo: a rule a `View`'s `body`
/// holds is a rule nothing can assert, and a rule these assertions can see is one they will catch.
///
/// ## The frame is the model's, and it pivots at noon
///
/// `0` is noon, `420` is 7 PM, `720` is midnight, `1140` is 7 AM — `SleepConsistencyMath`'s own
/// shifted frame, not minutes past midnight. The pivot is why: a night runs across midnight, so a
/// straight run of minutes puts a seam in the middle of every night, and no span can be drawn across
/// it. Read as a chart the frame is the evening at the top and the morning at the foot, so a whole
/// night is one contiguous run. `clockText` is the only bridge back and must not be inlined — see the
/// gotcha in `CLAUDE.md`, where handing a night-clock value straight to the clock formatter prints
/// twelve hours out and says nothing about it.
public struct SleepClockAxis: Equatable, Sendable {

    /// One tick of the scale down the leading edge.
    public struct Label: Equatable, Sendable, Identifiable {
        public var id: Int { index }

        /// Position in the label row, `0` first. The identity, because two labels can print the same
        /// string on a sufficiently narrow axis and a `String` id would collide.
        public let index: Int

        /// Distance down the plot, `0` at the top and `1` at the foot.
        public let fraction: Double

        /// The night-clock minute this tick sits on, so the suite can pin the mapping rather than
        /// the rendered string.
        public let minutes: Double

        /// `"7 PM"`, or `"10:30 PM"` when the tick falls between hours.
        public let text: String

        public init(index: Int, fraction: Double, minutes: Double, text: String) {
            self.index = index
            self.fraction = fraction
            self.minutes = minutes
            self.text = text
        }
    }

    /// The top of the axis, in night-clock minutes. `420` — 7 PM — unless a boundary widened it.
    public let startMinutes: Double

    /// The foot of the axis, in night-clock minutes. `1380` — 11 AM — unless a boundary widened it.
    public let endMinutes: Double

    /// The scale down the leading edge, `labelCount` of them from `startMinutes` to `endMinutes`.
    public let labels: [Label]

    /// The default window: 7 PM at the top, 11 AM at the foot.
    ///
    /// Sixteen hours, which leaves an hour of margin on either side of the widest night the export
    /// contains and is what makes the five ticks land on `7 PM / 11 PM / 3 AM / 7 AM / 11 AM` — the
    /// quarter points of a whole-hour window are whole hours, which is why the default axis needs no
    /// minutes in its labels at all.
    public static let defaultStartMinutes = 420.0
    public static let defaultEndMinutes = 1380.0

    /// Five, and the count is the reference's: four interior gaps, which is as many times of night as
    /// a reader can hold on one card without the labels crowding each other.
    public static let labelCount = 5

    /// Whether this frame can draw a night that began at `onset` and ended at `wake`, both on the
    /// night clock.
    ///
    /// **A span whose wake does not come after its own onset on the night clock contains noon**, and
    /// the axis runs from the evening at the top to the morning at the foot — so it has no seam at
    /// midday to cross and cannot represent such a span at all. An eleven-to-one afternoon row is two
    /// hours long and is refused; a fifteen-hour night that began in the evening is not, and it is the
    /// same comparison. Non-finite values are refused for the same reason `FittedAxis` refuses them: a
    /// position that is not a number is not a position.
    ///
    /// **The rule is here and the consequence is not.** The two charts answer a refused span
    /// differently, and each answer is the right one for its own shape: `SleepConsistencyChartLayout`
    /// draws **no chart**, because its five columns are one unit — an anchor and the four nights it was
    /// scored against — and four of five would silently change what the rules mean; `TimeInBedWeek`
    /// draws that night as **no column**, because its seven columns are seven independent readings on a
    /// frame that already renders "no night" as an empty column under a labelled day. Two policies, one
    /// rule, and the rule is stated once rather than restated by whichever caller forgot it.
    public static func isDrawable(onset: Double, wake: Double) -> Bool {
        onset.isFinite && wake.isFinite && wake > onset
    }

    /// The axis holding every boundary handed in, or `nil` when there are none to hold.
    ///
    /// **It widens in whole hours rather than clipping or dropping.** A boundary outside the default
    /// window pushes that edge out to the enclosing hour and no further — the rule
    /// `HoursOfSleepChartView` follows for a reading outside its own scale. Clipping would draw a mark
    /// at a position it does not have; dropping it would silently lose a night the card is about.
    /// `floor`/`ceil` to the hour rather than to the exact minute, so the axis stays a round number
    /// even on the night that moved it, and so the ticks keep landing on readable times.
    ///
    /// Measured on the bundled export this affects 1 night in 910 — the 16-hour night of 2024-12-09,
    /// whose 16:16 onset is above the default top — so the default window is what every night a user is
    /// likely to open looks like.
    ///
    /// `nil` for an empty boundary set, which no chart can reach: both series refuse a week or a window
    /// with no drawable night before they build an axis. It is refused rather than answered with the
    /// default window because an axis for nothing is a frame around no data, and every chart in this
    /// app draws nothing in that case.
    public init?(boundaries: [Double]) {
        guard !boundaries.isEmpty else { return nil }

        var start = Self.defaultStartMinutes
        var end = Self.defaultEndMinutes
        if let earliest = boundaries.min(), earliest < start {
            start = (earliest / 60).rounded(.down) * 60
        }
        if let latest = boundaries.max(), latest > end {
            end = (latest / 60).rounded(.up) * 60
        }
        guard start.isFinite, end.isFinite, end > start else { return nil }

        let span = end - start
        let divider = Double(max(1, Self.labelCount - 1))
        self.labels = (0..<Self.labelCount).map { index -> Label in
            let position = Double(index) / divider
            let minutes = start + position * span
            return Label(
                index: index,
                fraction: position,
                minutes: minutes,
                text: Self.clockText(forNightClockMinutes: minutes))
        }
        self.startMinutes = start
        self.endMinutes = end
    }

    /// Where a night-clock minute sits down the plot, `0` at the top and `1` at the foot.
    ///
    /// No clamp. A caller that reaches this with a value outside the window has built its axis from a
    /// different set of boundaries than it is drawing, and a clamped mark would stand at a position it
    /// does not have — the failure the widening above exists to prevent, moved somewhere a reader
    /// cannot see it.
    public func fraction(_ minutes: Double) -> Double {
        (minutes - startMinutes) / (endMinutes - startMinutes)
    }

    /// The one conversion from the model's own frame back to a clock.
    ///
    /// Here rather than at either call site because there are more than two of them — the consistency
    /// chart's two callouts, its card's spoken description, and both labels on every column of the
    /// time-in-bed card — and `SleepConsistencyMath.clockMinutes(fromNightClock:)` is the kind of
    /// inverse a caller gets wrong by an hour in one of them and not the others.
    public static func clockText(forNightClockMinutes minutes: Double) -> String {
        Date.formattedClock(
            minutesOfDay: SleepConsistencyMath.clockMinutes(fromNightClock: minutes))
    }
}
