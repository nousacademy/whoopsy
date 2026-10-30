import Foundation

/// How many of WHOOP's five Health Monitor vitals this app holds a reading for on one day.
///
/// **It counts readings, and it does not say whether they are in range.** WHOOP's Health Monitor
/// compares each vital against your normal and green-lights the set; this app has the five values on
/// the day's `recoveries` row (`hrv`, `restingHeartRate`, `respiratoryRate`, `spO2Percentage`,
/// `skinTemperatureCelsius`) and no per-metric band for two of them, so the honest summary is the
/// count it can prove. The card's copy says `ALL MEASURED` rather than the reference's `WITHIN RANGE`
/// for that reason — see `HealthMonitorCard`.
///
/// **It is a type rather than arithmetic in the view** for this repo's standing reason: the runner has
/// no renderer, so a count built inside a `body` is a count nothing can assert. It also gives the
/// gate one name: a day with no `recoveries` row is `0` of 5, not a crash and not a missing card.
public struct HealthMonitorSummary: Equatable, Sendable {

    /// WHOOP's five vitals, in the order its own screen lists them.
    public enum Vital: String, CaseIterable, Sendable {
        case heartRateVariability
        case restingHeartRate
        case respiratoryRate
        case bloodOxygen
        case skinTemperature

        /// The word a listener hears. The card itself draws no names — it draws a count.
        public var displayName: String {
            switch self {
            case .heartRateVariability: return "Heart rate variability"
            case .restingHeartRate: return "Resting heart rate"
            case .respiratoryRate: return "Respiratory rate"
            case .bloodOxygen: return "Blood oxygen"
            case .skinTemperature: return "Skin temperature"
            }
        }
    }

    /// The vitals this app holds a value for.
    public let measured: [Vital]

    /// Every vital the monitor tracks — the denominator, read off the enum rather than written as `5`.
    public static let total = Vital.allCases.count

    public init(measured: [Vital]) {
        self.measured = Vital.allCases.filter { measured.contains($0) }
    }

    /// One day's row, or `nil` for a day that was never measured.
    public init(recovery: RecoveryMetric?) {
        guard let recovery else {
            self.init(measured: [])
            return
        }
        // **Each presence rule is the field's own.** `hrvValueMs > 0` is `RecoveryMetric.hasMeasurement`'s
        // rule and a heart rate of `0` is the same absence — the app's convention that a value with no
        // measurement behind it is not a reading. The three optionals are `nil` on a day the export did
        // not carry them and on every night this app classified itself.
        var measured: [Vital] = []
        if recovery.hrvValueMs > 0 { measured.append(.heartRateVariability) }
        if recovery.restingHeartRate > 0 { measured.append(.restingHeartRate) }
        if recovery.respiratoryRate != nil { measured.append(.respiratoryRate) }
        if recovery.spO2Percentage != nil { measured.append(.bloodOxygen) }
        if recovery.skinTemperatureCelsius != nil { measured.append(.skinTemperature) }
        self.init(measured: measured)
    }

    public var measuredCount: Int { measured.count }

    /// Whether every vital has a reading — what the card's green state means.
    public var isComplete: Bool { measuredCount == Self.total }

    /// The vitals with no reading, in the monitor's own order.
    public var missing: [Vital] { Self.Vital.allCases.filter { !measured.contains($0) } }
}
