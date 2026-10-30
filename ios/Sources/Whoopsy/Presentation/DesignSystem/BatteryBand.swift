import SwiftUI

/// The dot beside Home's strap badge: three bands of remaining charge, and the one place their
/// boundaries are written down.
///
/// ## Where the numbers come from, and what they are not
///
/// **They are WHOOP's published charger scale, applied to the sensor.** The only percentage→colour
/// mapping WHOOP publishes is on the wireless PowerPack — double-tap it and it shows green at
/// 50–100%, yellow at 20–49%, red below 20% (`support.whoop.com`, *Battery Pack and Charging: Common
/// Questions*). The sensor itself publishes exactly one colour rule: five red flashes below 5%. So the
/// app uses the pack's three bands for the strap's state of charge, because that is the closest thing
/// to an official scale there is, and this comment is the record that the sensor's own thresholds are
/// not published rather than that they were consulted.
///
/// **It is the same three-verdict shape the rest of the app uses, and deliberately not the same
/// numbers.** Recovery's tiers are 67/34 and these are 50/20; the tokens are shared because a green,
/// an amber and a red are the app's three states, but a battery band is not a verdict about training.
/// A reader must not compute one from the other.
///
/// The colour itself lives here rather than on the enum in `Domain` for the reason
/// `RecoveryState.color` does: `Domain` imports only `Foundation`, so a `Color` cannot live on a domain
/// value, and the one mapping has to be somewhere a test can read.
public enum BatteryBand: String, CaseIterable, Sendable {
    /// 50% and above.
    case healthy
    /// 20–49%.
    case low
    /// Below 20%.
    case critical

    /// The inclusive lower bound of `.healthy`, and the figure the dot turns green at.
    public static let healthyFloor = 50

    /// The inclusive lower bound of `.low`, and the figure the dot turns red below.
    public static let lowFloor = 20

    /// The band a percentage falls in.
    ///
    /// **The boundaries are inclusive at the floor**: 50 is healthy and 20 is low, which is how the
    /// PowerPack's own ranges are written (`50–100`, `20–49`, `below 20`). A value outside 0–100 is
    /// clamped rather than refused — a state of charge is a percentage by definition, and the strap's
    /// own `0.1%`-unit field is divided down before it gets here.
    public static func band(for percentage: Int) -> BatteryBand {
        let clamped = max(0, min(100, percentage))
        if clamped >= healthyFloor { return .healthy }
        if clamped >= lowFloor { return .low }
        return .critical
    }

    /// The dot's colour for this band.
    public var color: Color {
        switch self {
        case .healthy: return Theme.recoveryGreen
        case .low: return Theme.recoveryYellow
        case .critical: return Theme.recoveryRed
        }
    }
}
