import SwiftUI

/// The Stress Monitor's series, drawn as one bar per five-minute window.
///
/// **Bars, not a line**, and that is the reference's shape rather than a styling preference: a window
/// is a five-minute measurement, so its height is a quantity standing over the stretch of time it
/// covers. A polyline joined the points and implied a value at every instant between them — including
/// the instants no window measured — and it needed a marker at each peak to be readable at all.
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
/// **A gap is a gap**: an ineligible window draws no bar, and no bar is not a bar of zero height.
/// With no windows at all the chart draws **nothing**: no frame, no axes, no zero line. A row of zero
/// bars is a measurement, and a day whose samples yielded no eligible window was never measured. The
/// caller's caption carries that absence in words.
public struct StressMonitorChartView: View {
    /// The day's scored windows. Order is not required — they are sorted here.
    public let windows: [StressWindow]

    /// The day to plot, used for its calendar bounds rather than for its time of day.
    public let day: Date

    /// The current instant, or `nil` for a day that is not today. Drawn as a dashed marker only when
    /// it falls inside the day.
    public let now: Date?

    /// The span to plot, or `nil` for the whole calendar day.
    ///
    /// **The detail page passes a trailing span and the tile passes `nil`.** The tile is a day's
    /// summary, so its line is the day; the page is a live monitor, and a line the width of a whole
    /// day is mostly empty when the last two hours are what the reader came for. A custom span draws
    /// no waking shading either — the axis no longer *is* the day, so shading its ends would claim
    /// hours outside the chart.
    public let range: Range<Date>?

    public init(
        windows: [StressWindow],
        day: Date,
        now: Date? = nil,
        range: Range<Date>? = nil
    ) {
        self.windows = windows
        self.day = day
        self.now = now
        self.range = range
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

            // The bars are a **mask over one full-height gradient** rather than a per-bar fill: a
            // `LinearGradient` applied to each bar is graded over that bar's own height, so a short
            // bar and a tall one would put "high" at different heights — the defect the token's own
            // doc comment names. Masked, every bar reads the same scale the axis is drawn on.
            Rectangle()
                .fill(bandGradient)
                .mask(BarsShape(bars: bars, slotFraction: slotFraction))

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
            ForEach(ticks, id: \.self) { tick in
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

    /// The instants the axis is labelled at.
    ///
    /// A whole day carries WHOOP's own four: midnight, 6 AM, noon, 6 PM. A trailing span carries its
    /// two ends and two points between them, read off the span itself rather than off the clock —
    /// a six-hour window ending at 14:20 labels 08:20, 11:20, 14:20, and rounding those to the hour
    /// would put the label under a different part of the line than the one it names.
    private var ticks: [Date] {
        guard let range else {
            return Self.hourTicks.compactMap {
                Calendar.current.date(byAdding: .hour, value: $0, to: dayStart)
            }
        }
        let length = range.upperBound.timeIntervalSince(range.lowerBound)
        return [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0].map {
            range.lowerBound.addingTimeInterval(length * $0)
        }
    }

    /// A tick's label centre, held far enough from the left edge that "12 AM" is not cut in half.
    private func labelX(for tick: Date, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 16
        let x = CGFloat(tick.timeIntervalSince(dayStart) / dayLength) * width
        return min(max(x, inset), max(inset, width - inset))
    }

    // MARK: - The day's bounds

    /// The plot's left edge: midnight for a whole day, the span's own start otherwise.
    private var dayStart: Date { range?.lowerBound ?? day.startOfDay }

    /// The plot's right edge. See `dayStart`.
    private var dayEnd: Date {
        if let range { return range.upperBound }
        return Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
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
        // A trailing span *ends* at now, so the marker would sit on the axis — a dashed line pinned
        // to the edge claims the time is at the axis, which is what this value refuses to draw.
        guard range == nil else { return nil }
        guard let now, now >= dayStart, now <= dayEnd else { return nil }
        return now.timeIntervalSince(dayStart) / dayLength
    }

    /// The hours this model cannot score, which on a full-day axis are always its two ends.
    private var unscoredSpans: [Range<Date>] {
        // A custom span is not a day, so it has no unscored ends to shade; see `range`.
        guard range == nil else { return [] }
        guard let waking = StressMath.wakingWindow(on: dayStart) else { return [] }
        var spans: [Range<Date>] = []
        if waking.lowerBound > dayStart { spans.append(dayStart..<waking.lowerBound) }
        if waking.upperBound < dayEnd { spans.append(waking.upperBound..<dayEnd) }
        return spans
    }

    // MARK: - The series

    /// The windows on the axis, in data terms — one bar each.
    ///
    /// **No run-splitting any more, and no joining across a gap.** Each bar is drawn from the window
    /// that produced it, so an ineligible window — the strap moving, or too few beats — simply has no
    /// bar, which is the honest rendering of a hole. The old line had to break itself into runs to say
    /// the same thing.
    private var bars: [PlotPoint] {
        // Only what the axis covers: a point outside it would be drawn at a fraction below zero or
        // past the frame, and a `Shape` handed such a fraction paints over its neighbours.
        windows
            .filter { $0.start >= dayStart && $0.start <= dayEnd }
            .sorted { $0.start < $1.start }
            .map(plotPoint)
    }

    /// One window's width as a fraction of the axis — the slot its five minutes occupy.
    private var slotFraction: Double {
        min(1, StressMath.windowSeconds / dayLength)
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

    /// One bar per scored window: its five minutes wide, its score tall.
    ///
    /// The width is a **fraction of the axis** rather than a constant, so the same code draws a day
    /// (where a window is a third of a percent of the width and the bars read as one dense series)
    /// and a six-hour span (where the same window is nearly five points wide). A constant width
    /// would either vanish on the tile or overlap on the page.
    ///
    /// A scored window of `0.0` is a real reading, so it is drawn at a minimum height rather than as
    /// nothing — the difference between "calm" and "not measured" is the whole reason this chart has
    /// a gap rule.
    private struct BarsShape: Shape {
        let bars: [PlotPoint]
        let slotFraction: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard slotFraction > 0, !bars.isEmpty else { return path }
            let slot = rect.width * CGFloat(slotFraction)
            let width = max(1, slot * 0.62)
            let radius = min(width / 2, 1.5)
            let minimumHeight: CGFloat = 1.5

            for bar in bars {
                let top = Scale.y(bar.score, in: rect)
                let height = max(minimumHeight, rect.maxY - top)
                let x = Scale.x(bar.timeFraction, in: rect) + (slot - width) / 2
                let frame = CGRect(
                    x: x,
                    y: max(rect.minY, rect.maxY - height),
                    width: width,
                    height: min(height, rect.height))
                path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius, height: radius))
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
