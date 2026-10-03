import SwiftUI

/// The geometry a session's heart-rate trace is drawn from, shared by the two charts that draw one.
///
/// ## Why this is a separate file, and why it is not just the shapes
///
/// `ActivityHeartRateChartView` draws the trace on the session page. `ActivityTimeTrimChartView` draws
/// the same trace on the `EDIT ACTIVITY` sheet, under two handles that trim the window. They are two
/// compositions and not one view with a flag: the page's chart carries a y-axis gutter, a scale and two
/// clock labels beneath the plot, while the sheet's has no gutter, prints its two readouts *above* the
/// plot and puts the handles below it. Sharing a view between them would mean a parameter that selects
/// half the layout, which is how the second reader ends up restyling the first.
///
/// **What they must share is the mapping as well as the marks**, and that is the whole reason this type
/// exists rather than a copy of the shapes. `plotRuns` and `fraction(for:)` are computed against a given
/// window, and the two charts ask a *different* question of them: the page maps the series across the
/// session's own bounds, while the sheet must map it across the **original** bounds even as the user
/// drags a handle to narrow the draft. A trim view that recomputed the mapping against its own draft
/// window would rescale the trace on every drag — the drawing would slide and stretch under the finger
/// holding it, which reads as the chart being broken rather than as the handle being moved. So the window
/// is a parameter here and each caller passes the one it means, and `ActivityTimeTrimChartView` passes
/// the original's.
///
/// **`ActivityHeartRateChartView`'s own output does not change.** Every shape below is the one that was
/// private in that file, moved rather than rewritten, and its §19 assertions are what says so.
///
/// ## The axis stays a parameter
///
/// The vertical scale is `ActivityHeartRateAxis`, and both charts fit it to the same series and so arrive
/// at the same one. It is passed to each shape rather than held here because it is a fact about the
/// *readings* — the series computes its own — while this type is a fact about the **window** the readings
/// are drawn across. Keeping them apart is what lets the sheet draw a series on the original axis while
/// its handles move.
struct ActivityHeartRatePlot: Equatable, Sendable {

    /// A point in the data's own terms rather than in screen points: `fraction` is 0 at the window's
    /// start and 1 at its end, and `bpm` is on the axis' scale. Data terms because a `Shape` must lay
    /// itself out in whatever rect it is handed.
    struct Point: Equatable, Sendable {
        let fraction: Double
        let bpm: Double

        init(fraction: Double, bpm: Double) {
            self.fraction = fraction
            self.bpm = bpm
        }
    }

    /// The window the trace is mapped across — **not necessarily the series' own bounds.** The sheet
    /// passes the session as it was recorded so the trace holds still while the handles move.
    let start: Date
    let end: Date

    /// The series' runs, each mapped into this window's fractions. Empty when there is no series, which
    /// is what lets every shape below be built unconditionally from it — and is why the shapes are only
    /// ever *drawn* inside a branch that has an axis.
    let runs: [[Point]]

    /// The window's real length rather than a flat figure, and never zero — a window whose end is not
    /// after its start divides by nothing, and this floor is the guard on that division.
    var length: TimeInterval { max(end.timeIntervalSince(start), 1) }

    init(series: ActivityHeartRateSeries?, start: Date, end: Date) {
        self.start = start
        self.end = end
        guard let series else {
            self.runs = []
            return
        }
        self.runs = series.runs.map { run in
            run.map { Point(fraction: Self.fraction(for: $0.time, start: start, end: end), bpm: $0.bpm) }
        }
    }

    /// Where an instant sits across the window, clamped to `0...1`.
    func fraction(for time: Date) -> Double {
        Self.fraction(for: time, start: start, end: end)
    }

    private static func fraction(for time: Date, start: Date, end: Date) -> Double {
        let length = max(end.timeIntervalSince(start), 1)
        return min(max(time.timeIntervalSince(start) / length, 0), 1)
    }

    // MARK: - Shapes

    /// The mapping every shape below shares: data terms in, screen points out.
    ///
    /// The y mapping goes through `ActivityHeartRateAxis.fraction` rather than restating the arithmetic,
    /// so a widening or a change to the bounds moves the drawing with it.
    enum Scale {
        static func x(_ fraction: Double, in rect: CGRect) -> CGFloat {
            rect.minX + CGFloat(min(max(fraction, 0), 1)) * rect.width
        }

        static func y(_ bpm: Double, axis: ActivityHeartRateAxis, in rect: CGRect) -> CGFloat {
            rect.maxY - CGFloat(axis.fraction(bpm)) * rect.height
        }
    }

    static func point(_ point: Point, axis: ActivityHeartRateAxis, in rect: CGRect) -> CGPoint {
        CGPoint(x: Scale.x(point.fraction, in: rect), y: Scale.y(point.bpm, axis: axis, in: rect))
    }

    /// The fill beneath the trace: each run walked as a line and closed to the plot's foot.
    ///
    /// Runs of one point are skipped, exactly as `LinePath` skips them — a single point has no width to
    /// fill, and the dot `DotPath` draws for it is the whole of that reading's mark.
    struct AreaPath: Shape {
        let runs: [[Point]]
        let axis: ActivityHeartRateAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count > 1 {
                guard let first = run.first, let last = run.last else { continue }
                path.move(to: CGPoint(x: Scale.x(first.fraction, in: rect), y: rect.maxY))
                for point in run {
                    path.addLine(to: ActivityHeartRatePlot.point(point, axis: axis, in: rect))
                }
                path.addLine(to: CGPoint(x: Scale.x(last.fraction, in: rect), y: rect.maxY))
                path.closeSubpath()
            }
            return path
        }
    }

    /// The trace. Runs of one point are skipped — `DotPath` draws those.
    struct LinePath: Shape {
        let runs: [[Point]]
        let axis: ActivityHeartRateAxis

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count > 1 {
                guard let first = run.first else { continue }
                path.move(to: ActivityHeartRatePlot.point(first, axis: axis, in: rect))
                for point in run.dropFirst() {
                    path.addLine(to: ActivityHeartRatePlot.point(point, axis: axis, in: rect))
                }
            }
            return path
        }
    }

    /// A lone reading, drawn as a point.
    ///
    /// A polyline through a single point draws nothing at all, and the value was still measured — a
    /// session the app heard from three times is thin, not absent. Drawing a flat segment instead would
    /// invent a duration the strap never recorded. `StressMonitorChartView`'s `LinePath`/`DotPath` pair
    /// makes the same split for the same reason.
    struct DotPath: Shape {
        let runs: [[Point]]
        let axis: ActivityHeartRateAxis
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count == 1 {
                guard let point = run.first else { continue }
                let centre = ActivityHeartRatePlot.point(point, axis: axis, in: rect)
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

    /// The horizontal rules at the axis' labelled values.
    struct Gridlines: Shape {
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

    /// The window's two ends, drawn at the plot's edges.
    ///
    /// They are at `rect.minX` and `rect.maxX` by construction, so this shape states that rather than
    /// recomputing a fraction that is 0 and 1 by definition. The page's chart draws it in **both**
    /// branches — its frame does not depend on there being a trace inside it — and the sheet's draws it
    /// against the original window, which is what makes the two handles read as moving *within* a fixed
    /// span rather than as the span itself.
    struct BoundsMarkers: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for x in [rect.minX, rect.maxX] {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }

    /// A dot at the foot of each bounds marker, so the two dashed lines read as the window's edges
    /// rather than as gridlines — the reference's own composition.
    ///
    /// Inset from the plot's corners by the radius, because a dot centred exactly on `minX` would be
    /// half outside the plot on either side.
    struct FootDots: Shape {
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
