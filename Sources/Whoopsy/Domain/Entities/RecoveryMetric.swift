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
        rhrBaselineDeltaBpm: Int? = nil
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
        /// A caller holding a bare score — a coaching message, say — must go through this rather than
        /// compare against `67` itself. `GenerateCoachInsightsUseCase` did exactly that, which made a
        /// second copy of the green boundary that would have gone on disagreeing with this one in
        /// silence the day the boundary moved.
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
