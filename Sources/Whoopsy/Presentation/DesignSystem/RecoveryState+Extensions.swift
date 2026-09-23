import SwiftUI

/// A recovery tier's colour, for every screen that draws one.
///
/// The tier itself is `RecoveryMetric.state` and its boundaries — green 67–100, yellow 34–66, red
/// 0–33 — are the app's published definition, with `docs/ALGORITHMS.md` §"Recovery Tiers" as the spec.
/// This file only maps that tier to a token.
///
/// It exists as **one** mapping because the alternative was a copy per screen, and the copies had
/// already diverged: `RecoveryDashboardView` carried its own private switch, while Home drew
/// `recoveryGreen` unconditionally, so a 20% morning was green on the ring and red on the tab. Two
/// definitions of one published tier is the drift this file removes — moving a boundary now moves
/// every screen that draws one.
///
/// It cannot live on the enum itself: `RecoveryMetric` is in `Domain`, which imports only
/// `Foundation` and so cannot name a `Color`.
extension RecoveryMetric.RecoveryState {
    public var color: Color {
        switch self {
        case .green: return Theme.recoveryGreen
        case .yellow: return Theme.recoveryYellow
        case .red: return Theme.recoveryRed
        }
    }
}
