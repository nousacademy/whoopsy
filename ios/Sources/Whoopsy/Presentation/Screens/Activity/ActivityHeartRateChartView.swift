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
/// The x axis is the **session**, not the clock day: 0 is `start` and the right edge is `end`, so a
/// fifteen-minute game and a two-hour hike are both drawn full-width. That is the sleep chart's choice
/// and it holds here for a stronger reason — the page is *about* one session, and a session placed on
/// a 24-hour clock would be a fifteen-minute mark on a mostly empty frame.
///
/// The y axis is **fixed and widens rather than fitting or clamping**; `ActivityHeartRateAxis`'s own
/// comment carries that argument, and it is why the numbers on the left are drawn at all: a trace with
/// no scale under it is a shape, not a reading.
///
/// ## The window is the frame, and its two edges are ruled anyway
///
/// The night chart rules its two bounds as dashed verticals with a dot at each foot because a night's
/// in-bed window sits *inside* a longer recording. Here `start` and `end` are the session's own
/// instants and the plot's own edges, so a rule at each end traces the frame rather than marking a
/// span within it — and **the same two ships here deliberately**. They are drawn because this page's
/// reference draws them and the page is being matched to it, which is the whole of the reason; they
/// mark where the session began and ended and nothing else, so nothing should read them as a band
/// inside a longer record the way the night chart's are read. The clock labels beneath each foot are
/// what actually name the two ends.
///
/// ## The frame is drawn whether or not there is a trace in it
///
/// `series` is **optional**, and the absent branch is not an empty view. `biometric_samples` holds 0
/// rows in every database this app has ever run against and the export carries no heart-rate series,
/// so **every session this app can currently show takes that branch** — and the session's window is
/// known without a single sample. So the frame, the two rules, the two clock labels and the empty
/// gutter the axis numbers would sit in are all drawn, with `absenceNote` centred in the plot.
///
/// **It is a sentence and not a flat line.** A line at the axis foot is the strongest possible claim
/// of a calm session, and it is the one mark this branch must never make — the rule
/// `StressMonitorChartView` follows for a day with no eligible window, applied here to a session with
/// no samples.
///
/// ## A run of one is drawn, and a gap is not bridged
///
/// `runs` comes from the series, which splits on a dropout. A run of two or more is stroked as one
/// segment; a run of exactly one draws a dot instead, because a polyline through a single point draws
/// nothing at all and that point *was* measured — the same two shapes, for the same reason, as
/// `StressMonitorChartView`'s `LinePath`/`DotPath` pair. The area beneath the trace is closed from the
/// same runs, so a gap is a gap in the fill as well as in the line.
public struct ActivityHeartRateChartView: View {

    /// The session's samples, or `nil` when it has none. See this type's comment: the absent case is
    /// the one every session on this machine draws, and it is a drawn frame rather than a blank.
    public let series: ActivityHeartRateSeries?

    /// The session's own window, which the frame is drawn across whether or not `series` is present.
    public let start: Date
    public let end: Date

    public init(series: ActivityHeartRateSeries?, start: Date, end: Date) {
        self.series = series
        self.start = start
        self.end = end
    }

    /// What the plot says when there is nothing to draw in it.
    ///
    /// A `nonisolated static` rather than text built in the `body`, on the rule this page's other
    /// strings follow: the runner has no renderer, so a sentence written into a `body` is a sentence
    /// nothing can assert.
    public nonisolated static let absenceNote = "No heart rate recorded"

    /// Total height including the time labels beneath the plot. A `GeometryReader` has no intrinsic
    /// size, so something has to state one.
    ///
    /// **This chart is taller than its three 132 pt siblings** — `HoursOfSleepChartView`,
    /// `SleepStressChartView` and `StressMonitorChartView` — and the difference is deliberate rather
    /// than drift. On each of those screens the trace is one element among several: the night chart's
    /// sits under a headline figure that is the card's actual subject, and the stress chart's is one
    /// card on a page of cards. Here the trace *is* the page's hero block in the reference, at roughly
    /// twice this family's height, and a session is a short window whose whole shape is the point — so
    /// drawing it at the siblings' size is the single most visible way this page can fail to look like
    /// the picture it is being matched to. Only this file moves; the three siblings keep their own.
    private static let totalHeight: CGFloat = 210

    /// Room for the clock labels under the plot, which are set larger here than the siblings' 9 pt for
    /// the same reason the plot is taller — see `totalHeight`.
    private static let labelHeight: CGFloat = 22

