import SwiftUI

/// A week of strain and recovery, drawn as two series on two axes.
///
/// Hand-rolled `Shape`s and a `GeometryReader`, like `StressMonitorChartView` and
/// `HypnogramChartView`. Nothing in this project uses Swift Charts and this is not the place to start.
///
/// ## Two series, two scales, seven calendar days
///
/// Strain is 0–21 and recovery is 0–100%, so each series is positioned by its own axis — plotting both
/// against one scale would either squash recovery into the bottom fifth or draw strain five times too
/// tall. The two axes are labelled on the left and right respectively, and their tick values are
/// **thirds of their own range** (0/7/14/21 and 0/33/66/100) so that a single set of gridlines is
/// honest for both. That is why those numbers, and not rounder ones, are on the reference.
///
/// ## The x axis is the week, not the data
///
/// One column per `MetricWeek` slot, always seven, whether or not a slot holds anything. A day with no
/// measurement is an empty column that still carries its own date label — never a missing column,
/// which would slide every later point one day to the left and relabel it. The line **breaks** at such
/// a slot rather than joining across it, because a segment drawn between two measured days spans days
/// nobody measured, and it would be read as a value for them.
///
/// With nothing measured in the whole week the chart draws **nothing**: no frame, no axes. An empty
/// seven-column grid reads as a week of zeros. The caller's caption carries that absence in words.
public struct StrainRecoveryChartView: View {
    /// The week to plot — its slots are the columns, in order.
    public let week: MetricWeek

    /// The day whose two values are labelled, if it is one of the week's slots.
    public let selectedDate: Date

    public init(week: MetricWeek, selectedDate: Date) {
        self.week = week
        self.selectedDate = selectedDate
    }

    /// The plot's height, excluding the two-line date labels beneath it.
    private static let plotHeight: CGFloat = 136
    private static let labelHeight: CGFloat = 24

    /// Gutters for the two axes. The right one is wider because its labels carry a percent sign.
    private static let leftGutter: CGFloat = 20
    private static let rightGutter: CGFloat = 32

    /// The strain scale's top. The entity clamps to it and documents the range as 0.0–21.0; there is
    /// no exported constant, so it is named here rather than repeated as a literal in four places.
    private static let strainCeiling = 21.0

    /// The recovery scale's top, which is the score's own definition rather than a choice.
    private static let recoveryCeiling = 100.0

