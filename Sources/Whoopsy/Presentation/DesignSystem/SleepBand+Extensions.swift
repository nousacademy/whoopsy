import SwiftUI

/// A sleep band's colour, for every screen that draws one.
///
/// The bands themselves — and the three different threshold pairs a figure is read against — are
/// `SleepBand`'s, with the anchors written out in its doc comment. This file only maps a band to a
/// token, which is why it exists at all: `SleepBand` is in `Domain`, and `Domain` imports only
/// `Foundation`, so it cannot name a `Color`. `RecoveryState+Extensions.swift` and
/// `StressBand+Extensions.swift` are the same file for the same reason.
///
/// **The three tokens are this screen's own, not the recovery tiers', and that is the one place this
/// mapping differs from `StressBand+Extensions`.** The stress tile borrows green/yellow/red because
/// calm-to-activated runs the same direction as recovered-to-strained and a parallel palette would put
/// two greens on the app that mean different things. Here the reference's own key is orange, grey and
/// green — a scale that is not a traffic light, because "Sufficient" is a colour between the two
/// rather than a warning — and borrowing `recoveryYellow` for it would read as a caution about a
/// night this app is calling adequate.
extension SleepBand {
    public var color: Color {
        switch self {
        case .poor: return Theme.bandPoor
        case .sufficient: return Theme.bandSufficient
        case .optimal: return Theme.bandOptimal
        }
    }
}
