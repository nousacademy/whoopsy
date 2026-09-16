import Foundation

extension Date {
    public var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    public var endOfDay: Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfDay) ?? self
    }

    public func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    public func formattedShortDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: self)
    }

    public func formattedHourMinute() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: self)
    }

    /// `"11:54 PM"` from a count of minutes past midnight, for a chart that has clock times but no
    /// date to hang them on.
    ///
    /// The sleep-consistency chart's axis is night-clock minutes — a position in the model's own
    /// shifted frame — so its five ticks and its two callouts are the only times on that card, and
    /// there is no `Date` anywhere near them to format. Rebuilt here rather than at the call site
    /// because the twelve-hour rule (a `0` hour is `12 AM`, an hour past noon is `1 PM`) is a
    /// formatting decision, and it belongs with the other four in this file.
    ///
    /// **The minutes are printed only when they are not zero.** `"7 PM"` and `"11:54 PM"` are the two
    /// strings that card needs and they are one rule apart: a tick on a whole-hour axis is a time of
    /// night, where `:00` is three characters of noise repeated five times down a 40pt gutter, while a
    /// callout is a mean that lands on a minute and has to print it. The alternative — two formatters,
    /// one of them stripping a suffix — is the same rule written twice.
    ///
    /// A minute past midnight is `12 AM` and a minute past noon is `12 PM`, which is why the hour is
    /// taken modulo twelve rather than from the 24-hour value.
    public static func formattedClock(minutesOfDay: Double) -> String {
        var total = Int(minutesOfDay.rounded())
        total = ((total % 1440) + 1440) % 1440
        let hour24 = total / 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let meridiem = hour24 < 12 ? "AM" : "PM"

        guard total % 60 != 0 else { return String(format: "%d %@", hour12, meridiem) }
        return String(format: "%d:%02d %@", hour12, total % 60, meridiem)
    }

    /// `"6 AM"`. The Stress Monitor chart's axis, where the hour is the whole resolution — the
    /// minutes on a between-the-hours tick would be noise, and there are none to show anyway.
    public func formattedHour() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter.string(from: self)
    }

    /// `"Sat"`. Used where a time range crosses a day boundary and the date alone would be ambiguous —
    /// a session from 11:19 PM to 7:25 AM is on two calendar days, and the range cannot say which
    /// without it.
    public func formattedWeekdayAbbreviation() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: self)
    }

    /// `"11"`. The Strain & Recovery chart's second axis label, under the weekday — the weekday alone
    /// repeats across a seven-day window's neighbours, and a bare day number alone cannot say which
    /// month. No ordinal suffix: the reference has none, and "11th" is wider than the tick.
    public func formattedDayOfMonth() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: self)
    }
}
