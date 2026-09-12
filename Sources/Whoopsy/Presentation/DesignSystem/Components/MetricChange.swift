import SwiftUI

/// Which way a figure moved against the value it is being compared with, and the one mapping from
/// that to a colour.
///
/// It was `TileChange`, private inside `HomeDashboardView`, and it is lifted here because a second
/// screen now draws the same thing: `RecoveryDetailView` prints four values each with a triangle and
/// a trailing mean beneath it, which is Home's `metricPanel` row for row. A copy would be a second
/// definition of two decisions that have already been argued once — which direction a figure moved,
/// and whether that direction is good news — and those two are exactly what a copy drifts on.
///
/// **Direction and verdict are separate, and that is the whole point of `marker`.** Up is green for
/// HRV, restorative sleep and steps; it is orange for resting heart rate, respiratory rate and sleep
/// need, because a body asking for more rest is not a body performing better. The direction keeps its
/// literal meaning everywhere — a triangle points the way the number went — and only the colour
/// inverts. A single "is this good" boolean would have lost the distinction between a value that fell
/// and a value that fell *well*.
public struct MetricChange: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case up
        case down
    }

    public let direction: Direction

    /// The comparison value, already formatted for display — the mean the day is being read against,
    /// not the day's own figure.
    public let previousText: String

    public init(direction: Direction, previousText: String) {
        self.direction = direction
        self.previousText = previousText
    }

    /// The glyph that draws `direction`. Here rather than at each use site so the two cannot come
    /// apart, and because the arrow is a drawn shape: a caller that renders `previousText` without it
    /// has dropped the only thing that says which way the number went.
    public var symbolName: String {
        direction == .up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
    }

    /// The change from a comparison value, or `nil` when there is nothing honest to say.
    ///
    /// `nil` covers three cases that all render as a plain comparison value with no triangle: either
    /// side missing a measurement, and the two being equal. A day with no steps is not zero steps, so
    /// treating the pair as a change would invent a number. `direction` marks which way the value
    /// moved and nothing more — for steps, more is not self-evidently better, so the colour `between`
    /// implies is not a verdict. Use `marker` when you want the verdict too.
    ///
    /// **The comparison is made on the text the caller will print, not on the raw pair.** A resting
    /// heart rate of 52 against a mean of 52.4 is genuinely below it, but both render as `52` — so a
    /// raw comparison draws a down triangle between two figures the reader can see are the same, and
    /// the row contradicts itself. The digits on screen are the whole of the evidence a reader has,
    /// so an arrow is only drawn when those digits differ. This is why the comparison lives here
    /// rather than at the call sites: every caller prints `previousText` beside its own value, so the
    /// gate has to be applied by whatever produced that text.
    public static func between(
        current: Double?,
        previous: Double?,
        formatted: (Double) -> String
    ) -> MetricChange? {
        guard let current, let previous else { return nil }
        let previousText = formatted(previous)
        guard formatted(current) != previousText else { return nil }
        return MetricChange(
            direction: current > previous ? .up : .down,
            previousText: previousText)
    }

    /// A day's figure against its trailing mean, with the colour that comparison should carry.
    ///
    /// Returns a pair rather than letting the view read `direction` and pick a colour itself, because
    /// the colour is not a property of the direction: `higherIsBetter` is what decides whether the
    /// same arrow is green or orange, and a view that has to remember to pass it has two chances to
    /// forget.
    ///
    /// `nil` when there is nothing honest to compare — a missing day, a missing baseline, or a day
    /// that *is* the mean. The caller renders the plain baseline figure in that case, with no triangle.
    public static func marker(
        current: Double?,
        baseline: Double?,
        higherIsBetter: Bool,
        formatted: (Double) -> String
    ) -> (change: MetricChange, color: Color)? {
        guard let change = between(current: current, previous: baseline, formatted: formatted) else {
            return nil
        }
        let isGood = higherIsBetter ? change.direction == .up : change.direction == .down
        return (change, isGood ? Theme.recoveryGreen : Theme.strainPrimary)
    }
}
