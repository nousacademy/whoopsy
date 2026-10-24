import Foundation

/// A session's perceived exertion, on the 0–10 scale the session-RPE method uses.
///
/// **Why this exists beside the heart-rate model.** `LiveSessionAccumulator` and
/// `CalculateStrainUseCase` measure cardiovascular work, and a session that was hard for another reason
/// — heat, a heavy carry that never raised the rate, an emotional day the user trained through — scores
/// the same as an easy one with the same heart rate. Asking the user one question at the end is the
/// measurement those cannot make, and it is the one a training load can be validated against later.
///
/// **The five buckets are the control; the value is what is stored.** Asking for a figure between 0 and
/// 10 is a slider nobody can reproduce a week later, so the sheet offers five words and this type is
/// the one place the word becomes a number. `EASY` is 2 rather than 1 and `MAX` is 10 rather than 9,
/// because the bucket names span the scale's ends: a five-way control that maps to 0–4 would make the
/// hardest possible answer 4/10.
///
/// **`nil` is not `0`.** A session never rated has no perceived load, and a stored `0` would claim the
/// user rated it as no exertion at all. `rpe` is nullable on the record for the same reason `strain`
/// is — the absence a screen draws as a dash, never as a zero.
public enum WorkoutRPE {

    /// The smallest and largest value the method defines. Clamped by every writer.
    public static let minimum = 0
    public static let maximum = 10

    /// The five words the control offers and the value each stores.
    ///
    /// Declared in ascending order because the control draws them in this order and a bucket's position
    /// is its position on the scale — there is no separate sort key.
    public enum Bucket: String, CaseIterable, Sendable {
        case easy = "EASY"
        case moderate = "MODERATE"
        case hard = "HARD"
        case veryHard = "VERY HARD"
        case maximum = "MAX"

        /// The 0–10 value this bucket stores.
        public var value: Int {
            switch self {
            case .easy: return 2
            case .moderate: return 4
            case .hard: return 6
            case .veryHard: return 8
            case .maximum: return 10
            }
        }

        /// The word beside the figure on the detail page, in the row's own casing.
        public var label: String {
            switch self {
            case .easy: return "Easy"
            case .moderate: return "Moderate"
            case .hard: return "Hard"
            case .veryHard: return "Very hard"
            case .maximum: return "Max"
            }
        }

        /// The word inside a five-way control, where `label` does not fit.
        ///
        /// `SegmentedPillControl` gives each segment an equal share of the phone's width — about 70 pt
        /// for five — and draws its title at a fixed size with no shrinking, so `VERY HARD` would run
        /// into its neighbours. These are abbreviations of the same five words, not a second scale;
        /// the accessibility label is `label`, which is what a reader hears.
        public var shortLabel: String {
            switch self {
            case .easy: return "EASY"
            case .moderate: return "MOD"
            case .hard: return "HARD"
            case .veryHard: return "V.HARD"
            case .maximum: return "MAX"
            }
        }

        /// The bucket a stored value belongs to, or `nil` for a value outside the five — a row a future
        /// control wrote, which the segmented control then shows as nothing selected rather than
        /// snapping it to a neighbour and misreporting the user's answer.
        public static func forValue(_ value: Int) -> Bucket? {
            allCases.first { $0.value == value }
        }
    }

    /// A value as it is allowed to be stored: clamped into 0–10.
    public static func clamped(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    /// **The session-RPE training load**: the rating multiplied by the session's minutes.
    ///
    /// Arbitrary units, and labelled as such on screen. It is deliberately not converted onto the
    /// 0–21 strain scale or compared with a `StrainScore`: the two are different quantities, and a
    /// conversion would invent a calibration that does not exist. Its only use is comparing one
    /// session with another under the same rating method.
    public static func perceivedLoad(rpe: Int, durationSeconds: TimeInterval) -> Double {
        let minutes = max(0, durationSeconds) / 60
        return Double(clamped(rpe)) * minutes
    }
}
