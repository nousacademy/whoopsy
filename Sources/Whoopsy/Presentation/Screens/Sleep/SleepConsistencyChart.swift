import SwiftUI

/// Where the sleep-consistency chart's five nights and two rules sit, as fractions of the plot.
///
/// **A value rather than arithmetic in a `body`, for the reason `SleepNeedBarLayout` and
/// `TypicalRangeBarLayout` are**: this repo's suite has no renderer, so a rule written into a `View`
/// is a rule nothing can assert. Three of the rules below fail silently on screen — an axis that
/// clipped an out-of-range boundary instead of widening (the bar would stand at a position it does
/// not have), a bar whose two ends were placed in the wrong order, and a callout printing minutes
/// out of the model's shifted frame rather than off a clock — and each is asserted in the runner.
///
/// ## The axis is the night clock, and the chart owns its own scale
///
/// The default window is `7 PM → 11 AM` — night-clock `420 … 1380`, `SleepConsistencyMath`'s
/// noon-pivot frame read as a chart: evening at the top, morning at the bottom, so a whole night is
/// one contiguous run with no midnight seam inside it. `WeekChartAxis` is **not** reused, and the
/// reason is geometry rather than taste: that type is a seven-column weekday axis with one label row
/// under it, while this chart has five columns, a labelled scale down its leading edge and a second
/// gutter trailing it. Bending it would move the Strain & Recovery chart to draw this one, which is
/// the same reasoning `WeekChartAxis`'s own doc comment gives for `StrainRecoveryChartView`.
///
/// **The axis widens in whole hours rather than clipping or dropping.** A boundary outside the
/// default window pushes that edge out to the enclosing hour and no further — the rule
/// `HoursOfSleepChartView` follows for a reading outside its own scale. Clipping would draw the bar
/// at a position it does not have; dropping the night would silently lose one of the five the card
/// is about, and the anchor is one of them. Measured on the bundled export this affects 1 night in
/// 910, so the default window is what every night a user is likely to open looks like.
///
/// ## The two rules are placed here and computed elsewhere
///
/// The pair arrives on `SleepConsistencyScoring.Summary` from
/// `SleepConsistencyMath.typicalBoundaries`, and this type only turns it into fractions. It is the
/// mean of the four priors and **not a target**, which is why the card's legend says `AVG` where the
/// reference says `OPTIMAL` — the argument for that is on `typicalBoundaries`.
///
/// The rules' own minutes are part of the widening set, so a mean that fell outside the bars' span
/// moves the axis with them instead of being drawn off the edge. In practice it never does — a
/// circular mean of the four priors lies inside their arc, and the priors are inside the axis — but
/// "in practice" is not a reason to leave a rule undrawable.
public struct SleepConsistencyChartLayout: Equatable, Sendable {

    /// One tick of the scale down the leading edge.
    public struct AxisLabel: Equatable, Sendable, Identifiable {
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

    /// One night as the chart draws it: a span down the plot, and whether it is the night the card is
    /// about.
    public struct Bar: Equatable, Sendable, Identifiable {
        public var id: Date { date }

        /// The day the night is keyed on, which is also the column's weekday label.
        public let date: Date

        /// Whether this is the night the card describes, drawn in the accent colour. The other four
        /// are the reference it was scored against.
        public let isAnchor: Bool

        /// Distance down the plot at which the night began — its onset. Always less than
        /// `bottomFraction`, which is the one thing `init?` refuses a night for.
        public let topFraction: Double

        /// Distance down the plot at which it ended — its wake.
        public let bottomFraction: Double

        /// The bar's length as a fraction of the plot, which is the night's duration on this scale.
        public var heightFraction: Double { bottomFraction - topFraction }

        public init(date: Date, isAnchor: Bool, topFraction: Double, bottomFraction: Double) {
            self.date = date
            self.isAnchor = isAnchor
            self.topFraction = topFraction
            self.bottomFraction = bottomFraction
        }
    }

    /// Five bars, oldest first, the anchor last.
    public let bars: [Bar]

