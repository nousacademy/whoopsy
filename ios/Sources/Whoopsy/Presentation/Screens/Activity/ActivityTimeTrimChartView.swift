import SwiftUI

/// The `EDIT ACTIVITY` sheet's time control: the session's heart rate across a fixed window with a
/// draggable handle at each end, and a readout above each handle naming the boundary it trims.
///
/// ## It is a composition, not a variant
///
/// `ActivityHeartRateChartView` draws the same trace on the session page and the two are deliberately not
/// one view with a flag. The page's chart carries a y-axis gutter, a labelled scale and the two clock
/// labels beneath the plot, because it is a *reading* — a trace with no scale under it is a shape rather
/// than a measurement. This one has no y labels, prints its two readouts **above** the plot and puts its
/// two grips **below** it, because it is a *control*: its two numbers name the boundaries the handles
/// move, and a scale would be furniture between the user's finger and the thing being edited. A shared
/// view would need a parameter selecting half the layout, which is how the second reader ends up
/// restyling the first.
///
/// **What the two do share is the mapping**, and that is why `ActivityHeartRatePlot` exists rather than a
/// copy of the shapes: see its own comment. The trace here is mapped across the **original** window while
/// the handles move inside it.
///
/// ## The window is the original's, and that is the whole of the drag's honesty
///
/// `ActivityEditDraft.startFraction` is a fraction of the session *as it was recorded*, and this view
/// draws its handles from that. So the plot behind them never moves: dragging the start handle inward
/// slides one dashed rule across a trace that holds still. A view that re-mapped the series against the
/// draft's own narrowing window would stretch the drawing on every frame of the drag, which reads as the
/// chart being broken rather than as the boundary being moved.
///
/// ## Both handles work on an empty chart, and that is the state every session draws
///
/// `series` is `nil` on every session this app can currently show — `biometric_samples` holds 0 rows in
/// every database on this machine — and the window is known without a single sample, so the frame, the two
/// rules, the two grips and the two clock readouts are all drawn regardless. What an absent series costs
/// is the trace, and the two `bpm` figures, which are withheld rather than invented. **This is not a
/// degraded control**: trimming a session's span is the sheet's whole purpose and it needs no sample at
/// all, so the control is complete today and its two readouts fill in the first time a strap is connected.
///
/// ## The bpm readouts name the reading *in force*
///
/// `ActivityHeartRateSeries.bpm(at:)` and never an interpolation between the two samples either side of
/// the handle: a figure averaged across a boundary is a rate the strap never reported. A handle dragged
/// before the first sample draws the dash, for the same reason a point at the axis foot is not this
/// repo's way to draw an absent reading.
///
/// ## The gesture's coordinate space is declared here and not on the grip
///
/// `DragGesture(coordinateSpace:)` resolves a *named* space by walking up from the view the gesture is
/// attached to, so the name below is declared on this chart's own frame. A gesture attached without it
/// measures `location.x` from the grip's own row — and since the grips sit below the plot with their own
/// padding, that is a silent visual error rather than a crash: the handles would lag the finger by
/// whatever offset the two disagreed by, and only a look at the screen would say so.
public struct ActivityTimeTrimChartView: View {

    /// The session's readings, or `nil` when it has none. See this type's comment.
    public let series: ActivityHeartRateSeries?

    /// The edit in progress. **Both handles read their position from it and write back through it**, so
    /// this view holds no state of its own and cannot come to disagree with the `DatePicker`s below it
    /// about either end of the window.
    @Binding public var draft: ActivityEditDraft

    public init(series: ActivityHeartRateSeries?, draft: Binding<ActivityEditDraft>) {
        self.series = series
        self._draft = draft
    }

    /// The coordinate space the drag is measured in. See this type's comment.
    private static let plotSpace = "activityTimeTrimPlot"

    /// Room for the two readouts above the plot. Two lines each — the clock time over the heart rate —
    /// so this is taller than a label row.
    private static let readoutHeight: CGFloat = 34

    /// The plot itself. Shorter than the page chart's 210 pt block, which is that page's hero figure:
    /// here the chart is one element of a sheet that also carries the activity row, two date pickers and
    /// the save button, and the trace is context for the handles rather than the subject.
    private static let plotHeight: CGFloat = 120

