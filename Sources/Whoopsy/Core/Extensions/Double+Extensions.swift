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
    /// Distinct from `formattedHoursMinutes()`, which spells the units out (`"7h 10m"`) and is what
    /// the workout HUD's elapsed timer wants. This shape is for a reading that already sits under a
    /// unit label, where `"7h 10m"` next to `HRS` says hours twice.
    public func formattedCompactHoursMinutes() -> String {
        let totalMinutes = Int(self) / 60
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
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
