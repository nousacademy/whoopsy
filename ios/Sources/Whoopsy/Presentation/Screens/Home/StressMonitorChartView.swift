import SwiftUI

/// The Stress Monitor's day, drawn as a line across the full 24 hours.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `HypnogramChartView` and the Recovery trend
/// chart. Nothing in this project uses Swift Charts and this is not the place to start.
///
/// ## What each axis claims
///
/// The x axis is the **whole calendar day**. The y axis is **fixed at 0–3** and never auto-scaled:
/// scaling to the data would draw a calm day and a wired day as the same picture, which is the one
/// thing this chart exists to distinguish.
///
/// ## Empty is not calm
///
/// The model only scores `StressMath.wakingWindowStartHour`–`wakingWindowEndHour`, so on a full-day
/// axis the ends are empty on *every* day, a fully-worn one included. Empty would read as calm, which
/// is the opposite of the truth — those hours were not measured. They are shaded instead, which is
/// this view's one addition beyond the reference image and the only thing on it that says what it
/// does not know.
///
/// With no windows at all the chart draws **nothing**: no frame, no axes, no zero line. A flat line at
/// zero is a measurement, and a day whose samples yielded no eligible window was never measured. The
/// caller's caption carries that absence in words.
public struct StressMonitorChartView: View {
    /// The day's scored windows. Order is not required — they are sorted here.
    public let windows: [StressWindow]

    /// The day to plot, used for its calendar bounds rather than for its time of day.
    public let day: Date

    /// The current instant, or `nil` for a day that is not today. Drawn as a dashed marker only when
    /// it falls inside the day.
    public let now: Date?

    public init(windows: [StressWindow], day: Date, now: Date? = nil) {
        self.windows = windows
        self.day = day
        self.now = now
    }

    /// The plot's height, excluding the hour labels beneath it. A `GeometryReader` has no intrinsic
    /// size, so something has to state one.
    private static let plotHeight: CGFloat = 132
    private static let labelHeight: CGFloat = 15

    /// The ticks WHOOP's own axis carries: midnight, 6 AM, noon, 6 PM.
    private static let hourTicks = [0, 6, 12, 18]

