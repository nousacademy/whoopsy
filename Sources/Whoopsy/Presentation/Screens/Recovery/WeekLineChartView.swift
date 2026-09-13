import SwiftUI

/// A week of one quantity, one point per measured day, for the Recovery detail page.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `StrainRecoveryChartView`, `StressMonitorChartView`
/// and `HypnogramChartView`. Nothing in this project uses Swift Charts and this is not the place to
/// start.
///
/// ## One view, three series
///
/// This draws the HRV, resting-heart-rate and respiratory-rate weeks. They differ in **which** days
/// plot and **how finely** their numbers read, and both are `WeekLineSeries`' business — the caller
/// hands the series in already built, narrowed or not — so everything downstream of it is the same
/// drawing: the same fitted axis, the same hollow points, the same labels over them, the same seven
/// columns and date strip. It is one type rather than three because three copies of a chart are three
/// chances for one of them to drift, and neither difference would be visible as a compile error.
///
/// ## Every value is labelled, and that is what the fitted axis is traded against
///
/// `FittedAxis` explains why these charts alone have an auto-fitted y-axis. The short version is that
/// none of the three quantities' absolute magnitudes is meaningful without the person's own baseline,
/// so the numbers over the points are what make the axis height honest: the height is a guide, and the
/// reading is stated. Remove the labels and this becomes the chart the fixed-scale rule exists to
/// forbid, so the two go together — a label is drawn over every point, including a run of one.
///
/// ## The columns are the calendar, and the anchor is the day the page is showing
///
/// Columns, the highlighted column and the date strip all come from `WeekChartAxis`, shared with the
/// recovery chart above. `MetricWeek.endingOn` is the anchor and always the last slot, so the
/// highlight needs no second input — it is the day whose figures the rows further up the page are
/// describing.
public struct WeekLineChartView: View {

    /// The week to plot — its seven slots are the columns, in order.
    public let week: MetricWeek

    /// The days to plot in it, already narrowed by the caller.
    public let series: WeekLineSeries

    public init(week: MetricWeek, series: WeekLineSeries) {
        self.week = week
        self.series = series
    }

    /// The plot's height above the date strip. Deliberately the recovery chart's `barAreaHeight`, so
    /// every card on this page is the same height and the page does not change shape when one of them
    /// is absent.
    private static let lineAreaHeight: CGFloat = 104

    /// The dot's diameter, and the point of the series it marks.
    private static let dotDiameter: CGFloat = 9

    /// How far the plot's top and bottom bounds sit inside the line area, so the highest and lowest
    /// dots are not half-cut by the frame.
    private static let yInset: CGFloat = 7

    /// How far above its point a value label's centre sits. Above rather than beside, unlike
    /// `StrainRecoveryChartView`'s, because these columns carry one series: a label to the side would
    /// be read as belonging to the neighbouring day's point.
    private static let labelLift: CGFloat = 13

    private static var plotHeight: CGFloat {
        WeekChartAxis.valueStripHeight + lineAreaHeight
    }

    public var body: some View {
        // Nil only if the series is non-empty but all its values are equal and unrepresentable, which
        // `FittedAxis` widens rather than refusing — so this is a guard against a future edit, not a
        // state a caller can reach. Nothing is drawn rather than an empty frame, for the reason the
        // series itself is optional: a frame with no line in it is a week of zeros.
        if let axis = FittedAxis(values: series.points.map(\.value)) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                VStack(spacing: 0) {
                    plot(axis: axis, width: width)
                    WeekChartAxis.dateLabels(week: week, width: width)
                }
            }
            .frame(height: Self.plotHeight + WeekChartAxis.dateLabelHeight)
            // The line and the dots are `Shape`s and a `Path` has nothing to say to VoiceOver. The
            // card that wraps this carries the week in words — including which quantity it is in and
            // what unit, which the shapes cannot say.
            .accessibilityHidden(true)
        }
    }

    // MARK: - The plot

    private func plot(axis: FittedAxis, width: CGFloat) -> some View {
        let columnWidth = WeekChartAxis.columnWidth(width)
        let height = Self.plotHeight

        return ZStack {
            // The anchor's column first, so everything else draws over it. Full plot height rather
            // than the height of the point in it, so it reads as the column the day occupies and not
            // as a second mark.
            if let anchor = WeekChartAxis.anchorSlot(in: week) {
                WeekChartAxis.anchorColumn(slot: anchor, width: width, height: height)
            }

            // At the axis' own round values rather than at thirds. A gridline a reader can name is
            // worth ruling; one at a fixed fraction of a fitted range is decoration that moves when
            // the data does.
            ForEach(axis.gridLines, id: \.self) { value in
                Rectangle()
                    .fill(Theme.ringTrack)
                    .frame(width: width, height: 1)
                    .position(x: width / 2, y: Self.y(axis.fraction(value), in: height))
            }

            WeekLinePath(series: series, axis: axis)
                .stroke(
                    Theme.weekLine,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(series.points.indices, id: \.self) { index in
                let point = series.points[index]
                // Hollow, so the line stays visible through the point that anchors it — the same
                // treatment `StrainRecoveryChartView` gives its strain dots.
                Circle()
                    .fill(Theme.cardBackground)
                    .overlay(Circle().stroke(Theme.weekLine, lineWidth: 2))
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                    .position(
                        x: WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                        y: Self.y(axis.fraction(point.value), in: height))

                // The figure the point's height only approximates, and the reason a fitted axis is
                // allowed here at all. The precision comes from the series, because it belongs to the
                // quantity rather than to the drawing: a whole bpm and a tenth of a breath per minute
                // are the resolutions their columns are stored and read at, and a week of respiratory
                // rates printed whole would be seven labels of `15`. No unit is printed, because the
                // card's own label over the chart says which quantity this is and seven labels
                // carrying "rpm" would be noise on a column an eighth of the width.
                Text(String(format: "%.\(series.valueDecimals)f", point.value))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.weekLine)
                    .monospacedDigit()
                    .fixedSize()
                    .position(
                        x: WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                        y: Self.y(axis.fraction(point.value), in: height) - Self.labelLift)
            }
        }
        .frame(width: width, height: height)
    }

    /// Where a height fraction sits on screen, inside the plot's frame.
    ///
    /// **The same mapping the line's `Shape` uses, and it has to be.** The shape is handed a `CGRect`
    /// and the dots are `.position`ed in the enclosing `ZStack`, but the two frames are the same rect,
    /// so one function serves both. Two formulas would be two chances for the dots to drift off the
    /// line they are supposed to sit on — which is a chart that looks fine until the week changes
    /// shape.
    private static func y(_ fraction: Double, in height: CGFloat) -> CGFloat {
        let usable = height - WeekChartAxis.valueStripHeight - yInset * 2
        return WeekChartAxis.valueStripHeight + yInset + CGFloat(1 - fraction) * usable
    }

    /// The week's line, one segment per run of adjacent measured days.
    ///
    /// A `Shape` rather than a `Path` built in the view, so the geometry is laid out in whatever rect
    /// the plot is given and the same series draws correctly at any width.
    private struct WeekLinePath: Shape {
        let series: WeekLineSeries
        let axis: FittedAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            // A run of one has no segment to draw, and reaching for a neighbour to make one would
            // span days this chart has no value for. Its dot is drawn by the caller, so the reading
            // is not lost.
            for run in series.runs where run.count > 1 {
                let columnWidth = WeekChartAxis.columnWidth(rect.width)
                for (index, point) in run.enumerated() {
                    let position = CGPoint(
                        x: rect.minX + WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                        y: rect.minY + WeekLineChartView.y(axis.fraction(point.value), in: rect.height))
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