    /// The scale down the leading edge, `axisLabelCount` of them from `axisStartMinutes` to
    /// `axisEndMinutes`.
    public let axisLabels: [AxisLabel]

    /// The top of the axis, in night-clock minutes. `420` — 7 PM — unless a boundary widened it.
    public let axisStartMinutes: Double

    /// The foot of the axis, in night-clock minutes. `1380` — 11 AM — unless a boundary widened it.
    public let axisEndMinutes: Double

    /// Where the average onset rule is drawn.
    public let typicalOnsetFraction: Double

    /// Where the average wake rule is drawn.
    public let typicalWakeFraction: Double

    /// The average onset as a clock time — `"11:54 PM"` — for the callout at the rule's trailing end.
    public let typicalOnsetText: String

    /// The average wake as a clock time.
    public let typicalWakeText: String

    /// The reference's own window: 7 PM at the top, 11 AM at the foot.
    ///
    /// Sixteen hours, which leaves an hour of margin on either side of the widest night the export
    /// contains and is what makes the five ticks land on the reference's own `7 PM / 11 PM / 3 AM /
    /// 7 AM / 11 AM` — the quarter points of a whole-hour window are whole hours, which is why the
    /// default axis needs no minutes in its labels at all.
    public static let defaultAxisStartMinutes = 420.0
    public static let defaultAxisEndMinutes = 1380.0

    /// Five, and the count is the reference's: four interior gaps, which is as many times of night as
    /// a reader can hold on one card without the labels crowding each other.
    public static let axisLabelCount = 5

    /// The one conversion from the model's own frame back to a clock.
    ///
    /// Here rather than at either call site because there are three of them — the two callouts and
    /// the card's spoken description — and `SleepConsistencyMath.clockMinutes(fromNightClock:)` is
    /// the kind of inverse a caller gets wrong by an hour in one of the three and not the others.
    public static func clockText(forNightClockMinutes minutes: Double) -> String {
        Date.formattedClock(
            minutesOfDay: SleepConsistencyMath.clockMinutes(fromNightClock: minutes))
    }

    /// The five nights, the scale and the two rules, or `nil` when there is no chart to draw.
    ///
    /// `nil` when the summary is empty, when a boundary is not a finite number of minutes, and when
    /// **a night's wake does not come after its own onset on the night clock** — an interval
    /// containing noon, since the axis runs from the evening at the top to the morning at the foot and
    /// so cannot represent a span that passes back through the top of its own frame. All three are
    /// corrupt rows rather than ordinary absences, and a caller with no layout draws no chart rather
    /// than a picture of a bad row. `SleepNeedBarLayout` refuses a non-positive scale on the same
    /// terms; the figure above this chart is a reading and is drawn either way.
    ///
    /// **The refused condition is about the interval and not about its length.** An eleven-to-one
    /// afternoon row is two hours long and is refused; a fifteen-hour night that began in the evening
    /// is refused for the same reason, and it is the same comparison. What the axis cannot draw is a
    /// night whose onset and wake are on opposite sides of midday, because the frame has no seam
    /// there to cross.
    public init?(summary: SleepConsistencyScoring.Summary) {
        let nights = summary.bars.map { ($0.onsetMinutes, $0.wakeMinutes) }
        let rules = (summary.typicalOnsetMinutes, summary.typicalWakeMinutes)

        guard !nights.isEmpty,
              nights.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0 }),
              rules.0.isFinite, rules.1.isFinite, rules.1 > rules.0
        else { return nil }

        // Widen, in whole hours, to hold every boundary the chart has to draw — the bars' and the two
        // rules'. `floor`/`ceil` to the hour rather than to the exact minute, so the axis stays a
        // round number even on the night that moved it, and so the ticks keep landing on readable
        // times.
        let boundaries = nights.flatMap { [$0.0, $0.1] } + [rules.0, rules.1]
        var start = Self.defaultAxisStartMinutes
        var end = Self.defaultAxisEndMinutes
        if let earliest = boundaries.min(), earliest < start {
            start = (earliest / 60).rounded(.down) * 60
        }
        if let latest = boundaries.max(), latest > end {
            end = (latest / 60).rounded(.up) * 60
        }
        guard end > start else { return nil }

