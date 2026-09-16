import SwiftUI

/// One night's stress trace, drawn across the night's own in-bed window.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `StressMonitorChartView` and
/// `HoursOfSleepChartView`. Nothing in this project uses Swift Charts.
///
/// ## What each axis claims
///
/// The x axis is the **night**, not the calendar day: 0 is the in-bed start and the right edge is the
/// wake, so a short night and a long one are both drawn full-width. `StressMonitorChartView`'s axis is
/// a fixed 24 hours and its marks land wherever the clock puts them; this night crosses midnight, so
/// there is no clock position to place a window at. That difference is carried by the series, which
/// takes a night and not a bare window list.
///
/// The y axis is **fixed at 0–3** and never auto-scaled, on the day chart's rule: scaling to the data
/// would draw a calm night and a wired one as the same picture, which is the one thing this chart
/// exists to distinguish.
///
/// ## Empty is not calm, and there is nothing here to draw it with
///
/// The day chart shades the hours its model cannot score, because on a full-day axis those hours are
/// present and empty on *every* day. This chart has no such region: its axis is exactly the span the
/// model was given, so every point on it was a chance to measure. Where it did not measure, the line
/// **breaks** — see `SleepStressChartSeries.maximumGapSeconds` — and a break is the honest rendering.
///
/// With no windows the view draws nothing at all, and its caller draws no card either. A flat line at
/// zero would be the strongest possible claim of calm.
public struct SleepStressChartView: View {

    public let series: SleepStressChartSeries

    public init(series: SleepStressChartSeries) {
        self.series = series
    }

    /// Total height including the time labels beneath the plot, matching the two charts this one sits
    /// between on the sleep page so all three read at the same weight. A `GeometryReader` has no
    /// intrinsic size, so something has to state one.
    private static let totalHeight: CGFloat = 132
    private static let labelHeight: CGFloat = 15

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                plot(plotHeight: max(1, proxy.size.height - Self.labelHeight))
                timeLabels
                    .frame(width: proxy.size.width, height: Self.labelHeight)
            }
        }
        .frame(height: Self.totalHeight)
        // The card's caption speaks the night's figures in words, and a `Path` has nothing to say to
        // VoiceOver — announcing a shape would only add noise ahead of the numbers.
        .accessibilityHidden(true)
    }

    // MARK: - Plot

    private func plot(plotHeight: CGFloat) -> some View {
        ZStack {
            // 0 and 3 are the scale's ends; 1 and 2 are the band edges, so they are drawn brighter.
            // Both sets come from `StressMath`, which is what stops this view from banding the scale
            // somewhere the score does not.
            Gridlines(values: [0, StressMath.maximumScore])
                .stroke(Theme.ringTrack.opacity(0.5), lineWidth: 1)
            Gridlines(values: [StressMath.lowMediumBandEdge, StressMath.mediumHighBandEdge])
                .stroke(Theme.ringTrack, lineWidth: 1)

            BandArea(runs: series.runs)
                .fill(StressMath.Band.gradient)
                .opacity(0.30)

            LinePath(runs: series.runs)
                .stroke(
                    Theme.textPrimary,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            DotPath(runs: series.runs, radius: 3.5)
                .fill(Theme.textPrimary)
        }
        .frame(height: plotHeight)
    }

    /// The night's two ends, labelled under their own edges.
    ///
    /// Two labels rather than the day chart's four clock ticks: the axis is not a clock, so the only
    /// positions on it that mean anything are where the night began and where it ended.
    private var timeLabels: some View {
        GeometryReader { proxy in
            HStack {
                Text(series.start.formattedHour())
                Spacer(minLength: 0)
                Text(series.end.formattedHour())
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .frame(width: proxy.size.width)
        }
    }

    // MARK: - Shapes

    /// The mapping every shape below shares: data terms in, screen points out.
    private enum Scale {
        static func x(_ fraction: Double, in rect: CGRect) -> CGFloat {
            rect.minX + CGFloat(min(max(fraction, 0), 1)) * rect.width
        }

        static func y(_ score: Double, in rect: CGRect) -> CGFloat {
            let clamped = min(max(score, 0), StressMath.maximumScore)
            return rect.maxY - CGFloat(clamped / StressMath.maximumScore) * rect.height
        }
    }

    /// The area between the line and zero.
    private struct BandArea: Shape {
        let runs: [SleepStressChartSeries.Run]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs {
                guard let first = run.points.first, let last = run.points.last else { continue }
                path.move(to: CGPoint(x: Scale.x(first.timeFraction, in: rect), y: rect.maxY))
                for point in run.points {
                    path.addLine(
                        to: CGPoint(
                            x: Scale.x(point.timeFraction, in: rect),
                            y: Scale.y(point.score, in: rect)))
                }
                path.addLine(to: CGPoint(x: Scale.x(last.timeFraction, in: rect), y: rect.maxY))
                path.closeSubpath()
            }
            return path
        }
    }

    /// The line itself. Runs of one point are skipped — `DotPath` draws those.
    private struct LinePath: Shape {
        let runs: [SleepStressChartSeries.Run]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.points.count > 1 {
                guard let first = run.points.first else { continue }
                path.move(
                    to: CGPoint(
                        x: Scale.x(first.timeFraction, in: rect),
                        y: Scale.y(first.score, in: rect)))
                for point in run.points.dropFirst() {
                    path.addLine(
                        to: CGPoint(
                            x: Scale.x(point.timeFraction, in: rect),
                            y: Scale.y(point.score, in: rect)))
                }
            }
            return path
        }
    }

    /// A lone scored window, drawn as a point.
    ///
    /// A polyline through a single point draws nothing at all, and the value was still measured — a
    /// night whose only eligible window is one five-minute stretch is a real, thin reading. Drawing a
    /// flat segment instead would invent a duration the strap never recorded.
    private struct DotPath: Shape {
        let runs: [SleepStressChartSeries.Run]
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.points.count == 1 {
                guard let point = run.points.first else { continue }
                let centre = CGPoint(
                    x: Scale.x(point.timeFraction, in: rect),
                    y: Scale.y(point.score, in: rect))
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
        let values: [Double]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for value in values {
                let y = Scale.y(value, in: rect)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }
}
