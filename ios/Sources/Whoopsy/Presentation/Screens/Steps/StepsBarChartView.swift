import SwiftUI

/// One window of step counts as bars, with the axis drawn behind them.
///
/// **A gap is drawn as a gap.** A slot with no measurement renders no bar at all rather than a
/// zero-height one, because a zero-height bar and a missing day look identical on a chart whose axis
/// starts at zero — and one of those is a claim that the wearer did not walk. The page's footnote says
/// how many of the window's slots were measured, which is the only thing that distinguishes them.
///
/// The value above each bar is drawn only for a seven-day window: thirty or twenty-six figures across
/// a phone's width is a wall of numbers rather than a reading, and the average above the chart is the
/// figure that window is about.
struct StepsBarChartView: View {
    let trend: StepsTrend

    /// The plot's height, gridlines included.
    private let plotHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                gridlines
                bars
            }
            .frame(height: plotHeight)

            labels
        }
    }

    /// Four interior lines and the top one, labelled with the values they stand for. The ceiling is
    /// `StepsTrend.axisMaximum`, a round number above the tallest bar, so the top line is never the
    /// data's own maximum wearing an axis's clothes.
    private var gridlines: some View {
        GeometryReader { geometry in
            let steps = 4
            ForEach(0...steps, id: \.self) { index in
                let fraction = Double(index) / Double(steps)
                let value = Int(Double(trend.axisMaximum) * fraction)
                let y = geometry.size.height * (1 - fraction)
                HStack(spacing: 6) {
                    Text(Self.axisLabel(value))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                    Rectangle()
                        .fill(Theme.ringTrack)
                        .frame(height: 1)
                }
                .offset(y: y)
            }
        }
    }

    private var bars: some View {
        GeometryReader { geometry in
            let leading: CGFloat = 38
            let available = max(0, geometry.size.width - leading)
            let count = max(1, trend.points.count)
            let slotWidth = available / CGFloat(count)
            let barWidth = max(2, min(18, slotWidth * 0.55))

            HStack(alignment: .bottom, spacing: 0) {
                Color.clear.frame(width: leading, height: 1)
                ForEach(trend.points) { point in
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        if trend.period == .week, let value = point.value {
                            Text(Self.axisLabel(value))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                        if let value = point.value {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.strainRing)
                                .frame(
                                    width: barWidth,
                                    height: height(
                                        for: value, in: geometry.size.height,
                                        topLabelInset: trend.period == .week ? 14 : 0))
                        }
                    }
                    .frame(width: slotWidth, height: geometry.size.height, alignment: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
    }

    private func height(for value: Int, in plot: CGFloat, topLabelInset: CGFloat) -> CGFloat {
        let usable = max(0, plot - topLabelInset)
        let fraction = min(1, Double(value) / Double(max(1, trend.axisMaximum)))
        return max(1, usable * fraction)
    }

    /// The labels under the bars, drawn in the same slots so they line up with their bars.
    private var labels: some View {
        GeometryReader { geometry in
            let leading: CGFloat = 38
            let available = max(0, geometry.size.width - leading)
            let count = max(1, trend.points.count)
            let slotWidth = available / CGFloat(count)
            HStack(spacing: 0) {
                Color.clear.frame(width: leading, height: 1)
                ForEach(trend.points) { point in
                    Text(point.label ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: slotWidth)
                }
            }
        }
        .frame(height: 12)
    }

    /// `12,156` → `12k`. The axis is a scale, not a table; the figure over a bar keeps its digits in
    /// the seven-day view, where there is room for them.
    static func axisLabel(_ value: Int) -> String {
        if value >= 1_000 {
            let thousands = Double(value) / 1_000
            return thousands == thousands.rounded()
                ? "\(Int(thousands))k"
                : String(format: "%.1fk", thousands)
        }
        return "\(value)"
    }
}
