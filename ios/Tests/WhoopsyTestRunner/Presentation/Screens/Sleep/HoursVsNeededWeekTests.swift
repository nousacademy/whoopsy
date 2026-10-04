import Foundation
import Whoopsy

enum HoursVsNeededWeekTests {
    static func run() async throws {
        do {
            // ── The hours-vs-needed week ─────────────────────────────────────────────────────────────
            //
            // The card that closes the page draws two lanes of the same quantity against **one** scale, so
            // almost everything worth asserting about it is about the join rather than the drawing: which
            // nights plot in each lane, that the two lanes are built independently, and that the axis is
            // fitted to the union rather than to whichever lane was reached for first. The runner has no
            // renderer, so the lines and the labels are unasserted; `HoursVsNeededWeek` is a type rather
            // than logic in the view for exactly that reason.

            // The two fixtures this block needs — today's snapped anchor, and a night with a stated time
            // asleep and a stated need — are statics on the section's own `TypicalRangeTests`, because the
            // three week charts below this one (the asleep total, the restorative stack and time in bed)
            // are built on the same two. They began as locals here and are now one definition rather than
            // four that could drift.

            // Two nights whose need is the higher lane on both, chosen so the union spans 6h30m–9h30m:
            // three hours, which fits inside `FittedAxis`'s four-band limit at a step of one hour.
            let comparison = MetricWeek(
                endingOn: TypicalRangeTests.weekAnchor,
                sleep: [
                    TypicalRangeTests.durationed(dayOffset: 0, asleep: 27000, need: 34200),  // 7:30 against 9:30
                    TypicalRangeTests.durationed(dayOffset: 1, asleep: 23400, need: 28800),  // 6:30 against 8:00
                ])

            if let series = HoursVsNeededWeek(week: comparison) {
                assertTest(
                    series.asleep.map(\.slot) == [5, 6] && series.need.map(\.slot) == [5, 6],
                    "Both lanes plot the same two nights, in slot order — the anchor is slot 6, so a "
                        + "night filed under today lands in the last column (got "
                        + "\(series.asleep.map(\.slot)) asleep, \(series.need.map(\.slot)) need)")
                assertTest(
                    series.asleep.map(\.seconds) == [23400, 27000]
                        && series.need.map(\.seconds) == [28800, 34200],
                    "…and each lane carries the night's own stored seconds rather than a rounded hour "
                        + "count, which is what lets the label print the same clock reading the card "
                        + "above the chart prints")
                assertTest(
                    series.axis.lowerBound == 6 && series.axis.upperBound == 10
                        && series.axis.gridLines == [7, 8, 9],
                    "The axis is fitted to the **union** of the two lanes: 6h30m to 9h30m rounds out to "
                        + "a 6–10 plot, ruled at the three whole hours inside it (got "
                        + "\(series.axis.lowerBound)–\(series.axis.upperBound), "
                        + "\(series.axis.gridLines))")
                assertTest(
                    FittedAxis(values: series.asleep.map(\.hours))?.upperBound == 8,
                    "…and that is not the axis either lane would give alone: fitted to the sleep lane "
                        + "the plot tops out at 8h, which would clamp the 9h30m need to the frame's top "
                        + "and draw it level with the 8h one on the night before. Two axes here would "
                        + "state the same shortfall as no shortfall at all")
                assertTest(
                    series.spokenSentence
                        == "Hours versus needed for the last seven days, 2 of 7 nights measured, "
                            + "from 6h 30m to 9h 30m",
                    "…and the spoken sentence counts the nights carrying both lanes and speaks the span "
                        + "in the duration form rather than the compact one the labels print (got "
                        + "\"\(series.spokenSentence)\")")
            } else {
                assertTest(false, "A week of two nights yielding both durations produced no series")
            }

            // The two lanes are built independently, and the gating is what makes that visible: a need is
            // only read off a night whose target is above zero, while the asleep total is read off the row
            // unconditionally. So a stored night with no need is a sleep point with no need point beside
            // it — the honest picture of that row, and not a reason to drop the column.
            let needless = MetricWeek(
                endingOn: TypicalRangeTests.weekAnchor,
                sleep: [
                    TypicalRangeTests.durationed(dayOffset: 0, asleep: 27000, need: 0),
                    TypicalRangeTests.durationed(dayOffset: 1, asleep: 23400, need: 28800),
                ])
            assertTest(
                HoursVsNeededWeek(week: needless)?.asleep.map(\.slot) == [5, 6]
                    && HoursVsNeededWeek(week: needless)?.need.map(\.slot) == [5],
                "A night with no need still plots in the sleep lane and draws nothing in the need lane, "
                    + "rather than dropping the night or inventing a need for it")
            assertTest(
                HoursVsNeededWeek(week: MetricWeek(
                    endingOn: TypicalRangeTests.weekAnchor,
                    sleep: [TypicalRangeTests.durationed(dayOffset: 0, asleep: 27000, need: 0)])) == nil,
                "…but a week with no need on any night has one lane and no comparison, which is no card "
                    + "at all — the same rule every other chart here follows for a frame that would be "
                    + "drawn over nothing")
            assertTest(
                HoursVsNeededWeek(week: MetricWeek(endingOn: TypicalRangeTests.weekAnchor)) == nil,
                "…and a week with no nights is absent for the same reason, not an empty plot")

            // A gap breaks each lane's line, on the slot index rather than on the date — `WeekLineSeries`'
            // rule, and for its reason: the slots are one calendar day apart by construction, so a
            // segment drawn across a missing index would span nights the lane has no value for.
            let holed = MetricWeek(
                endingOn: TypicalRangeTests.weekAnchor,
                sleep: [
                    TypicalRangeTests.durationed(dayOffset: 0, asleep: 27000, need: 34200),
                    TypicalRangeTests.durationed(dayOffset: 1, asleep: 23400, need: 28800),
                    TypicalRangeTests.durationed(dayOffset: 3, asleep: 25200, need: 32400),
                ])
            assertTest(
                HoursVsNeededWeek(week: holed)?.asleepRuns.map { $0.map(\.slot) } == [[3], [5, 6]]
                    && HoursVsNeededWeek(week: holed)?.needRuns.map { $0.map(\.slot) } == [[3], [5, 6]],
                "A week with a night missing in the middle draws two segments per lane and never joins "
                    + "across the hole (got "
                    + "\((HoursVsNeededWeek(week: holed)?.asleepRuns ?? []).map { $0.map(\.slot) }))")
            assertTest(
                HoursVsNeededWeek(week: holed)?.axis.lowerBound == 6
                    && HoursVsNeededWeek(week: holed)?.axis.upperBound == 10,
                "…and the hole does not change the axis, which is fitted to the points that are there "
                    + "rather than to the seven columns the frame has")

        }
    }
}
