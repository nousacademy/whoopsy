import SwiftUI

/// A fast's nights, drawn as **one column per night with the three quantities stacked inside it**, on
/// a scale this app can defend.
///
/// ## The shape it takes from the reference, and the one it refuses
///
/// The reference draws grouped columns against a shared axis with a legend and a templated sentence
/// beneath. This chart keeps the frame, the date strip and the sentence and refuses its axis: it plots
/// **standard deviations of the user's own baseline window**, not raw ms/bpm/rpm on one frame. Three
/// quantities in three units cannot share a ruler, and the reference's own answer — normalising them
/// onto one — is right; what this app adds is saying *what* they were normalised against, in the
/// caption and by drawing the baseline mean as a labelled rule rather than leaving zero implicit.
///
/// ## One column, three segments, and what "stacked" costs
///
/// The first version of this drawing put the three quantities **side by side** in a group, three thin
/// bars per night. It is now one column per night with the three stacked inside it, which is the
/// user's own instruction — *"a merged chart for all 3, the lower one goes the less it shows on the
/// bar"* — and the consequence is that the axis is no longer fitted to the z-scores but to the
/// **columns**: three half-σ excursions stacked reach one σ up the frame, and an axis that held only
/// half a σ would draw that night off its own top edge. See `FastingRecoveryAxis`.
///
/// Nothing else about the encoding moves. A segment's length is still its own excursion, read against
/// the same labelled scale the individual z-scores were read against, so the merge costs the chart
/// precision of position and buys it legibility of shape — three quantities that used to be three
/// parallel bars to compare across are now one column whose total reads at a glance.
///
/// ## Every segment grows up from the baseline, and a fall shrinks rather than dipping below it
///
/// The chart drew a diverging column for one revision: segments above the rule and segments below it,
/// because a z-score has a sign and half the interesting nights are below the user's own average. That
/// is **not what this draws**, and the change is the user's — *"if they go negative just shrink it
/// essentially"*.
///
/// So a quantity's segment is as long as its excursion **above** the baseline and no longer. One that
/// fell draws nothing at all, because there is no length below zero to draw: as a reading falls toward
/// its baseline its segment shrinks, and at the baseline it is gone. That is *the lower one goes the
/// less it shows on the bar* taken literally, and it is why `FastingRecoveryAxis` has a floor and no
/// lower bound.
///
/// **The cost is real and is recorded rather than hidden.** A night whose three readings all fell
/// draws an *empty column* — a labelled slot with no bar in it — and on this screen an empty slot is
/// otherwise the picture of a night nothing measured. Two things keep that from being a lie. The
/// column carries its date, so it is visibly a night that was read; and the **sentence under the chart
/// is composed from the same z-scores and names the direction of every quantity**, so a night that
/// fell reads `HRV fell below your baseline` directly beneath its own empty column. The drawing stopped
/// being the place a fall is visible, and the sentence is where it went — which is why the two are
/// built off one series rather than assembled separately.
///
/// ## No minimum segment height
///
/// `RestorativeSleepChartView` and its two siblings floor a drawn column at a few points so a night
/// with a little restorative sleep is a visible stub rather than nothing. **That floor is wrong here
/// and is deliberately absent**: on this chart a segment's length *is* its value, so a `2` pt floor on
/// a segment whose true extent is `0.4` pt would state a night as five times further from its baseline
/// than it was. And with the direction gone from the drawing a floor would be worse than imprecise —
/// it would draw a stub for a quantity that is *below* its baseline, which is the one thing this
/// encoding refuses to draw.
///
/// ## The legend lists only what is drawn, and it sits below the columns
///
/// Its entries come from `series.metrics` rather than from `FastingMetric.allCases`, so a fast whose
/// window carried no respiratory readings does not get a key to a segment that appears nowhere. It is
/// drawn **under** the date strip rather than above the plot — the user's own *"on the lower
/// horizontal bar, put hrv, rhr, rr"* — which puts the key next to the thing it explains and leaves
/// the top of the card to the drawing.
///
/// The stacking order is the legend's order read **from the top of the column down**: the first
/// quantity listed is the one stacked furthest from the baseline, so a column reads top-to-bottom in
/// the same order as the legend reads left-to-right. Without that a reader has the colours to go on
/// and nothing else, since three segments inside one column cannot be told apart by position the way
/// three bars side by side could.
///
/// That order is now the **column's** rather than each side's, which is a simplification the shrink
/// bought: with nothing drawn below the baseline there is only one stack, so the first-listed quantity
/// takes the far end on every night rather than only on the nights it happened to rise.
///
/// `series` is never `nil` here: the page decides between this view and an absence line, so the view
/// is never asked to draw a fast with nothing to plot.
public struct FastingRecoveryChartView: View {