    public var body: some View {
        if !windows.isEmpty {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    plot(plotHeight: max(1, proxy.size.height - Self.labelHeight))
                    hourLabels
                        .frame(width: proxy.size.width, height: Self.labelHeight)
                }
            }
            .frame(height: Self.plotHeight)
            // The tile's own label already speaks the figure, and a `Path` has nothing to say to
            // VoiceOver — announcing a shape would only add noise ahead of the number.
            .accessibilityHidden(true)
        }
    }

    // MARK: - Plot

    private func plot(plotHeight: CGFloat) -> some View {
        ZStack {
            UnscoredSpans(spans: unscoredSpans, dayStart: dayStart, dayLength: dayLength)
                .fill(Theme.ringTrack.opacity(0.35))

            // 0 and 3 are the scale's ends; 1 and 2 are the band edges, so they are drawn brighter.
            // Both sets come from `StressMath`, which is what stops this view from banding the scale
            // somewhere the score does not.
            Gridlines(values: [0, StressMath.maximumScore])
                .stroke(Theme.ringTrack.opacity(0.5), lineWidth: 1)
            Gridlines(values: [StressMath.lowMediumBandEdge, StressMath.mediumHighBandEdge])
                .stroke(Theme.ringTrack, lineWidth: 1)

            BandArea(runs: runs)
                .fill(bandGradient)
                .opacity(0.30)

            LinePath(runs: runs)
                .stroke(
                    Theme.textPrimary,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            DotPath(runs: runs, radius: 3.5)
                .fill(Theme.textPrimary)

            if let nowFraction {
                TimeMarker(fraction: nowFraction)
                    .stroke(
                        Theme.textSecondary.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(height: plotHeight)
    }

    /// WHOOP's three bands as a hard-edged vertical gradient.
    ///
    /// **Moved to `StressMath.Band.gradient`, and read from there.** The sleep detail screen's night
    /// chart fills under the same three bands, and the argument this comment used to carry — that the
    /// stops are the edges divided by the scale, so the fill changes colour exactly where
    /// `band(forScore:)` changes band — is the argument for there being one of these rather than two.
    /// See that property for the hard edge and for why the fill must be a `Shape` and not a `Path`.
    private var bandGradient: LinearGradient { StressMath.Band.gradient }

    private var hourLabels: some View {
        GeometryReader { proxy in
            ForEach(Self.hourTicks, id: \.self) { hour in
                if let tick = Calendar.current.date(byAdding: .hour, value: hour, to: dayStart) {
                    Text(tick.formattedHour())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize()
                        .position(
                            x: labelX(for: tick, width: proxy.size.width),
                            y: proxy.size.height / 2)
                }
            }
        }
    }

    /// A tick's label centre, held far enough from the left edge that "12 AM" is not cut in half.
    private func labelX(for tick: Date, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 16
        let x = CGFloat(tick.timeIntervalSince(dayStart) / dayLength) * width
        return min(max(x, inset), max(inset, width - inset))
    }

    // MARK: - The day's bounds

    private var dayStart: Date { day.startOfDay }

    private var dayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
    }

    /// The day's real length rather than a flat 86,400 seconds, so the 23- and 25-hour days either
    /// side of a daylight-saving change put their hours where the clock does.
    private var dayLength: TimeInterval { max(dayEnd.timeIntervalSince(dayStart), 1) }

    /// Where `now` sits in the day, or `nil` when it is not in it.
    ///
    /// `nil` rather than clamped to an edge: a marker pinned to the axis is a claim that the time is
    /// at the axis. A past day has no "now" on it at all.
    private var nowFraction: Double? {
        guard let now, now >= dayStart, now <= dayEnd else { return nil }
        return now.timeIntervalSince(dayStart) / dayLength
    }

    /// The hours this model cannot score, which on a full-day axis are always its two ends.
    private var unscoredSpans: [Range<Date>] {
        guard let waking = StressMath.wakingWindow(on: dayStart) else { return [] }
        var spans: [Range<Date>] = []
        if waking.lowerBound > dayStart { spans.append(dayStart..<waking.lowerBound) }
        if waking.upperBound < dayEnd { spans.append(waking.upperBound..<dayEnd) }
        return spans
    }

    // MARK: - The series

    /// The day's windows in data terms, split wherever the record is not continuous.
    ///
    /// A gap longer than one and a half windows ends a run, and the next window starts a new one.
    /// Ineligible windows — the strap moving, or too few beats — are **unmeasured**, and joining
    /// across one would draw a reading nobody took. A break is the honest rendering of a hole.
    private var runs: [[PlotPoint]] {
        let ordered = windows.sorted { $0.start < $1.start }
        let gap = StressMath.windowSeconds * 1.5
        var runs: [[PlotPoint]] = []
        var current: [StressWindow] = []

        for window in ordered {
            if let last = current.last, window.start.timeIntervalSince(last.start) > gap {
                runs.append(current.map(plotPoint))
                current = []
            }
            current.append(window)
        }
        if !current.isEmpty { runs.append(current.map(plotPoint)) }
        return runs
    }

    private func plotPoint(_ window: StressWindow) -> PlotPoint {
        PlotPoint(
            timeFraction: window.start.timeIntervalSince(dayStart) / dayLength,
            score: window.score)
    }

    /// A point in the data's own terms rather than in screen points: `timeFraction` is 0 at midnight
    /// and 1 at the next midnight, and `score` is on the 0–3 scale.
    ///
    /// Data terms because a `Shape` must lay itself out in whatever rect it is handed. That is what
    /// keeps the geometry right when the tile's width changes and the gradient stops on the scale.
    private struct PlotPoint {
        let timeFraction: Double
        let score: Double
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
        let runs: [[PlotPoint]]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs {
                guard let first = run.first, let last = run.last else { continue }
                path.move(to: CGPoint(x: Scale.x(first.timeFraction, in: rect), y: rect.maxY))
                for point in run {
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
        let runs: [[PlotPoint]]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count > 1 {
                guard let first = run.first else { continue }
                path.move(
                    to: CGPoint(
                        x: Scale.x(first.timeFraction, in: rect),
                        y: Scale.y(first.score, in: rect)))
                for point in run.dropFirst() {
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
    /// day whose only eligible window is one five-minute stretch is a real, thin reading. Drawing a
    /// flat segment instead would invent a duration the strap never recorded.
    private struct DotPath: Shape {
        let runs: [[PlotPoint]]
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count == 1 {
                guard let point = run.first else { continue }
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

    private struct TimeMarker: Shape {
        let fraction: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let x = Scale.x(fraction, in: rect)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            return path
        }
    }

    /// The hours the model does not score, shaded so that "no line here" reads as "not measured"
    /// rather than as "calm".
    private struct UnscoredSpans: Shape {
        let spans: [Range<Date>]
        let dayStart: Date
        let dayLength: TimeInterval

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for span in spans {
                let start = Scale.x(span.lowerBound.timeIntervalSince(dayStart) / dayLength, in: rect)
                let end = Scale.x(span.upperBound.timeIntervalSince(dayStart) / dayLength, in: rect)
                guard end > start else { continue }
                path.addRect(CGRect(x: start, y: rect.minY, width: end - start, height: rect.height))
            }
            return path
        }
    }
}
