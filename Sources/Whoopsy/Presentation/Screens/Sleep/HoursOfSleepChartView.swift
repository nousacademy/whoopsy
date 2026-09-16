import SwiftUI

/// One night's heart rate, drawn across the night's own in-bed window.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `StressMonitorChartView` — which is this view's
/// closest precedent and the pattern it copies. Nothing in this project uses Swift Charts.
///
/// ## What each axis claims
///
/// The x axis is the **night**, not the calendar day: 0 is `series.start` (in-bed) and the right edge
/// is `series.end` (wake), so a short night and a long one are both drawn full-width and the two
/// dashed markers stand at the night's own bounds. That differs from `StressMonitorChartView`, whose
/// axis is a fixed 24 hours and whose marks therefore land wherever the clock puts them — here there
/// is nothing to place a mark against except the window itself.
///
/// The y axis is **fixed** and widens rather than fitting or clamping; `HoursOfSleepChartAxis`'s own
/// comment carries that argument, and it is the reason the numbers on the left are drawn at all: a
/// trace with no scale under it is a shape, not a reading.
///
/// ## A run of one is drawn, and a gap is not bridged
///
/// `runs` comes from the series, which split on a dropout. A run of two or more is stroked as one
/// segment; a run of exactly one draws a dot instead, because a polyline through a single point draws
/// nothing at all and that point *was* measured — the same reasoning, and the same two shapes, as
/// `StressMonitorChartView`'s `LinePath`/`DotPath` pair.
public struct HoursOfSleepChartView: View {

    public let series: HoursOfSleepChartSeries

    public init(series: HoursOfSleepChartSeries) {
        self.series = series
    }

    /// Total height including the time labels beneath the plot, matching `StressMonitorChartView`'s
    /// pair so the two charts sit at the same weight on their screens. A `GeometryReader` has no
    /// intrinsic size, so something has to state one.
    private static let totalHeight: CGFloat = 132
    private static let labelHeight: CGFloat = 15