    /// The gutter the y labels sit in, to the left of the plot.
    ///
    /// **Reserved in both branches**, so the frame does not move when a session has no samples: the
    /// trace starts at the same x either way, and the two branches are the same picture with a
    /// different middle rather than two different pictures. It is wider than the siblings' 26 pt
    /// because the numbers in it are set larger; at 12 pt a `100` does not fit a 26 pt gutter without
    /// crowding the plot it labels.
    private static let axisLabelWidth: CGFloat = 30

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if let series {
                        yLabels(axis: series.axis, height: max(1, proxy.size.height - Self.labelHeight))
                            .frame(width: Self.axisLabelWidth)
                    } else {
                        Color.clear
                            .frame(width: Self.axisLabelWidth)
                    }
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

    /// The trace mapped across this session's own window. See `ActivityHeartRatePlot` for why the window
    /// is the caller's to state rather than the series' to imply.
    private var plot: ActivityHeartRatePlot {
        ActivityHeartRatePlot(series: series, start: start, end: end)
    }

    private func plot(plotHeight: CGFloat) -> some View {
        ZStack {
            if let series {
                ActivityHeartRatePlot.Gridlines(axis: series.axis)
                    .stroke(Theme.ringTrack, lineWidth: 1)

                // The area is a `Shape` and not a `Path` built here: `path(in:)` is handed the frame,
                // so the gradient's stops land on the plot rather than on the shape's own bounding box
                // — the trap `StressMonitorChartView` records for its fill.
                ActivityHeartRatePlot.AreaPath(runs: plot.runs, axis: series.axis)
                    .fill(
                        LinearGradient(
                            colors: [Theme.weekLine.opacity(0.35), Theme.weekLine.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom))

                ActivityHeartRatePlot.LinePath(runs: plot.runs, axis: series.axis)
                    .stroke(
                        Theme.weekLine,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ActivityHeartRatePlot.DotPath(runs: plot.runs, axis: series.axis, radius: 2.5)
                    .fill(Theme.weekLine)
            } else {
                Text(Self.absenceNote)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }

            // The session's own bounds, drawn the way this repo draws every vertical marker —
            // `HoursOfSleepChartView.BoundsMarkers`, `StressMonitorChartView.TimeMarker` and
            // `TypicalRangeBar`'s band edges all use this exact style.
            ActivityHeartRatePlot.BoundsMarkers()
                .stroke(
                    Theme.textSecondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            ActivityHeartRatePlot.FootDots(radius: 2.5)
                .fill(Theme.textSecondary.opacity(0.6))
        }
        .frame(height: plotHeight)
    }

    private func yLabels(axis: ActivityHeartRateAxis, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ForEach(axis.gridLines, id: \.self) { value in
                Text(Self.axisText(value))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .position(
                        x: proxy.size.width - Self.axisLabelWidth / 2,
                        y: labelY(for: value, axis: axis, height: proxy.size.height))
            }
        }
        .frame(height: height)
    }

    /// Where a gridline's label sits, held far enough from the plot's edges that it is not cut in half.
    ///
    /// It bites at the lower bound: the standard axis' bottom gridline *is* the frame's bottom edge, so
    /// an unclamped label would have its lower half outside the view.
    private func labelY(for value: Double, axis: ActivityHeartRateAxis, height: CGFloat) -> CGFloat {
        let inset: CGFloat = 5
        let y = (1 - CGFloat(axis.fraction(value))) * height
        return min(max(y, inset), max(inset, height - inset))
    }

    /// No clamp and no inset: the two labels are the session's ends, so `HStack` + `Spacer` puts them
    /// flush to the corners of the plot they belong to.
    ///
    /// **A clock time each, and not a duration.** The session's own length is printed above this chart
    /// as `DURATION`, so two more durations here would say the same thing twice; the times say when the
    /// session was, which nothing else on the page does. They are drawn in both branches, because the
    /// session's window is a fact the page has whether or not any sample arrived inside it.
    private var timeLabels: some View {
        HStack(spacing: 0) {
            Text(start.formattedHourMinute())
            Spacer(minLength: 4)
            Text(end.formattedHourMinute())
        }
        // Offset by the gutter so the labels line up with the plot above them rather than with the axis
        // numbers, which are not a time. Set larger and brighter than the y numbers beside them, which
        // is the reference's own hierarchy: the two ends of the session are the frame's caption, and the
        // scale is furniture.
        .padding(.leading, Self.axisLabelWidth)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A gridline value as a label. Whole numbers by construction — see `ActivityHeartRateAxis.lines` —
    /// so this rounds rather than printing a decimal the axis never meant.
    private static func axisText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

}