        let span = end - start
        func fraction(_ minutes: Double) -> Double { (minutes - start) / span }

        let divider = Double(max(1, Self.axisLabelCount - 1))
        let labels = (0..<Self.axisLabelCount).map { index -> AxisLabel in
            let position = Double(index) / divider
            let minutes = start + position * span
            return AxisLabel(
                index: index,
                fraction: position,
                minutes: minutes,
                text: Self.clockText(forNightClockMinutes: minutes))
        }

        self.bars = summary.bars.map {
            Bar(
                date: $0.date,
                isAnchor: $0.isAnchor,
                topFraction: fraction($0.onsetMinutes),
                bottomFraction: fraction($0.wakeMinutes))
        }
        self.axisLabels = labels
        self.axisStartMinutes = start
        self.axisEndMinutes = end
        self.typicalOnsetFraction = fraction(rules.0)
        self.typicalWakeFraction = fraction(rules.1)
        self.typicalOnsetText = Self.clockText(forNightClockMinutes: rules.0)
        self.typicalWakeText = Self.clockText(forNightClockMinutes: rules.1)
    }
}

/// Five nights drawn as spans on a clock, with the average of the four oldest ruled across them.
///
/// **It is a time-of-day chart, not a duration chart, and the difference is what its bars mean.** A
/// bar's length is how long that night was; where it sits is when it happened. Two nights of the same
/// length at different hours are two bars of the same height at different places, which is the whole
/// of what consistency is and what a duration chart cannot show.
///
/// **The two rules are drawn over the bars, and the bars are not drawn over each other.** Each column
/// is a night so the bars never overlap horizontally, and the rules lie across all five — which is
/// what makes them read as a property of the *window* rather than of any one night. They are the last
/// thing in the stack for that reason.
///
/// **There are no gridlines.** The five ticks down the leading edge are labels, and the bars' own ends
/// are what a reader measures against them; a line ruled across at each tick would put five more
/// horizontals on the card and leave the two dashed rules competing with them for the eye, which is
/// the opposite of what a mark that is the card's comparison should do. This is a decision and not an
/// omission — a later reader comparing this against a reference that does carry gridlines should read
/// this paragraph before adding them.
///
/// **The two callouts sit in a trailing gutter rather than on the bars.** The rules have to be
/// readable at their own ends, and a value written over five bars is a value written over a bar; the
/// gutter is the same shape the leading edge already uses for its scale. It also means the two cannot
/// collide: they are one average night's length apart, and a callout is about a tenth of the plot's
/// height.
struct SleepConsistencyChartView: View {
    let layout: SleepConsistencyChartLayout

    /// The plot's height. Deep enough that a three-hour night is still a visible span — at the default
    /// sixteen-hour axis that is a fifth of it — and shallow enough that the card does not push the
    /// need card off the page.
    static let plotHeight: CGFloat = 168

    /// Room for `"11:54 PM"` at `11`pt, which is the widest string either gutter holds.
    private static let leadingGutterWidth: CGFloat = 40
    private static let trailingGutterWidth: CGFloat = 58

    /// Half a label's line, so the tick at each end is centred on the axis rather than clipped by the
    /// frame. Applied to the plot's fractions too, so a bar and the tick beside it agree on where the
    /// axis starts.
    private static let labelInset: CGFloat = 9

    private static let maximumBarWidth: CGFloat = 26
    private static let minimumBarWidth: CGFloat = 4
    private static let columnSpacing: CGFloat = 6

    /// A short night still has to be visible: half an hour on the default axis is 5pt, and an hour
    /// night is under a point of antialiased ink. This is a floor on the *drawing* and not on the
    /// value — the bar's ends are still where the fractions put them, so the floor can only lengthen
    /// a bar, never move one.
    private static let minimumBarHeight: CGFloat = 2