    public let series: FastingRecoveryChartSeries

    public init(series: FastingRecoveryChartSeries) {
        self.series = series
    }

    // MARK: - Geometry

    // `nonisolated` on all of these, for the reason `FastingZonePill`'s five carry: `View` is
    // `@MainActor`-isolated, so a plain `static` here is reachable only from the main actor — and the
    // runner is a `main.swift` whose assertions do not run on it. These are arithmetic, and arithmetic
    // only a `body` can reach is arithmetic nothing can assert.

    /// The height of the bar area, excluding the date strip and the legend.
    ///
    /// Taller than the week charts' `104`. Those charts plot one quantity per column and their bars
    /// stand on an axis foot; this one stacks up to three segments above a baseline, and an ordinary
    /// night spends part of that height in each of them — at `104` a column reaching `1σ` of a `4σ`
    /// scale would be five points of segment per quantity.
    public nonisolated static let barAreaHeight: CGFloat = 132

    /// The strip the legend is drawn in, below the columns.
    public nonisolated static let legendHeight: CGFloat = 30

    /// The two stacked date lines' own line boxes — `10` pt semibold is `12`, `11` pt bold is `14`.
    ///
    /// **This is the number the strip was missing.** The label is a `VStack` of two fixed-size `Text`s
    /// centred in the strip, so the strip has to be at least this tall or the block spills out of both
    /// ends at once: the weekday's ascenders are pushed up **through the baseline rule** the columns
    /// stand on, and the day number is pushed down into the legend. It was `18` against this `26`, so
    /// eight points of overflow was drawn on every fast's page — the labels sitting on the rule rather
    /// than under it — and nothing in this repo could see it, because the overflow is a `body`'s
    /// arrangement and the runner has no renderer.
    public nonisolated static let dateLabelTextHeight: CGFloat = 26

    /// The air between the baseline rule and the weekday under it.
    ///
    /// Not part of the line box: it is the gap that makes the strip read as *below* the rule rather
    /// than on it, and it is what keeps the lowest tick label — which hangs half its own height out of
    /// the plot by design, see `axisLabelY` — from meeting the weekday text beside it.
    public nonisolated static let dateStripInset: CGFloat = 6

    /// The strip the date labels sit in, below the columns.
    ///
    /// Derived from what it holds rather than picked, which is the whole of the fix: the two lines plus
    /// the air above them. `WeekChartAxis.dateLabelHeight` is the same strip on the three week charts,
    /// at `28` for the same two lines in `10` pt; this one draws its number a point larger, so it needs
    /// the extra pair of points.
    public nonisolated static var dateLabelHeight: CGFloat {
        dateStripInset + dateLabelTextHeight
    }

    /// Where the date label's own centre goes — **the line box's midpoint, offset by the inset**.
    ///
    /// `.position` centres the view it is applied to, so the strip's own midpoint is the wrong answer
    /// whenever the inset is not zero: it would split the air evenly above and below the label, which
    /// puts half of it back on the baseline rule and is the defect this file was carrying.
    public nonisolated static var dateLabelCentreY: CGFloat {
        dateStripInset + dateLabelTextHeight / 2
    }

    /// The strip the tick labels sit in, one per gridline, down the plot's right margin.
    public nonisolated static let axisLabelWidth: CGFloat = 34

    /// How much of a night's slot the merged column occupies. The rest is the gap between nights.
    ///
    /// Wider than the grouped chart's `0.72` per bar and narrower than it per group, because one
    /// column has to carry what three did: `0.52` of a slot leaves a clear channel between nights on a
    /// chart of four, which is the most this page ever draws.
    public nonisolated static let columnWidthFraction: CGFloat = 0.52

    /// The widest a column is allowed to become, in points.
    ///
    /// A cap rather than a fraction alone, because the slot width is `plotWidth / nightCount` and the
    /// count can be **one**: a single-night fast would otherwise draw a 170 pt slab for a column whose
    /// whole point is that its height is read against the scale down the right margin. Capping it
    /// keeps a one-night column the same shape as a four-night one.
    public nonisolated static let maximumColumnWidth: CGFloat = 46

