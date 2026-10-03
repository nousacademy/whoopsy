import SwiftUI

/// How a figure compares with the value it is read against — which way it went, and whether that is
/// good news — and the one mapping from the second of those to a colour.
///
/// It was `TileChange`, private inside `HomeDashboardView`, and it is lifted here because a second
/// screen now draws the same thing: `RecoveryDetailView` prints four values each with a marker and a
/// trailing mean beneath it, which is Home's `metricPanel` row for row. A copy would be a second
/// definition of two decisions that have already been argued once — which way a figure moved, and
/// whether that direction is good news — and those two are exactly what a copy drifts on.
///
/// **Direction and verdict are separate, and both are carried.** The glyph points the way the number
/// went, literally and everywhere: up is green for HRV, restorative sleep and steps, and *worse* for
/// resting heart rate, respiratory rate and sleep need, because a body asking for more rest is not a
/// body performing better. The colour is the verdict alone — green better, yellow the same, red worse
/// — so a reader never has to hold "is up good for this one?" in their head. A single "is this good"
/// boolean would have lost the distinction between a value that fell and a value that fell *well*.
///
/// **The verdict is three states, not two, and the middle one is why the colour is not read off the
/// direction.** A figure equal to its own average draws a dot rather than a triangle, because there
/// is no direction to point: it has not moved. That case is a comparison worth drawing — "you are
/// exactly at your baseline" is an answer — where `nil` is reserved for having nothing to compare at
/// all.
public struct MetricChange: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case up
        case down
    }

    /// What the movement means as news. This, and nothing else, is what the colour says.
    public enum Verdict: Hashable, Sendable {
        case better
        case same
        case worse
    }

    /// Which way the figure went, or `nil` when the two formatted figures are the same. Optional
    /// rather than a third case on `Direction` because "same" is the absence of a direction, not a
    /// third one — and every reader that draws an arrow has to handle the absence anyway.
    public let direction: Direction?

    public let verdict: Verdict

    /// The comparison value, already formatted for display — the mean the day is being read against,
    /// not the day's own figure.
    public let previousText: String

    public init(direction: Direction?, verdict: Verdict, previousText: String) {
        self.direction = direction
        self.verdict = verdict
        self.previousText = previousText
    }

    /// The glyph this comparison draws. Here rather than at each use site so the direction and the
    /// shape cannot come apart, and because the arrow is a drawn shape: a caller that renders
    /// `previousText` without it has dropped the only thing that says which way the number went.
    public var symbolName: String {
        switch direction {
        case .up: return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case nil: return "circle.fill"
        }
    }

    /// The colour this comparison draws — the verdict, and only the verdict.
    public var color: Color { Self.color(for: verdict) }

    /// The verdict's colour, and the app's only mapping from a verdict to a token.
    ///
    /// A static rather than folded into `color` so it can be read by a caller that holds a verdict and
    /// no comparison to hang one on: `RecoveryDetailView`'s badge draws the key — two triangles in
    /// `better` and `worse` — and cannot go through `color` to get them. It is the one place `Theme`'s
    /// three tokens are assigned to `Verdict`'s three cases, so a key drawn from it cannot come to show
    /// a colour no marker uses.
    public static func color(for verdict: Verdict) -> Color {
        switch verdict {
        case .better: return Theme.recoveryGreen
        case .same: return Theme.recoveryYellow
        case .worse: return Theme.recoveryRed
        }
    }

    /// A figure against the value it is read against, or `nil` when there is nothing honest to draw.
    ///
    /// `nil` is now reserved for a missing side: a day with no measurement, or a window too thin to
    /// produce a baseline. Equal figures are **not** `nil` — they are `.same`, and the caller draws
    /// the dot. A day with no steps is not zero steps, so treating the pair as a change would invent
    /// a number; a day sitting exactly on its mean is a real answer and gets one.
    ///
    /// **The comparison is made on the text the caller will print, not on the raw pair.** A resting
    /// heart rate of 52 against a mean of 52.4 is genuinely below it, but both render as `52` — so a
    /// raw comparison draws a down triangle between two figures the reader can see are the same, and
    /// the row contradicts itself. The digits on screen are the whole of the evidence a reader has,
    /// which is also why "the same" is decided there rather than on the doubles: two figures that
    /// print alike *are* the same as far as this screen is concerned. This is why the comparison
    /// lives here rather than at the call sites: every caller prints `previousText` beside its own
    /// value, so the gate has to be applied by whatever produced that text.
    ///
    /// `higherIsBetter` is what turns the direction into the verdict, and it is not derivable from
    /// anything else here: the same upward move is better for HRV and worse for a resting heart rate.
    /// It is a parameter rather than two call sites choosing a colour, because a view that has to
    /// remember to pass it has two chances to forget.
    public static func between(
        current: Double?,
        previous: Double?,
        higherIsBetter: Bool,
        formatted: (Double) -> String
    ) -> MetricChange? {
        guard let current, let previous else { return nil }
        let previousText = formatted(previous)
        guard formatted(current) != previousText else {
            return MetricChange(direction: nil, verdict: .same, previousText: previousText)
        }
        let direction: Direction = current > previous ? .up : .down
        let isGood = higherIsBetter ? direction == .up : direction == .down
        return MetricChange(
            direction: direction,
            verdict: isGood ? .better : .worse,
            previousText: previousText)
    }
}