    private static let barCornerRadius: CGFloat = 3
    private static let ruleLineWidth: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                scale
                plot
                callouts
            }
            .frame(height: Self.plotHeight)

            weekdayRow
        }
    }

    // MARK: - The scale

    /// The five ticks, each centred on the height its minute sits at.
    ///
    /// `.position` rather than an offset, because it centres the label on the point — a text view's
    /// height is not a number this file should be writing down, and an offset would need half of it
    /// to keep the tick beside the bar it belongs to.
    private var scale: some View {
        GeometryReader { proxy in
            let usable = plotHeight(in: proxy.size.height)
            ZStack {
                ForEach(layout.axisLabels) { label in
                    Text(label.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: Self.leadingGutterWidth, alignment: .trailing)
                        .position(
                            x: Self.leadingGutterWidth / 2,
                            y: Self.labelInset + usable * label.fraction)
                }
            }
        }
        .frame(width: Self.leadingGutterWidth)
    }

    // MARK: - The nights

    private var plot: some View {
        GeometryReader { proxy in
            let usable = plotHeight(in: proxy.size.height)
            let column = proxy.size.width / CGFloat(max(1, layout.bars.count))
            let barWidth = min(
                Self.maximumBarWidth,
                max(Self.minimumBarWidth, column - Self.columnSpacing))

            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.bars.enumerated()), id: \.element.id) { index, bar in
                    RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous)
                        .fill(bar.isAnchor ? Theme.sleepConsistencyBar : Theme.sleepConsistencyPriorBar)
                        .frame(
                            width: barWidth,
                            height: max(Self.minimumBarHeight, usable * bar.heightFraction))
                        .offset(
                            x: column * CGFloat(index) + (column - barWidth) / 2,
                            y: Self.labelInset + usable * bar.topFraction)
                }

                // Last in the stack, so they lie over the bars rather than under them.
                rule(at: Self.labelInset + usable * layout.typicalOnsetFraction, width: proxy.size.width)
                rule(at: Self.labelInset + usable * layout.typicalWakeFraction, width: proxy.size.width)
            }
        }
        .clipped()
    }

    /// One dashed rule across the plot. The colour and the dash are the band mark's, so the app has
    /// one dashed rule and not two that can drift apart.
    private func rule(at y: CGFloat, width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(
            Theme.bandMarkEdge,
            style: StrokeStyle(lineWidth: Self.ruleLineWidth, dash: TypicalRangeBar.markDash))
    }

    // MARK: - The rules' values

    /// The two averages, each centred on its own rule and at the trailing edge.
    ///
    /// `Theme.textSecondary` rather than the muted grey of the scale: these two are the card's
    /// comparison and the scale is a yardstick, so the values a reader came for are the brighter pair.
    private var callouts: some View {
        GeometryReader { proxy in
            let usable = plotHeight(in: proxy.size.height)
            ZStack {
                callout(
                    text: layout.typicalOnsetText,
                    y: Self.labelInset + usable * layout.typicalOnsetFraction)
                callout(
                    text: layout.typicalWakeText,
                    y: Self.labelInset + usable * layout.typicalWakeFraction)
            }
        }
        .frame(width: Self.trailingGutterWidth)
    }

    private func callout(text: String, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: Self.trailingGutterWidth, alignment: .leading)
            .position(x: Self.trailingGutterWidth / 2, y: y)
    }

    // MARK: - The columns' names

    /// The weekday under each column, so five anonymous bars are five named nights.
    ///
    /// The same `formattedWeekdayAbbreviation()` the rest of the app labels a day with — one definition
    /// of a weekday's short form, not a second one lettered for this chart.
    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(layout.bars) { bar in
                Text(bar.date.formattedWeekdayAbbreviation())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, Self.leadingGutterWidth)
        .padding(.trailing, Self.trailingGutterWidth)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    /// The height the fractions are measured over: the frame less the inset at each end, so the tick
    /// at `0` and the tick at `1` are centred inside the frame rather than half outside it.
    ///
    /// Never below one point, so a caller that gives this chart no height divides by nothing.
    private func plotHeight(in height: CGFloat) -> CGFloat {
        max(1, height - 2 * Self.labelInset)
    }
}
