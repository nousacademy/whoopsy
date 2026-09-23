import SwiftUI

/// The one place a heart-rate zone becomes a `Color`.
///
/// It exists for the reason `RecoveryState+Extensions.swift` and `SleepStageType+Extensions.swift`
/// exist: a value-to-drawing rule written at each call site is a rule the copies can disagree about,
/// and this app has already paid for that twice — Home drew every recovery green while the Recovery
/// tab tiered it, and the coach message held its own green boundary. `HeartRateZoneIndex` cannot carry
/// the property itself, because `Domain/` imports only `Foundation`, so the mapping lives here.
///
/// **It has one reader, and that count has already moved once.** `HeartRateZoneBar` held this as a
/// `private func colorForZone(_:)` while it was the only one and now reads it through here; the live
/// session screen's zone card was briefly a second reader and is gone — its bar is a *position* scale
/// over band edges rather than a share of the session, so it has no segment to fill and no legend dot
/// to colour. A sixth zone, or a screen that wants "a slightly different zone 4", goes through this
/// file or not at all.
///
/// The five colours are the recovery tokens in zone order, which is the ramp the tab's zone bar has
/// always drawn: zone 1 is a neutral grey rather than a fourth semantic colour, because it is the
/// band a session spends most of its time in and it should not read as an alert.
extension HeartRateZoneIndex {
    public var color: Color {
        switch self {
        case .zone1: return Color(white: 0.5)
        case .zone2: return Theme.livePulseCyan
        case .zone3: return Theme.recoveryGreen
        case .zone4: return Theme.recoveryYellow
        case .zone5: return Theme.recoveryRed
        }
    }
}