    /// How round the top of a stack is. Square at the baseline, so a column is visibly measured *from*
    /// the rule rather than floating above it.
    public nonisolated static let segmentCornerRadius: CGFloat = 2

    public nonisolated static var plotHeight: CGFloat {
        barAreaHeight + dateLabelHeight
    }

    /// Where a tick's label sits vertically — **exactly on the line it names**.
    ///
    /// The same expression the gridline's own `Rectangle` is positioned by, deliberately, and with no
    /// clamp. The obvious clamp is at the floor, since the baseline **is** the lowest line and the
    /// frame's bottom edge — so the lowest label centres on the bar area's last pixel and hangs about
    /// half its own height into the date strip below. **It is not clamped, and that is the decision**:
    /// nudging it up to sit inside the frame moves it off its own line, and a scale whose figures
    /// drift off the lines they label is worse than one whose last figure overhangs. Nothing is
    /// overlapped either way — the date strip is `plotWidth` wide and this column is outside it.
    public nonisolated static func axisLabelY(value: Double, axis: FastingRecoveryAxis) -> CGFloat {
        barAreaHeight * CGFloat(1 - axis.fraction(value))
    }

    /// One column's width inside a slot of `slotWidth`.
    public nonisolated static func columnWidth(slotWidth: CGFloat) -> CGFloat {
        min(maximumColumnWidth, max(1, slotWidth * columnWidthFraction))
    }

    /// One segment's height, in points — **its own excursion above the baseline, against the shared
    /// axis**.
    ///
    /// A plain fraction of the frame, because the axis' `0` *is* the baseline and its floor is the
    /// frame's foot — so the distance from the baseline is the value's own fraction and there is no
    /// second fraction to subtract. The `max(0, …)` is the shrink the user asked for, expressed once:
    /// a reading at or below its baseline has no length on this drawing, and folding it in here rather
    /// than at the drawing means a negative z cannot reach the layout by any route.
    ///
    /// The fraction is linear in the value, so these heights **add up**: the segments of one column sum
    /// to exactly the height of a single segment drawn at their total. That identity is what lets the
    /// stack be laid out by accumulating heights rather than by re-deriving a fraction per boundary,
    /// and §19 asserts it.
    public nonisolated static func segmentHeight(
        zScore: Double, axis: FastingRecoveryAxis
    ) -> CGFloat {
        CGFloat(axis.fraction(max(0, zScore))) * barAreaHeight
    }

    /// One quantity's piece of a night's column, resolved into the rectangle it draws.
    ///
    /// A value rather than a `body` for this file's standing reason: the runner has no renderer, so a
    /// layout written inside a view is a layout nothing can assert. Everything the drawing needs is
    /// here — the distance of the segment's foot from the baseline, its height, and whether it is the
    /// one whose far end is rounded.
    public struct Segment: Equatable, Sendable {
        public let metric: FastingMetric

        /// The z-score the segment was built from, always strictly positive here: a reading at or
        /// below its baseline draws nothing, so no such segment exists to carry a negative one.
        public let zScore: Double

        /// The segment's own length, in points.
        public let height: CGFloat

        /// How far the segment's **foot** sits above the baseline, in points. The segment standing on
        /// the baseline is at `0`.
        public let offsetFromFloor: CGFloat

        /// The segment at the top of the column — the only one whose end away from the baseline is
        /// rounded. Every boundary inside the column is flush, so the stack reads as one column rather
        /// than as a run of separate chips.
        public var isTopmost: Bool
    }

