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
/// ## The clock is `SleepClockAxis`, and the chart owns its own frame
///
/// The scale is the shared one — the night clock, widening in whole hours, read back out through one
/// inverse — and it lives in `SleepClockAxis` because the time-in-bed card below this one on the page
/// draws on the same scale. What stays here is the frame, and `WeekChartAxis` is **not** reused for
/// it. The reason is geometry rather than taste: that type is a seven-column weekday axis with one
/// label row under it, while this chart has five columns, a labelled scale down its leading edge and a
/// second gutter trailing it. Bending it would move the Strain & Recovery chart to draw this one,
/// which is the same reasoning `WeekChartAxis`'s own doc comment gives for `StrainRecoveryChartView`.
/// The week version of this same quantity takes the opposite decision, and for this reason read
/// backwards: it is seven columns with no gutters, so it takes `WeekChartAxis` and lets each column
/// label its own two ends instead of carrying a scale.
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

    /// One tick of the leading scale. The shared type, not a second one: the time-in-bed card's axis
    /// is the same axis, and two label types would be two answers to what a tick is.
    public typealias AxisLabel = SleepClockAxis.Label

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

    /// The clock the five bars and the two rules are placed on — the shared axis, so this card and
    /// the time-in-bed card below it cannot come to disagree about where a minute sits.
    public let axis: SleepClockAxis

    /// The scale down the leading edge, `axisLabelCount` of them from `axisStartMinutes` to
    /// `axisEndMinutes`.
    ///
    /// Forwarded rather than stored twice, so a tick and the fraction it is drawn at are one value.
    public var axisLabels: [AxisLabel] { axis.labels }

    /// The top of the axis, in night-clock minutes. `420` — 7 PM — unless a boundary widened it.
    public var axisStartMinutes: Double { axis.startMinutes }

    /// The foot of the axis, in night-clock minutes. `1380` — 11 AM — unless a boundary widened it.
    public var axisEndMinutes: Double { axis.endMinutes }

    /// Where the average onset rule is drawn.
    public let typicalOnsetFraction: Double

    /// Where the average wake rule is drawn.
    public let typicalWakeFraction: Double

    /// The average onset as a clock time — `"11:54 PM"` — for the callout at the rule's trailing end.
    public let typicalOnsetText: String

    /// The average wake as a clock time.
    public let typicalWakeText: String

    /// The reference's own window, forwarded from the shared axis so this card and the time-in-bed
    /// card below it cannot come to hold two answers to where 7 PM is.
    public static let defaultAxisStartMinutes = SleepClockAxis.defaultStartMinutes
    public static let defaultAxisEndMinutes = SleepClockAxis.defaultEndMinutes

    /// Five, forwarded for the same reason: one count of ticks for both clocks.
    public static let axisLabelCount = SleepClockAxis.labelCount

    /// The one conversion from the model's own frame back to a clock. Forwarded from the shared axis,
    /// which is where the argument for not inlining it lives.
    public static func clockText(forNightClockMinutes minutes: Double) -> String {
        SleepClockAxis.clockText(forNightClockMinutes: minutes)
    }

    /// The five nights, the scale and the two rules, or `nil` when there is no chart to draw.
    ///
    /// `nil` when the summary is empty, when a boundary is not a finite number of minutes, and when
    /// **any night's wake does not come after its own onset on the night clock** — an interval
    /// containing noon, which the frame has no seam to cross. The predicate is
    /// `SleepClockAxis.isDrawable`; what is decided here is only what a refused night *costs*, and on
    /// this card it costs the whole chart rather than its own column. The five columns are one unit —
    /// the anchor and the four nights it was scored against — so drawing four of five would change
    /// what the two rules over them mean, and the anchor is one of the five. All three cases are
    /// corrupt rows rather than ordinary absences, and a caller with no layout draws no chart rather
    /// than a picture of a bad row. `SleepNeedBarLayout` refuses a non-positive scale on the same
    /// terms; the figure above this chart is a reading and is drawn either way.
    ///
    /// **The refused condition is about the interval and not about its length.** An eleven-to-one
    /// afternoon row is two hours long and is refused; a fifteen-hour night that began in the evening
    /// is not, and it is the same comparison.
    ///
    /// The week version of this chart takes the opposite decision on the same predicate and for a
    /// reason that is about its own shape rather than about the rule — see `TimeInBedWeek`.
    public init?(summary: SleepConsistencyScoring.Summary) {
        let nights = summary.bars.map { ($0.onsetMinutes, $0.wakeMinutes) }
        let rules = (summary.typicalOnsetMinutes, summary.typicalWakeMinutes)

        guard !nights.isEmpty,
              nights.allSatisfy({ SleepClockAxis.isDrawable(onset: $0.0, wake: $0.1) }),
              rules.0.isFinite, rules.1.isFinite, rules.1 > rules.0
        else { return nil }

        // Every boundary the chart has to draw — the bars' and the two rules' — so a mean that fell
        // outside the bars' span moves the axis with them instead of being drawn off the edge. In
        // practice it never does, since a circular mean of the four priors lies inside their arc and
        // the priors are inside the axis; "in practice" is not a reason to leave a rule undrawable.
        let boundaries = nights.flatMap { [$0.0, $0.1] } + [rules.0, rules.1]
        guard let axis = SleepClockAxis(boundaries: boundaries) else { return nil }

        self.bars = summary.bars.map {
            Bar(
                date: $0.date,
                isAnchor: $0.isAnchor,
                topFraction: axis.fraction($0.onsetMinutes),
                bottomFraction: axis.fraction($0.wakeMinutes))
        }
        self.axis = axis
        self.typicalOnsetFraction = axis.fraction(rules.0)
        self.typicalWakeFraction = axis.fraction(rules.1)
        self.typicalOnsetText = SleepClockAxis.clockText(forNightClockMinutes: rules.0)
        self.typicalWakeText = SleepClockAxis.clockText(forNightClockMinutes: rules.1)
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
