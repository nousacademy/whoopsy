import SwiftUI

/// A stress band's colour, for the tile's label and the chart's fill alike.
///
/// The bands themselves — low 0–1, medium 1–2, high 2–3, with the edges as
/// `StressMath.lowMediumBandEdge`/`mediumHighBandEdge` — are the model's published definition, and
/// `StressMath.band(forScore:)` is the one place a score becomes one. This file only maps that band
/// to a token.
///
/// The tokens are the recovery tiers, deliberately: calm-to-activated runs the same direction as
/// recovered-to-strained, and a parallel palette would give this app two greens that mean different
/// things. What it must **not** be is a second copy per screen — `HomeDashboardView` carried a private
/// `stressBandColor(_:)` before the chart needed the same three bands, which is exactly the shape of
/// the drift `RecoveryState+Extensions` exists to prevent.
///
/// It cannot live on the enum itself: `StressMath` is in `Core`, which imports only `Foundation` and
/// so cannot name a `Color`.
extension StressMath.Band {
    public var color: Color {
        switch self {
        case .low: return Theme.recoveryGreen
        case .medium: return Theme.recoveryYellow
        case .high: return Theme.recoveryRed
        }
    }

    /// The three bands as a hard-edged vertical gradient over a 0–`StressMath.maximumScore` axis.
    ///
    /// **Hard-edged rather than blended**, because the band edges are thresholds and a soft ramp
    /// between them would draw a gradual transition across a step. The stop locations are the edges
    /// divided by the scale, so the fill changes colour at exactly the score where
    /// `band(forScore:)` changes band.
    ///
    /// It is **here rather than in a chart** because two charts now fill under a stress trace — the
    /// day's `StressMonitorChartView` and the night's `SleepStressChartView` — and a divergence between
    /// them would not be a styling difference: it would put "high" at a different score on two screens
    /// that label their axis with the same 0–3. Neither chart types `1.0` or `2.0`; both read
    /// `StressMath`'s edges through this.
    ///
    /// A `LinearGradient` is not a `Shape`, so a caller must still apply it to one — and it must be a
    /// `Shape` rather than a `Path`, because `path(in:)` receives the frame and the stops therefore
    /// land on the score scale. A `Path` laid out in a `ZStack` is graded over its own bounding box
    /// instead, and a calm night and a wired one would put "high" in different places on screen.
    ///
    /// It takes no scale parameter: the axis is `StressMath.maximumScore` on both charts, so a
    /// parameter would only be a way for one of them to grade against something else.
    public static var gradient: LinearGradient {
        let highEdge = 1 - StressMath.mediumHighBandEdge / StressMath.maximumScore
        let lowEdge = 1 - StressMath.lowMediumBandEdge / StressMath.maximumScore
        return LinearGradient(
            stops: [
                .init(color: StressMath.Band.high.color, location: 0),
                .init(color: StressMath.Band.high.color, location: highEdge),
                .init(color: StressMath.Band.medium.color, location: highEdge),
                .init(color: StressMath.Band.medium.color, location: lowEdge),
                .init(color: StressMath.Band.low.color, location: lowEdge),
                .init(color: StressMath.Band.low.color, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
    }
}
