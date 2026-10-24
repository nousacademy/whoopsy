import Foundation

/// When the app is allowed to talk to its sync API.
///
/// **One window, once a day, and the window is a rate limit rather than a preference.** Every write
/// the phone makes used to mirror immediately when the destination was `.cloud`, including step rows
/// written once a second while the strap was moving; the deployment's call budget does not survive
/// that. The rule now is: local writes are always immediate, and the API is called **once per Eastern
/// day, at or after 18:00**. The window stays open until midnight so a run that starts at 18:00 cannot
/// be cut off halfway through seven resources.
///
/// **Eastern rather than the phone's zone**, because the owner asked for 6 PM EST and a phone that
/// travels should not carry the window with it. `America/New_York` handles the DST shift; the hour is
/// still 6 PM on the wall.
///
/// The type is pure so the runner can assert every boundary without a clock, a database or a network.
public enum SyncSchedule {

    /// The window's zone. `America/New_York` rather than a fixed `-05:00`, so 6 PM remains 6 PM across
    /// daylight saving.
    public static let timeZone = TimeZone(identifier: "America/New_York") ?? .current

    /// The first hour calls are allowed, on the Eastern wall clock.
    public static let windowStartHour = 18

    public static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Whether the API may be called at `now`: 18:00 through 23:59:59 Eastern.
    ///
    /// A closed window is not an outage. The client throws `CloudSyncError.outsideWindow`, and every
    /// reader degrades to this phone without marking the day unavailable — the database is fine; the
    /// app is simply not calling it yet.
    public static func isOpen(now: Date = Date()) -> Bool {
        calendar().component(.hour, from: now) >= windowStartHour
    }

    /// The Eastern day key for an instant, snapped to midnight there.
    public static func dayKey(for date: Date) -> Date {
        calendar().startOfDay(for: date)
    }

    /// Whether today's run is still owed.
    ///
    /// **At or after 18:00, and the stored day is older than today's.** A run at 18:00 marks today;
    /// a second launch at 21:00 finds today marked and does nothing. Before 18:00 the answer is always
    /// false — the window has not opened, so there is nothing a caller could do with a `true`.
    public static func isDue(lastRunDay: Date?, now: Date = Date()) -> Bool {
        guard isOpen(now: now) else { return false }
        guard let lastRunDay else { return true }
        return dayKey(for: now) > dayKey(for: lastRunDay)
    }

    /// The next 18:00 Eastern strictly after `now`, which is what a running app sleeps until.
    ///
    /// Built with `date(bySettingHour:)` rather than by adding hours to midnight: on a spring-forward
    /// day "midnight + 18 h" is 19:00 on the wall, while the intent is the clock time.
    public static func nextWindowStart(after now: Date = Date()) -> Date {
        let calendar = calendar()
        let today = calendar.startOfDay(for: now)
        let todayWindow = calendar.date(
            bySettingHour: windowStartHour, minute: 0, second: 0, of: today) ?? today
        if now < todayWindow { return todayWindow }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return calendar.date(
            bySettingHour: windowStartHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