    /// The segments one night draws, returned in `metrics` order — the legend's order.
    ///
    /// A quantity with no z-score, a non-finite one, or one at or below the baseline contributes
    /// nothing. The first two have no reading to draw; the third is the shrink: an excursion below the
    /// baseline has no length on a scale whose foot *is* the baseline, and one exactly on it has an
    /// excursion of zero — a segment of no height rather than a segment of some minimum.
    ///
    /// Offsets accumulate **from the top down**, which is what makes the *first* quantity listed the
    /// topmost one, so a column reads top-to-bottom in the legend's own order. There is one stack
    /// rather than one per side, because nothing is drawn below the baseline.
    ///
    /// Returned in `metrics` order rather than accumulation order, so a caller — the drawing, or a
    /// fixture in the runner — can zip the segments against the legend's entries positionally.
    public nonisolated static func segments(
        for point: FastingRecoveryChartSeries.Point,
        metrics: [FastingMetric],
        axis: FastingRecoveryAxis
    ) -> [Segment] {
        let drawn: [(metric: FastingMetric, zScore: Double)] = metrics.compactMap { metric in
            guard let zScore = point.zScores[metric], zScore.isFinite, zScore > 0 else { return nil }
            return (metric, zScore)
        }
        guard !drawn.isEmpty else { return [] }

        // The top of the column, which is the **first** quantity listed — see above, where the offsets
        // are accumulated from the top down. Read off `drawn` rather than off the accumulation loop so
        // the two cannot come to disagree about which segment is rounded.
        let topmost = drawn.first?.metric

        var offset: CGFloat = 0
        var layout: [FastingMetric: (height: CGFloat, offset: CGFloat)] = [:]

        for entry in drawn.reversed() {
            let height = segmentHeight(zScore: entry.zScore, axis: axis)
            layout[entry.metric] = (height, offset)
            offset += height
        }

        return drawn.compactMap { entry in
            guard let placed = layout[entry.metric] else { return nil }
            return Segment(
                metric: entry.metric,
                zScore: entry.zScore,
                height: placed.height,
                offsetFromFloor: placed.offset,
                isTopmost: entry.metric == topmost)
        }
    }

