import SwiftUI

/// A reading's trend line, with its typical-range band and the latest reading marked.
///
/// **A gap breaks the line.** A day with no measured reading is not a zero and is not interpolated
/// across: either would draw a reading this app never took, and a straight segment through a missing
/// week is the strongest possible claim that nothing happened in it.
///
/// The axis is `HRVTrend`'s — five ticks covering the readings **and** the band, so the band is never
/// clipped off the plot it is meant to be read against.
struct ReadingTrendChartView: View {
    let trend: ReadingTrend

    private let leading: CGFloat = 34
    private let bottom: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let plotWidth = max(0, geometry.size.width - leading)
            let plotHeight = max(0, geometry.size.height - bottom)

            ZStack(alignment: .topLeading) {
                gridlines(width: plotWidth, height: plotHeight)
                band(width: plotWidth, height: plotHeight)
                line(width: plotWidth, height: plotHeight)
                lastPoint(width: plotWidth, height: plotHeight)
                xLabels(width: plotWidth, height: plotHeight)
            }
        }
        .frame(height: 260)
    }

    private func y(_ value: Double, in height: CGFloat) -> CGFloat {
        let span = Double(max(1, trend.axisMaximum - trend.axisMinimum))
        let fraction = (value - Double(trend.axisMinimum)) / span
        return height * (1 - CGFloat(min(max(fraction, 0), 1)))
    }

    private func x(_ index: Int, in width: CGFloat) -> CGFloat {
        guard trend.points.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(trend.points.count - 1)
    }

    private func gridlines(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(trend.axisTicks.enumerated()), id: \.offset) { _, tick in
            let y = y(Double(tick), in: height)
            HStack(spacing: 6) {
                Text("\(tick)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .frame(width: leading - 6, alignment: .trailing)
                Rectangle()
                    .fill(Theme.ringTrack)
                    .frame(height: 1)
            }
            .offset(y: y)
        }
    }

    private func band(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let range = trend.typicalRange {
                let top = y(range.upperBound, in: height)
                let bottomY = y(range.lowerBound, in: height)
                Rectangle()
                    .fill(Theme.ringTrack.opacity(0.55))
                    .frame(width: width, height: max(2, bottomY - top))
                    .offset(x: leading, y: top)
            }
        }
    }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            var previous: CGPoint?
            for (index, point) in trend.points.enumerated() {
                guard let value = point.value else {
                    // A gap ends the run; the next measured day starts a new segment rather than
                    // connecting across the absence.
                    previous = nil
                    continue
                }
                let current = CGPoint(x: x(index, in: width), y: y(value, in: height))
                if let previous {
                    path.move(to: previous)
                    path.addLine(to: current)
                }
                previous = current
            }
        }
        .stroke(Theme.weekLine, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .offset(x: leading)
    }

    private func lastPoint(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let index = trend.points.lastIndex(where: { $0.value != nil }),
               let value = trend.points[index].value
            {
                let point = CGPoint(x: x(index, in: width), y: y(value, in: height))
                ZStack(alignment: .top) {
                    Circle()
                        .fill(Theme.backgroundDark)
                        .overlay(Circle().stroke(Theme.weekLine, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(x: point.x, y: point.y)
                    Text("\(Int(value.rounded()))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                        .position(x: max(14, point.x), y: max(8, point.y - 14))
                }
            }
        }
        .offset(x: leading)
    }

    private func xLabels(width: CGFloat, height: CGFloat) -> some View {
        ForEach(trend.labelIndices, id: \.self) { index in
            Text(
                trend.points[index].date.formatted(
                    .dateTime.month(.abbreviated).day())
            )
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 44)
            .position(
                x: min(
                    width - 22 + leading,
                    max(leading + 22, x(index, in: width) + leading)),
                y: height + bottom / 2)
        }
    }
}
