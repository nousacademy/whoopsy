import SwiftUI

/// A week's time in bed, drawn as seven columns each spanning its own night on a clock — the
/// reference's `TIME IN BED` card.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like every other chart in this project. Its frame is
/// `WeekChartAxis`'s — the same seven columns, the same anchor tint, the same weekday/day-of-month
/// strip as the two week charts above it on this page — so the three cards a reader can put side by
/// side are the same width and land on the same dates.
///
/// ## It is the same drawing as the consistency card's, at seven columns and with no gutters
///
/// A column is a rounded bar from a night's onset down to its wake, placed by
/// `SleepClockAxis.fraction`. Where it parts from `SleepConsistencyChartView` is what it does *around*
/// the plot, and both differences come from the same fact: this chart has seven columns bound to seven
/// labelled days, and that one has five unlabelled ones.
///
/// - **No leading scale and no trailing gutter.** A labelled scale and the two rule callouts cost that
///   chart 98pt of its width; spending the same here would push every column in from the edges and put
///   this card's seven days out of line with the two cards above it. The scale is also redundant, which
///   is the stronger reason: every column **states both of its own boundaries**, so the axis would be a
///   fifth way of saying what the labels already say fourteen times.
/// - **Every column labels both of its ends.** That is what the reference does and it is why the two
///   figures on a column are a bedtime and a waketime rather than a pair of durations — the mistake
///   those labels exist to prevent. The five-night chart labels only its anchor, because its other four
///   are a comparison and not four readings.
///
/// ## No gridlines, on the consistency chart's rule and one step further
///
/// A gridline is a labelled tick's rule. This chart has no labelled ticks — nothing on it names an hour
/// but the columns themselves — so a line ruled across it would sit at a position no reader can put a
/// time to, and seven such lines would leave the bars competing with them for the eye. This is a
/// decision and not an omission: a later reader comparing this against a reference that does carry
/// gridlines should read this paragraph before adding them.
///
/// ## Every rule about *which* nights plot, and where the axis lands, is in `TimeInBedWeek`
///
/// including the one that decides a span the frame cannot represent costs its own column and not the
/// card. What is left here is the drawing. The view is never asked to draw an empty week: the series
/// returns `nil` for one, and the card that wraps this draws nothing rather than an empty frame.
public struct TimeInBedChartView: View {

    /// The week to plot — its seven slots are the columns, in order.
    public let week: MetricWeek

    /// The nights, already joined and fitted by the caller.
    public let series: TimeInBedWeek

    public init(week: MetricWeek, series: TimeInBedWeek) {
        self.week = week
        self.series = series
    }

    /// The columns' range, excluding the strip the labels sit in and the date labels beneath. The same
    /// `104` as this page's two other week charts and the Recovery page's five, so a card does not
    /// change height when its neighbour is absent.
    private static let barAreaHeight: CGFloat = 104

    /// One label's line, reserved at the top and the foot of the plot.
    ///
    /// **The two labels are inside the plot rather than in a strip above it**, which is the one place
    /// this chart's geometry departs from its two neighbours. Those put a single figure over the
    /// tallest bar, in `WeekChartAxis.valueStripHeight`; this chart has a label at each end of every
    /// column, and a bedtime belongs immediately above the bar it starts rather than at a fixed height
    /// over the plot. Reserving a line at each end is what keeps the topmost bedtime and the bottommost
    /// waketime inside the frame on the week whose axis widened to hold them — and the axis' own ends
    /// are exactly where those two cases live.
    private static let labelStripHeight: CGFloat = 13

    /// A bar's width as a fraction of its column. The same `0.44` as the two week charts above it, so
    /// the three cards' seven columns line up as the same seven days rather than as three rhythms.
    private static let barWidthFraction: CGFloat = 0.44

    /// Rounded at both ends and not just the top: a span chart's bar does not grow from a baseline, so
    /// it has two real ends rather than one end and a foot. The same `3` — and the same reasoning — as
    /// the consistency card's bars, which are the only other spans in the app.
    private static let barCornerRadius: CGFloat = 3

    /// The floor on a drawn column's height, so a night of twenty minutes is a visible stub rather
    /// than nothing at all. On `SleepConsistencyChartView`'s rule it applies to the *drawing* and not
    /// to the value: the bar's top end stays where its onset puts it, so the floor can only lengthen a
    /// bar downward, never move one — and the waketime printed under it is the real one either way.
    private static let minimumBarHeight: CGFloat = 3

    private static let labelSize: CGFloat = 9

    private static var plotHeight: CGFloat {
        WeekChartAxis.valueStripHeight + barAreaHeight
    }

    /// The height the fractions are measured over: the plot less the line reserved at each end.
    private static var usableHeight: CGFloat { plotHeight - 2 * labelStripHeight }

    public var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            VStack(spacing: 0) {
                plot(width: width)
                WeekChartAxis.dateLabels(week: week, width: width)
            }
        }
        .frame(
            height: WeekChartAxis.valueStripHeight + Self.barAreaHeight
                + WeekChartAxis.dateLabelHeight)
        // The bars are `Shape`s and a `Path` has nothing to say to VoiceOver, so the card that wraps
        // this carries the week in words instead.
        .accessibilityHidden(true)
    }

    // MARK: - The nights

    private func plot(width: CGFloat) -> some View {
        let axis = series.axis
        let columnWidth = WeekChartAxis.columnWidth(width)
        let barWidth = columnWidth * Self.barWidthFraction

        return ZStack {
            // The anchor's column first, so everything else draws over it. The same tint the two week
            // charts above use, and the *only* thing marking the anchor on this card — see
            // `TimeInBedWeek.Point.isAnchor` for why a second bar colour would be a distinction with
            // nothing behind it.
            if let anchor = WeekChartAxis.anchorSlot(in: week) {
                WeekChartAxis.anchorColumn(
                    slot: anchor,
                    width: width,
                    height: Self.plotHeight)
            }

            ForEach(series.nights) { night in
                let x = WeekChartAxis.x(slot: night.slot, columnWidth: columnWidth)
                let top = Self.labelStripHeight + Self.usableHeight * axis.fraction(night.onsetMinutes)
                let bottom =
                    Self.labelStripHeight + Self.usableHeight * axis.fraction(night.wakeMinutes)
                let height = max(Self.minimumBarHeight, bottom - top)

                RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous)
                    .fill(Theme.sleepConsistencyBar)
                    .frame(width: barWidth, height: height)
                    .position(x: x, y: top + height / 2)

                // The night's two boundaries, each against the end of the bar it belongs to. They are
                // the only figures on this chart: the bar's ends are where the clock put them, and the
                // axis that would let a reader measure them is deliberately absent — see the type's
                // comment.
                label(night.onsetText, x: x, y: top - Self.labelStripHeight / 2, columnWidth: columnWidth)
                label(night.wakeText, x: x, y: bottom + Self.labelStripHeight / 2, columnWidth: columnWidth)
            }
        }
        .frame(width: width, height: Self.plotHeight)
    }

    /// One clock time, centred on its column.
    ///
    /// `minimumScaleFactor` rather than a smaller font, because the strings are not all the same
    /// length: `"7 PM"` is four characters and `"11:54 PM"` is eight, and a column is a seventh of the
    /// card. Scaling the long one down is what lets one size serve both, so a week whose bedtimes are
    /// all on the hour does not print in a visibly different size from one whose are not.
    private func label(_ text: String, x: CGFloat, y: CGFloat, columnWidth: CGFloat) -> some View {
        Text(text)
            .font(.system(size: Self.labelSize, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: columnWidth, alignment: .center)
            .position(x: x, y: y)
    }
}