    /// Where a segment's own centre sits, given that `.position` centres the view it is applied to.
    ///
    /// Measured **down from the baseline**, since every segment is above it.
    public nonisolated static func segmentCentreY(_ segment: Segment, floorY: CGFloat) -> CGFloat {
        floorY - segment.offsetFromFloor - segment.height / 2
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            VStack(spacing: 0) {
                plot(width: width)
                dateLabels(width: width)
                legend
            }
        }
        .frame(height: Self.plotHeight + Self.legendHeight)
        // A `Path` and a `Rectangle` have nothing to say to VoiceOver, so the page carries the chart
        // in words instead — `FastingRecoveryChartSeries.spokenSentence`.
        .accessibilityHidden(true)
    }

    // MARK: - The plot

    private func plot(width: CGFloat) -> some View {
        let axis = series.axis
        let plotWidth = max(1, width - Self.axisLabelWidth)
        let slotWidth = plotWidth / CGFloat(max(1, series.points.count))
        let barWidth = Self.columnWidth(slotWidth: slotWidth)
        // The baseline, which `FastingRecoveryAxis.fraction` puts at `0` — so this is the frame's own
        // bottom edge, and every column stands on it.
        let floorY = Self.barAreaHeight * CGFloat(1 - axis.fraction(FastingRecoveryAxis.baselineLine))

        return ZStack(alignment: .topLeading) {
            // The gridlines first, then the rule over them. `FastingRecoveryAxis.gridLines` excludes
            // the baseline, so these two never draw on the same pixel.
            ForEach(axis.gridLines, id: \.self) { value in
                Rectangle()
                    .fill(Theme.ringTrack)
                    .frame(width: plotWidth, height: 1)
                    .position(x: plotWidth / 2, y: Self.barAreaHeight * CGFloat(1 - axis.fraction(value)))
            }

            Rectangle()
                .fill(Theme.textMuted)
                .frame(width: plotWidth, height: 1)
                .position(x: plotWidth / 2, y: floorY)

            ForEach(Array(series.points.enumerated()), id: \.element.id) { index, point in
                let centreX = (CGFloat(index) + 0.5) * slotWidth

                ForEach(
                    Self.segments(for: point, metrics: series.metrics, axis: axis), id: \.metric
                ) { segment in
                    segmentShape(segment)
                        .frame(width: barWidth, height: segment.height)
                        .position(
                            x: centreX, y: Self.segmentCentreY(segment, floorY: floorY))
                }
            }

            // **Every line carries its own value, down the right margin.** The two corner labels this
            // replaces named the frame's *bounds* — `+4σ` and `-4σ` — which is the pair a reader has no
            // use for: nobody's night sits four of their own deviations from their own mean, and `±4`
            // is only where this app's clamp stops. The lines between them, which are what a segment is
            // actually read against, were unlabelled. So the margin now reads as the scale it is.
            //
            // The baseline is among them, and it is the one figure in the run that is below every other
            // — so the column a reader counts down ends at the line the columns stand on. There is no
            // word for it in the plot: the caption above the chart names the baseline in full, and a
            // label drawn across the frame's foot would sit on the foot of the middle column.
            ForEach(axis.gridLines + [FastingRecoveryAxis.baselineLine], id: \.self) { value in
                Text(Self.tickLabel(value))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .fixedSize()
                    .position(
                        x: plotWidth + Self.axisLabelWidth / 2,
                        y: Self.axisLabelY(value: value, axis: axis))
            }
        }
        .frame(width: plotWidth, height: Self.barAreaHeight, alignment: .topLeading)
    }

    /// One segment: a square foot at the baseline and a rounded top at the top of the stack.
    ///
    /// `UnevenRoundedRectangle` rather than a clip, since the two ends genuinely differ — and only the
    /// topmost segment is rounded, so the boundaries *inside* a column are flush and the column reads
    /// as one bar divided rather than as a run of chips.
    private func segmentShape(_ segment: Segment) -> some View {
        let radius = segment.isTopmost ? Self.segmentCornerRadius : 0

        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: radius),
            style: .continuous)
            .fill(segment.metric.color)
    }

    // MARK: - The date strip

    private func dateLabels(width: CGFloat) -> some View {
        let plotWidth = max(1, width - Self.axisLabelWidth)
        let slotWidth = plotWidth / CGFloat(max(1, series.points.count))

        return ZStack(alignment: .topLeading) {
            ForEach(Array(series.points.enumerated()), id: \.element.id) { index, point in
                VStack(spacing: 0) {
                    Text(point.date.formattedWeekdayAbbreviation())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(point.date.formattedDayOfMonth())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .position(x: (CGFloat(index) + 0.5) * slotWidth, y: Self.dateLabelCentreY)
            }
        }
        .frame(width: plotWidth, height: Self.dateLabelHeight, alignment: .topLeading)
    }

    // MARK: - The legend

    /// The key to the colours, under the columns rather than over them — the user's own *"on the
    /// lower horizontal bar, put hrv, rhr, rr"*.
    ///
    /// The swatch is the **segment** that carries the name, so it is drawn in the same shape the chart
    /// draws it: a small rounded rectangle in `metric.color`, read through the one metric-to-`Color`
    /// mapping both this and the plot use.
    ///
    /// Ten points and not eleven: the three names laid end to end — `HRV (RMSSD)`, `RHR`,
    /// `RESPIRATORY RATE` — are the widest run of text on this card, and at eleven they and their
    /// swatches come within a few points of the gutter on a narrow phone. The size is a fit rather than
    /// a preference, and the longest name is the one to measure.
    private var legend: some View {
        HStack(spacing: 0) {
            ForEach(series.metrics, id: \.self) { metric in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(metric.color)
                        .frame(width: 10, height: 10)

                    Text(metric.legendLabel(hrvMetric: series.hrvMetric))
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.legendHeight)
    }

    // MARK: - The chart's own strings

    /// `"+2σ"` from a line's value, and a bare `"0"` for the baseline.
    ///
    /// The unit is spelled out once, in the caption above the chart, so a tick carries the naked figure
    /// and the glyph — a `+2 σ` on every line and a sentence above them is the same word nine times on
    /// one drawing.
    ///
    /// **Zero is the one line that gets no sign and no glyph**, and it is not a special case for its
    /// own sake: `+0σ` and `−0σ` are both wrong about a line that is neither above nor below. It is the
    /// scale's floor rather than its middle — every column stands on it — and a bare figure is what a
    /// reader expects at the foot of a scale.
    ///
    /// **`+` is the only sign this function can produce**, because the axis it labels has no lower
    /// bound: every line above `0` is a height above the baseline, and a `−` branch would be a label
    /// for a line the drawing cannot reach. A value between two lines keeps its decimal rather than
    /// being rounded onto one it is not.
    public nonisolated static func tickLabel(_ bound: Double) -> String {
        guard bound != 0 else { return "0" }
        let magnitude = abs(bound)
        let figure = magnitude == magnitude.rounded()
            ? String(Int(magnitude))
            : magnitude.formattedOneDecimal()
        return "+" + figure + "σ"
    }
}
