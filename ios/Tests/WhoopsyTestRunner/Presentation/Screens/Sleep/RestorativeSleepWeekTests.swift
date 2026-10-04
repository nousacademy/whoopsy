import Foundation
import Whoopsy

enum RestorativeSleepWeekTests {
    static func run() async throws {
        do {
            // ── The restorative-sleep week ────────────────────────────────────────────────────────────
            //
            // The one stacked bar chart in the app, and the only chart here whose axis **must** reach
            // zero: a bar's height is its value, so a foot anywhere else draws every column as a
            // proportion of a range nobody named. That is the assertion this block is built around, and
            // the runner has no renderer — `RestorativeSleepWeek` is a type rather than logic in the view
            // for exactly that reason.

            /// A night carrying a stated deep/REM split, with an hour of light sleep beside it so the
            /// night is a whole one. `TypicalRangeTests.durationed` is the same shape with the split at zero.
            func restorative(dayOffset: Int, deep: TimeInterval, rem: TimeInterval) -> SleepSession {
                let day = Calendar.current.startOfDay(
                    for: Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!)
                let onset = day.addingTimeInterval(-8 * 3600)
                return SleepSession(
                    date: day,
                    startTime: onset,
                    endTime: onset.addingTimeInterval(deep + rem + 3600),
                    targetSleepNeedSeconds: 28800,
                    lightSleepSeconds: 3600,
                    deepSleepSeconds: deep,
                    remSleepSeconds: rem,
                    awakeSeconds: 0)
            }

            // 1:30 deep + 1:15 REM is a 2:45 night, and 2:00 + 2:00 is a 4:00 one. The two totals are
            // chosen so the axis has a whole-hour span to fit: the discriminating half of the foot
            // assertion below needs a week whose totals alone would fit at a different step.
            let restorativeWeek = MetricWeek(
                endingOn: TypicalRangeTests.weekAnchor,
                sleep: [
                    restorative(dayOffset: 0, deep: 7200, rem: 7200),  // 4:00 restorative
                    restorative(dayOffset: 1, deep: 5400, rem: 4500),  // 2:45 restorative
                ])

            if let series = RestorativeSleepWeek(week: restorativeWeek) {
                assertTest(
                    series.nights.map(\.slot) == [5, 6],
                    "The two nights plot in slot order, the anchor's own night last — so the column under "
                        + "the chip is the day the page is showing (got \(series.nights.map(\.slot)))")
                assertTest(
                    series.nights.map(\.deepSeconds) == [5400, 7200]
                        && series.nights.map(\.remSeconds) == [4500, 7200],
                    "…and each night carries its two stages as stored rather than a ratio, which is what "
                        + "lets the stack's two bands be drawn at the night's own proportions")
                assertTest(
                    series.nights.map(\.totalSeconds) == [9900, 14400]
                        && series.nights.map(\.totalHours) == [2.75, 4.0],
                    "…and the figure over each column is their sum, `SleepSession`'s own restorative "
                        + "total, with no third stored field free to disagree with the two bands under it "
                        + "(got \(series.nights.map(\.totalSeconds)))")
                assertTest(
                    series.axis.lowerBound == 0 && series.axis.upperBound == 4
                        && series.axis.gridLines == [1, 2, 3],
                    "The axis' foot is **zero**, which is the one thing this chart needs and the two "
                        + "fitted axes beside it deliberately refuse: a bar's height is its value, so a "
                        + "foot anywhere else draws every column as a proportion of a range nobody named. "
                        + "Zero is handed to the fit as a value rather than forced as a bound, so the "
                        + "ladder still picks the step (got "
                        + "\(series.axis.lowerBound)–\(series.axis.upperBound), "
                        + "\(series.axis.gridLines))")
                assertTest(
                    FittedAxis(values: series.nights.map(\.totalHours))?.lowerBound == 2,
                    "…and that is not the axis the totals alone would give: fitted to them the plot "
                        + "starts at 2h, which for a line chart of the same week is merely a tight frame "
                        + "and for a bar chart is a scale that no bar's height means anything on")
                assertTest(
                    TypicalRangeTests.near(series.axis.fraction(2.75), 0.6875)
                        && TypicalRangeTests.near(
                            (FittedAxis(values: series.nights.map(\.totalHours))?.fraction(2.75)) ?? 0,
                            0.375),
                    "…and the consequence is the drawn height, not a label: the 2:45 night is 0.6875 of "
                        + "the bars' axis and 0.375 of the totals-only one, so a chart drawn against the "
                        + "second would state it as barely more than half what it is")
                assertTest(
                    series.spokenSentence
                        == "Restorative sleep for the last seven days, 2 of 7 nights measured, "
                            + "from 2h 45m to 4h 0m",
                    "…and the spoken sentence counts the nights it draws and speaks the span in the "
                        + "duration form rather than the compact one the columns print (got "
                        + "\"\(series.spokenSentence)\")")
            } else {
                assertTest(false, "A week of two nights with a stated split produced no series")
            }

            // A night of unbroken light sleep is a **zero and not an absence** — the two fields are nil
            // for a day with no classified night and non-nil for a night the classifier read, so a night
            // with no deep and no REM in it arrives here as `0 + 0`. One such night is in the bundled
            // export (2024-12-10), which is what makes this a case to handle rather than a hypothetical.
            let lightOnly = MetricWeek(
                endingOn: TypicalRangeTests.weekAnchor,
                sleep: [
                    restorative(dayOffset: 0, deep: 5400, rem: 4500),
                    restorative(dayOffset: 1, deep: 0, rem: 0),
                ])
            assertTest(
                RestorativeSleepWeek(week: lightOnly)?.nights.map(\.totalSeconds) == [0, 9900],
                "A night whose deep and REM are both zero still plots, as a column carrying no bar and "
                    + "the figure `0:00` — the same reading the typical-range card above prints for that "
                    + "night, and not a dropped column")
            assertTest(
                RestorativeSleepWeek(week: MetricWeek(
                    endingOn: TypicalRangeTests.weekAnchor,
                    sleep: [restorative(dayOffset: 0, deep: 0, rem: 0)])) == nil,
                "…but a week in which no night has anything to stack draws no card at all, because seven "
                    + "zero-height columns are not a picture of a week")
            assertTest(
                RestorativeSleepWeek(week: MetricWeek(endingOn: TypicalRangeTests.weekAnchor)) == nil,
                "…and a week with no nights is absent for the same reason, not an empty plot — the rule "
                    + "every chart in this app follows")
            assertTest(
                RestorativeSleepWeek(week: MetricWeek(
                    endingOn: TypicalRangeTests.weekAnchor,
                    sleep: [restorative(dayOffset: 0, deep: 600, rem: 300)])) == nil,
                "A week whose tallest night is under half an hour of restorative sleep is **also** "
                    + "absent, and that is not the same rule: `FittedAxis` widens a range under half a "
                    + "unit to `value ± 1`, which with zero among the values puts the foot an hour below "
                    + "zero — and a bar drawn against that axis takes most of its height from the empty "
                    + "range beneath it, so a two-minute night and a twenty-minute one draw alike")
            assertTest(
                MetricWeek(endingOn: TypicalRangeTests.weekAnchor).days.allSatisfy {
                    $0.deepSleepSeconds == nil && $0.remSleepSeconds == nil
                },
                "A day with no classified night carries neither stage, which is the absence the chart's "
                    + "`nil` reads through")

        }
    }
}
