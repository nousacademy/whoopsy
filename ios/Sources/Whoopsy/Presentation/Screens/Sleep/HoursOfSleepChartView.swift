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
/// ## A draggable cursor reads the night's clock
///
/// Touching the plot puts a vertical rule under the finger, prints the instant it stands for in the
/// label row beneath, and the heart rate there at the rule's other end — so the clock and the reading
/// are read at one glance and never compete for a row. The label rows are the night's own two ends
/// while nothing is held. The rule
/// is white and solid where the night's bounds are grey and dashed: one is the reader's finger rather
/// than a fact about the night, and the two must not be mistaken for one another. Releasing removes it;
/// a rule left behind would be a mark nothing put there.
///
/// The mapping from a plot fraction to an instant is `HoursOfSleepChartSeries.time(atFraction:)` and
/// the reading is `value(atFraction:)` — both on the series rather than in the gesture, so the parts
/// of the cursor that are rules are asserted by the suite: the arithmetic, its clamping at both ends,
/// and the hole rule, since a cursor in a stretch the strap did not measure prints no reading rather
/// than the nearest one from the far side of the gap. The gesture itself is not,
/// and the chart stays out of VoiceOver's way; the section's label above still describes the trace's
/// bounds and size.
///
/// ## A run of one is drawn, and a gap is not bridged
///
/// `runs` comes from the series, which split on a dropout. A run of two or more is stroked as one
/// segment; a run of exactly one draws a dot instead, because a polyline through a single point draws
/// nothing at all and that point *was* measured — the same reasoning, and the same two shapes, as
/// `StressMonitorChartView`'s `LinePath`/`DotPath` pair.
public struct HoursOfSleepChartView: View {

    public let series: HoursOfSleepChartSeries

    /// Where the draggable cursor is, as a fraction of the night, or `nil` when it is not being held.
    ///
    /// **View state, not model state**: it is a finger's position rather than a reading, it is not
    /// stored, and it changes nothing the page prints. Holding it here keeps the gesture and the marks
    /// it draws in one file. The mapping from a fraction to an instant is the series' own —
    /// `time(atFraction:)` — so what the label says is asserted without a renderer.
    @State private var cursorFraction: Double?

    public init(series: HoursOfSleepChartSeries) {
        self.series = series
    }

    /// Total height including the time labels beneath the plot, matching `StressMonitorChartView`'s
    /// pair so the two charts sit at the same weight on their screens. A `GeometryReader` has no
    /// intrinsic size, so something has to state one.
    private static let totalHeight: CGFloat = 168
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

            // The draggable cursor. White and solid, where the night's bounds are grey and dashed —
            // it is the reader's finger, not a fact about the night, and the two must not be
            // mistaken for one another.
            if let cursorFraction {
                CursorLine(fraction: cursorFraction)
                    .stroke(Theme.textPrimary, lineWidth: 1)
            }
        }
        .frame(height: plotHeight)
        // The cursor's reading, at the **opposite end of the rule from the time**: the clock sits
        // under the axis and the heart rate over the trace, so a reader dragging sees both without
        // the two labels competing for the same row. Nothing is drawn where the cursor sits in a gap
        // the strap did not measure — see `HoursOfSleepChartSeries.value(atFraction:)`.
        .overlay {
            GeometryReader { proxy in
                if
                    let cursorFraction,
                    let value = series.value(atFraction: cursorFraction)
                {
                    Text("\(Int(value.rounded())) bpm")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                        .fixedSize()
                        // The rule is drawn through this point, so the label carries the page's own
                        // background: a capsule is what stops the line crossing the digits.
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.backgroundDark))
                        .position(
                            x: Self.plotLabelX(for: cursorFraction, width: proxy.size.width),
                            y: 9)
                }
            }
        }
        // The gesture sits on a clear rectangle **over** the plot rather than on the shapes: a
        // stroked line has no fill to hit-test, and a `Shape`'s hit area is its bounding box, which
        // would make the whole plot respond to a drag that never touched the trace.
        .overlay {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let width = max(1, proxy.size.width)
                                cursorFraction = min(1, max(0, value.location.x / width))
                            }
                            // Released, the cursor goes: a rule left behind would be a mark on the
                            // night that nothing put there.
                            .onEnded { _ in cursorFraction = nil })
            }
        }
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

    /// The night's two ends, or — while the cursor is held — the exact instant under it.
    ///
    /// **The ends are replaced rather than joined**, because the cursor's label is drawn at the
    /// cursor's `x` and an end label at the same corner would be drawn over. A reader dragging to
    /// either bound therefore still reads one unambiguous time under the line.
    ///
    /// The two-ended row is `HStack` + `Spacer` at the corners of the plot, with a **trailing inset
    /// that is the screen's, not the plot's**: the sleep page draws this chart edge to edge, so
    /// without it the end label's last glyph runs into the display's edge and reads as cut.
    private var timeLabels: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let cursorFraction {
                    Text(series.time(atFraction: cursorFraction).formattedHourMinute())
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                        .position(
                            x: cursorLabelX(for: cursorFraction, width: proxy.size.width),
                            y: proxy.size.height / 2)
                } else {
                    HStack(spacing: 0) {
                        Text(series.start.formattedHourMinute())
                        Spacer(minLength: 4)
                        Text(series.end.formattedHourMinute())
                    }
                    // Offset by the gutter so the labels line up with the plot above them rather
                    // than with the axis numbers, which are not a time.
                    .padding(.leading, Self.axisLabelWidth)
                    .padding(.trailing, 6)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Theme.textMuted)
    }

    /// Where the cursor's clock label sits: under the line, held far enough from either edge that a
    /// time is not cut in half — the same clamp `StressMonitorChartView.labelX` makes, for the same
    /// reason. The leading gutter is added because the label row starts where the axis numbers do.
    private func cursorLabelX(for fraction: Double, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 26
        let x = Self.axisLabelWidth + CGFloat(fraction) * max(0, width - Self.axisLabelWidth)
        return min(max(x, inset), max(inset, width - inset))
    }

    /// The same clamp in the **plot's** own terms, for the reading drawn over the trace: this overlay
    /// spans the plot and not the label row, so there is no gutter to add back.
    private static func plotLabelX(for fraction: Double, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 24
        let x = CGFloat(min(max(fraction, 0), 1)) * max(0, width)
        return min(max(x, inset), max(inset, width - inset))
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

    /// The reader's cursor: one vertical rule at a fraction of the plot's width.
    private struct CursorLine: Shape {
        let fraction: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let x = rect.minX + CGFloat(min(max(fraction, 0), 1)) * rect.width
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
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
