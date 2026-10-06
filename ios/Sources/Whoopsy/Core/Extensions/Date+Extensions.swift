import Foundation

extension Date {
    public var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// `23:59:59` — the last **instant** of this day, which is the right end for an inclusive bound.
    ///
    /// It is the wrong end for a **half-open** one, and reaching for it there costs exactly one second
    /// per day. `getWorkouts(covering:)` and `WorkoutSession.elapsedSeconds(byEndOf:)` both ask "how much
    /// of this day" rather than "up to and including", so they want ``startOfNextDay`` — measured against
    /// the bundled fasts, the one-second under-count flips four real fast-days whose per-day elapsed
    /// lands exactly on a zone edge, drawing three of them a zone too early. The `?? self` fallback here
    /// is a further reason not to borrow it: it would return the day's own start and fabricate an
    /// elapsed of `0`.
    public var endOfDay: Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfDay) ?? self
    }

    /// Midnight at the start of the following day — the exclusive upper bound of this day.
    ///
    /// **Defined once and shared, because the two copies would drift by a second and the drift is
    /// invisible.** The covering read's SQL argument and the fasting pill's elapsed arithmetic have to
    /// agree about where a day ends, or a fast's last day and its row's zone disagree by a boundary
    /// nothing on the screen would explain.
    ///
    /// **It snaps first, and that is load-bearing rather than defensive.** `startOfDay + 1 day` and
    /// `self + 1 day` are the same instant only when `self` is already midnight. Callers pass instants:
    /// `HomeDashboardView.selectedDate` is seeded with `Date()`, so it is *today at 14:23*. `self + 1 day`
    /// would put the day's end at tomorrow 14:23 — up to 24 hours too late — so a fast still running
    /// would read more elapsed time than the day holds, a two-day in-progress fast scoring 38 h and
    /// drawing `KETOSIS` where it should draw `FAT BURNING`. On a day *after* a fast ended the `min`
    /// clamp would hide the error entirely, so the feature would silently no-op on exactly the days it
    /// exists for.
    public var startOfNextDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
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

    /// `"23 Jul 2023"` — a day named inside a sentence rather than beside a figure.
    ///
    /// It exists for the two import summaries, whose `message` states the span a file covered. Both
    /// sentences are prose read once after a button press, so the two ends want a form a reader can
    /// hold in their head — not `formattedShortDate`'s `"Sun, Jul 23"`, which drops the year and is
    /// built for a row already stamped with the day it belongs to, and not `formattedTime`'s
    /// locale-dependent style, which reorders the month and the day from region to region.
    ///
    /// **It is `en_US_POSIX` and pinned rather than `.current`, and here that is a choice rather than
    /// a bug being avoided.** These two strings go into a sentence together — *"23 Jul 2023 → 5 Oct
    /// 2026"* — and an arrow between two dates means the pair must be read as one span. A locale that
    /// writes `"23/07/2023"` makes that span a column of digits, and one that writes `"Jul 23, 2023"`
    /// moves the separator into the middle of each end. `WhoopImportSummary` writes its own report the
    /// same way, and the fixed grammar is what keeps the three files' reports reading alike.
    ///
    /// It is defined here rather than on the summaries because three files now write this grammar —
    /// `WhoopExportImporter`, `FastingImportSummary` and `InactivityImportSummary` — and it had
    /// already been copied twice before the third arrived. Both of the first two now forward to it,
    /// so their public surfaces and their callers are untouched, and the three reports cannot come to
    /// spell a day three ways.
    public func formattedImportDay() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: self)
    }
}
