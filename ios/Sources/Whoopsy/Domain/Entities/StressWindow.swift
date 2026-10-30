import Foundation

/// One scored window of the Stress Monitor — the unit the day's aggregate is built from.
///
/// `StressScore` answers "how activated was the day"; this answers "when". They are not two
/// measurements: the aggregate is the mean of a day's windows, so anything that draws one beside the
/// other has to get both from the same evaluation or the line can disagree with the number above it.
/// That is why `AnalyzeStressUseCase` returns them together, as a `StressDay`.
///
/// There is no placeholder and no zero, on the same reasoning as `StressScore`: a window exists only
/// where the strap was still and held enough beats, and an hour with no window is an hour that was
/// never measured — not a calm one.
public struct StressWindow: Equatable, Sendable {
    /// When the window begins.
    ///
    /// The anchor of the bucket it was drawn from, which is the day's first in-window sample plus
    /// whole `StressMath.windowSeconds` steps. It is therefore clock-aligned only to within one
    /// window length — a day whose samples start at 09:03 has windows at :03, not on the hour. The
    /// chart plots this value rather than rounding it, because rounding would move a measurement.
    public let start: Date

    /// The window's activation on WHOOP's 0–3 scale, already scored against the personal baseline.
    public let score: Double

    /// The band `score` falls in. Derived, so it cannot sit beside a score from another evaluation.
    public var band: StressMath.Band { StressMath.band(forScore: score) }

    /// What the score was made from, when the caller kept it.
    ///
    /// The analyzer fills this in for every window it scores, because the **recent** baseline is
    /// built *from* these numbers: with no personal baseline, a window is scored against the mean
    /// and spread of the previous few hours' features, so a live tick needs the day's own features to
    /// extend the line at all. `nil` on a window a caller assembled by hand — a preview, a fixture, a
    /// chart test — which is why it is optional rather than a second required value.
    public let features: StressWindowFeatures?

    public init(start: Date, score: Double, features: StressWindowFeatures? = nil) {
        self.start = start
        self.score = score
        self.features = features
    }
}
