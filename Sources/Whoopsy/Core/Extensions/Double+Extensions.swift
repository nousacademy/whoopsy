import Foundation

extension Double {
    /// One decimal place, e.g. `62.5`.
    public func formattedOneDecimal() -> String {
        String(format: "%.1f", self)
    }

    /// A duration in seconds as `"2h 45m"`, e.g. `9900.0` → `"2h 45m"`, `2700.0` → `"0h 45m"`.
    public func formattedHoursMinutes() -> String {
        let totalMinutes = Int(self) / 60
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    /// A duration in seconds as `"7:10"` — hours and zero-padded minutes, no unit letters.
    ///
    /// Distinct from `formattedHoursMinutes()`, which spells the units out (`"7h 10m"`) and is for a
    /// caption that has room for them. This shape is for a reading that already sits under a unit
    /// label, where `"7h 10m"` next to `HRS` says hours twice.
    public func formattedCompactHoursMinutes() -> String {
        let totalMinutes = Int(self) / 60
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    /// A duration in seconds as `"0:15:58"` — hours, minutes and seconds, seconds zero-padded.
    ///
    /// The third shape this file holds, and it is distinct from both of the other two by what it is
    /// *for* rather than by its separator. `formattedHoursMinutes()` spells its units out and is for a
    /// caption with room for them; `formattedCompactHoursMinutes()` drops seconds because a sleep
    /// figure is hours-and-minutes and a seconds digit on a nine-hour night is noise. This one is for a
    /// figure whose whole magnitude is minutes — a workout's own length, and the time a session spent
    /// inside one heart-rate zone — where the seconds are a real part of the answer and the hours digit
    /// is usually a `0`. The reference's activity page prints exactly this: `DURATION 0:15:58`, and
    /// `ZONE 1 … 0:00:12` beneath it.
    ///
    /// The hours field is **not** padded, matching the reference: `0:15:58` and not `00:15:58`. A
    /// workout long enough to need two digits is a session this app cannot record in one sitting
    /// anyway, so the asymmetry costs nothing and copying the reference is the safer default.
    public func formattedClockDuration() -> String {
        let total = Int(max(0, self).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A duration in seconds as `"+1:44"`, with a leading `+` and never a `-`.
    ///
    /// The sleep need card's breakdown box is a list of things *added to* a base requirement, so every
    /// figure in it carries a sign — that is the reference's own convention and the only thing on the
    /// card that says the rows are increments rather than a second set of totals.
    ///
    /// **The sign is a literal `"+"` rather than a format specifier's`, and the minus case is
    /// deliberately unreachable.** No part of a need can be negative — `SleepNeedBreakdown.breakdown`
    /// refuses a debt below zero and the other part is a subtraction of one non-negative quantity from
    /// a larger one — so there is no negative value to render, and `String(format: "%+.0f")` would
    /// print `"-0:00"` for a negative zero. A `0` prints as `"+0:00"`, which is the right answer for a
    /// night in perfect sleep credit: the term is present and contributes nothing.
    public func formattedSignedCompactHoursMinutes() -> String {
        "+" + formattedCompactHoursMinutes()
    }

    /// A duration in seconds as words with units spelled out, e.g. `280860.0` → `"3 days 6 hrs"`,
    /// `52320.0` → `"14 hrs 32 min"`, `86400.0` → `"1 day"`, `1920.0` → `"32 min"`.
    ///
    /// The fourth shape this file holds, and the one that exists because a fast is the only session in
    /// this app whose length is routinely **days**. The other three are all bounded by a night or a
    /// workout: `formattedHoursMinutes()` prints `"78h 1m"` for a fast, which reads as a number nobody
    /// says out loud, and `formattedCompactHoursMinutes()` prints `"78:01"` — a figure with no unit
    /// beside it, under a `TOTAL DURATION` label that would have to supply one.
    ///
    /// **Above a day the minutes are dropped, and that is not a rounding concession.** It is what the
    /// reference does — its own `3 days 6 hrs` is exactly this formatter's output for the 78-hour fast
    /// this app ships — and it is the honest precision for a span that long: a fast's minutes are an
    /// artefact of when the user tapped, not a quantity anything reads. Below a day the minutes are
    /// kept, because there they are the part that moves.
    ///
    /// Singular forms are elided (`"1 day"`, not `"1 days"`), and a component that is exactly zero is
    /// dropped rather than printed as `"3 days 0 hrs"` — so `24 h` reads `"1 day"` and a sub-hour fast
    /// reads `"32 min"`. A span under a minute is `"0 min"`: a fast of no length is a fast of no length,
    /// and the alternative is an empty string under a label that promises a figure.
    ///
    /// **It is on `Double` and not on `TimeInterval`**, which is not a style choice: `TimeInterval` *is*
    /// `Double`, so declaring this member on both is a redeclaration error. See this file's other five.
    public func formattedDayHoursMinutes() -> String {
        let totalMinutes = Int(max(0, self)) / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        func pluralised(_ value: Int, _ singular: String, _ plural: String) -> String {
            "\(value) \(value == 1 ? singular : plural)"
        }

        guard days == 0 else {
            let day = pluralised(days, "day", "days")
            return hours == 0 ? day : "\(day) \(pluralised(hours, "hr", "hrs"))"
        }
        guard hours == 0 else {
            let hour = pluralised(hours, "hr", "hrs")
            return minutes == 0 ? hour : "\(hour) \(pluralised(minutes, "min", "min"))"
        }
        return pluralised(minutes, "min", "min")
    }

    /// Rounds to a fixed number of decimal places.
    ///
    /// Stored physiological values are rounded through here rather than with an inline
    /// `(x * 10).rounded() / 10`, which appears in several places and silently encodes a different
    /// precision at each one.
    public func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