    /// The row the grips are drawn in.
    private static let handleRowHeight: CGFloat = 26

    /// The visible grip's diameter.
    private static let handleDiameter: CGFloat = 14

    /// The width of a grip's touch target. Wider than the grip, because a 14 pt circle is below the
    /// 44 pt target a finger needs and the two are close together on a short session.
    private static let handleTouchWidth: CGFloat = 44

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 0) {
                readouts(width: width)
                    .frame(height: Self.readoutHeight)
                plot
                    .frame(height: Self.plotHeight)
                handles(width: width)
                    .frame(height: Self.handleRowHeight)
            }
        }
        .frame(height: Self.readoutHeight + Self.plotHeight + Self.handleRowHeight)
        .coordinateSpace(.named(Self.plotSpace))
        // The two `DatePicker`s below this chart are the accessible route to the same two instants, and
        // they are a real one — a control a VoiceOver user can read and set. Labelling the grips as well
        // would offer the same value twice by two routes, one of which cannot be operated without
        // dragging; the page's own chart is hidden for the same reason.
        .accessibilityHidden(true)
    }

    // MARK: - The two readouts

    /// The clock time and the heart rate at each boundary, drawn above the handle that owns it.
    ///
    /// **Each is anchored to its own handle rather than to its own side of the row**, which is the one
    /// layout decision here worth stating: a readout pinned to the frame's left edge would keep naming the
    /// start of the session while the handle above nothing had moved to the middle of it, and the whole
    /// point of the figure is that it names the boundary under it. The start readout grows rightwards from
    /// its handle and the end readout grows leftwards from its, so neither can leave the chart however far
    /// a handle is dragged — which is what an unanchored `.position` would do at either extreme.
    private func readouts(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            readout(at: draft.start, alignment: .leading)
                .frame(width: width, alignment: .leading)
                .offset(x: Self.x(forFraction: draft.startFraction, width: width))
            readout(at: draft.end, alignment: .trailing)
                .frame(width: width, alignment: .trailing)
                .offset(x: Self.x(forFraction: draft.endFraction, width: width) - width)
        }
    }

    private func readout(at instant: Date, alignment: Alignment) -> some View {
        VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 1) {
            Text(instant.formattedHourMinute())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(Self.bpmText(series, at: instant))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(series == nil ? Theme.textMuted : Theme.textSecondary)
        }
        .fixedSize()
    }

    /// The reading in force at a boundary, as the readout prints it, or the dash an unmeasured one draws.
    ///
    /// `nonisolated static` rather than text built in the `body`, on the rule every string in this feature
    /// follows: the runner has no renderer, so a sentence composed inside a `body` is one nothing can
    /// assert. The `—` is not a placeholder for a figure that failed to load — it is the same claim
    /// `ActivityDetailViewModel.stepsText` makes, and the honest answer for every session on this machine.
    public nonisolated static func bpmText(_ series: ActivityHeartRateSeries?, at instant: Date) -> String {
        guard let bpm = series?.bpm(at: instant) else { return "—" }
        return "\(Int(bpm.rounded()))bpm"
    }

    // MARK: - The plot

    /// The trace mapped across the **original** window — see this type's comment.
    private var plotModel: ActivityHeartRatePlot {
        ActivityHeartRatePlot(
            series: series, start: draft.original.startedAt, end: draft.original.endedAt)
    }

    /// The trace, its fill, and the two dashed rules the handles move.
    ///
    /// **Inset by the grip's radius on both sides**, which is what makes a fraction of `0` and a fraction
    /// of `1` land on a grip's *centre* rather than half off the plot: the mapping the shapes use and the
    /// mapping the grips use are then the same one, and a rule drawn at a handle's fraction passes through
    /// that handle's middle. Without the inset the two would agree only in the middle of the row.
    ///
    /// **No gridlines and no y labels**, unlike the page's chart: this plot is the thing being trimmed, and
    /// a scale under a control is furniture. The window's own two ends are ruled by the handles instead,
    /// which is why `BoundsMarkers` is not drawn here — the frame's edges and the markers would coincide
    /// until a handle moved, and then there would be two marks claiming to be the start.
    private var plot: some View {
        ZStack {
            if let series {
                ActivityHeartRatePlot.AreaPath(runs: plotModel.runs, axis: series.axis)
                    .fill(
                        LinearGradient(
                            colors: [Theme.weekLine.opacity(0.35), Theme.weekLine.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom))
                ActivityHeartRatePlot.LinePath(runs: plotModel.runs, axis: series.axis)
                    .stroke(
                        Theme.weekLine,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ActivityHeartRatePlot.DotPath(runs: plotModel.runs, axis: series.axis, radius: 2.5)
                    .fill(Theme.weekLine)
            } else {
                // The page's own sentence, read from the page's own constant rather than restated: the two
                // charts are describing the same absence and a second copy of the words could drift.
                Text(ActivityHeartRateChartView.absenceNote)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }

            // The two boundaries the draft currently holds, drawn the way this repo draws every vertical
            // marker — the same style as the page's `BoundsMarkers` and `TypicalRangeBar`'s band edges.
            TrimRules(startFraction: draft.startFraction, endFraction: draft.endFraction)
                .stroke(
                    Theme.textSecondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .padding(.horizontal, Self.handleDiameter / 2)
    }

    /// The window's two trimmed edges, at the draft's own fractions rather than at the frame's.
    ///
    /// They go through `ActivityHeartRatePlot.Scale.x` so the rule and the trace it crosses are placed by
    /// one mapping: a second copy of the arithmetic here is how a marker ends up a few points off the
    /// handle it belongs to on a wide chart and exactly on it on a narrow one.
    private struct TrimRules: Shape {
        let startFraction: Double
        let endFraction: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for fraction in [startFraction, endFraction] {
                let x = ActivityHeartRatePlot.Scale.x(fraction, in: rect)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }

    // MARK: - The handles

    /// The two grips, each writing to its own end of the draft.
    ///
    /// The drag is attached to the grip rather than to the plot, so a touch anywhere on the grabbable row
    /// moves the handle it is nearest — which is the behaviour a finger expects from a control it can see.
    /// Both write through `ActivityEditDraft`, so the clamp and the minute-write guard are the same code
    /// path the `DatePicker`s take and the two surfaces cannot express different values.
    private func handles(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            grip(fraction: draft.startFraction, width: width, isStart: true)
            grip(fraction: draft.endFraction, width: width, isStart: false)
        }
    }

    private func grip(fraction: Double, width: CGFloat, isStart: Bool) -> some View {
        Circle()
            .fill(Theme.textPrimary)
            .frame(width: Self.handleDiameter, height: Self.handleDiameter)
            .frame(width: Self.handleTouchWidth, height: Self.handleRowHeight)
            .contentShape(Rectangle())
            .position(
                x: Self.x(forFraction: fraction, width: width), y: Self.handleRowHeight / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.plotSpace))
                    .onChanged { value in
                        let moved = Self.fraction(atX: value.location.x, width: width)
                        if isStart {
                            draft.setStart(fraction: moved)
                        } else {
                            draft.setEnd(fraction: moved)
                        }
                    })
    }

    // MARK: - Placement

    /// Where a fraction of the window sits across this chart, in the chart's own coordinates.
    ///
    /// Inset by the grip's radius at both ends so `0` and `1` are the *centres* of the two grips rather
    /// than the chart's corners — the pairing `plot`'s horizontal padding makes with it.
    private static func x(forFraction fraction: Double, width: CGFloat) -> CGFloat {
        let usable = max(0, width - handleDiameter)
        return handleDiameter / 2 + CGFloat(min(1, max(0, fraction))) * usable
    }

    /// The inverse of `x(forFraction:width:)`: a touch's x back to a fraction of the window.
    ///
    /// Clamped rather than refused, because a drag that leaves the chart is an ordinary gesture rather
    /// than an error — a finger sliding off the end of a plot means "all the way to that end", and a
    /// handle that stopped tracking at the edge would look stuck. `ActivityEditDraft` clamps again against
    /// its own bounds, so a fraction of `1` cannot extend a window this sheet is forbidden to extend.
    private static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        let usable = width - handleDiameter
        guard usable > 0 else { return 0 }
        return min(1, max(0, Double((x - handleDiameter / 2) / usable)))
    }
}
