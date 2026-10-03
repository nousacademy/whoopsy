import Foundation

/// A y-axis fitted to the values it will draw, with its bounds and gridlines snapped to round
/// numbers.
///
/// ## Why this chart is the only one in the app with a fitted axis
///
/// Every other chart here fixes its scale, and each has a definition to fix it to: recovery is a
/// percentage, strain is 0–21 by the model's own range, stress is 0–3 by its bands. The rule those
/// charts follow — never auto-scale, because an auto-scaled axis draws a bad week and a good week as
/// the same picture — is a rule about *unlabelled* shapes, where the height of a mark is the whole of
/// the evidence.
///
/// The three quantities this fits have no such definition, and each fails to have one in its own way.
/// HRV is milliseconds, unbounded above, and its magnitude is meaningless without the person it came
/// from: a 45 ms week is a good week for one reader and a collapse for another, which is the entire
/// premise of the Recovery model's z-score. A resting heart rate and a respiratory rate are both in
/// units with real physiological floors and ceilings, but a week of either spans a couple of units —
/// measured over the bundled export, a week of respiratory rates spans under two breaths per minute
/// against a range of 13.5–20.2 — so a fixed axis wide enough to hold every person would flatten every
/// week to a straight line, the same failure arrived at from the other side. So the two honest options
/// are a fixed axis against a **fabricated ceiling**, or one fitted to the week with every reading
/// labelled — and the labels are what make the second honest, because the reader is given the numbers
/// the axis is only a guide to. `WeekLineChartView` prints one over every point.
///
/// It is a general fit and knows nothing about its caller: the same ladder rounds a week of
/// milliseconds out to tens and a week of breaths out to single units. That is why the resolution a
/// quantity is *printed* at is not decided here — see `WeekLineSeries.valueDecimals` — since this type
/// only ever sees numbers.
///
/// The bounds are snapped to round numbers so the gridlines are at values a reader can name. An axis
/// fitted to 32–67 and gridded at 43.7 and 55.3 would be decoration; this one grids at 40, 50 and 60.
///
/// The bounds are **not** forced to include zero. Forcing it would flatten a real week into the top
/// half of the frame — the failure the fixed scales exist to avoid, arrived at from the other side.
///
/// ## What it does not claim
///
/// It is a drawing instruction and nothing else: it carries no opinion about whether a value is good,
/// and it is not a baseline. The mean a reading is compared against is `MetricWeek.hrvBaselineMs`,
/// which is computed over a fixed floor of measured days; this is fitted to whatever it is handed,
/// including a single point.
public struct FittedAxis: Equatable, Sendable {

    /// The value at the foot of the plot.
    public let lowerBound: Double

    /// The value at the top of the plot.
    public let upperBound: Double

    /// The round values strictly inside the bounds, low to high — where the chart rules its lines.
    public let gridLines: [Double]

    /// The interval the bounds and gridlines are multiples of.
    public let step: Double

    /// Fits an axis to these values, or `nil` when there are none to fit.
    ///
    /// `nil` rather than a default 0–1 range: an axis with nothing to describe is not a scale, and a
    /// caller that draws through it would be drawing an empty frame — which is the one thing a chart
    /// of unmeasured days must not do.
    public init?(values: [Double]) {
        guard let lowest = values.min(), let highest = values.max() else { return nil }

        // A week where every reading is the same number still needs a band to draw in. Without this a
        // zero-height range would put the line on the frame's edge and leave `fraction` dividing by
        // zero.
        let low = highest - lowest < 0.5 ? lowest - 1 : lowest
        let high = highest - lowest < 0.5 ? highest + 1 : highest

        // The smallest step that keeps the plot to a handful of bands. Walked from the smallest so
        // fine-grained data gets fine gridlines, and the last entry is the fallback for a range wider
        // than any of them — a coarser grid than ideal, never a broken one.
        let span = high - low
        let step = Self.steps.first { span / $0 <= Self.maximumIntervals } ?? Self.steps[Self.steps.count - 1]

        let lower = (low / step).rounded(.down) * step
        var upper = (high / step).rounded(.up) * step
        // Unreachable for any input the expansion above did not already widen, and kept because a
        // degenerate axis would divide by zero rather than draw something wrong.
        if upper <= lower { upper = lower + step }

        var gridLines: [Double] = []
        var line = lower + step
        // `1e-9` rather than `<` on the raw values: the stride accumulates binary rounding, and the
        // top bound is itself a multiple of the step, so an exact comparison would draw the frame's
        // top edge as an extra gridline on some inputs and not others.
        while line < upper - 1e-9 {
            gridLines.append(line)
            line += step
        }

        self.lowerBound = lower
        self.upperBound = upper
        self.step = step
        self.gridLines = gridLines
    }

    /// Where a value sits vertically, as a fraction from the foot of the plot to its top.
    ///
    /// Clamped, because a value outside the bounds must not draw outside the frame. Nothing the
    /// chart hands it can be — the bounds were fitted to exactly those values — but the type is
    /// public and a caller fitting one series and drawing another is a mistake this can absorb.
    public func fraction(_ value: Double) -> Double {
        let span = upperBound - lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - lowerBound) / span, 0), 1)
    }

    /// The steps an axis may be gridded at, smallest first. Multiples a reader reads without
    /// arithmetic: the 25 and 250 entries are here because a step of 20 over a 100 ms range gives
    /// five bands where 25 gives four.
    private static let steps: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000]

    /// The most bands the plot is cut into. Four is what the chart's height can carry without the
    /// gridlines competing with the line they are behind.
    private static let maximumIntervals: Double = 4
}
