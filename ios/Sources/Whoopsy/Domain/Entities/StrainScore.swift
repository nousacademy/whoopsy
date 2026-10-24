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

    /// The motion term's own contribution to `rawAccumulatedLoad`, in the same weighted seconds.
    ///
    /// **A diagnostic component, not a second score.** It explains how much of the day the wrist
    /// supplied on a day the heart rate missed, is stored on the day row for audit, and is never drawn
    /// as a figure or compared against the score. `nil` on a row written before `v35` and on an
    /// imported row, which has no components at all.
    public let motionLoad: Double?

    /// The provenance label the row was stored with — `whoop_export` for an imported day, `device`
    /// for one this app computed.
    ///
    /// **The read-side bit that decides whether a row is repairable.** A day this app scored from a
    /// partial drain may be recomputed when more samples arrive; WHOOP's own figure for the same day
    /// must never be replaced by this app's estimate. A legacy `nil` is treated as this app's, which
    /// is what a row written before the label existed was.
    public let source: String?

    /// The formula that produced `score` — see `StrainAlgorithm`.
    public let algorithm: StrainAlgorithm?

    /// The newest input instant the row included, as stored in `strains.scoredThrough`.
    ///
    /// **The refresh watermark.** A day is recomputed only when its input is newer than this, so an
    /// unchanged day costs one cheap read per tick and does not churn the database. Local-only: it
    /// describes what this phone has seen, not what the record says.
    public let scoredThrough: Date?

    /// The label `CalculateStrainUseCase` writes: this phone computed the row.
    ///
    /// `nil` on a row written before the label existed is read as the same thing — see `isDeviceScored`.
    public static let deviceSource = "device"

    /// The `strains.source` value `WhoopExportImporter` writes for WHOOP's own figure.
    ///
    /// Spelled here as well as on the importer because Domain may not name a Data type, and this is
    /// the string a repair decision turns on. A suite assertion pins the two equal.
    public static let importSource = "whoop_export"

    /// Whether this app produced the row and may therefore recompute it.
    ///
    /// Since `v35` the writer labels every computed row, but rows from older builds carry `nil` — and
    /// they were every one of them written by the integrator. An imported row is the only one that must
    /// be left alone.
    public var isDeviceScored: Bool {
        guard source != Self.importSource else { return false }
        guard let algorithm else { return true }
        return algorithm.isAppComputed
    }

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        score: Double,
        hasMeasurement: Bool,
        rawAccumulatedLoad: Double = 0.0,
        activeCalories: Double = 0.0,
        averageHeartRate: Int = 0,
        maxHeartRate: Int = 0,
        zones: [HeartRateZone] = [],
        motionLoad: Double? = nil,
        source: String? = nil,
        algorithm: StrainAlgorithm? = nil,
        scoredThrough: Date? = nil
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
        self.motionLoad = motionLoad
        self.source = source
        self.algorithm = algorithm
        self.scoredThrough = scoredThrough
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