    public var body: some View {
        if hasAnySeries {
            GeometryReader { proxy in
                let plotWidth = max(1, proxy.size.width - Self.leftGutter - Self.rightGutter)
                let plotHeight = max(1, proxy.size.height - Self.labelHeight)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        axisColumn(Self.strainTicks, height: plotHeight, width: Self.leftGutter)
                        plot(width: plotWidth, height: plotHeight)
                        axisColumn(Self.recoveryTicks, height: plotHeight, width: Self.rightGutter)
                    }
                    dateLabels(width: plotWidth, leading: Self.leftGutter)
                }
            }
            .frame(height: Self.plotHeight)
            // The tile above speaks both of the highlighted day's figures as text, and a `Path` has
            // nothing to say to VoiceOver — announcing seven columns of shapes would only add noise
            // ahead of the numbers. Same reasoning as `StressMonitorChartView`.
            .accessibilityHidden(true)
        }
    }

    /// Whether either series has a point at all. Both empty means no chart — see the type's comment.
    private var hasAnySeries: Bool {
        week.days.contains { $0.strain != nil || $0.recoveryScore != nil }
    }

    // MARK: - The plot

    private func plot(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // The scale's ends, drawn dimmer than the interior ticks, which are the ones a reader
            // measures against.
            Gridlines(fractions: [0, 1])
                .stroke(Theme.ringTrack.opacity(0.5), lineWidth: 1)
            Gridlines(fractions: [Self.third, Self.twoThirds])
                .stroke(Theme.ringTrack, lineWidth: 1)

            if let selectedSlot {
                HighlightColumn(slot: selectedSlot)
                    .fill(Theme.ringTrack.opacity(0.35))
            }

            // Recovery's line is neutral and its points carry the tier colour, which is the
            // reference's own division: one line cannot be three colours, and the tier is the thing
            // worth showing.
            LinePath(runs: recoveryRuns, ceiling: Self.recoveryCeiling)
                .stroke(
                    Theme.textSecondary,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            LinePath(runs: strainRuns, ceiling: Self.strainCeiling)
                .stroke(
                    Theme.strainRing,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            dots(width: width, height: height)
            selectedLabels(width: width, height: height)
        }
        .frame(width: width, height: height)
    }

    /// One column's centre, as a fraction of the plot's width.
    ///
    /// Half a column in, so a point sits in the middle of the day it describes rather than on the
    /// boundary between two.
    static func columnFraction(_ slot: Int) -> Double {
        (Double(slot) + 0.5) / Double(MetricWeek.dayCount)
    }

    /// Where a value sits vertically, as a fraction from the bottom of the plot.
    private static func heightFraction(_ value: Double, ceiling: Double) -> Double {
        min(max(value / ceiling, 0), 1)
    }

    /// The seven columns' dots, each positioned by its own series' axis and coloured by its own rule.
    ///
    /// Built as views rather than as a `Shape` because the colour is per point — a recovery dot is its
    /// day's tier — and a single `Shape` holds one fill. The strain dots are hollow so the line they
    /// sit on stays visible through them.
    private func dots(width: CGFloat, height: CGFloat) -> some View {
        ForEach(week.days.indices, id: \.self) { slot in
            let day = week.days[slot]
            ZStack {
                if let score = day.recoveryScore {
                    Circle()
                        .fill(RecoveryMetric.RecoveryState(score: score).color)
                        .frame(width: 8, height: 8)
                        .position(
                            x: Self.columnFraction(slot) * width,
                            y: y(for: Self.heightFraction(Double(score), ceiling: Self.recoveryCeiling), height: height))
                }
                if let strain = day.strain {
                    Circle()
                        .fill(Theme.homeCard)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Theme.strainRing, lineWidth: 2))
                        .position(
                            x: Self.columnFraction(slot) * width,
                            y: y(for: Self.heightFraction(strain, ceiling: Self.strainCeiling), height: height))
                }
            }
        }
    }

    /// The selected day's two figures, and only that day's — six other columns carrying six other
    /// pairs of numbers is a table, not a chart, and the reference labels one day for the same reason.
    ///
    /// Each label is nudged to the side of its dot rather than above it: a value printed over the
    /// point it describes hides the point.
    private func selectedLabels(width: CGFloat, height: CGFloat) -> some View {
        ForEach(week.days.indices, id: \.self) { slot in
            let day = week.days[slot]
            if let selectedSlot, slot == selectedSlot {
                ZStack {
                    if let strain = day.strain {
                        valueLabel(String(format: "%.1f", strain), color: Theme.strainRing)
                            .position(
                                x: Self.columnFraction(slot) * width,
                                y: y(for: Self.heightFraction(strain, ceiling: Self.strainCeiling), height: height) - 14)
                    }
                    if let score = day.recoveryScore {
                        valueLabel("\(score)%", color: RecoveryMetric.RecoveryState(score: score).color)
                            .position(
                                x: Self.columnFraction(slot) * width,
                                y: y(for: Self.heightFraction(Double(score), ceiling: Self.recoveryCeiling), height: height) + 14)
                    }
                }
            }
        }
    }

    private func valueLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.homeCard.opacity(0.85))
            .clipShape(Capsule())
            .fixedSize()
    }

    /// The slot the selected day occupies, or nil when it is not in this week.
    private var selectedSlot: Int? {
        let key = selectedDate.startOfDay
        return week.days.firstIndex { $0.date == key }
    }

    /// Screen y for a height fraction. Held off both edges so the top and bottom labels and dots are
    /// not half-cut by the frame.
    private func y(for fraction: Double, height: CGFloat) -> CGFloat {
        let inset: CGFloat = 6
        let usable = max(1, height - inset * 2)
        return inset + CGFloat(1 - fraction) * usable
    }

    // MARK: - The series

    /// A measured point, in the week's own terms: which column it belongs to and its raw value.
    ///
    /// Data terms because a `Shape` must lay itself out in whatever rect it is handed — the same split
    /// `StressMonitorChartView` makes, and what keeps the geometry right when the tile's width changes.
    struct SeriesPoint {
        let slot: Int
        let value: Double
    }

    /// The strain series, in runs of consecutive measured days.
    ///
    /// A run ends at a slot with no strain. That slot is unmeasured, and a line drawn across it would
    /// be a reading nobody took — the same rule the stress chart applies to its ineligible windows.
    private var strainRuns: [[SeriesPoint]] {
        Self.runs(week.days.map { $0.strain.map { SeriesPoint(slot: 0, value: $0) } })
    }

    private var recoveryRuns: [[SeriesPoint]] {
        Self.runs(week.days.map { $0.recoveryScore.map { SeriesPoint(slot: 0, value: Double($0)) } })
    }

    /// Splits a slot-by-slot series into consecutive measured runs, numbering each point by its slot.
    ///
    /// The slot index is assigned here from the position in the array rather than carried in, so a
    /// point's column can only ever be the column it came from.
    private static func runs(_ series: [SeriesPoint?]) -> [[SeriesPoint]] {
        var runs: [[SeriesPoint]] = []
        var current: [SeriesPoint] = []
        for (slot, point) in series.enumerated() {
            guard let point else {
                if !current.isEmpty { runs.append(current) }
                current = []
                continue
            }
            current.append(SeriesPoint(slot: slot, value: point.value))
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// One third, the left axis' `7/21` and the right's `33/100` to within a percent. The two are
    /// drawn on the same line deliberately: the reference's tick values were chosen to make that true,
    /// and a reader comparing the series is comparing them at those shared heights.
    private static let third = 1.0 / 3.0
    private static let twoThirds = 2.0 / 3.0

    // MARK: - Axis labels

    private struct AxisTick {
        let text: String
        let color: Color
        let fraction: Double
    }

    private static let strainTicks: [AxisTick] = [
        AxisTick(text: "21", color: Theme.textMuted, fraction: 1),
        AxisTick(text: "14", color: Theme.textMuted, fraction: twoThirds),
        AxisTick(text: "7", color: Theme.textMuted, fraction: third),
        AxisTick(text: "0", color: Theme.textMuted, fraction: 0),
    ]

    /// Coloured by tier, which is not decoration: it is the same mapping the recovery dots and the
    /// Home ring use, read from `RecoveryState.color`, so the axis cannot band the scale somewhere
    /// `RecoveryState.init(score:)` does not.
    private static let recoveryTicks: [AxisTick] = [
        AxisTick(text: "100%", color: RecoveryMetric.RecoveryState(score: 100).color, fraction: 1),
        AxisTick(text: "66%", color: RecoveryMetric.RecoveryState(score: 66).color, fraction: twoThirds),
        AxisTick(text: "33%", color: RecoveryMetric.RecoveryState(score: 33).color, fraction: third),
        AxisTick(text: "0%", color: RecoveryMetric.RecoveryState(score: 0).color, fraction: 0),
    ]

    /// One axis' labels, positioned at the fractions their values sit at.
    private func axisColumn(_ ticks: [AxisTick], height: CGFloat, width: CGFloat) -> some View {
        ZStack {
            ForEach(ticks.indices, id: \.self) { index in
                let tick = ticks[index]
                Text(tick.text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tick.color)
                    .fixedSize()
                    .position(x: width / 2, y: y(for: tick.fraction, height: height))
            }
        }
        .frame(width: width, height: height)
    }

    /// The weekday and day-of-month under each column — the date a point belongs to, which the
    /// column's position alone cannot state.
    private func dateLabels(width: CGFloat, leading: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leading, height: Self.labelHeight)
            ZStack {
                ForEach(week.days.indices, id: \.self) { slot in
                    let day = week.days[slot]
                    VStack(spacing: 0) {
                        Text(day.date.formattedWeekdayAbbreviation())
                        Text(day.date.formattedDayOfMonth())
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
                    .position(
                        x: Self.columnFraction(slot) * width,
                        y: Self.labelHeight / 2)
                }
            }
            .frame(width: width, height: Self.labelHeight)
            Color.clear.frame(width: Self.rightGutter, height: Self.labelHeight)
        }
    }

    // MARK: - Shapes

    /// The mapping every shape below shares: a column and a height fraction in, screen points out.
    ///
    /// A height fraction rather than a value, so both series share one mapping: each has already
    /// divided by its own ceiling by the time a shape sees it, and neither can be drawn on the
    /// other's scale.
    private enum Scale {
        static func x(_ slot: Int, in rect: CGRect) -> CGFloat {
            rect.minX + CGFloat(StrainRecoveryChartView.columnFraction(slot)) * rect.width
        }

        static func y(_ fraction: Double, in rect: CGRect) -> CGFloat {
            rect.maxY - CGFloat(fraction) * rect.height
        }
    }

    /// A series drawn as a line through each run's points.
    ///
    /// Runs of one point are skipped — a lone measured day has no segment to draw, and inventing one
    /// by reaching for a neighbour would span days that were not measured. Its dot is drawn by the
    /// caller, so the reading is not lost.
    private struct LinePath: Shape {
        let runs: [[SeriesPoint]]
        let ceiling: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for run in runs where run.count > 1 {
                guard let first = run.first else { continue }
                path.move(to: point(first, in: rect))
                for item in run.dropFirst() { path.addLine(to: point(item, in: rect)) }
            }
            return path
        }

        private func point(_ item: SeriesPoint, in rect: CGRect) -> CGPoint {
            CGPoint(
                x: Scale.x(item.slot, in: rect),
                y: Scale.y(min(max(item.value / ceiling, 0), 1), in: rect))
        }
    }

    private struct Gridlines: Shape {
        let fractions: [Double]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for fraction in fractions {
                let y = Scale.y(fraction, in: rect)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }

    /// The band behind the highlighted column, so its two labels are anchored to a visible column
    /// rather than floating between two.
    private struct HighlightColumn: Shape {
        let slot: Int

        func path(in rect: CGRect) -> Path {
            let width = rect.width / CGFloat(MetricWeek.dayCount)
            let x = rect.minX + CGFloat(slot) * width
            return Path(
                roundedRect: CGRect(x: x, y: rect.minY, width: width, height: rect.height),
                cornerRadius: 6)
        }
    }
}
