import Foundation

/// The three physiological quantities a fast's page charts, one segment each in a night's column.
///
/// ## Why this is a type
///
/// There are exactly three, they are the only three `recoveries` carries a reading of that the export
/// produces on every night, and each one needs a name, a unit and a colour. Spreading those three
/// answers across a chart's body would put the legend's labels, the axis's unit and the bar fills in
/// three places, and **the runner has no renderer** — so a label typed into a `body` is a label
/// nothing can assert. It is the same reason `ActivityGlyph`, `ActivityMenu` and `FastingZone` are
/// types.
///
/// ## The names are the Recovery screen's, and that is deliberate
///
/// `RecoveryDetailView`'s breakdown card already draws these three under `HRV` / `RHR` /
/// `RESPIRATORY RATE` with the units below. A chart that called one of them `RR` would be a second
/// name for one quantity in one app, which is the failure `FastingMetric` exists to prevent one
/// degree further on: this app's reader has already learned that column's name.
///
/// The HRV entry is the one that has to say more, because the app holds **two** HRV quantities that
/// are never averaged together. `legendLabel(hrvMetric:)` names the one in force.
public enum FastingMetric: String, CaseIterable, Sendable {

    /// Heart-rate variability, in the quantity the page's own window was narrowed to.
    case hrv

    /// Resting heart rate. Unaffected by which HRV quantity was recorded, so it is never narrowed.
    case restingHeartRate

    /// Respiratory rate, derived from the R-R series on the strap path and stored verbatim from the
    /// export's own column.
    case respiratoryRate

    /// The quantity's name, matching `RecoveryDetailView`'s breakdown rows.
    public var label: String {
        switch self {
        case .hrv: return "HRV"
        case .restingHeartRate: return "RHR"
        case .respiratoryRate: return "RESPIRATORY RATE"
        }
    }

    /// The unit the raw reading is measured in, matching the same rows.
    public var rawUnit: String {
        switch self {
        case .hrv: return "ms"
        case .restingHeartRate: return "bpm"
        case .respiratoryRate: return "rpm"
        }
    }

    /// The legend's label: `label`, with the HRV quantity appended when there is one in force.
    ///
    /// `HRV (RMSSD)` is the shape WHOOP's own screens use and the one this app's recovery vocabulary
    /// already implies; a bare `HRV` on a chart whose window was narrowed to one of two quantities
    /// would leave the reader unable to tell which. With no metric in force — a fast that enclosed no
    /// night — there is nothing to name and the bare label is the honest one.
    public func legendLabel(hrvMetric: HRVMetric?) -> String {
        guard self == .hrv, let hrvMetric else { return label }
        return "\(label) (\(hrvMetric.displayName))"
    }

    /// The quantity's name as it reads inside a sentence, lower case and unpunctuated.
    ///
    /// A second name for the same three cases, and it exists because the two are genuinely different
    /// strings: `label` is a legend key drawn in caps beside a swatch, while this is a clause inside a
    /// sentence — `RESPIRATORY RATE finished below your baseline` reads as a shouted fragment where
    /// `respiratory rate finished below your baseline` reads.
    ///
    /// **It takes the metric and returns the same answer for all three**, deliberately: a clause
    /// saying `HRV (RMSSD) held at your baseline` would put a parenthesis in the middle of prose, and
    /// the quantity in force is already stated by the legend key one line above.
    public func proseName(hrvMetric: HRVMetric?) -> String {
        switch self {
        case .hrv: return "HRV"
        case .restingHeartRate: return "resting heart rate"
        case .respiratoryRate: return "respiratory rate"
        }
    }
}
