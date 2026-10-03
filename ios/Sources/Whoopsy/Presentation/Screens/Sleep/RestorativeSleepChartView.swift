import SwiftUI

/// A week's restorative sleep, drawn as seven columns with slow-wave sleep at the foot and REM above
/// it — the reference's `RESTORATIVE SLEEP (HOURS)` card.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like every other chart in this project. Its frame is
/// `WeekChartAxis`'s — the same seven columns, the same anchor tint, the same weekday/day-of-month
/// strip as the five charts on the Recovery page and the two week charts above it on this one — so
/// the three week charts a reader can put side by side here are the same width and land on the same
/// dates.
///
/// ## What is stacked, and what is left to the legend
///
/// The bars are the only stacked ones in the app, and the reason is the quantity: restorative sleep is
/// a sum of two stages that are drawn separately everywhere else this app shows them, so a card about
/// the sum has to say which parts it is made of. **Only the total is labelled.** The split is carried
/// by the two colours and by the legend beneath the drawing, which is what the reference does — so a
/// reader can see that Tuesday was mostly REM and cannot read either figure off the chart. The
/// alternative is fourteen numbers over seven columns, which is a table rather than a chart.
///
/// ## The two stages are read through `SleepStageType.color`
///
/// The same mapping the hypnogram and this page's typical-range card draw their four stages in, so
/// the deep band here is the deep row three cards up. Nothing is re-picked; a local pair of colours
/// is how three recovery tiers once diverged.
///
/// ## Every rule about *which* nights plot, and how the axis is fitted, is in `RestorativeSleepWeek`
///
/// including the one that decides a stacked bar's axis must reach zero. What is left here is the
/// drawing. The view is never asked to draw an empty week: the series returns `nil` for one, and the
/// card that wraps this draws nothing rather than an empty frame.
public struct RestorativeSleepChartView: View {

    /// The week to plot — its seven slots are the columns, in order.
    public let week: MetricWeek

    /// The nights, already joined and fitted by the caller.
    public let series: RestorativeSleepWeek

    public init(week: MetricWeek, series: RestorativeSleepWeek) {
        self.week = week
        self.series = series
    }

    /// What the two bands are called, in the order the legend draws them — the upper band first,
    /// reading down the stack.
    ///
    /// Static and shared with the legend rather than written twice: the legend's swatch and the band
    /// it names are one fact, and two lists are two chances to colour the wrong one.
    ///
    /// **The names are `SleepStageType.rawValue`, not the reference's `DEEP SLEEP` and `REM SLEEP`**,
    /// on `SleepTypicalRangeCard.stageRow`'s rule and for its reason: this page names the four stages
    /// one way, and the typical-range card three cards up reads `DEEP / SWS`. A legend here using the
    /// reference's wording would make a reader match two names to one colour, which is the drift a
    /// single vocabulary exists to prevent.
    public static let remLabel = SleepStageType.rem.rawValue
    public static let deepLabel = SleepStageType.deep.rawValue

    /// The columns' range, excluding the strip the value labels sit in and the date labels beneath.
    /// The same `104` as this page's two other week charts and the Recovery page's five, so a card
    /// does not change height when its neighbour is absent.
    private static let barAreaHeight: CGFloat = 104

    private static let legendHeight: CGFloat = 34

    private static var plotHeight: CGFloat {
        WeekChartAxis.valueStripHeight + barAreaHeight + WeekChartAxis.dateLabelHeight
    }

    /// A bar's width as a fraction of its column. The same `0.44` as the bar chart above it on this
    /// page, so the two cards' seven columns line up as the same seven days rather than as two
    /// different rhythms.
    private static let barWidthFraction: CGFloat = 0.44

    /// Rounded at the top of the stack and square at its foot, matching `WeekBarChartView`'s bars:
    /// the column grows from the axis, so a fully rounded one would float above the line it is
    /// measured from.
    private static let barCornerRadius: CGFloat = 5

    /// The floor on a drawn column's height, so a night with a minute of restorative sleep is a
    /// visible stub rather than nothing at all. It applies only to a night that has a *positive*
    /// total — a night of no restorative sleep at all draws no bar, and this constant must never be
    /// the reason one appears.
    private static let minimumBarHeight: CGFloat = 3

