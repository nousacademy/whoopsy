import Foundation

/// Recovery status score (0% to 100%) and physiological markers.
public struct RecoveryMetric: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let score: Int // 0 to 100%
    public let hrvValueMs: Double // in milliseconds
    /// Which quantity `hrvValueMs` holds. Never compare or average across metrics.
    public let hrvMetric: HRVMetric
    public let restingHeartRate: Int // in BPM
    public let skinTemperatureCelsius: Double?
    public let skinTemperatureBaselineDelta: Double? // in °C
    public let spO2Percentage: Double?
    public let respiratoryRate: Double? // Breaths per minute (e.g. 14.2)
    public let hrvBaselineDeltaMs: Double?
    public let rhrBaselineDeltaBpm: Int?

    /// Which producer wrote the row, as `recoveries.source` holds it — `nil` for a day this app
    /// classified from the strap, a label for an imported one.
    ///
    /// **It is a read-side provenance bit, not a wire field.** A row written by an estimator that
    /// has since been corrected must be distinguishable from one the current estimator stands
    /// behind: the strap path is the only writer with no label, so `source == nil` is exactly the
    /// set a repair may reconsider. The cloud mapper does not carry it, on the two-names rule —
    /// it describes this phone's history rather than the record's own fields.
    public let source: String?

    /// The label `CalculateRecoveryUseCase` writes for a **scored** day.
    public static let strapSource = "strap"

    /// The label for a day that was measured but could not be scored: fewer than
    /// `RecoveryScoring.minimumBaselineDays` measured days before it, and no cold-start substitute.
    ///
    /// **It is a measurement, not a missing one.** The HRV and resting rate are real and count toward
    /// the baseline; only the composite is absent. The stored `score` is the reserved `0`, which
    /// `hasScore` keeps off every ring and trend — a zero that is never drawn is a storage encoding
    /// for "no score", not a default result.
    public static let measurementSource = "measurement"

    /// Whether the row carries a composite score. A measured but unscored day has an HRV to show and
    /// no recovery percentage to draw, which is a different state from `hasMeasurement` (the absence
    /// of a reading).
    public var hasScore: Bool { hasMeasurement && source != Self.measurementSource }

    /// Whether this phone produced the row, as opposed to an import. The delete-on-refusal rule is
    /// allowed to remove only these; an imported row is a measurement from another source.
    public var isLocallyComputed: Bool {
        source == nil || source == Self.strapSource || source == Self.measurementSource
    }

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        score: Int,
        hrvValueMs: Double,
        hrvMetric: HRVMetric = .rmssd,
        restingHeartRate: Int,
        skinTemperatureCelsius: Double? = nil,
        skinTemperatureBaselineDelta: Double? = nil,
        spO2Percentage: Double? = nil,
        respiratoryRate: Double? = nil,
        hrvBaselineDeltaMs: Double? = nil,
        rhrBaselineDeltaBpm: Int? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.date = date
        self.score = max(0, min(100, score))
        self.hrvValueMs = hrvValueMs
        self.hrvMetric = hrvMetric
        self.restingHeartRate = restingHeartRate
        self.skinTemperatureCelsius = skinTemperatureCelsius
        self.skinTemperatureBaselineDelta = skinTemperatureBaselineDelta
        self.spO2Percentage = spO2Percentage
        self.respiratoryRate = respiratoryRate
        self.hrvBaselineDeltaMs = hrvBaselineDeltaMs
        self.rhrBaselineDeltaBpm = rhrBaselineDeltaBpm
        self.source = source
    }

    /// Whether this day holds an actual measurement, as opposed to a placeholder for a day that had
    /// none.
    ///
    /// **No writer produces a placeholder any more.** `CalculateRecoveryUseCase` returns `nil` and
    /// stores nothing for a night it could not measure, so a day with no data has no row — and this
    /// flag is now reader tolerance for rows written before that change, which are still on disk
    /// holding zeros. It stays because those rows have to keep rendering as `—` and keep staying out
    /// of every baseline.
    ///
    /// A placeholder stores zeros rather than the cold-start values it would otherwise be scored
    /// from — recording a profile default as if the strap had reported it is what put a fabricated
    /// 65 ms HRV into the baseline and made an unworn day look perfectly average.
    ///
    /// `score == 0` is the reserved marker: the scoring formula is clamped to `1...99`, so it can
    /// never produce a 0, and no HRV or resting heart rate is ever physiologically zero either. Three
    /// independent signals, one meaning.
    public var hasMeasurement: Bool { hrvValueMs > 0 }

    public var state: RecoveryState { RecoveryState(score: score) }

    public enum RecoveryState: String, Sendable {
        case green = "Green"
        case yellow = "Yellow"
        case red = "Red"

        /// The tier boundaries, and the only place they are written down.
        ///
        /// A caller holding a bare score must go through this rather than compare against `67` itself.
        /// The type that did exactly that is deleted — it made a second copy of the green boundary,
        /// which would have gone on disagreeing with this one in silence the day the boundary moved,
        /// and it is why a bare score now has one place to become a tier.
        ///
        /// Written as half-open ranges rather than as the `case 67...100` literals they replace,
        /// because a **view** now has to print them: the month calendar's legend reads `<34%`,
        /// `34% - 66%` and `>66%` off these instead of typing `34` and `66` a second time. The spec
        /// and `docs/ALGORITHMS.md` §3 spell the tiers inclusively — green 67–100, yellow 34–66, red 0–33 —
        /// and `67..<101` is those same numbers in the form a `contains` test can answer.
        ///
        /// The inclusive upper bounds the legend needs are arithmetic on the range, not new
        /// constants: "above 66" is `greenRange.lowerBound - 1`. That distinction is the point. A
        /// legend that hardcoded `66` while `init(score:)` banded on a different number would colour
        /// a day yellow under a key calling it green, and a key that lies about its own colours is
        /// worse than no key.
        public static let greenRange: Range<Int> = 67..<101
        public static let yellowRange: Range<Int> = 34..<67
        public static let redRange: Range<Int> = 0..<34

        public init(score: Int) {
            if Self.greenRange.contains(score) {
                self = .green
            } else if Self.yellowRange.contains(score) {
                self = .yellow
            } else {
                // `else`, not `Self.redRange.contains(score)`: a negative score reached the
                // `switch`'s `default` and must still land here, or making the initialiser total
                // over a new range would have quietly turned an out-of-band input into a crash
                // path or a wrong tier.
                self = .red
            }
        }

        public var description: String {
            switch self {
            case .green: return "Primed for high strain"
            case .yellow: return "Maintain baseline activity"
            case .red: return "Focus on rest and recovery"
            }
        }
    }
}
