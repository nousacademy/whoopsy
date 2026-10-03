import Foundation

/// The two date rules the shared day bar applies, named so they can be asserted.
///
/// They live here rather than inline in `DayNavigationBar`'s body because the test runner has no
/// renderer: a rule written into a view is a rule nothing can check, and these two are the whole of
/// the bar's new behaviour. `now` is a parameter for the same reason — a test that has to wait for
/// the clock, or hardcode a date, is a test that goes red on its own.
///
/// Every comparison is on `startOfDay`, never on the instant. `selectedDate` is initialised to
/// `Date()`, so an instant comparison would call "today" true for exactly one moment of today and
/// false for the other 86,399 seconds — the bar would print the date instead of `TODAY` a
/// microsecond after it was built.
public enum DayBarRules {

    /// Whether this day is the calendar day it is now.
    public static func isToday(_ date: Date, now: Date = Date()) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: now)
    }

    /// Whether this day has not happened yet.
    ///
    /// A day-key test, not `date > Date()`: that instant form calls 09:00 today "past" and
    /// 00:00:00.000 today "future", and neither is what the calendar means by the future.
    public static func isFuture(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
    }

    /// Whether the bar may step forward from this day.
    ///
    /// False on today **and on anything after it**. Written as `isToday || isFuture` rather than the
    /// shorter `!isToday` because those differ on exactly one input: a day that is already in the
    /// future. Nothing produces one today, and the bar is the wrong place to leave that dependency —
    /// `!isToday` would let a forward step out of a future day, which is how a clamp stops clamping.
    public static func canStepForward(from date: Date, now: Date = Date()) -> Bool {
        !isToday(date, now: now) && !isFuture(date, now: now)
    }

    /// The bar's centre label: `TODAY` on today, otherwise the date it already printed.
    ///
    /// The word replaces the date rather than joining it — the reference puts `TODAY` alone in the
    /// bar — so the accessible name has to carry what the eye loses; see the view.
    public static func label(for date: Date, now: Date = Date()) -> String {
        isToday(date, now: now) ? "TODAY" : date.formattedShortDate().uppercased()
    }
}
