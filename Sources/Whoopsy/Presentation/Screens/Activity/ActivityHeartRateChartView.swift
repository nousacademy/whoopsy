import SwiftUI

/// One session's heart rate, drawn across the session's own window.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `HoursOfSleepChartView` and
/// `StressMonitorChartView` — nothing in this project uses Swift Charts. It is a sibling of the first
/// of those rather than a reuse, for the reasons `ActivityHeartRateSeries`' comment gives: a different
/// card, a different x window and a different scale.
///
/// ## What each axis claims
///
/// The x axis is the **session**, not the clock day: 0 is `series.start` and the right edge is
/// `series.end`, so a fifteen-minute game and a two-hour hike are both drawn full-width. That is the
/// sleep chart's choice and it holds here for a stronger reason — the page is *about* one session, and
/// a session placed on a 24-hour clock would be a fifteen-minute mark on a mostly empty frame.
///
/// The y axis is **fixed and widens rather than fitting or clamping**; `ActivityHeartRateAxis`'s own
/// comment carries that argument, and it is why the numbers on the left are drawn at all: a trace with
/// no scale under it is a shape, not a reading.
///
/// ## Two marks the sleep chart draws and this one does not
///
/// The night chart rules its two bounds as dashed verticals with a dot at each foot, because a night's
/// in-bed window sits *inside* a longer recording and the marks say where the night was. **Here the
/// window is the frame.** `start` and `end` are the session's own instants and are drawn at
/// `rect.minX` and `rect.maxX` by construction, so dashed rules there would trace the plot's own edges
/// and say nothing; the two ends are named by the labels beneath instead, which is the fact a reader
/// actually wants. That is the whole of why this view is shorter than its sibling rather than a copy of
/// it with two shapes switched off.
///
/// ## A run of one is drawn, and a gap is not bridged
///
/// `runs` comes from the series, which splits on a dropout. A run of two or more is stroked as one
/// segment; a run of exactly one draws a dot instead, because a polyline through a single point draws
/// nothing at all and that point *was* measured — the same two shapes, for the same reason, as
/// `StressMonitorChartView`'s `LinePath`/`DotPath` pair.
public struct ActivityHeartRateChartView: View {

    public let series: ActivityHeartRateSeries

    public init(series: ActivityHeartRateSeries) {
        self.series = series
    }

    /// Total height including the time labels beneath the plot, matching the other two charts' pair so
    /// the three sit at the same weight on their screens. A `GeometryReader` has no intrinsic size, so
    /// something has to state one.
    private static let totalHeight: CGFloat = 132
    private static let labelHeight: CGFloat = 15

    /// The gutter the y labels sit in, to the left of the plot.
    private static let axisLabelWidth: CGFloat = 26

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
        // The page speaks the session in words, and a `Path` has nothing to say to VoiceOver.
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

    /// Where a gridline's label sits, held far enough from the plot's edges that it is not cut in half.
    ///
    /// It bites at the lower bound: the standard axis' bottom gridline *is* the frame's bottom edge, so
    /// an unclamped label would have its lower half outside the view.
    private func labelY(for value: Double, height: CGFloat) -> CGFloat {
        let inset: CGFloat = 5
        let y = (1 - CGFloat(series.axis.fraction(value))) * height
        return min(max(y, inset), max(inset, height - inset))
    }

    /// No clamp and no inset: the two labels are the session's ends, so `HStack` + `Spacer` puts them
    /// flush to the corners of the plot they belong to.
    ///
    /// **A clock time each, and not a duration.** The session's own length is printed above this chart
    /// as `DURATION`, so two more durations here would say the same thing twice; the times say when the
    /// session was, which nothing else on the card does.
    private var timeLabels: some View {
        HStack(spacing: 0) {
            Text(series.start.formattedHourMinute())
            Spacer(minLength: 4)
            Text(series.end.formattedHourMinute())
        }
        // Offset by the gutter so the labels line up with the plot above them rather than with the axis
        // numbers, which are not a time.
        .padding(.leading, Self.axisLabelWidth)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A gridline value as a label. Whole numbers by construction — see `ActivityHeartRateAxis.lines` —
    /// so this rounds rather than printing a decimal the axis never meant.
    private static func axisText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    // MARK: - The series in plot terms

    /// A point in the data's own terms rather than in screen points: `fraction` is 0 at the session's
    /// start and 1 at its end, and `bpm` is on the axis' scale. Data terms because a `Shape` must lay
    /// itself out in whatever rect it is handed.
    private struct PlotPoint {
        let fraction: Double
        let bpm: Double
    }

    private var plotRuns: [[PlotPoint]] {
        series.runs.map { run in
            run.map { PlotPoint(fraction: fraction(for: $0.time), bpm: $0.bpm) }
        }
    }

    /// The session's real length rather than a flat figure, and never zero — the series refuses a
    /// window whose end is not after its start, and this floor is the second guard on the same division.
    private var length: TimeInterval { max(series.end.timeIntervalSince(series.start), 1) }

    private func fraction(for time: Date) -> Double {
        min(max(time.timeIntervalSince(series.start) / length, 0), 1)
    }

    // MARK: - Shapes

    /// The mapping every shape below shares: data terms in, screen points out.
    ///
    /// The y mapping goes through `ActivityHeartRateAxis.fraction` rather than restating the arithmetic,
    /// so a widening or a change to the bounds moves the drawing with it.
    private enum Scale {
        static func x(_ fraction: Double, in rect: CGRect) -> CGFloat {
            rect.minX + CGFloat(min(max(fraction, 0), 1)) * rect.width
        }

        static func y(_ bpm: Double, axis: ActivityHeartRateAxis, in rect: CGRect) -> CGFloat {
            rect.maxY - CGFloat(axis.fraction(bpm)) * rect.height
        }
    }

    private static func point(
        _ point: PlotPoint, axis: ActivityHeartRateAxis, in rect: CGRect
    ) -> CGPoint {
        CGPoint(x: Scale.x(point.fraction, in: rect), y: Scale.y(point.bpm, axis: axis, in: rect))
    }

    /// The trace. Runs of one point are skipped — `DotPath` draws those.
    private struct LinePath: Shape {
        let runs: [[PlotPoint]]
        let axis: ActivityHeartRateAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count > 1 {
                guard let first = run.first else { continue }
                path.move(to: ActivityHeartRateChartView.point(first, axis: axis, in: rect))
                for point in run.dropFirst() {
                    path.addLine(to: ActivityHeartRateChartView.point(point, axis: axis, in: rect))
                }
            }
            return path
        }
    }

    /// A lone reading, drawn as a point.
    ///
    /// A polyline through a single point draws nothing at all, and the value was still measured — a
    /// session the app heard from three times is thin, not absent. Drawing a flat segment instead would
    /// invent a duration the strap never recorded.
    private struct DotPath: Shape {
        let runs: [[PlotPoint]]
        let axis: ActivityHeartRateAxis
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count == 1 {
                guard let point = run.first else { continue }
                let centre = ActivityHeartRateChartView.point(point, axis: axis, in: rect)
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
        let axis: ActivityHeartRateAxis

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
}
