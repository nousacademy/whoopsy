import Foundation

/// Represents a computed cardiovascular Strain score (0.0 to 21.0 scale).
public struct StrainScore: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let score: Double // 0.0 to 21.0

    /// Whether that score came from samples the strap actually recorded — the counterpart of
    /// `RecoveryMetric.hasMeasurement`, and the same reserved-zero convention.
    ///
    /// **No writer produces a placeholder any more.** `CalculateStrainUseCase` returns `nil` and
    /// stores nothing for a day it recorded no samples for, so an unmeasured day has no row at all —
    /// and this flag is now reader tolerance for rows written before that change, still on disk
    /// holding `0.0`. It stays because those rows have to keep rendering as `—` and keep staying out
    /// of `MetricWeek`'s plotted points.
    ///
    /// A genuine rest day is representable as `0.0` too — the export's own `Day Strain` holds exactly
    /// `0.0` on two of its 933 rows — so **the score cannot tell you which one you are holding**. On
    /// a legacy row this flag can, and it is the only thing that can: every reader that draws a
    /// strain value must gate on it, or a day the strap was on the charger renders as a real 0.0 — a
    /// measurement nobody took.
    ///
    /// It is a **required** initialiser parameter rather than one defaulted to `true`, deliberately.
    /// A default would let a construction site mark a placeholder as measured by saying nothing,
    /// which is the exact bug this exists to prevent.
    public let hasMeasurement: Bool

    public let rawAccumulatedLoad: Double
    public let activeCalories: Double
    public let averageHeartRate: Int
    public let maxHeartRate: Int
    public let zones: [HeartRateZone]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        score: Double,
        hasMeasurement: Bool,
        rawAccumulatedLoad: Double = 0.0,
        activeCalories: Double = 0.0,
        averageHeartRate: Int = 0,
        maxHeartRate: Int = 0,
        zones: [HeartRateZone] = []
    ) {
        self.id = id
        self.date = date
        self.score = max(0.0, min(21.0, (score * 10).rounded() / 10))
        self.hasMeasurement = hasMeasurement
        self.rawAccumulatedLoad = rawAccumulatedLoad
        self.activeCalories = activeCalories
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.zones = zones
    }

    public var category: StrainCategory {
        switch score {
        case 0.0..<6.0: return .light
        case 6.0..<10.0: return .moderate
        case 10.0..<14.0: return .strenuous
        case 14.0..<18.0: return .hard
        default: return .allOut
        }
    }

    public enum StrainCategory: String, Sendable {
        case light = "Light"
        case moderate = "Moderate"
        case strenuous = "Strenuous"
        case hard = "Hard"
        case allOut = "All-Out"
    }
}
