import SwiftUI

/// A week's hours asleep and hours needed, drawn as two lines against one scale.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like every other chart in this project. Its frame is
/// `WeekChartAxis`'s — the same seven columns, the same anchor tint, the same weekday/day-of-month
/// strip as the five charts on the Recovery page and the bar chart above it on this one — so the three
/// week charts a reader can put side by side here are the same width and land on the same dates.
///
/// ## The two lanes answer to two different rules, and both are in `HoursVsNeededWeek`
///
/// Which nights plot, how the axis is fitted and whether there is a chart at all are the series'
/// business, not this view's. What is left here is the drawing: one axis, two polylines, two sets of
/// hollow points, and the labels.
///
/// ## The labels go above and below, and which lane takes which side is decided per night
///
/// This is the one thing the drawing does that no other week chart does, and it is forced by the
/// data rather than by taste: the two lanes are the same quantity, so on a night that met its need
/// they are minutes apart — the reference week's Friday is `8:11` against `8:12` — and two labels
/// stacked on the same side would be drawn over each other at the same x.
///
/// So the **higher value's label sits above its point and the lower one's below**, which is 22pt of
/// separation at the closest. Deciding it by lane instead of by value would be the same picture on
/// the 895 export nights where the need is the larger of the two, and would collide on the 15 where
/// it is not: `SleepSession.totalTimeAsleepSeconds` can exceed the need, and on a night that overshot
/// by under an hour and a half a lane-fixed rule puts both labels between the two points.
///
/// The label is clamped into the plot's frame, because the lower lane's point can sit on the axis'
/// foot — `FittedAxis` snaps its bounds to round numbers, so a week whose shortest night is exactly on
/// a step boundary lands its label a few points below the frame and over the date strip.
public struct HoursVsNeededChartView: View {

    /// The week to plot — its seven slots are the columns, in order.
    public let week: MetricWeek

    /// The two lanes, already joined and fitted by the caller.
    public let series: HoursVsNeededWeek

    public init(week: MetricWeek, series: HoursVsNeededWeek) {
        self.week = week
        self.series = series
    }

    /// What the two lanes are called, in the order the legend draws them.
    ///
    /// Static and shared with the legend rather than written twice: the legend's swatch and the line
    /// it names are one fact, and two lists are two chances to colour the wrong one.
    public static let asleepLabel = "Hours of sleep"
    public static let needLabel = "Sleep needed"

    /// The plot's height above the date strip. The same `104` as this page's other week charts and
    /// the Recovery page's five, so a card does not change height when its neighbour is absent.
    private static let lineAreaHeight: CGFloat = 104

    /// The dot's diameter, and the point of the lane it marks.
    private static let dotDiameter: CGFloat = 9

    /// How far the plot's top and bottom bounds sit inside the line area, so the highest and lowest
    /// dots are not half-cut by the frame.
    private static let yInset: CGFloat = 7

    /// How far a value label's centre sits from the point it belongs to. Smaller than
    /// `WeekLineChartView`'s `13`, because these labels come in pairs and the smaller lift is what
    /// keeps a night that met its need from reading as one crowded number.
    private static let labelLift: CGFloat = 11

    /// How close a label's centre may come to the plot's edge before it is pushed back in. Half a
    /// line of 11pt text, so a clamped label is inside the frame rather than half outside it.
    private static let labelMargin: CGFloat = 8