    public var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            VStack(spacing: 0) {
                legend
                plot(width: width)
                WeekChartAxis.dateLabels(week: week, width: width)
            }
        }
        .frame(
            height: WeekChartAxis.valueStripHeight + Self.barAreaHeight
                + WeekChartAxis.dateLabelHeight + Self.legendHeight)
        // The bars are `Shape`s and a `Path` has nothing to say to VoiceOver, so the card that wraps
        // this carries the week in words instead.
        .accessibilityHidden(true)
    }

    /// The two stages named over a swatch of their own colour.
    ///
    /// A **filled** swatch and not the hollow ring `HoursVsNeededChartView`'s legend draws: that
    /// legend keys dots, and these key filled bands. Centred as a pair rather than spread edge to
    /// edge, so the legend reads as one line of text about the drawing below it.
    private var legend: some View {
        HStack(spacing: 22) {
            legendEntry(color: SleepStageType.rem.color, label: Self.remLabel)
            legendEntry(color: SleepStageType.deep.color, label: Self.deepLabel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.legendHeight)
    }

    private func legendEntry(color: Color, label: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)

            Text(label.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - The plot

    private func plot(width: CGFloat) -> some View {
        let axis = series.axis
        let columnWidth = WeekChartAxis.columnWidth(width)
        let baseline = WeekChartAxis.valueStripHeight + Self.barAreaHeight

        return ZStack {
            // The anchor's column first, so everything else draws over it.
            if let anchor = WeekChartAxis.anchorSlot(in: week) {
                WeekChartAxis.anchorColumn(
                    slot: anchor,
                    width: width,
                    height: WeekChartAxis.valueStripHeight + Self.barAreaHeight)
            }

            // At the axis' own round values rather than at even fractions of the fitted range. On this
            // chart they are the axis' zero plus whole hours, because zero is in the fit and the ladder
            // therefore spends its steps on the week's own magnitude — see `RestorativeSleepWeek`.
            ForEach(axis.gridLines, id: \.self) { value in
                Rectangle()
                    .fill(Theme.ringTrack)
                    .frame(width: width, height: 1)
                    .position(
                        x: width / 2,
                        y: baseline - CGFloat(axis.fraction(value)) * Self.barAreaHeight)
            }

            ForEach(series.nights, id: \.slot) { night in
                let x = WeekChartAxis.x(slot: night.slot, columnWidth: columnWidth)
                let height = Self.barHeight(for: night, axis: axis)

                if height > 0 {
                    stackedBar(night, height: height, width: columnWidth * Self.barWidthFraction)
                        .position(x: x, y: baseline - height / 2)
                }

                // The night's restorative total, which is the figure the columns are read by and the
                // only number on this chart. It is **white**, not a band colour: the stack under it is
                // two colours in one column, so a label in either would be claiming to belong to one
                // of them.
                Text(night.totalSeconds.formattedCompactHoursMinutes())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .fixedSize()
                    .position(x: x, y: baseline - height - 10)
            }
        }
        .frame(width: width, height: WeekChartAxis.valueStripHeight + Self.barAreaHeight)
    }

    /// One night's column: REM above slow-wave sleep, in a stack as tall as the night's total.
    ///
    /// The two bands are stacked in a `VStack` with its own explicit height, so the taller band's
    /// height is `total − the shorter one` rather than a second multiplication — a hairline of the
    /// track showing between them is the failure that arithmetic avoids, and it is invisible on
    /// screen because both bands are drawn and only their boundary would be wrong.
    private func stackedBar(
        _ night: RestorativeSleepWeek.Point, height: CGFloat, width: CGFloat
    ) -> some View {
        let deepHeight = height * CGFloat(night.deepSeconds / night.totalSeconds)
        let remHeight = height - deepHeight

        return VStack(spacing: 0) {
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: Self.barCornerRadius,
                    bottomLeading: 0,
                    bottomTrailing: 0,
                    topTrailing: Self.barCornerRadius),
                style: .continuous)
                .fill(SleepStageType.rem.color)
                .frame(height: remHeight)

            Rectangle()
                .fill(SleepStageType.deep.color)
                .frame(height: deepHeight)
        }
        .frame(width: width)
    }

    /// A night's column height on the fitted axis, or `0` for a night with no restorative sleep.
    ///
    /// **The zero is the one case the axis cannot place.** `fraction(0)` is exactly `0` on this axis,
    /// so the arithmetic would give a zero-height bar and the `minimumBarHeight` floor would then turn
    /// it into a stub of a colour that was never measured — a bar where the night had none. So the
    /// floor is applied only to a positive total and a total of zero draws nothing, which is what
    /// `SleepSession`'s own columns say about that night.
    private static func barHeight(for night: RestorativeSleepWeek.Point, axis: FittedAxis) -> CGFloat {
        guard night.totalSeconds > 0 else { return 0 }
        return max(minimumBarHeight, CGFloat(axis.fraction(night.totalHours)) * barAreaHeight)
    }
}
