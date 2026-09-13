import SwiftUI

/// A week of percentages, one bar per day, for the Recovery detail page.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `StrainRecoveryChartView`, `StressMonitorChartView`
/// and `HypnogramChartView`. Nothing in this project uses Swift Charts and this is not the place to
/// start.
///
/// **One view for both of the page's bar charts** — recovery scores and sleep performance — the same
/// way `WeekLineChartView` is one view for its three lines. They are the same drawing: seven columns
/// from a `MetricWeek`, a whole percentage per column on a fixed 0–100 scale, a label over each bar.
/// Everything that differs between them is in the series — which slots plot, what colour a bar is, and
/// whether there are gridlines — and a second copy of this body would be a second place for the bar
/// geometry to drift.
///
/// ## One bar per calendar day, always seven columns
///
/// The columns come from `MetricWeek`, so the week is generated from the **calendar** rather than from
/// the rows that were handed in: a day with nothing stored is an empty column that still carries its
/// own date label, never a missing column. A missing column would slide every later bar one day to the
/// left and relabel it with the wrong date, which is a chart that is wrong about which day it is
/// showing with nothing on screen to say so.
///
/// A day with no value draws **no bar and no value label** — which is the series' decision and not
/// this view's: `WeekBarSeries` has no point for such a day, and it returns `nil` entirely for a week
/// with nothing in it, so this view is never asked to draw an empty one.
///
/// ## The scale is fixed at 0–100
///
/// The scale is the percentage's own definition rather than a choice, and it is never auto-scaled: an
/// axis fitted to the week would draw a bad week and a good week as the same picture, which is the
/// rule the Stress Monitor's fixed 0–3 axis already follows. The lines below this chart are the
/// opposite and are the app's only fitted axis, because each of them labels every point and so states
/// its own range on the drawing.
///
/// ## The frame is shared with the three line charts beside it
///
/// The column geometry, the highlighted column and the date strip come from `WeekChartAxis`, because
/// `WeekLineChartView` draws the same seven columns directly beneath this one — three times, for
/// heart-rate variability, resting heart rate and respiratory rate — and five copies of a date label
/// are five chances to label a column with the wrong day.
public struct WeekBarChartView: View {
    /// The week to plot — its seven slots are the columns, in order.
    public let week: MetricWeek

    /// Which slots carry a bar, what colour each is, and whether there are gridlines.
    public let series: WeekBarSeries

    public init(week: MetricWeek, series: WeekBarSeries) {
        self.week = week
        self.series = series
    }

    /// The bars' range, excluding the strip the value labels sit in and the date labels beneath.
    private static let barAreaHeight: CGFloat = 104

    /// The strip above the bars, sized for the label over a full-height bar — the tallest one there
    /// can be. Without it a 100% bar's label would be drawn outside the frame and clipped.
    private static var valueStripHeight: CGFloat { WeekChartAxis.valueStripHeight }

    private static var plotHeight: CGFloat {
        valueStripHeight + barAreaHeight + WeekChartAxis.dateLabelHeight
    }

    /// A bar's width as a fraction of its column. The gap this leaves is what makes seven bars read as
    /// seven days rather than as one block.
    private static let barWidthFraction: CGFloat = 0.44

    private static let barCornerRadius: CGFloat = 5

    /// The floor on a drawn bar's height, so a measured score of `0` is a visible stub rather than
    /// nothing at all. It applies only to a day that *has* a value — an unmeasured day has no point in
    /// the series, and this constant must never be the reason a bar appears.
    private static let minimumBarHeight: CGFloat = 3

    public var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            VStack(spacing: 0) {
                plot(width: width)
                WeekChartAxis.dateLabels(week: week, width: width)
            }
        }
        .frame(height: Self.plotHeight)
        // The bars are `Shape`s and a `Path` has nothing to say to VoiceOver. The card that wraps this
        // carries the week in words, which is the same division `StrainRecoveryChartView` makes with
        // its tile.
        .accessibilityHidden(true)
    }

    // MARK: - The plot

    private func plot(width: CGFloat) -> some View {
        let columnWidth = WeekChartAxis.columnWidth(width)
        let barWidth = columnWidth * Self.barWidthFraction
        let baseline = Self.valueStripHeight + Self.barAreaHeight

        return ZStack {
            // The anchor's column first, so everything else draws over it.
            if let anchor = WeekChartAxis.anchorSlot(in: week) {
                WeekChartAxis.anchorColumn(
                    slot: anchor,
                    width: width,
                    height: Self.valueStripHeight + Self.barAreaHeight)
            }

            // The thresholds, when the quantity has any. The same `Theme.ringTrack` the Strain &
            // Recovery chart grids with, so the two charts' lines are the same weight of line.
            ForEach(series.gridEdges, id: \.self) { edge in
                Rectangle()
                    .fill(Theme.ringTrack)
                    .frame(width: width, height: 1)
                    .position(x: width / 2, y: baseline - CGFloat(edge) * Self.barAreaHeight)
            }

            ForEach(series.points, id: \.slot) { point in
                let color = Self.color(for: point.value, palette: series.palette)
                let height = max(
                    Self.minimumBarHeight,
                    CGFloat(Self.fraction(point.value)) * Self.barAreaHeight)

                ZStack {
                    // Rounded at the top and square at the foot, because the bar grows from the
                    // axis: a fully rounded one would float above the line it is measured from.
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: Self.barCornerRadius,
                            bottomLeading: 0,
                            bottomTrailing: 0,
                            topTrailing: Self.barCornerRadius),
                        style: .continuous)
                        .fill(color)
                        .frame(width: barWidth, height: height)
                        .position(x: WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth), y: baseline - height / 2)

                    // The value over its own bar. It is the figure the bar's height only
                    // approximates, and the only place on this chart a value is stated rather than
                    // drawn.
                    Text("\(point.value)%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .fixedSize()
                        .position(
                            x: WeekChartAxis.x(slot: point.slot, columnWidth: columnWidth),
                            y: baseline - height - 10)
                }
            }
        }
        .frame(width: width, height: Self.valueStripHeight + Self.barAreaHeight)
    }

    // MARK: - Geometry

    /// A value's height on the 0–100 scale. Clamped because the scale is the percentage's own range
    /// and a bar must not be able to leave it however it was constructed.
    private static func fraction(_ value: Int) -> Double {
        min(max(Double(value) / 100, 0), 1)
    }

    /// A bar's colour, from the one mapping each palette names.
    ///
    /// The recovery tier comes from `RecoveryState.color` in `RecoveryState+Extensions.swift`, which is
    /// the only place a tier becomes a `Color` — the same mapping Home's recovery ring and the gauge at
    /// the top of this page read. `Theme.sleepPerformance` is likewise the token Home's sleep ring is
    /// drawn in, so a week's bars and a ring showing the same quantity are visibly the same quantity.
    /// Neither is re-picked here; a private copy of a tier colour is how three of them diverged before.
    private static func color(for value: Int, palette: WeekBarSeries.Palette) -> Color {
        switch palette {
        case .recoveryTier: return RecoveryMetric.RecoveryState(score: value).color
        case .sleepPerformance: return Theme.sleepPerformance
        }
    }
}
