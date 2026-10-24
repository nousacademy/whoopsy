import Foundation

/// An age-typical sleep-timing window, used only when a night has no consistency score to read.
///
/// **This is a population prior, not a measurement.** The app has no circadian-phase sensor and no
/// chronotype model: `SleepConsistencyMath` measures how regular a night's boundaries are, which is a
/// different question. This type answers "where would a person of this age typically place the middle
/// of their night?", and it exists so a night in the first few days of a history — or one after a
/// recording gap — can still carry a timing term instead of losing a quarter of the composite.
///
/// ## The curve
///
/// The anchors are the free-day mid-sleep means reported by Fischer, Lombardi, Marucci-Wellman and
/// Roenneberg (2017), *Chronobiology International* 34(9), the US replication of the Munich
/// ChronoType Questionnaire:
///
/// | Age | Mid-sleep | Between-person SD |
/// | :--- | ---: | ---: |
/// | 20 | 4:30 | 150 min |
/// | 25 | 3:58 | 149 min |
/// | 65 | 2:58 | 119 min |
/// | 70 | 2:49 | 110 min |
/// | 75+ | 2:49 | 100 min |
///
/// The paper reports five-year bins by sex. The app has no sex field, so these anchors are pooled
/// values and the curve is **this app's piecewise-linear interpolation** of the published bins — not
/// an equation the paper prints. Under 20 uses the 20-year anchor; over 75 uses the 75-year one.
///
/// The between-person SD is the tolerance, and the score ramps across **two** SDs: a midpoint on the
/// target scores 100, one SD away scores 50, two SDs away scores 0. That is deliberately generous,
/// because the SD is the spread of a population and an individual is allowed to sit inside it.
///
/// ## What it refuses
///
/// A night whose clock span crosses noon is not an overnight night and returns `nil`; neither can a
/// night shorter than two hours or longer than sixteen. Those guards matter most on imported rows,
/// where `Sleep onset` is unreliable and a `00:00:00` onset can otherwise turn into a plausible-looking
/// timing score.
///
/// All arithmetic is on `SleepConsistencyMath`'s night-clock frame, so a 23:50 onset and a 00:10 one
/// are twenty minutes apart rather than 1420.
public enum CircadianAgeMath {

    /// An age-typical mid-sleep and the tolerance it is read against.
    public struct TargetWindow: Equatable, Sendable {
        /// Mid-sleep on the night clock — `SleepConsistencyMath.nightClockMinutes`' frame.
        public let midpointMinutes: Double
        /// One between-person standard deviation, in minutes.
        public let toleranceMinutes: Double

        public init(midpointMinutes: Double, toleranceMinutes: Double) {
            self.midpointMinutes = midpointMinutes
            self.toleranceMinutes = toleranceMinutes
        }
    }

    /// The anchors, oldest first: age, mid-sleep as minutes past midnight, SD in minutes.
    private static let anchors: [(age: Double, midSleepMinutes: Double, toleranceMinutes: Double)] = [
        (20, 4 * 60 + 30, 150),
        (25, 3 * 60 + 58, 149),
        (65, 2 * 60 + 58, 119),
        (70, 2 * 60 + 49, 110),
        (75, 2 * 60 + 49, 100),
    ]

    /// The window for an age, or `nil` when no age is known.
    public static func targetWindow(forAge age: Int?) -> TargetWindow? {
        guard let age else { return nil }

        let clamped = min(max(Double(age), anchors[0].age), anchors[anchors.count - 1].age)
        let (lower, upper) = segment(for: clamped)
        let span = upper.age - lower.age
        let fraction = span > 0 ? (clamped - lower.age) / span : 0
        let midSleep = lower.midSleepMinutes
            + fraction * (upper.midSleepMinutes - lower.midSleepMinutes)
        let tolerance = lower.toleranceMinutes
            + fraction * (upper.toleranceMinutes - lower.toleranceMinutes)

        return TargetWindow(
            midpointMinutes: nightClockMinutes(fromClockMinutes: midSleep),
            toleranceMinutes: tolerance)
    }

    /// How well a night's midpoint aligns with the age-typical window, in 0…100.
    ///
    /// `nil` when the age is absent, the span is implausible, the span crosses noon, or the circular
    /// midpoint of the two boundaries is undefined.
    public static func timingScore(
        for night: SleepConsistencyMath.Night,
        age: Int,
        calendar: Calendar = .current
    ) -> Int? {
        guard let target = targetWindow(forAge: age), target.toleranceMinutes > 0 else { return nil }

        let span = night.wake.timeIntervalSince(night.onset)
        guard span >= 2 * 3600, span <= 16 * 3600 else { return nil }

        let onset = SleepConsistencyMath.nightClockMinutes(night.onset, calendar: calendar)
        let wake = SleepConsistencyMath.nightClockMinutes(night.wake, calendar: calendar)

        // A night that begins before noon and ends after it is a daytime span, not an overnight
        // night. The age curve is a mid-sleep-of-the-night prior, so this is not a case it can read.
        let onsetClock = SleepConsistencyMath.clockMinutes(fromNightClock: onset)
        let wakeClock = SleepConsistencyMath.clockMinutes(fromNightClock: wake)
        if onsetClock < 720, wakeClock >= 720 { return nil }

        guard let midpoint = SleepConsistencyMath.circularMean([onset, wake]) else { return nil }
        let distance = SleepConsistencyMath.circularMinuteDistance(midpoint, target.midpointMinutes)
        let fraction = max(0.0, 1.0 - distance / (2.0 * target.toleranceMinutes))
        return max(0, min(100, Int((fraction * 100).rounded())))
    }

    /// Converts minutes past midnight into `SleepConsistencyMath`'s noon-shifted frame.
    public static func nightClockMinutes(fromClockMinutes minutes: Double) -> Double {
        let shifted = (minutes - 720).truncatingRemainder(dividingBy: 1440)
        return shifted < 0 ? shifted + 1440 : shifted
    }

    /// The pair of anchors surrounding an already-clamped age.
    private static func segment(
        for age: Double
    ) -> ((age: Double, midSleepMinutes: Double, toleranceMinutes: Double),
         (age: Double, midSleepMinutes: Double, toleranceMinutes: Double)) {
        for index in 1..<anchors.count where age <= anchors[index].age {
            return (anchors[index - 1], anchors[index])
        }
        return (anchors[anchors.count - 2], anchors[anchors.count - 1])
    }
}
