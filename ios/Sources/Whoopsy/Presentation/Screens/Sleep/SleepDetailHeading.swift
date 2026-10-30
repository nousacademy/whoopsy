import Foundation

/// The sleep detail page's heading — the one the `SLEEP` row opens: the word `SLEEP`, and the line
/// beneath it naming the night's window.
///
/// **It is the reference's header, measured off it rather than invented**: a crescent, `SLEEP`, and
/// `1:29 AM to 8:35 AM` — the night's own clock span, which is the one thing on a sleep page a reader
/// checks first against the night they remember.
///
/// **It is a second type rather than a second function on `SleepNightHeading`**, and that is the split
/// the two pages made: `SleepNightHeading` is the *performance* page's heading (`Last Night's Sleep`
/// over `Today vs. prior 30 days`), which the sleep ring opens and which the user asked not to change;
/// this is the shorter page's. One type carrying two titles would be a page's name decided by which
/// function a caller happened to call.
///
/// **It is a type rather than two `Text` views for the reason every rule on this screen is.** The test
/// runner has no renderer, so a string built inside a `body` is a string nothing can assert — and the
/// span's date half has more than one answer. Today's night is just its span; a past night carries its
/// date first, because a screen opened on a night from three weeks ago has to say which one it is
/// showing, and `1:29 AM to 8:35 AM` alone would be true of every night in the record. That decision is
/// `DayBarRules.isToday`, the app's single answer to "is this day today", which is a **calendar-day**
/// comparison and not an instant one.
public enum SleepDetailHeading {

    /// The heading, in the reference's word. The moon beside it is the view's, not this string's.
    public static let title = "SLEEP"

    /// `1:29 AM to 8:35 AM`, or `Aug 5 · 1:29 AM to 8:35 AM` on a night that is not today's.
    ///
    /// The two ends are the session's own, through `formattedHourMinute()` — the same formatter
    /// `HoursOfSleepChartView` labels its axis ends with, so the line above the chart and the labels
    /// beneath it cannot print one night's span two ways.
    public static func subtitle(
        start: Date,
        end: Date,
        on date: Date,
        now: Date = Date()
    ) -> String {
        let span = "\(start.formattedHourMinute()) to \(end.formattedHourMinute())"
        guard !DayBarRules.isToday(date, now: now) else { return span }
        return "\(date.formattedShortDate()) · \(span)"
    }

    /// The heading and its subtitle as one sentence.
    public static func spoken(
        start: Date,
        end: Date,
        on date: Date,
        now: Date = Date()
    ) -> String {
        "\(title), \(subtitle(start: start, end: end, on: date, now: now))"
    }
}
