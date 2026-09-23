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
