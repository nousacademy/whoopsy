import Foundation

/// One displayed month laid out as whole weeks, together with the header row that must agree with it.
///
/// The invariant this type exists to make structural is that `weekdaySymbols` and `leadingBlanks` are
/// two views of **one** rotation. Column `i` is always `symbols[(firstWeekday - 1 + i) % 7]`, and
/// `leadingBlanks` is the offset that puts the 1st in the column whose symbol is its own weekday.
/// Both are computed from the same `calendar.firstWeekday`, so a Monday-first locale rotates the
/// header and shifts the blanks together and there is no second convention for a later edit to
/// introduce.
///
/// The trap this avoids is the natural-looking `let blanks = weekdayOfFirst - 1`, which is correct
/// only where the week starts on Sunday and silently shifts every day one column right everywhere
/// else — a header of `MON … SUN` over a grid still laid out from Sunday, with nothing on screen
/// saying so.
///
/// The shape comes from the calendar and never from the data: a month with nothing stored is a full
/// grid of grey days, not a shorter one. `MetricWeek` makes the same choice for the same reason — a
/// shape assembled from the rows slides a gap into every later slot.
///
/// `Calendar.current` is used rather than an injected calendar, and there is deliberately no
/// parameter for one on the model. The database's day keys are `Calendar.current.startOfDay`
/// (`Date.startOfDay`, and `LocalDatabaseManager.save*` snapping centrally), so this grid joins
/// against those keys; a calendar from another zone would not shift the grid, it would fail to match
/// the rows inside it and draw a month of grey. `MetricWeek` documents the same decision.
public struct MonthGrid: Equatable, Sendable {
    /// Midnight on the 1st of the displayed month.
    public let month: Date
    /// Seven weekday abbreviations, rotated so element 0 is the calendar's first weekday.
    ///
    /// From `shortWeekdaySymbols` and not `veryShortWeekdaySymbols`: the very short set is
    /// `["S", "M", "T", "W", "T", "F", "S"]`, in which three of the seven are indistinguishable on
    /// screen and two are identical as accessible names.
    public let weekdaySymbols: [String]
    /// How many blanks precede the 1st.
    public let leadingBlanks: Int
    /// Midnight on each day of the month, ascending — exactly as many as the month has days.
    public let days: [Date]
    /// The rows to draw: `leadingBlanks` nils, then every day, padded to a whole number of weeks.
    public let cells: [Date?]

    /// The grid for the month containing `monthAnchor`, or `nil` if this calendar cannot describe a
    /// month at all.
    public static func make(for monthAnchor: Date, calendar: Calendar = .current) -> MonthGrid? {
        // Resolved once. `Calendar.current` is re-read on every access, so a region or time zone
        // change mid-computation could otherwise build the header against one calendar and the
        // blanks against another.
        let components = calendar.dateComponents([.year, .month], from: monthAnchor)
        guard let first = calendar.date(from: components),
              // `range` is optional by contract, and nil means this calendar cannot answer the
              // question. The answer is then no grid — never `?? 30`, which would draw a confident
              // 30-day month out of a calendar that had just said it did not know.
              let range = calendar.range(of: .day, in: .month, for: first)
        else { return nil }

        let start = calendar.startOfDay(for: first)
        // `byAdding: .day` and never `addingTimeInterval(86_400)`: a DST transition inside the month
        // makes the second form repeat or skip a day number.
        let days = (0..<range.count).map { offset in
            calendar.date(byAdding: .day, value: offset, to: start) ?? start
        }

        let symbols = calendar.shortWeekdaySymbols
        let rotation = calendar.firstWeekday - 1
        let rotated = Array(symbols[rotation...] + symbols[..<rotation])

        // `weekday` and `firstWeekday` are both 1...7 with 1 meaning Sunday, so this is one
        // subtraction rather than two conventions meeting. The `+ 7) % 7` is what makes a month
        // beginning on the calendar's own first weekday come out as zero blanks rather than seven.
        let blanks = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: blanks)
        cells.append(contentsOf: days.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }

        return MonthGrid(
            month: start, weekdaySymbols: rotated, leadingBlanks: blanks, days: days, cells: cells)
    }
}
