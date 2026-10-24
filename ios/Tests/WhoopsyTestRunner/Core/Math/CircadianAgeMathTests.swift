import Foundation
import Whoopsy

/// The age-typical mid-sleep prior, and the guards that keep it from scoring a daytime span.
enum CircadianAgeMathTests {
    static let calendar = Calendar.current
    static let day = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))

    /// A night on a fixed day, with an onset in clock hours and a wake that may roll past midnight.
    static func night(onsetHour: Double, wakeHour: Double) -> SleepConsistencyMath.Night {
        let onset = day.addingTimeInterval(onsetHour * 3600)
        let span = wakeHour > onsetHour ? wakeHour - onsetHour : 24 - onsetHour + wakeHour
        return SleepConsistencyMath.Night(
            day: day, onset: onset, wake: onset.addingTimeInterval(span * 3600))
    }

    static func run() async throws {
        assertTest(
            CircadianAgeMath.targetWindow(forAge: nil) == nil,
            "No birth date means no age prior — not an adult default dressed up as one")

        // The anchors, in the night-clock frame the scorer actually uses. 4:30 is 990, 3:58 is 958,
        // 2:58 is 898, 2:49 is 889.
        let twenty = CircadianAgeMath.targetWindow(forAge: 20)
        assertTest(twenty?.midpointMinutes == 990, "20 years targets 4:30 mid-sleep")
        assertTest(twenty?.toleranceMinutes == 150, "20 years carries the 2.5-hour SD")

        let twentyFive = CircadianAgeMath.targetWindow(forAge: 25)
        assertTest(twentyFive?.midpointMinutes == 958, "25 years targets 3:58 mid-sleep")
        assertTest(twentyFive?.toleranceMinutes == 149, "25 years carries the 2.49-hour SD")

        let sixtyFive = CircadianAgeMath.targetWindow(forAge: 65)
        assertTest(sixtyFive?.midpointMinutes == 898, "65 years targets 2:58 mid-sleep")
        assertTest(sixtyFive?.toleranceMinutes == 119, "65 years carries the 1.98-hour SD")

        let seventy = CircadianAgeMath.targetWindow(forAge: 70)
        assertTest(seventy?.midpointMinutes == 889, "70 years targets 2:49 mid-sleep")
        assertTest(seventy?.toleranceMinutes == 110, "70 years interpolates the SD")

        let seventyFive = CircadianAgeMath.targetWindow(forAge: 75)
        assertTest(seventyFive?.midpointMinutes == 889, "75 years holds the 2:49 target")
        assertTest(seventyFive?.toleranceMinutes == 100, "75 years carries the 1.66-hour SD")

        assertTest(
            CircadianAgeMath.targetWindow(forAge: 80) == seventyFive,
            "Beyond 75 the curve plateaus rather than extrapolating")
        assertTest(
            CircadianAgeMath.targetWindow(forAge: 10) == twenty,
            "Below 20 the curve holds the 20-year anchor")

        // A midpoint exactly on the target is full marks; one SD is 50; two SDs is 0.
        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 0.5, wakeHour: 8.5), age: 20) == 100,
            "A night centred on 4:30 scores full timing at age 20")
        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 22, wakeHour: 6), age: 20) == 50,
            "One SD from the target scores 50")
        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 19.5, wakeHour: 3.5), age: 20) == 0,
            "Two SDs from the target scores 0")

        // 23:50 → 07:10 is a 7h20m night centred at 03:30, one hour before the age-20 target. The
        // circular midpoint is the point: a minute-of-day mean would put this near noon.
        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 23.833333, wakeHour: 7.166667), age: 20)
                == 80,
            "The score uses the circular midpoint, not a minute-of-day mean")

        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 10, wakeHour: 18), age: 20) == nil,
            "A span that crosses noon is not an overnight night")
        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 2, wakeHour: 3), age: 20) == nil,
            "A one-hour span is not a night")
        assertTest(
            CircadianAgeMath.timingScore(for: night(onsetHour: 18, wakeHour: 12), age: 20) == nil,
            "An eighteen-hour span is not a night")
    }
}
