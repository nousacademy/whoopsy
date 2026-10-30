import Foundation

/// The steps trend page's series: which days plot, what each one holds, and the average above them.
///
/// ## Why this is a value and not arithmetic in the page
///
/// The same reason every other extracted rule in this app has: the runner has no renderer, so a rule
/// written into a `body` is a rule nothing can assert. Three of the rules here are worth asserting and
/// none of them is visible in a screenshot of a good week — **the average is over measured days only**,
/// **an unmeasured day is a gap and never a zero**, and **the axis ceiling is a round number the bars
/// are read against**.
///
/// ## The average, and the one way it could lie
///
/// A day with no `stepCounts` row was not measured: the strap was off, or the phone never drained that
/// day. Counting it as a zero would say the user did not walk, which is the strongest false claim a
/// step average can make — and on a gappy history it would pull the figure down by however long the
/// gaps were. So the mean is taken over `StepCount.measuredStepCount` values, and a window with none
/// has `nil` rather than `0`.
///
/// The *slots* still count the unmeasured days: the chart draws a gap where there is no bar, and the
/// page says how many of the window's days were measured, so the reader can see what the mean is taken
/// over without the model inventing a number for the rest.
public struct StepsTrend: Equatable, Sendable {

    /// The three spans the page offers. The raw values are the drawn titles.
    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case week = "W"
        case month = "M"
        case sixMonths = "6M"

        public var id: String { rawValue }

        /// How many days the window covers, and therefore what the average is taken over.
        public var dayCount: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .sixMonths: return 182
            }
        }

        /// How many bars the chart draws. `week` and `month` are one bar per day; `sixMonths` is one
        /// bar per **week**, because 182 daily bars in the width of a phone are a smear rather than a
        /// reading — and a weekly mean is a figure the reader is told the unit of by the range title.
        public var isWeekly: Bool { self == .sixMonths }

        public var barCount: Int { isWeekly ? 26 : dayCount }
    }

    /// One bar. `value` is `nil` exactly when the slot holds no measurement — a gap, never a zero.
    public struct Point: Equatable, Sendable, Identifiable {
        /// The slot's index, oldest first. Stable across reloads of the same window.
        public let id: Int
        /// The day the bar describes (for a weekly bucket, the week's first day).
        public let date: Date
        /// The drawn label under the bar, or `nil` when the axis is too dense to label every slot.
        public let label: String?
        public let value: Int?
    }

    public let period: Period
    public let points: [Point]

    /// The mean of the measured slots, or `nil` when the window holds none.
    public let average: Int?

    /// How many slots carried a measurement — the denominator the average is taken over.
    public let measuredSlots: Int

    /// The chart's top gridline. A round figure above the tallest bar, never the tallest bar itself:
    /// an axis whose ceiling is the data makes every week look full.
    public let axisMaximum: Int

    /// The window's own bounds, oldest first. The page formats these; the model decides them.
    public let windowStart: Date
    public let windowEnd: Date

    /// The smallest axis ceiling drawn. A window with no bars still draws its gridlines, so the page
    /// keeps its shape on a fresh install rather than collapsing to nothing.
    public static let minimumAxisMaximum = 10_000

    /// The gridline step every axis uses.
    public static let axisStep = 5_000

    /// Builds the trend ending on `anchor`'s day.
    ///
    /// - Parameter rows: `StepCount`s read over a window at least as wide as the period. Rows outside
    ///   the window are ignored, so a caller may read wider than it draws — the page reads a week more
    ///   than it needs so a future bucket cannot be short.
    public static func make(
        rows: [StepCount],
        anchor: Date,
        period: Period,
        calendar: Calendar = .current
    ) -> StepsTrend {
        let end = calendar.startOfDay(for: anchor)
        let start = calendar.date(byAdding: .day, value: -(period.dayCount - 1), to: end) ?? end

        let byDay = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (Date, Int)? in
                guard let value = row.measuredStepCount else { return nil }
                return (calendar.startOfDay(for: row.date), value)
            })

        let points: [Point]
        if period.isWeekly {
            points = weeklyPoints(
                byDay: byDay, start: start, end: end, calendar: calendar)
        } else {
            points = dailyPoints(byDay: byDay, start: start, end: end, period: period, calendar: calendar)
        }

        let measured = points.compactMap(\.value)
        let average = measured.isEmpty
            ? nil
            : Int((Double(measured.reduce(0, +)) / Double(measured.count)).rounded())

        let tallest = measured.max() ?? 0
        let ceiling = max(
            minimumAxisMaximum,
            Int((Double(tallest) / Double(axisStep)).rounded(.up)) * axisStep)

        return StepsTrend(
            period: period,
            points: points,
            average: average,
            measuredSlots: measured.count,
            axisMaximum: ceiling,
            windowStart: start,
            windowEnd: end)
    }

    private static func dailyPoints(
        byDay: [Date: Int],
        start: Date,
        end: Date,
        period: Period,
        calendar: Calendar
    ) -> [Point] {
        var points: [Point] = []
        var day = start
        var slot = 0
        while day <= end {
            let label: String?
            switch period {
            case .week:
                label = day.formatted(.dateTime.weekday(.abbreviated))
            case .month, .sixMonths:
                // Every fifth day and the last, so thirty bars carry an axis without a wall of text.
                let dayNumber = calendar.component(.day, from: day)
                label = (slot % 5 == 0 || calendar.isDate(day, inSameDayAs: end))
                    ? String(dayNumber) : nil
            }
            points.append(Point(id: slot, date: day, label: label, value: byDay[day]))
            slot += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    /// One bar per week, oldest first, labelled where a month turns over.
    ///
    /// The bucket is the calendar's week containing the day, and a week's value is the mean of its
    /// measured days — so the bar means "an average day that week", which is the unit the page's
    /// range title states. A week with no measured day is a gap.
    private static func weeklyPoints(
        byDay: [Date: Int],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> [Point] {
        // Align the first bucket to the week containing `start`, so every bar is a whole week.
        guard let firstWeek = calendar.dateInterval(of: .weekOfYear, for: start),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: end)
        else { return [] }

        var points: [Point] = []
        var weekStart = firstWeek.start
        var slot = 0
        while weekStart <= lastWeek.start {
            let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            var values: [Int] = []
            var day = weekStart
            while day <= weekEnd {
                if day >= start, day <= end, let value = byDay[day] { values.append(value) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }

            // Label the bucket when the month turns over inside it, so the axis names the months
            // rather than every week.
            let startMonth = calendar.component(.month, from: weekStart)
            let endMonth = calendar.component(.month, from: weekEnd)
            let label = startMonth != endMonth
                ? weekEnd.formatted(.dateTime.month(.abbreviated))
                : (slot == 0 ? weekStart.formatted(.dateTime.month(.abbreviated)) : nil)

            points.append(
                Point(
                    id: slot,
                    date: weekStart,
                    label: label,
                    value: values.isEmpty
                        ? nil
                        : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())))
            slot += 1
            guard let next = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }
        // The first bucket can start before the window; the caller draws from it, so the model's own
        // window bounds stay the days the average is over.
        return points
    }
}
