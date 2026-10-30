import Foundation
import Whoopsy

// MARK: - 14. The steps trend page's series

/// `StepsTrend` — what the steps page plots, what its average is taken over, and how the axis is set.
///
/// Three rules here are invisible in a screenshot of a good week: an unmeasured day is a **gap**
/// rather than a zero, the mean is over measured days only, and the axis ceiling is a round number
/// above the data rather than the data's own maximum.
enum StepsTrendTests {
    static func run() async throws {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
        }
        func measured(_ offset: Int, _ count: Int) -> StepCount {
            StepCount(date: day(offset), stepCount: count, measuredSeconds: 3_600)
        }

        // MARK: A week: gaps, the mean, and a measured zero

        let weekRows = [
            measured(-6, 8_000),
            measured(-5, 12_156),
            // -4 and -3 unmeasured: no row at all.
            StepCount(date: day(-2), stepCount: 0, measuredSeconds: 3_600),  // a real zero
            // -1 has a row that measured nothing: reader tolerance, and it must be a gap too.
            StepCount(date: day(-1), stepCount: 9_999, measuredSeconds: 0),
        ]
        let week = StepsTrend.make(rows: weekRows, anchor: anchor, period: .week, calendar: calendar)

        assertTest(
            week.points.count == 7 && week.points.last?.date == anchor,
            "A week is seven slots ending on the anchor, so the newest bar is the day the page opened on")

        assertTest(
            week.points.compactMap(\.value).count == 3,
            "…with three of the seven slots carrying a value: two rows, plus the measured zero, and "
                + "the row whose measured span is zero is a gap rather than a 9,999 "
                + "(\(week.points.compactMap(\.value)))")

        assertTest(
            week.points[2].value == nil && week.points[3].value == nil && week.points[4].value == 0,
            "…an unmeasured day draws no bar, while a measured day of no walking draws a real `0` — "
                + "the distinction `StepCount.measuredStepCount` exists to keep")

        let weekMean: Int = Int(((8_000.0 + 12_156.0 + 0.0) / 3.0).rounded())
        assertTest(
            week.measuredSlots == 3,
            "Three of the week's seven slots were measured — the count the average is taken over")
        assertTest(
            week.average == weekMean,
            "The mean is taken over the measured slots only — dividing by the whole week would call "
                + "four unworn days a day of no walking (\(String(describing: week.average)) vs "
                + "\(weekMean))")

        assertTest(
            week.axisMaximum == 15_000,
            "The axis tops out at the next 5,000 above the tallest bar (12,156 → 15,000), not at the "
                + "bar itself — an axis whose ceiling is the data makes every window look full")

        assertTest(
            week.points.allSatisfy { $0.label != nil },
            "A seven-bar chart labels every bar; the weekday is what makes the columns readable")

        assertTest(
            StepsTrend.make(rows: [], anchor: anchor, period: .week, calendar: calendar).average == nil,
            "A window with nothing measured has no average — not a zero")

        assertTest(
            StepsTrend.make(rows: [], anchor: anchor, period: .week, calendar: calendar).axisMaximum
                == StepsTrend.minimumAxisMaximum,
            "…and still draws an axis, so an empty window keeps the page's shape")

        // MARK: A month, and the labels that keep it readable

        let month = StepsTrend.make(
            rows: (0..<30).map { measured(-$0, 5_000) }, anchor: anchor, period: .month,
            calendar: calendar)
        assertTest(
            month.points.count == 30 && month.points.first?.date == day(-29),
            "A month is thirty bars ending on the anchor")
        assertTest(
            (month.points.filter { $0.label != nil }.count) < 30,
            "…and not every bar is labelled: thirty figures under thirty bars is a wall of numbers, "
                + "so the axis labels every fifth day and the last")

        // MARK: Six months, in weeks

        // Both rows inside the anchor's own week, so the last bar is deterministic whatever weekday
        // the fixed anchor happens to fall on.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        let inWeek = [
            StepCount(date: weekStart, stepCount: 6_000, measuredSeconds: 3_600),
            StepCount(
                date: calendar.date(byAdding: .day, value: 1, to: weekStart) ?? weekStart,
                stepCount: 2_000, measuredSeconds: 3_600),
        ]
        let sixMonths = StepsTrend.make(
            rows: inWeek, anchor: anchor, period: .sixMonths, calendar: calendar)
        assertTest(
            sixMonths.points.count >= 26 && sixMonths.points.count <= 27,
            "Six months plots one bar per week rather than 182 daily bars — a weekly mean is a figure "
                + "a phone-width chart can actually draw (\(sixMonths.points.count) bars)")
        assertTest(
            sixMonths.points.last?.value == 4_000,
            "…and the newest bar is the mean of its week's measured days, not their sum "
                + "(\(String(describing: sixMonths.points.last?.value)))")

        assertTest(
            sixMonths.measuredSlots == 1,
            "A week counts as one measured slot, so the average above a six-month window is a mean of "
                + "weeks rather than a mean of days wearing a week's label")
    }
}
