import Foundation
import Whoopsy

// MARK: - 22.1 The once-a-day window

/// The schedule is the whole of the call-rate policy, so its edges are asserted rather than trusted.
///
/// **The window is Eastern, not the phone's zone.** The owner asked for 6 PM EST and a phone that
/// travels should not carry the window with it; `America/New_York` keeps the wall clock at 6 PM across
/// daylight saving. The tests construct dates in that calendar so they do not depend on where the
/// machine runs.
enum SyncScheduleTests {
    static func run() {
        let calendar = SyncSchedule.calendar()
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(
                from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute))!
        }

        let before = date(2026, 10, 22, 17, 59)
        let opening = date(2026, 10, 22, 18, 0)
        let late = date(2026, 10, 22, 23, 59)
        let midnight = date(2026, 10, 23, 0, 0)

        assertTest(
            !SyncSchedule.isOpen(now: before) && SyncSchedule.isOpen(now: opening)
                && SyncSchedule.isOpen(now: late) && !SyncSchedule.isOpen(now: midnight),
            "The API window opens at 18:00 Eastern, stays open through 23:59, and is closed before "
                + "18:00 and after midnight")

        assertTest(
            SyncSchedule.isDue(lastRunDay: nil, now: opening),
            "A day with no successful run is owed one once the window opens")
        assertTest(
            !SyncSchedule.isDue(lastRunDay: opening, now: late),
            "…and a run already marked today is not repeated later the same evening")
        assertTest(
            !SyncSchedule.isDue(lastRunDay: date(2026, 10, 21, 18), now: before),
            "Before the window opens, yesterday's run is not treated as due — there is nothing a "
                + "caller could do with a true")
        assertTest(
            SyncSchedule.isDue(lastRunDay: date(2026, 10, 21, 18), now: opening),
            "…but once it opens, a marker older than today is due")

        assertTest(
            SyncSchedule.nextWindowStart(after: date(2026, 10, 22, 9)) == opening,
            "The next window from the morning is 18:00 that day")
        assertTest(
            SyncSchedule.nextWindowStart(after: date(2026, 10, 22, 20)) == date(2026, 10, 23, 18),
            "…and from the evening it is 18:00 the next day")

        // A spring-forward 18:00 is still 18:00 on the wall. Built through `date(bySettingHour:)` so
        // the clock time is the intent rather than a count of elapsed hours from midnight.
        assertTest(
            SyncSchedule.isOpen(now: date(2027, 3, 14, 18)),
            "…and 6 PM stays 6 PM across the spring-forward wall")
    }
}