    private static var plotHeight: CGFloat {
        WeekChartAxis.valueStripHeight + lineAreaHeight
    }

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
            height: Self.plotHeight + WeekChartAxis.dateLabelHeight + Self.legendHeight)
        // The lines and the dots are `Shape`s and a `Path` has nothing to say to VoiceOver, so the
        // card that wraps this carries the week in words instead.
        .accessibilityHidden(true)
    }

    /// The two lanes named over a swatch of their own colour.
    ///
    /// The swatch is a **hollow ring at the point's own diameter**, not a filled dash: the marks this
    /// keys are hollow dots, and a solid rectangle beside the word would be a second visual language
    /// for one chart. Centred as a pair rather than spread edge to edge, so the legend reads as one
    /// line of text about the drawing below it.
    private var legend: some View {
        HStack(spacing: 22) {
            legendEntry(color: Theme.sleepPerformance, label: Self.asleepLabel)
            legendEntry(color: Theme.sleepNeedLine, label: Self.needLabel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.legendHeight)
    }

    private func legendEntry(color: Color, label: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.cardBackground)
                .overlay(Circle().stroke(color, lineWidth: 2))
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)

            Text(label.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private static let legendHeight: CGFloat = 34

    // MARK: - The plot

    private func plot(width: CGFloat) -> some View {
        let axis = series.axis
        let columnWidth = WeekChartAxis.columnWidth(width)
        let height = Self.plotHeight

        return ZStack {
            // The anchor's column first, so everything else draws over it.
            if let anchor = WeekChartAxis.anchorSlot(in: week) {
                WeekChartAxis.anchorColumn(slot: anchor, width: width, height: height)
            }

            // At the axis' own round values rather than at fixed fractions of the fitted range, which
            // is `WeekLineChartView`'s rule and for its reason: a gridline a reader can name is worth
            // ruling. A week of sleep hours spans under five of them, so `FittedAxis`'s step ladder
            // lands on whole or two-hour steps and the lines come out on readable clock times.
            ForEach(axis.gridLines, id: \.self) { value in
                Rectangle()
                    .fill(Theme.ringTrack)
                    .frame(width: width, height: 1)
                    .position(x: width / 2, y: Self.y(axis.fraction(value), in: height))
            }

            // The sleep lane under the need lane, so a night they were equal on reads as a need
            // night rather than as a gap — the two are minutes apart on the commonest night there is.
            LanePath(runs: series.asleepRuns, axis: axis)
                .stroke(
                    Theme.sleepPerformance,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            LanePath(runs: series.needRuns, axis: axis)
                .stroke(
                    Theme.sleepNeedLine,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(series.asleep, id: \.slot) { point in
                dot(color: Theme.sleepPerformance, point: point, axis: axis, columnWidth: columnWidth)
                label(
                    point, color: Theme.sleepPerformance, axis: axis, columnWidth: columnWidth,
                    above: asleepIsHigher(at: point.slot))
            }

            ForEach(series.need, id: \.slot) { point in
                dot(color: Theme.sleepNeedLine, point: point, axis: axis, columnWidth: columnWidth)
                label(
                    point, color: Theme.sleepNeedLine, axis: axis, columnWidth: columnWidth,
                    above: !asleepIsHigher(at: point.slot))
            }
        }
        .frame(width: width, height: height)
    }

    /// Whether the sleep lane is the higher of the two on this slot, which is the one case the
    /// reference's fixed above/below arrangement would draw over itself. See the type's comment.
    private func asleepIsHigher(at slot: Int) -> Bool {
        guard let asleep = series.asleep.first(where: { $0.slot == slot })?.hours,
              let need = series.need.first(where: { $0.slot == slot })?.hours
        else {
            // Only one lane has a point here, so there is nothing to collide with and the need keeps
            // the side the reference gives it.
            return false
        }
        return asleep > need
    }

    /// A hollow point, so the line stays visible through the mark that anchors it — the same
    /// treatment `WeekLineChartView` and `StrainRecoveryChartView` give theirs.
    private func dot(
        color: Color, point: HoursVsNeededWeek.Point, axis: FittedAxis, columnWidth: CGFloat
    ) -> some View {
        Circle()
            .fill(Theme.cardBackground)
            .overlay(Circle().stroke(color, lineWidth: 2))
            .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            .position(
                x: WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                y: Self.y(axis.fraction(point.hours), in: Self.plotHeight))
    }

    /// The duration the point's height only approximates.
    ///
    /// **A clock reading and not a decimal**, which is the one place this parts from
    /// `WeekLineChartView`'s `%.\(valueDecimals)f`: the quantity is a duration the same card prints as
    /// `7:33` a few rows up, and a chart labelling it `7.5` would state the same night in a second
    /// unit on one screen. The seconds are what the series carries, so the label reads the stored
    /// figure rather than a rounded hour count — see `HoursVsNeededWeek.Point`.
    ///
    /// **The label carries its own lane's colour**, the reference's treatment and the thing that makes
    /// a pair of numbers over one column readable at all — with both lanes labelled at once, a single
    /// colour would leave a reader unable to tell which of `8:11` and `8:12` is the need.
    private func label(
        _ point: HoursVsNeededWeek.Point, color: Color, axis: FittedAxis, columnWidth: CGFloat,
        above: Bool
    ) -> some View {
        let y = Self.y(axis.fraction(point.hours), in: Self.plotHeight)
        return Text(point.seconds.formattedCompactHoursMinutes())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .monospacedDigit()
            .fixedSize()
            .position(
                x: WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                y: Self.labelY(y, above: above))
    }

    /// Where a height fraction sits on screen, inside the plot's frame.
    ///
    /// The same mapping the lanes' `Shape`s use — one function for both, so the points cannot drift
    /// off the lines they are supposed to sit on.
    private static func y(_ fraction: Double, in height: CGFloat) -> CGFloat {
        let usable = height - WeekChartAxis.valueStripHeight - yInset * 2
        return WeekChartAxis.valueStripHeight + yInset + CGFloat(1 - fraction) * usable
    }

    /// A label's centre, lifted off its point and pushed back inside the frame if the lift would take
    /// it out. See the type's comment for the case that needs the clamp.
    private static func labelY(_ pointY: CGFloat, above: Bool) -> CGFloat {
        let lifted = above ? pointY - labelLift : pointY + labelLift
        return min(max(lifted, labelMargin), plotHeight - labelMargin)
    }

    /// One lane's line, one segment per run of adjacent measured nights.
    ///
    /// A `Shape` rather than a `Path` built in the view, so the geometry is laid out in whatever rect
    /// the plot is given and the same runs draw correctly at any width.
    private struct LanePath: Shape {
        let runs: [[HoursVsNeededWeek.Point]]
        let axis: FittedAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            // A run of one has no segment to draw, and reaching for a neighbour to make one would
            // span nights this lane has no value for. Its dot is drawn by the caller, so the reading
            // is not lost.
            for run in runs where run.count > 1 {
                let columnWidth = WeekChartAxis.columnWidth(rect.width)
                for (index, point) in run.enumerated() {
                    let position = CGPoint(
                        x: rect.minX + WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                        y: rect.minY
                            + HoursVsNeededChartView.y(
                                axis.fraction(point.hours), in: rect.height))
                    if index == 0 {
                        path.move(to: position)
                    } else {
                        path.addLine(to: position)
                    }
                }
            }
            return path
        }
    }
}
