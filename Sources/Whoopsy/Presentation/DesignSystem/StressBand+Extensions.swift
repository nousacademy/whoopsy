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
}