    /// The gutter the y labels sit in, to the left of the plot.
    private static let axisLabelWidth: CGFloat = 22

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    yLabels(height: max(1, proxy.size.height - Self.labelHeight))
                        .frame(width: Self.axisLabelWidth)
                    plot(plotHeight: max(1, proxy.size.height - Self.labelHeight))
                }
                timeLabels
                    .frame(width: proxy.size.width, height: Self.labelHeight)
            }
        }
        .frame(height: Self.totalHeight)
        // The card's caption speaks the night in words, and a `Path` has nothing to say to VoiceOver.
        .accessibilityHidden(true)
    }

    // MARK: - Plot

    private func plot(plotHeight: CGFloat) -> some View {
        ZStack {
            Gridlines(axis: series.axis)
                .stroke(Theme.ringTrack, lineWidth: 1)

            LinePath(runs: plotRuns, axis: series.axis)
                .stroke(
                    Theme.weekLine,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            DotPath(runs: plotRuns, axis: series.axis, radius: 2.5)
                .fill(Theme.weekLine)

            // The night's own bounds. One marker per end, drawn the way this repo draws every
            // vertical marker — `StressMonitorChartView.TimeMarker` and `TypicalRangeBar`'s band
            // edges both use this exact style.
            BoundsMarkers()
                .stroke(
                    Theme.textSecondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            FootDots(radius: 2.5)
                .fill(Theme.textSecondary.opacity(0.6))
        }
        .frame(height: plotHeight)
    }

    private func yLabels(height: CGFloat) -> some View {
        GeometryReader { proxy in
            ForEach(series.axis.gridLines, id: \.self) { value in
                Text(Self.axisText(value))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
                    .position(
                        x: proxy.size.width - Self.axisLabelWidth / 2,
                        y: labelY(for: value, height: proxy.size.height))
            }
        }
        .frame(height: height)
    }

    /// Where a gridline's label sits, held far enough from the plot's edges that it is not cut in
    /// half — the same clamp, for the same reason, as `StressMonitorChartView.labelX`.
    ///
    /// It bites at the lower bound: the standard axis' bottom gridline *is* the frame's bottom edge,
    /// so an unclamped label would have its lower half outside the view.
    private func labelY(for value: Double, height: CGFloat) -> CGFloat {
        let inset: CGFloat = 5
        let y = (1 - CGFloat(series.axis.fraction(value))) * height
        return min(max(y, inset), max(inset, height - inset))
    }

    /// No clamp and no inset: the two labels are the night's ends, so `HStack` + `Spacer` puts them
    /// flush to the corners of the plot they belong to.
    private var timeLabels: some View {
        HStack(spacing: 0) {
            Text(series.start.formattedHourMinute())
            Spacer(minLength: 4)
            Text(series.end.formattedHourMinute())
        }
        // Offset by the gutter so the labels line up with the plot above them rather than with the
        // axis numbers, which are not a time.
        .padding(.leading, Self.axisLabelWidth)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A gridline value as a label. Whole numbers by construction — see `HoursOfSleepChartAxis.lines` —
    /// so this rounds rather than printing a decimal the axis never meant.
    private static func axisText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    // MARK: - The series in plot terms

    /// A point in the data's own terms rather than in screen points: `fraction` is 0 at in-bed and 1
    /// at wake, and `bpm` is on the axis' scale. Data terms because a `Shape` must lay itself out in
    /// whatever rect it is handed.
    private struct PlotPoint {
        let fraction: Double
        let bpm: Double
    }

    private var plotRuns: [[PlotPoint]] {
        series.runs.map { run in
            run.map { PlotPoint(fraction: fraction(for: $0.time), bpm: $0.bpm) }
        }
    }

    /// The night's real length rather than a flat figure, and never zero — the series refuses a
    /// window whose end is not after its start, and this floor is the second guard on the same
    /// division.
    private var length: TimeInterval { max(series.end.timeIntervalSince(series.start), 1) }

    private func fraction(for time: Date) -> Double {
        min(max(time.timeIntervalSince(series.start) / length, 0), 1)
    }

    // MARK: - Shapes

    /// The mapping every shape below shares: data terms in, screen points out.
    ///
    /// The y mapping goes through `HoursOfSleepChartAxis.fraction` rather than restating the arithmetic,
    /// so a widening or a change to the bounds moves the drawing with it.
    private enum Scale {
        static func x(_ fraction: Double, in rect: CGRect) -> CGFloat {
            rect.minX + CGFloat(min(max(fraction, 0), 1)) * rect.width
        }

        static func y(_ bpm: Double, axis: HoursOfSleepChartAxis, in rect: CGRect) -> CGFloat {
            rect.maxY - CGFloat(axis.fraction(bpm)) * rect.height
        }
    }

    private static func point(
        _ point: PlotPoint, axis: HoursOfSleepChartAxis, in rect: CGRect
    ) -> CGPoint {
        CGPoint(x: Scale.x(point.fraction, in: rect), y: Scale.y(point.bpm, axis: axis, in: rect))
    }

    /// The trace. Runs of one point are skipped — `DotPath` draws those.
    private struct LinePath: Shape {
        let runs: [[PlotPoint]]
        let axis: HoursOfSleepChartAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count > 1 {
                guard let first = run.first else { continue }
                path.move(to: HoursOfSleepChartView.point(first, axis: axis, in: rect))
                for point in run.dropFirst() {
                    path.addLine(to: HoursOfSleepChartView.point(point, axis: axis, in: rect))
                }
            }
            return path
        }
    }

    /// A lone reading, drawn as a point.
    ///
    /// A polyline through a single point draws nothing at all, and the value was still measured — a
    /// night the app heard from three times is thin, not absent. Drawing a flat segment instead would
    /// invent a duration the strap never recorded.
    private struct DotPath: Shape {
        let runs: [[PlotPoint]]
        let axis: HoursOfSleepChartAxis
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count == 1 {
                guard let point = run.first else { continue }
                let centre = HoursOfSleepChartView.point(point, axis: axis, in: rect)
                path.addEllipse(
                    in: CGRect(
                        x: centre.x - radius,
                        y: centre.y - radius,
                        width: radius * 2,
                        height: radius * 2))
            }
            return path
        }
    }

    private struct Gridlines: Shape {
        let axis: HoursOfSleepChartAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for value in axis.gridLines {
                let y = Scale.y(value, axis: axis, in: rect)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }

    /// The night's two ends, drawn at the plot's edges.
    ///
    /// They are at `rect.minX` and `rect.maxX` by construction, so this shape states that rather than
    /// recomputing a fraction that is 0 and 1 by definition.
    private struct BoundsMarkers: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for x in [rect.minX, rect.maxX] {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }

    /// A dot at the foot of each bounds marker, so the two dashed lines read as the night's edges
    /// rather than as gridlines — the reference's own composition.
    ///
    /// Inset from the plot's corners by the radius, because a dot centred exactly on `minX` would be
    /// half outside the plot on either side.
    private struct FootDots: Shape {
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for x in [rect.minX + radius, rect.maxX - radius] {
                path.addEllipse(
                    in: CGRect(
                        x: x - radius,
                        y: rect.maxY - radius * 2,
                        width: radius * 2,
                        height: radius * 2))
            }
            return path
        }
    }
}
