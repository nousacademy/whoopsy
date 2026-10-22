import Foundation
import Whoopsy

// MARK: - 13. The window a strap night is read out of

/// A file of §13's body, called by `SleepNeedTests.run()` after `SleepOnsetMathTests`.
///
/// `AnalyzeSleepUseCase` reads a night out of a 9 PM → 10 AM window and lets `SleepOnsetMath` trim it
/// to the night inside that span, so the window is the one thing that bounds what a night can ever be.
/// **It is asserted here because it was wrong for the entire life of the strap path and nothing saw
/// it**: the code computed `startOfDay − 11 h`, which is **1 PM the previous day**, while its own
/// comment, `SleepOnsetMath`'s documentation and every other reference in this repo say 9 PM. A
/// 21-hour window accepted an afternoon as the start of a night, and on a real strap the
/// consequence was a night reported from an afternoon hour to the following morning.
///
/// The rule is not "13 hours" — it is **the clock times**, which is why the fix builds both ends from
/// calendar components rather than adding hours to midnight: hour arithmetic lands on the wrong wall
/// time across a DST boundary exactly as it landed here.
enum AnalyzeSleepUseCaseTests {
    static func run() async throws {
        let calendar = Calendar.current

        // A morning date **at 13:38**, which is the shape `SleepViewModel` passes on a first load —
        // a raw `Date()`, not a midnight. The window must be the same regardless.
        let thisMorning = calendar.date(
            from: DateComponents(year: 2026, month: 10, day: 20, hour: 13, minute: 38))!
        let window = AnalyzeSleepUseCase.readWindow(for: thisMorning, calendar: calendar)

        func clock(_ date: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }

        let from = clock(window.from)
        let to = clock(window.to)
        assertTest(
            from.year == 2026 && from.month == 10 && from.day == 19 && from.hour == 21 && from.minute == 0,
            "The window opens at **9 PM the previous evening** — 2026-10-19 21:00 — not at the 1 PM a "
                + "`startOfDay − 11 h` lands on (\(from))")
        assertTest(
            to.year == 2026 && to.month == 10 && to.day == 20 && to.hour == 10 && to.minute == 0,
            "…and closes at 10 AM on the morning it is analysing (\(to))")
        assertTest(
            window.to.timeIntervalSince(window.from) == 13 * 3600,
            "…which is a **13-hour** read window. It was 21 hours, and the width is the assertion that "
                + "fails if either end drifts again "
                + "(\(Int(window.to.timeIntervalSince(window.from) / 3600)) h)")

        // The instant the bug admitted. An afternoon hour is inside a 1 PM → 10 AM window and outside a
        // 9 PM → 10 AM one, so this is the byte-level difference the fix makes.
        let afternoon = calendar.date(
            from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 33))!
        assertTest(
            afternoon < window.from,
            "An afternoon session is **outside** the window — the kind of onset the old window admitted as the start "
                + "of the night. Nothing in the read can begin before 9 PM once the window is right")

        // A midnight morning date and a raw afternoon one must answer identically, because the two
        // callers pass different shapes and a night is not allowed to depend on when the page opened.
        let midnight = calendar.startOfDay(for: thisMorning)
        assertTest(
            AnalyzeSleepUseCase.readWindow(for: midnight, calendar: calendar).from == window.from,
            "…and a midnight morning date yields the same window as an afternoon one, so opening the "
                + "page at 13:38 does not move the night it is analysing")

        // ── The staging threshold is measured, not the profile's cold start ──────────────────────
        //
        // With no profile row `restingHeartRate` is 60, so the awake test is `> 75` and a real awake
        // evening at 69–75 classified as sleep from the window's edge. The estimator below is the
        // lowest-third rule `CalculateRecoveryUseCase` applies, so one night has one resting rate.
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func night(hours: Double, awake: Int, asleep: Int) -> [BiometricSample] {
            let count = Int(hours * 3_600)
            let awakeCount = count * 2 / 5
            return (0..<count).map { index in
                BiometricSample(
                    timestamp: base.addingTimeInterval(Double(index)),
                    heartRate: index < awakeCount ? awake : asleep)
            }
        }
        assertTest(
            AnalyzeSleepUseCase.restingHeartRate(
                from: night(hours: 1, awake: 70, asleep: 50)) == 50,
            "A night's resting rate is the lowest third's mean — 50 bpm, not the profile's cold-start "
                + "60 that made an awake evening pass the awake test")
        assertTest(
            AnalyzeSleepUseCase.restingHeartRate(
                from: night(hours: 1, awake: 70, asleep: 62)) == 62,
            "…and the estimate follows the data rather than a constant")
        assertTest(
            AnalyzeSleepUseCase.restingHeartRate(
                from: Array(night(hours: 1, awake: 70, asleep: 50).prefix(1_799))) == nil,
            "A window shorter than thirty minutes has no estimate, so the profile remains the "
                + "fallback rather than a handful of beats becoming a threshold")
        assertTest(
            AnalyzeSleepUseCase.restingHeartRate(
                from: night(hours: 1, awake: 120, asleep: 120)) == nil,
            "…and an implausible 120 bpm window is refused rather than accepted as a person's resting "
                + "rate")
    }
}
