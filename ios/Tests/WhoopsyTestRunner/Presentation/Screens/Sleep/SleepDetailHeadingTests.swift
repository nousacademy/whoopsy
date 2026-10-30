import Foundation
import Whoopsy

/// The `SLEEP` row's page heading: `SLEEP` over the night's own clock span.
///
/// Its sibling `SleepNightHeadingTests` pins the *performance* page's heading (`Last Night's Sleep` over
/// `Today vs. prior 30 days`), which the sleep ring opens. The two pages have two headings, so they have
/// two blocks.
enum SleepDetailHeadingTests {
    static func run() async throws {
        let calendar = Calendar.current
        func instant(day: Int, hour: Int, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
        }

        let day = instant(day: 5, hour: 12)
        let sameDayLate = instant(day: 5, hour: 23, minute: 59)
        let nextDayEarly = instant(day: 6, hour: 0, minute: 1)
        let start = instant(day: 5, hour: 1, minute: 29)
        let end = instant(day: 5, hour: 8, minute: 35)
        let span = "\(start.formattedHourMinute()) to \(end.formattedHourMinute())"

        assertTest(
            SleepDetailHeading.title == "SLEEP",
            "The page's heading is the reference's word — the moon beside it is the view's, so this is "
                + "the string alone (got \(SleepDetailHeading.title))")

        assertTest(
            SleepDetailHeading.subtitle(start: start, end: end, on: day, now: day) == span,
            "On the night the user is having, the subtitle is the night's own clock span and nothing "
                + "else — the reference's second line")

        // The pair that pins the rule as a *calendar-day* comparison. Either half alone passes on the
        // wrong implementation: a raw `date == now` is false at both instants, and a comparison on the
        // instant would print the date at 23:59 on the very day it is today.
        assertTest(
            SleepDetailHeading.subtitle(start: start, end: end, on: day, now: sameDayLate) == span,
            "…and it is still just the span at 23:59, because the test is on the day and not on the "
                + "instant")
        assertTest(
            SleepDetailHeading.subtitle(start: start, end: end, on: day, now: nextDayEarly)
                == "\(day.formattedShortDate()) · \(span)",
            "…while at 00:01 the next morning the same night is dated — a bare span is true of every "
                + "night in the record")

        assertTest(
            SleepDetailHeading.spoken(start: start, end: end, on: day, now: day) == "SLEEP, \(span)",
            "The heading and its subtitle are announced as one sentence, so a listener is not left "
                + "holding the title while the span arrives on its own")

        assertTest(
            SleepDetailHeading.subtitle(start: start, end: end, on: day, now: day)
                == "\(start.formattedHourMinute()) to \(end.formattedHourMinute())",
            "…and both ends are the chart's own clock format rather than a second one written here")
    }
}
