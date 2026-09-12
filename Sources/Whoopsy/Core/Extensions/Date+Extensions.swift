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
