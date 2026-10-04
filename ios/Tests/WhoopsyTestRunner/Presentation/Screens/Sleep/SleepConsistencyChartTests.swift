import Foundation
import Whoopsy

enum SleepConsistencyChartTests {
    static func run() async throws {
        // ── 8. The five nights, the two rules and the figure ─────────────────────────────────────────
        //
        // Fixed clock times rather than elapsed offsets, for §13's reason: `date(byAdding: .minute,)`
        // adds elapsed time, so on a spring-forward day every literal below would move.
        do {
            let calendar = Calendar.current
            let base = calendar.startOfDay(for: Date())

            func session(
                _ dayOffset: Int, onset: (Int, Int), wake: (Int, Int), stored: Int? = nil
            ) -> SleepSession {
                let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
                return SleepSession(
                    date: day,
                    startTime: calendar.date(
                        bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!,
                    endTime: calendar.date(
                        bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!,
                    sleepConsistency: stored)
            }

            // Four identical priors and an anchor on the same clock times: perfect consistency, and a
            // rule that lands exactly on the bars.
            let anchor = session(0, onset: (23, 0), wake: (7, 0), stored: 91)
            let priors = (1...4).map { session($0, onset: (23, 0), wake: (7, 0), stored: 88) }
            let history = priors + [anchor]

            if let summary = SleepConsistencyScoring.summary(
                for: anchor, history: history, score: 91, typicalScore: 88) {
                assertTest(
                    summary.bars.count == 5
                        && summary.bars.last?.isAnchor == true
                        && summary.bars.dropLast().allSatisfy { !$0.isAnchor },
                    "Five columns, the anchor last — the four priors are the reference the fifth was "
                        + "scored against, and the order is the model's own window")

                assertTest(
                    zip(summary.bars, summary.bars.dropFirst()).allSatisfy { $0.date < $1.date },
                    "…and they run left to right in time, oldest first, which is what makes the "
                        + "weekday row under them read as a week rather than a set")

                assertTest(
                    TypicalRangeTests.near(summary.bars.last?.onsetMinutes ?? .nan, 660)
                        && TypicalRangeTests.near(summary.bars.last?.wakeMinutes ?? .nan, 1140),
                    "The anchor's boundaries are night-clock minutes and not `Date`s: 11 PM is 660 and "
                        + "7 AM is 1140 on the noon-pivot frame")

                assertTest(
                    TypicalRangeTests.near(summary.typicalOnsetMinutes, 660) && TypicalRangeTests.near(summary.typicalWakeMinutes, 1140),
                    "Four identical nights average to themselves — the rule lands on the bars it was "
                        + "taken from, which is what a reader checking the picture will see")

                if let layout = SleepConsistencyChartLayout(summary: summary) {
                    assertTest(
                        TypicalRangeTests.near(layout.axisStartMinutes, 420) && TypicalRangeTests.near(layout.axisEndMinutes, 1380),
                        "The default axis is 7 PM to 11 AM — 420 to 1380 — and no boundary in this "
                            + "history is outside it, so nothing widened it")

                    assertTest(
                        layout.axisLabels.map(\.text)
                            == ["7 PM", "11 PM", "3 AM", "7 AM", "11 AM"],
                        "Five ticks on the reference's own times. They are the quarter points of the axis "
                            + "rather than five literals, so a widened axis relabels itself — and on the "
                            + "default window the quarter points of a whole-hour span are whole hours "
                            + "(got \(layout.axisLabels.map(\.text).joined(separator: ", ")))")

                    assertTest(
                        TypicalRangeTests.near(layout.bars.last?.topFraction ?? .nan, 0.25)
                            && TypicalRangeTests.near(layout.bars.last?.bottomFraction ?? .nan, 0.75)
                            && layout.bars.allSatisfy { $0.topFraction < $0.bottomFraction },
                        "The anchor spans a quarter to three quarters of a sixteen-hour axis — 11 PM to "
                            + "7 AM — and every bar's onset is above its wake")

                    assertTest(
                        layout.typicalOnsetText == "11 PM" && layout.typicalWakeText == "7 AM",
                        "The two callouts print the rules as clock times, read back through the frame "
                            + "rather than through the number the model works in "
                            + "(got \(layout.typicalOnsetText) / \(layout.typicalWakeText))")
                } else {
                    assertTest(false, "A perfectly ordinary five-night history produced no chart layout")
                }
            } else {
                assertTest(false, "Four priors and an anchor produced no summary")
            }

            // Below four priors there is no rule and no chart — the card is absent rather than drawn over
            // four empty columns. The figure the card would have headed itself with is on the breakdown
            // row above either way, so the absence hides no reading.
            assertTest(
                SleepConsistencyScoring.summary(
                    for: anchor, history: Array(history.dropFirst(2)), score: 91, typicalScore: nil)
                    == nil,
                "Two priors are not four: no summary, so no card — and `SleepConsistencyMath`'s own gate "
                    + "is what refuses it rather than a second copy of the rule here")
            assertTest(
                SleepConsistencyMath.typicalBoundaries(
                    for: SleepConsistencyScoring.night(from: anchor),
                    history: Array(history.dropFirst(2)).map(SleepConsistencyScoring.night(from:)))
                    == nil,
                "…and the rule is refused by the same gate as the score, so a chart can never be drawn "
                    + "for a night the figure above it declined to score")

            // The twelve-hour demonstration at the card's own level: four priors straddling midnight, and
            // the rule comes back as midnight rather than as noon.
            //
            // The pair is **antisymmetric in time order** — 23:50, 00:10, 00:10, 23:50 newest first — and
            // that is what makes the answer exact rather than approximate. On the night clock the weights
            // read 710, 730, 730, 710, so the 4:3:2:1 sum puts `4 + 1` on one side of the pivot and
            // `3 + 2` on the other: the sine terms cancel to the bit and `atan2(0, −10·cos 2.5°)` is
            // exactly π, which is exactly 720. Grouped the other way the same four nights average
            // 715.9979 — still the middle of the night, but no longer a literal a reader can check.
            let crossing = [
                session(1, onset: (23, 50), wake: (7, 0)),
                session(2, onset: (0, 10), wake: (7, 0)),
                session(3, onset: (0, 10), wake: (7, 0)),
                session(4, onset: (23, 50), wake: (7, 0)),
            ]
            if let crossed = SleepConsistencyMath.typicalBoundaries(
                for: SleepConsistencyScoring.night(from: anchor),
                history: crossing.map(SleepConsistencyScoring.night(from:))) {
                assertTest(
                    SleepConsistencyChartLayout.clockText(forNightClockMinutes: crossed.onsetMinutes)
                        == "12 AM",
                    "Four bedtimes of 11:50 PM and 00:10 average to midnight **on a clock**, and the "
                        + "card's own conversion is what says so. Averaged as minutes past midnight they "
                        + "are 1430 and 10 and the mean prints `12 PM` — a rule drawn through the middle "
                        + "of the day, which is the bug this frame exists to prevent "
                        + "(got "
                        + "\(SleepConsistencyChartLayout.clockText(forNightClockMinutes: crossed.onsetMinutes)))")
            } else {
                assertTest(false, "Four priors straddling midnight produced no average boundaries")
            }

            // The axis widens in whole hours to hold a boundary outside it, and relabels itself.
            let early = session(1, onset: (17, 30), wake: (7, 0))
            let earlyHistory = [early] + (2...4).map { session($0, onset: (23, 0), wake: (7, 0)) }
            if let earlySummary = SleepConsistencyScoring.summary(
                for: anchor, history: earlyHistory + [anchor], score: 91, typicalScore: nil),
                let earlyLayout = SleepConsistencyChartLayout(summary: earlySummary) {
                assertTest(
                    TypicalRangeTests.near(earlyLayout.axisStartMinutes, 300)
                        && TypicalRangeTests.near(earlyLayout.axisEndMinutes, 1380),
                    "A 5:30 PM bedtime — night-clock 330 — pushes the top of the axis out to 5 PM and no "
                        + "further. Clipping would draw the bar at a position it does not have and "
                        + "dropping the night would lose one of the five the card is about")
                assertTest(
                    earlyLayout.axisLabels.first?.text == "5 PM"
                        && earlyLayout.axisLabels[1].text == "9:30 PM",
                    "…and the ticks follow the axis, which is why they are derived: a widened span of "
                        + "1080 minutes puts its second tick on a half hour and the label prints one "
                        + "(got \(earlyLayout.axisLabels.map(\.text).joined(separator: ", ")))")
            } else {
                assertTest(false, "A night outside the default axis produced no layout")
            }

            // A night whose interval contains noon cannot be drawn on a linear axis whose top is the
            // evening and whose foot is the morning: read forward from the onset the reader reaches midday
            // before the wake. No layout, so the card prints its figure and draws no chart.
            //
            // The span here is 11:00 → 13:00, two hours and not twelve, which is the point: the rule is
            // about the *interval*, not about a duration. A fifteen-hour mis-keyed row is refused for the
            // same reason and by the same comparison. The two rules are given valid minutes deliberately,
            // so the bar is the only thing that can fail the initialiser.
            let overnight = session(0, onset: (11, 0), wake: (13, 0), stored: 91)
            assertTest(
                SleepConsistencyChartLayout(
                    summary: SleepConsistencyScoring.Summary(
                        bars: [
                            SleepConsistencyScoring.Bar(
                                date: overnight.date,
                                onsetMinutes: SleepConsistencyMath.nightClockMinutes(overnight.startTime),
                                wakeMinutes: SleepConsistencyMath.nightClockMinutes(overnight.endTime),
                                isAnchor: true)
                        ],
                        typicalOnsetMinutes: 600, typicalWakeMinutes: 660, score: 91,
                        typicalScore: nil))
                    == nil,
                "A bar whose interval contains noon is refused rather than drawn upside down — its onset "
                    + "reads 1380 on the night clock and its wake 60, so the pair would draw a bar "
                    + "running backwards up the plot. That is a corrupt row and not an absence, and the "
                    + "figure above the chart is a reading that stands either way")
        }

    }
}
