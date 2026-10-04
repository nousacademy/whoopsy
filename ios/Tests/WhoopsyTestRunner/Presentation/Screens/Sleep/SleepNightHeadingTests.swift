import Foundation
import Whoopsy

enum SleepNightHeadingTests {
    static func run() async throws {
        // ── 6. The night's heading ───────────────────────────────────────────────────────────────────
        //
        // The one string on this screen with a branch in it, and the branch is a calendar-day question
        // rather than an instant one. Every fixture here is built in `Calendar.current` and the day is
        // named by `formattedShortDate()`, so nothing below depends on the device's time zone: the block
        // asserts the *shape* — today replaces the date, any other day is the date — and never the letters
        // `Wed, Aug 5`, which are only right in an English locale.
        let headingCalendar = Calendar.current
        func headingInstant(day: Int, hour: Int, minute: Int = 0) -> Date {
            headingCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
        }

        let headingDay = headingInstant(day: 5, hour: 12)
        let sameDayLate = headingInstant(day: 5, hour: 23, minute: 59)
        let nextDayEarly = headingInstant(day: 6, hour: 0, minute: 1)

        assertTest(
            SleepNightHeading.title == "Last Night's Sleep",
            "The heading over the hours-of-sleep card reads \(SleepNightHeading.title)")

        assertTest(
            SleepNightHeading.subtitle(for: headingDay, now: headingDay)
                == "Today vs. prior \(RecoveryScoring.baselineWindowDays) days",
            "On the day the user is having, the heading's date half is the word Today rather than the date "
                + "— and the window is the defaulted constant rather than a literal "
                + "(got \(SleepNightHeading.subtitle(for: headingDay, now: headingDay)))")

        // The pair that pins the rule as a *calendar-day* comparison. Either half alone passes on the
        // wrong implementation: a raw `date == now` is false at both instants, and a comparison on the
        // instant would print the date at 23:59 on the very day it is today.
        assertTest(
            SleepNightHeading.subtitle(for: headingDay, now: sameDayLate).hasPrefix("Today"),
            "…and it is still Today at 23:59, because the test is on the day and not on the instant")
        assertTest(
            !SleepNightHeading.subtitle(for: headingDay, now: nextDayEarly).hasPrefix("Today"),
            "…while at 00:01 the next morning the same day is a date again, which is what keeps the word "
                + "from being a statement about how recently the app was opened")

        assertTest(
            SleepNightHeading.subtitle(for: headingDay, now: nextDayEarly)
                == "\(headingDay.formattedShortDate()) vs. prior \(RecoveryScoring.baselineWindowDays) days",
            "A past night is named by its own date, in the app's one short-date form, over the same window")
        assertTest(
            !SleepNightHeading.subtitle(for: headingDay, now: headingDay).contains(
                headingDay.formattedShortDate()),
            "…and Today *replaces* that date rather than joining it, so the two can never both appear")

        assertTest(
            SleepNightHeading.subtitle(for: headingDay, windowDays: 7, now: headingDay)
                == "Today vs. prior 7 days",
            "The window is the parameter and not a constant baked into the sentence — a caller that asks "
                + "for a different window gets a different claim rather than the same one")

        assertTest(
            SleepNightHeading.spoken(for: headingDay, now: headingDay)
                == "Last Night's Sleep, Today vs. prior \(RecoveryScoring.baselineWindowDays) days",
            "The heading and its subtitle are announced as one sentence, so a listener is not left holding "
                + "the title while the date arrives on its own")

    }
}
