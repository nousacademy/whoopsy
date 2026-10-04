import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The seven-day MetricWeek join

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeMetricWeekTests {
    static func run() async throws {
        // ---- MetricWeek: the seven-day join, and the three absence rules it applies ----
        //
        // The join is the riskiest logic in the week's chart and panels — pairing a day's strain with the
        // *same* day's recovery, and deciding which days count as measured — which is why it lives in
        // Domain where this runner can reach it rather than in a view it cannot. Fixtures are built from
        // `Calendar.current` offsets, never hardcoded dates, so the block holds on whatever day it runs.
        do {
            let calendar = Calendar.current
            let anchor = calendar.startOfDay(for: Date())
            func day(_ back: Int) -> Date {
                calendar.date(byAdding: .day, value: -back, to: anchor) ?? anchor
            }
            func days(_ count: Int) -> [Date] { (0..<count).map(day) }

            // Measured on offsets 0, 2 and 4 — deliberately not contiguous, so the holes are interior
            // rather than only at the leading edge. A week assembled from the rows it was handed would
            // come back holding three slots and no hole at all.
            let week = MetricWeek(
                endingOn: anchor,
                strain: [0, 2, 4].map {
                    StrainScore(date: day($0), score: 8.0 + Double($0), hasMeasurement: true)
                },
                recovery: [0, 2, 4].map {
                    RecoveryMetric(date: day($0), score: 60 + $0, hrvValueMs: 55, restingHeartRate: 50 + $0)
                },
                sleep: [0, 2, 4].map {
                    SleepSession(
                        date: day($0), startTime: day($0), endTime: day($0).addingTimeInterval(28800),
                        targetSleepNeedSeconds: 28800)
                })

            assertTest(
                week.days.count == MetricWeek.dayCount,
                "A week holds exactly \(MetricWeek.dayCount) slots however few days have data "
                    + "(got \(week.days.count))")
            assertTest(
                week.days.first?.date == day(6) && week.days.last?.date == anchor,
                "…oldest first and ending on the anchor, so the rightmost column is the selected day")
            assertTest(
                week.days[1].strain == nil && week.days[3].recoveryScore == nil,
                "…and a day with nothing stored is an empty slot rather than a missing one — the "
                    + "invariant that stops a gap sliding every later point one day to the left")

            // The placeholder rules, which are what the chart's absence depends on. Both rows here *exist*
            // and hold a zero; neither is a measurement.
            let placeholders = MetricWeek(
                endingOn: anchor,
                strain: [StrainScore(date: anchor, score: 0.0, hasMeasurement: false)],
                recovery: [RecoveryMetric(date: anchor, score: 0, hrvValueMs: 0, restingHeartRate: 0)])
            assertTest(
                placeholders.days.last?.strain == nil,
                "An unmeasured strain row plots nothing: its `0.0` is the reserved marker, not a rest day")
            assertTest(
                placeholders.days.last?.recoveryScore == nil
                    && placeholders.days.last?.restingHeartRate == nil,
                "…and an unmeasured recovery row yields neither a tier nor a resting heart rate")
            assertTest(
                !(placeholders.days.last?.hasAnyMeasurement ?? true),
                "…so a day holding only placeholder rows counts as unmeasured")

            // The baseline floor, asserted at both edges: two measured days have a mean, and are still not
            // a baseline.
            let twoDays = MetricWeek(
                endingOn: anchor,
                recovery: days(2).map {
                    RecoveryMetric(date: $0, score: 60, hrvValueMs: 55, restingHeartRate: 50)
                })
            assertTest(
                twoDays.restingHeartRateBaseline == nil,
                "Two measured days are below `minimumBaselineDays` and give no baseline, though their mean "
                    + "is arithmetically defined")
            let threeDays = MetricWeek(
                endingOn: anchor,
                recovery: [50, 52, 54].enumerated().map { offset, rate in
                    RecoveryMetric(
                        date: day(offset), score: 60, hrvValueMs: 55, restingHeartRate: rate)
                })
            assertTest(
                threeDays.restingHeartRateBaseline == 52,
                "…and three are a baseline, as the mean of only the measured days (got "
                    + "\(threeDays.restingHeartRateBaseline.map { "\($0)" } ?? "nil"))")

            let needs = MetricWeek(
                endingOn: anchor,
                sleep: [8.0, 9.0, 10.0].enumerated().map { offset, hours in
                    SleepSession(
                        date: day(offset), startTime: day(offset),
                        endTime: day(offset).addingTimeInterval(hours * 3600),
                        targetSleepNeedSeconds: hours * 3600)
                })
            assertTest(
                needs.sleepNeedBaselineSeconds == 32400,
                "The sleep-need baseline is the mean of the measured nights — nine hours here, not "
                    + "`UserProfile.targetSleepHours`' hard-coded 8.0 (got "
                    + "\(needs.sleepNeedBaselineSeconds.map { "\($0)" } ?? "nil"))")
            assertTest(
                MetricWeek(endingOn: anchor, sleep: []).sleepNeedBaselineSeconds == nil,
                "…and a week with no nights at all has no baseline to print")

            // ---- The HRV baseline, and the never-mix rule it has to obey ----
            //
            // The week's other two baselines average a column. This one cannot: SDNN and RMSSD are
            // different quantities on different scales, so an average across both is a statistic about
            // neither while looking exactly like a reading — the failure `RecoveryScoring` filters
            // history for, reached here by a different route.
            //
            // The week below is deliberately built so that the mixture and the narrowing give different
            // answers: three RMSSD days and two SDNN days, with the SDNN days *lower*. Averaging all five
            // would give 56.4; the correct answer is the RMSSD mean alone.
            let mixed = MetricWeek(
                endingOn: anchor,
                recovery: [
                    (0, 60.0, HRVMetric.rmssd), (1, 30.0, HRVMetric.sdnn),
                    (2, 62.0, HRVMetric.sdnn), (3, 64.0, HRVMetric.rmssd),
                    (4, 66.0, HRVMetric.rmssd),
                ].map { offset, value, metric in
                    RecoveryMetric(
                        date: day(offset), score: 60, hrvValueMs: value, hrvMetric: metric,
                        restingHeartRate: 50)
                })
            assertTest(
                mixed.hrvBaselineMetric == .rmssd,
                "The HRV baseline is narrowed to one metric — the newest measured day's, so the mean "
                    + "belongs to the same quantity as the figure printed above it (got "
                    + "\(mixed.hrvBaselineMetric.map(\.displayName) ?? "nil"))")
            assertTest(
                abs((mixed.hrvBaselineMs ?? 0) - 190.0 / 3.0) < 0.0001,
                "…and averages only that metric's days, so the two SDNN days are excluded rather than "
                    + "mixed in (got \(mixed.hrvBaselineMs.map { "\($0)" } ?? "nil"), not the "
                    + "\(mixed.days.compactMap(\.hrvValueMs).reduce(0, +) / 5) an unfiltered mean gives)")
            assertTest(
                mixed.days.last?.hrvValueMs == 60.0 && mixed.days.last?.hrvMetric == .rmssd,
                "…while the anchor's own slot still carries its reading and the metric it was measured in")

            // The other direction, and the one that would be easy to paper over: narrowing can drop a
            // week below the floor with readings present. That is a week with no *comparable* baseline,
            // and the answer is no mean — not a mean over the days that happen to be a different quantity.
            let mostlySdnn = MetricWeek(
                endingOn: anchor,
                recovery: [
                    (0, 40.0, HRVMetric.sdnn), (1, 42.0, HRVMetric.sdnn),
                    (2, 44.0, HRVMetric.sdnn), (3, 55.0, HRVMetric.rmssd),
                ].map { offset, value, metric in
                    RecoveryMetric(
                        date: day(offset), score: 60, hrvValueMs: value, hrvMetric: metric,
                        restingHeartRate: 50)
                })
            assertTest(
                mostlySdnn.hrvBaselineMs == 42.0 && mostlySdnn.hrvBaselineMetric == .sdnn,
                "A week holding both metrics baselines the newest one even when it is the minority "
                    + "(got \(mostlySdnn.hrvBaselineMs.map { "\($0)" } ?? "nil"))")
            assertTest(
                MetricWeek(
                    endingOn: anchor,
                    recovery: (0..<2).map { offset in
                        RecoveryMetric(
                            date: day(offset), score: 60, hrvValueMs: 60, restingHeartRate: 50)
                    }
                ).hrvBaselineMs == nil,
                "…and two measured days are below the floor for HRV as they are for the other two")

            // The double gate, on the panel's own field. A placeholder's `0.0` ms is this column's
            // reserved marker, and a slot must not report a metric for a reading it does not have.
            assertTest(
                placeholders.days.last?.hrvValueMs == nil
                    && placeholders.days.last?.hrvMetric == nil,
                "An unmeasured recovery row yields no HRV and no metric — the two can never disagree, "
                    + "so a slot cannot name a quantity it has no reading in")

            assertTest(
                week.day(for: day(9)) == nil && week.day(for: anchor)?.date == anchor,
                "A date outside the window has no slot rather than the nearest one, and the anchor's own "
                    + "day resolves to the last slot")

            // ---- The week charts' series, on the same narrowing ----
            //
            // `WeekLineSeries` is what `WeekLineChartView` plots, and it is a type rather than logic in
            // that view's body for the reason `DayBarRules` is: the runner has no renderer, so a rule
            // written into a `View` is a rule nothing can assert. Both rules below are ones this app has
            // already got wrong somewhere else — the mixture, and the interpolated gap.
            //
            // **The two line charts answer "which days plot" differently, and that is the whole of the
            // difference between them.** Resting heart rate is one quantity in one unit, so every measured
            // day plots and its series needs no narrowing; HRV cannot, because SDNN and RMSSD are
            // different quantities on different scales. The fixtures below are shared by both blocks
            // deliberately — the same week has to give the RHR series more points than the HRV one, or the
            // narrowing is not being applied.
            //
            // The fixtures are the two above, reused deliberately: `mixed` is already built so the
            // narrowed answer and the unfiltered one differ, which is exactly what makes it able to fail.
            // The two SDNN days in it are *measured*, and the chart must drop them anyway — a mixed week
            // plots fewer points than it has readings, which is why the count of points is not the count
            // of measured days.
            if let mixedSeries = WeekLineSeries(hrvWeek: mixed) {
                assertTest(
                    mixedSeries.points.map(\.slot) == [2, 3, 6],
                    "The HRV chart plots only the week's own metric, so a week holding both plots fewer "
                        + "points than it has readings — the two SDNN days here are measured and are "
                        + "still dropped (got slots \(mixedSeries.points.map(\.slot)), and the week's own "
                        + "quantity is "
                        + "\(mixed.hrvBaselineMetric.map(\.displayName) ?? "nil"))")
                assertTest(
                    mixedSeries.runs.map { $0.map(\.slot) } == [[2, 3], [6]],
                    "…and the line breaks at the gap the narrowing made: slots 4 and 5 are measured, in "
                        + "the other quantity, and a segment drawn across them would be a reading this "
                        + "chart never took (got \(mixedSeries.runs.map { $0.map(\.slot) }))")
            } else {
                assertTest(false, "The mixed week yields no HRV series at all, so no chart is drawn")
            }

            // The minority case, from the other fixture: narrowing to the newest metric leaves three
            // adjacent SDNN days and drops the one RMSSD day, so the series is a single unbroken run and
            // the RMSSD reading is not plotted as a collapse on an SDNN axis.
            if let sdnnSeries = WeekLineSeries(hrvWeek: mostlySdnn) {
                assertTest(
                    mostlySdnn.hrvBaselineMetric == .sdnn
                        && sdnnSeries.points.map(\.slot) == [4, 5, 6]
                        && sdnnSeries.runs.count == 1,
                    "A week whose newest reading is the minority still plots its own quantity, so the "
                        + "single RMSSD day is dropped rather than drawn on an SDNN axis (got metric "
                        + "\(mostlySdnn.hrvBaselineMetric.map(\.displayName) ?? "nil") at slots "
                        + "\(sdnnSeries.points.map(\.slot)))")
            } else {
                assertTest(false, "The mostly-SDNN week yields no HRV series at all")
            }

            // The other line chart, on the same week. Every one of `mixed`'s five days carries a resting
            // rate, so this series has five points where the HRV one has three — which is the assertion
            // that fails if anyone folds the narrowing into the shared series type and quietly drops RHR
            // days that were never in two quantities.
            if let mixedRates = WeekLineSeries(restingHeartRateWeek: mixed) {
                assertTest(
                    mixedRates.points.map(\.slot) == [2, 3, 4, 5, 6]
                        && mixedRates.runs.count == 1,
                    "The resting-heart-rate chart plots every measured day and narrows nothing, so the "
                        + "same week that gives the HRV line three points gives this one five (got slots "
                        + "\(mixedRates.points.map(\.slot)) in "
                        + "\(mixedRates.runs.count) run(s))")
                assertTest(
                    mixedRates.points.allSatisfy { $0.value == 50 },
                    "…and each point is that day's own rate rather than a mean of the week's, since a "
                        + "chart of one repeated number would draw a flat line that looks like data")
            } else {
                assertTest(false, "The week's measured days yield no resting-heart-rate series")
            }

            // A hole in the middle, which is the rule the two charts share. The day at slot 4 has no row
            // at all, so it has no rate; the line has to break there rather than join slot 3 to slot 5,
            // which would draw a reading across a day nothing measured.
            if let holedRates = WeekLineSeries(
                restingHeartRateWeek: MetricWeek(
                    endingOn: anchor,
                    recovery: [0, 1, 3, 4].map { offset in
                        RecoveryMetric(
                            date: day(offset), score: 60, hrvValueMs: 60, hrvMetric: .rmssd,
                            restingHeartRate: 50)
                    }))
            {
                assertTest(
                    holedRates.points.map(\.slot) == [2, 3, 5, 6]
                        && holedRates.runs.map { $0.map(\.slot) } == [[2, 3], [5, 6]],
                    "A day with no rate ends a run, so the line breaks at the hole rather than joining "
                        + "the days either side of it (got "
                        + "\(holedRates.runs.map { $0.map(\.slot) }))")
            } else {
                assertTest(false, "A week with four measured days yields no series")
            }

            // An unmeasured week has no series, which is what omits the card — and is not the same as an
            // empty one. Seven labelled columns with no line or bar in them is a week of zeros drawn once
            // per column, the same fabrication a point at zero would be. Asserted for all five charts,
            // because each card is omitted on its own series and one of them going non-optional would put
            // an empty frame on the page.
            let blankWeek = MetricWeek(endingOn: anchor, recovery: [])
            assertTest(
                WeekLineSeries(hrvWeek: blankWeek) == nil
                    && WeekLineSeries(restingHeartRateWeek: blankWeek) == nil
                    && WeekLineSeries(respiratoryRateWeek: blankWeek) == nil
                    && WeekBarSeries(recoveryWeek: blankWeek) == nil
                    && WeekBarSeries(sleepPerformanceWeek: blankWeek) == nil,
                "A week with no reading in it has no series rather than an empty one, for any of the "
                    + "five charts, so every card is omitted instead of drawn empty")

            // ---- The third line, and the precision rule that only it exercises ----
            //
            // Respiratory rate is the one quantity here that is not read to whole units, and the week
            // below is the reference week's own — measured off the imported export, 14.8 15.4 14.9 14.9
            // 14.9 16.5 14.9 — chosen because it is the case that fails if anyone prints it the way the
            // other two are printed. Rounded to whole numbers it reads 15 15 15 15 15 17 15: six distinct
            // days collapsed into one number, and the 16.5 that is the week's entire point erased. So the
            // assertion is not "it formats" but "it does not lose the reading".
            // Written offset-first like the fixtures above, so `day(offset)` is the day each rate is
            // filed under and the slot it lands in is `6 - offset` — the anchor is slot 6.
            let referenceRespiratory = MetricWeek(
                endingOn: anchor,
                recovery: [
                    (0, 14.9), (1, 16.5), (2, 14.9), (3, 14.9), (4, 14.9), (5, 15.4), (6, 14.8),
                ].map { offset, rate in
                    RecoveryMetric(
                        date: day(offset), score: 60, hrvValueMs: 60, hrvMetric: .rmssd,
                        restingHeartRate: 52, respiratoryRate: rate)
                })
            if let breaths = WeekLineSeries(respiratoryRateWeek: referenceRespiratory) {
                assertTest(
                    breaths.points.map(\.slot) == [0, 1, 2, 3, 4, 5, 6] && breaths.runs.count == 1,
                    "The respiratory-rate chart plots every measured day and narrows nothing, so a full "
                        + "week is seven points in one run (got slots \(breaths.points.map(\.slot)) in "
                        + "\(breaths.runs.count) run(s))")
                assertTest(
                    breaths.valueDecimals == 1,
                    "…and reads its numbers to one decimal, which is the resolution the column is stored "
                        + "at — printing this week whole would render six of its seven days as `15`")
                assertTest(
                    breaths.points.map { String(format: "%.\(breaths.valueDecimals)f", $0.value) }
                        == ["14.8", "15.4", "14.9", "14.9", "14.9", "16.5", "14.9"],
                    "…so the labels the chart draws for the reference week are the week's own figures (got "
                        + "\(breaths.points.map { String(format: "%.1f", $0.value) }))")
            } else {
                assertTest(false, "The reference respiratory week yields no series at all")
            }

            // The other two are whole-number quantities and must stay that way: a `52.0` bpm or a `47.0`
            // ms would claim a resolution neither column is stored at. Asserted together because the
            // precision now lives in one shared property and a single edit could move all three.
            assertTest(
                WeekLineSeries(hrvWeek: mixed)?.valueDecimals == 0
                    && WeekLineSeries(restingHeartRateWeek: mixed)?.valueDecimals == 0
                    && WeekLineSeries(respiratoryRateWeek: referenceRespiratory)?.valueDecimals == 1,
                "Each quantity carries its own resolution, so the fractional one cannot drag the other "
                    + "two to a decimal they were never measured at")

            // The ungated pass-through, which is the one place in `makeDay` a value is not filtered. The
            // column has no reserved zero — it is optional on the row and on the slot — so the optional is
            // the whole rule, and the chart and the RESPIRATORY RATE row above it read the same value
            // through it. A gate here would let the chart omit a point the row prints.
            let onlyBreaths = MetricWeek(
                endingOn: anchor,
                recovery: [
                    RecoveryMetric(
                        date: anchor, score: 0, hrvValueMs: 0, restingHeartRate: 0,
                        respiratoryRate: 14.4)
                ])
            assertTest(
                onlyBreaths.days.last?.respiratoryRate == 14.4,
                "A respiratory rate reaches its slot even from a row this app calls unmeasured, because "
                    + "the column has no reserved zero to gate and the row above the chart is not gated "
                    + "either (got \(onlyBreaths.days.last?.respiratoryRate.map { "\($0)" } ?? "nil"))")
            assertTest(
                onlyBreaths.days.last?.hasAnyMeasurement == false,
                "…while still not counting as a measurement on the STRAIN & RECOVERY chart, which draws "
                    + "neither a respiratory rate nor anything else this row holds")

            // The reference week's own breaths, and the axis they fit to. A two-unit span against the
            // ladder's smallest step, which is the tightest fit in this app and the one where an
            // off-by-one in the snapping would be most visible.
            if let fitted = FittedAxis(values: [14.8, 15.4, 14.9, 14.9, 14.9, 16.5, 14.9]) {
                assertTest(
                    fitted.lowerBound == 14 && fitted.upperBound == 17 && fitted.step == 1,
                    "The reference week's breaths fit to a one-rpm step rather than to the data's own "
                        + "14.8…16.5 (got \(fitted.lowerBound)…\(fitted.upperBound) at step "
                        + "\(fitted.step))")
                assertTest(
                    fitted.gridLines == [15, 16],
                    "…and rule gridlines at whole breaths, which is as coarse as a reader can name on a "
                        + "two-unit span (got \(fitted.gridLines))")
            } else {
                assertTest(false, "The reference week's respiratory rates yield no axis")
            }

            // The reserved-zero row: a day an older build wrote as unmeasured. `makeDay` gates the rate on
            // `hasMeasurement && > 0`, so the `0` never reaches the series — the same double gate the
            // panel's own field is asserted on above, reached through the drawing this time. Without it a
            // placeholder day would plot a real-looking point at zero bpm.
            assertTest(
                WeekLineSeries(
                    restingHeartRateWeek: MetricWeek(
                        endingOn: anchor,
                        recovery: [
                            RecoveryMetric(
                                date: anchor, score: 0, hrvValueMs: 0, restingHeartRate: 0)
                        ])) == nil,
                "A reserved-zero row plots no point on the resting-heart-rate chart, so a day nothing "
                    + "measured cannot arrive as a rate of zero")

            // The reference week's own rates, and the axis the screenshot's chart is drawn from. These are
            // the seven days the resting-heart-rate card was built against, measured off the imported
            // export — 55, 55, 52, 52, 49, 66, 52 — so a change to the fitting shows up here as numbers
            // rather than as a chart that merely looks a little different.
            if let fitted = FittedAxis(values: [55, 55, 52, 52, 49, 66, 52]) {
                assertTest(
                    fitted.lowerBound == 45 && fitted.upperBound == 70 && fitted.step == 5,
                    "The reference week's rates fit to a 5 bpm step rather than to the data's own 49…66 "
                        + "(got \(fitted.lowerBound)…\(fitted.upperBound) at step \(fitted.step))")
                assertTest(
                    fitted.gridLines == [50, 55, 60, 65],
                    "…and rule gridlines at those five-bpm values, so the reader can name every line "
                        + "without a label (got \(fitted.gridLines))")
            } else {
                assertTest(false, "The reference week's resting rates yield no axis")
            }

            // ---- The bars, and the two questions a bar series answers ----
            //
            // The page's two bar charts are one drawing, so which slots plot and what colour each bar is
            // now live in `WeekBarSeries` rather than in a `View`'s body — the reason `DayBarRules` is a
            // type. Neither rule is visible in a screenshot of a week where it happens not to bite, and
            // both were previously unassertable.
            //
            // The recovery bars first: the rule they carry is that a day with no score gets no bar, which
            // `mixed` exercises because only five of its seven slots hold a row.
            if let scores = WeekBarSeries(recoveryWeek: mixed) {
                assertTest(
                    scores.points.map(\.slot) == [2, 3, 4, 5, 6],
                    "The recovery bars cover exactly the days carrying a score — five of the seven slots, "
                        + "and the two with no row draw no bar rather than a zero-height one (got "
                        + "\(scores.points.map(\.slot)))")
                assertTest(
                    scores.points.allSatisfy { $0.value == 60 },
                    "…and each bar states its own day's score, which is what the tier colour below is "
                        + "computed from (got \(scores.points.map(\.value)))")
            } else {
                assertTest(false, "A week of five scored days yields no recovery bar series")
            }
            assertTest(
                WeekBarSeries(recoveryWeek: mixed)?.palette == .recoveryTier,
                "The recovery bars take their colour from the day's own tier — so the colour is the "
                    + "reading rather than decoration")
            // The gridlines are the tier edges, so they move with the tiers: an off-by-one at 66/67 in
            // `RecoveryState` would leave the bars coloured by one boundary and measured against another.
            assertTest(
                WeekBarSeries(recoveryWeek: mixed)?.gridEdges == [0.34, 0.67],
                "…and the two lines it grids at are 34% and 67%, read off the tier ranges rather than "
                    + "typed, so a reader can see the boundaries the bar colours come from (got "
                    + "\((WeekBarSeries(recoveryWeek: mixed)?.gridEdges ?? []).map { "\($0)" }))")

            // A night with a known need, so the chain from a `sleeps` row through `MetricDay` to a drawn
            // bar is asserted end to end rather than at one end. The figures are chosen for their
            // arithmetic — a 30% night is the case a chart is worth drawing for — and are not anyone's
            // week: the app's own imported nights run to a different set of percentages.
            func night(_ offset: Int, fraction: Double) -> SleepSession {
                SleepSession(
                    date: day(offset),
                    startTime: day(offset),
                    endTime: day(offset),
                    targetSleepNeedSeconds: 8 * 3600,
                    lightSleepSeconds: fraction * 8 * 3600)
            }
            // Written offset-first like the fixtures above, so `day(offset)` is the night each is filed
            // under and the slot it lands in is `6 - offset` — the anchor is slot 6.
            let sleepWeek = MetricWeek(
                endingOn: anchor,
                sleep: [
                    (0, 0.81), (1, 0.30), (2, 0.81), (3, 0.82), (4, 0.82), (5, 0.76), (6, 0.81),
                ].map { offset, fraction in night(offset, fraction: fraction) })

            if let performance = WeekBarSeries(sleepPerformanceWeek: sleepWeek) {
                assertTest(
                    performance.points.map(\.slot) == [0, 1, 2, 3, 4, 5, 6],
                    "The sleep-performance bars cover every classified night, so a full week is seven "
                        + "bars (got \(performance.points.map(\.slot)))")
                assertTest(
                    performance.points.map(\.value) == [81, 76, 82, 82, 81, 30, 81],
                    "…and each bar states that night's own percentage, computed from its staged minutes "
                        + "over its need — the whole chain from a stored night to a drawn bar (got "
                        + "\(performance.points.map(\.value)))")
            } else {
                assertTest(false, "A week of seven classified nights yields no sleep bar series")
            }
            assertTest(
                WeekBarSeries(sleepPerformanceWeek: sleepWeek)?.palette == .sleepPerformance,
                "The sleep bars are one flat colour rather than tiered: the quantity *is* banded, but the "
                    + "band is not what this chart is about — tiering would say the bars are a grade "
                    + "rather than a week of hours, and the reference draws every one of them flat")
            // The sleep bars grid at the same two boundaries the `HOURS VS. NEEDED` row above them is
            // coloured by — `SleepBand.Metric.hoursVsNeeded`'s. This assertion used to require an empty
            // list, on the stated premise that this app has no sleep-performance bands; that premise was
            // false and the sleep detail screen disproves it by colouring the same percentage through
            // `SleepBand` three cards up. Reading the bounds rather than typing 0.70/0.95 is the point:
            // a chart gridding at one pair while the row bands at another is two boundaries for one
            // quantity, which is the drift `recoveryTierEdges` above exists to prevent.
            assertTest(
                WeekBarSeries(sleepPerformanceWeek: sleepWeek)?.gridEdges == [0.70, 0.95],
                "…and they grid at 70% and 95%, read off `SleepBand.Metric.hoursVsNeeded` rather than "
                    + "typed, so the bars and the `HOURS VS. NEEDED` row that colours the same night "
                    + "cannot come to disagree about where the bands are (got "
                    + "\((WeekBarSeries(sleepPerformanceWeek: sleepWeek)?.gridEdges ?? []).map { "\($0)" })). "
                    + "The literal is what makes this discriminating: `SleepBand` carries three band pairs "
                    + "on one shared 0–100 scale and they differ only in their bounds, so a chart pointed "
                    + "at the consistency metric would grid at 60/90")

            // ---- The fifth chart is omitted on its own data, and it is the one that can be alone ----
            //
            // Sleep performance is read off a `sleeps` row and the other four off a `recoveries` row, so
            // this is the only card on the page that can be drawn on a week all the others are absent
            // from. The strap records nights and recoveries independently, so it is a real week and not a
            // constructed one.
            assertTest(
                WeekBarSeries(recoveryWeek: sleepWeek) == nil
                    && WeekLineSeries(hrvWeek: sleepWeek) == nil
                    && WeekLineSeries(restingHeartRateWeek: sleepWeek) == nil
                    && WeekLineSeries(respiratoryRateWeek: sleepWeek) == nil
                    && WeekBarSeries(sleepPerformanceWeek: sleepWeek) != nil,
                "A week whose only data is its nights draws the sleep-performance chart and none of the "
                    + "other four, rather than omitting the whole section or drawing four empty frames")
            assertTest(
                WeekBarSeries(sleepPerformanceWeek: mixed) == nil
                    && WeekBarSeries(recoveryWeek: mixed) != nil,
                "…and the omissions are independent the other way: a week of recovery rows with no "
                    + "nights draws the recovery bars and no sleep chart")
            assertTest(
                sleepWeek.days.last?.recoveryScore == nil
                    && sleepWeek.days.last?.sleepPerformance == 81
                    && sleepWeek.days.last?.hasAnyMeasurement == true,
                "A slot can hold a night and no recovery row at all, and still count as measured — "
                    + "through the night's need, which is the field `hasAnyMeasurement` already reads. "
                    + "That is why excluding the performance from it is redundant rather than "
                    + "load-bearing")

            // The one path by which a bar could state a figure with no measurement behind it, asserted as
            // the trap it is rather than as a behaviour. `SleepSession.sleepPerformancePercentage` guards
            // `targetSleepNeedSeconds > 0` with a hard `100`, and `sleepNeedSeconds` on the same slot is
            // gated to `nil` — so the pair disagree, which is only visible when they are asserted
            // together. The chart plots the 100 because the SLEEP PERFORMANCE row above it prints the same
            // 100, and dropping the bar here would make two statements of one figure contradict. It is
            // unreachable on stored nights — every imported row with a wake onset carries a need, and the
            // strap path computes one — so this fails loudly if anyone makes it reachable, which is the
            // point.
            let needlessNight = MetricWeek(
                endingOn: anchor,
                sleep: [
                    SleepSession(
                        date: anchor, startTime: anchor, endTime: anchor, targetSleepNeedSeconds: 0)
                ])
            assertTest(
                needlessNight.days.last?.sleepPerformance == 100
                    && needlessNight.days.last?.sleepNeedSeconds == nil,
                "A night stored with no need states a performance of exactly 100 — the guard inside "
                    + "`SleepSession.sleepPerformancePercentage` standing in for a denominator that was "
                    + "not there — while the need on the same slot is nil, and the chart draws that 100 "
                    + "because the row above it prints it (got performance "
                    + "\(needlessNight.days.last?.sleepPerformance.map { "\($0)" } ?? "nil"), need "
                    + "\(needlessNight.days.last?.sleepNeedSeconds.map { "\($0)" } ?? "nil"))")

            // ---- The fitted axis ----
            //
            // The one auto-scaled axis in this app, and the assertions that keep it from becoming the
            // thing the fixed-scale rule forbids. The bounds are round and the gridlines are values a
            // reader can name; `32…67` is the reference week's own range, so these are the numbers the
            // screenshot's chart is drawn from.
            if let fitted = FittedAxis(values: [47, 51, 59, 58, 63, 32, 67]) {
                assertTest(
                    fitted.lowerBound == 30 && fitted.upperBound == 70 && fitted.step == 10,
                    "The fitted axis rounds out to a step a reader can name rather than to the data's "
                        + "own extremes (got \(fitted.lowerBound)…\(fitted.upperBound) at step "
                        + "\(fitted.step))")
                assertTest(
                    fitted.gridLines == [40, 50, 60],
                    "…and rules its gridlines at those round values, strictly inside the bounds so the "
                        + "frame's own edges are not drawn twice (got \(fitted.gridLines))")
                assertTest(
                    fitted.upperBound >= 67 && fitted.lowerBound <= 32,
                    "The bounds contain every value they were fitted to, so nothing the chart hands this "
                        + "can be clamped away by the frame")
            } else {
                assertTest(false, "The reference week's values yield no axis at all")
            }

            // A flat week is still a band to draw in. Without the widening a zero-span range would put
            // the line on the frame's edge and leave the fraction dividing by zero.
            if let flat = FittedAxis(values: [55, 55, 55]) {
                assertTest(
                    flat.upperBound > flat.lowerBound,
                    "A week where every reading is identical still gets a non-zero range (got "
                        + "\(flat.lowerBound)…\(flat.upperBound))")
            } else {
                assertTest(false, "A flat week yields no axis, which would draw an empty frame")
            }

            assertTest(
                FittedAxis(values: []) == nil,
                "An axis with nothing to describe is nil rather than a default range, so a caller cannot "
                    + "draw an empty frame through it")

            // ---- A day with no samples is not a day ----
            //
            // `CalculateStrainUseCase` used to write a placeholder here — `score: 0.0` with the flag clear
            // — so that a reader could tell it apart from a measured rest day. Nothing read it that way,
            // and the row cost two things: `WhoopExportImporter` saw a row and skipped the day, so WHOOP's
            // genuine `Day Strain` for it was never imported, and the strain backfill below treats the
            // shape as its signature. Absence is now the answer, matching `AnalyzeSleepUseCase` — and the
            // shape itself is no longer produced by any writer, so it is covered by the direct
            // construction in the marker block below rather than by driving a use case into it.
            let emptyBranchDB = LocalDatabaseManager(inMemory: true)
            let emptyBranchRepository = GRDBStrainRepository(db: emptyBranchDB)
            let emptyBranch = try await CalculateStrainUseCase(
                biometricRepository: EmptyBiometricStore(),
                strainRepository: emptyBranchRepository,
                userProfileRepository: GRDBUserProfileRepository(db: emptyBranchDB)
            ).execute(for: anchor)
            assertTest(
                emptyBranch == nil,
                "A day with no samples returns nil rather than a reserved `0.0` — a real strain of `0.0` "
                    + "and an unmeasured day are not the same claim")
            assertTest(
                try await emptyBranchRepository.getStrain(for: anchor) == nil,
                "…and it writes no row, so nothing downstream can mistake the day for stored data")

            // ---- The strain marker, through the repository that stores it ----
            //
            // This is v7's coverage. The migration's backfill `UPDATE` cannot be asserted here — the
            // migrator runs it before any row can exist — so what is tested is the column's existence and
            // the write/read path through it, which is what a subsequent launch depends on.
            let markerDB = LocalDatabaseManager(inMemory: true)
            let markerRepository = GRDBStrainRepository(db: markerDB)
            try await markerRepository.saveStrain(
                StrainScore(date: anchor, score: 0.0, hasMeasurement: false))
            try await markerRepository.saveStrain(
                StrainScore(date: day(1), score: 0.1, hasMeasurement: true))

            let unmeasured = try await markerRepository.getStrain(for: anchor)
            let measured = try await markerRepository.getStrain(for: day(1))
            assertTest(
                unmeasured?.hasMeasurement == false && measured?.hasMeasurement == true,
                "The strain marker survives the round trip: a saved placeholder reads back unmeasured and "
                    + "a saved reading measured")
            assertTest(
                unmeasured?.score == 0.0 && measured?.score == 0.1,
                "…and the two zero-ish rows are distinguishable only by the flag — the placeholder's `0.0` "
                    + "is a real `0.0` on disk, which is why `score > 0` is not the test")
        } catch {
            assertTest(false, "The seven-day MetricWeek join threw: \(error)")
        }
    }
}
