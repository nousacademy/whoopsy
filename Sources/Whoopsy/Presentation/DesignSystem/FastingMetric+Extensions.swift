import SwiftUI

/// A charted physiological quantity's bar colour.
///
/// The quantity itself and its name and unit are `FastingMetric` in `Domain`, which imports only
/// `Foundation` and so cannot name a `Color` — the same split, and the same reason, as
/// `RecoveryState+Extensions.swift`, `SleepStageType+Extensions.swift` and
/// `FastingZone+Extensions.swift` above it. This file is the app's **only** metric-to-`Color` mapping
/// for that chart: a second copy would be the drift those three files record, where one value drawn on
/// two screens comes to mean two different things.
///
/// Nothing here re-picks a colour — the three tokens are `Theme`'s, and the reasoning behind the
/// palette (three shades of one blue, and why a verdict scale was rejected) is in their own doc
/// comment.
extension FastingMetric {

    /// The bar's fill, and the swatch beside its name in the legend.
    ///
    /// The legend and the bars read through this one property, so a swatch can never disagree with the
    /// bar it keys. That is the whole of what this file buys: the two are drawn in different parts of
    /// the chart and would otherwise be two independent switches over the same three cases.
    public var color: Color {
        switch self {
        case .hrv: return Theme.fastingChartHRV
        case .restingHeartRate: return Theme.fastingChartRestingHeartRate
        case .respiratoryRate: return Theme.fastingChartRespiratoryRate
        }
    }
}
