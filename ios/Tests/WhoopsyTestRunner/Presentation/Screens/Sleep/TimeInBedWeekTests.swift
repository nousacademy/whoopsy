import Foundation
import Whoopsy

enum TimeInBedWeekTests {
    static func run() async throws {
        do {
            // ── The time-in-bed week ──────────────────────────────────────────────────────────────────
            //
            // Seven nights drawn as spans on a clock, and the one thing this block has that no other
            // block here does: **a second minute scale on the same value.** `MetricDay.sleepOnsetMinutes`
            // is `SleepConsistencyMath.nightClockMinutes`' noon-pivoted frame — `0` is noon, `420` is
            // 7 PM, `720` is midnight, `1140` is 7 AM — while the two figures a column prints are
            // minutes past midnight, reached only through `SleepClockAxis.clockText`. So every literal
            // below is written in the model's frame and read back through that one bridge, which is what
            // `CLAUDE.md`'s gotcha says a caller gets wrong by twelve hours in one place and not the
            // others.
            //
            // The clock times are set with `bySettingHour:`, for the consistency block's reason:
            // `date(byAdding: .minute,)` adds elapsed time, so on a spring-forward day every literal here
            // would move. The hours used (06:00–08:00, 16:00–23:00) sit outside both the 02:00 gap and
            // the 01:00 fold, so the wall clock is unambiguous all year.
            do {
                let calendar = Calendar.current
                let base = calendar.startOfDay(for: Date())

                /// One night, keyed on the day it **ended** — `SleepSession.date` and this app's own day
                /// key.
                ///
                /// Both times are set on that same date, so a 23:00→07:00 pair is `bySettingHour: 23` and
                /// `bySettingHour: 7` of one day. The noon pivot is what makes that a single contiguous
                /// eight-hour span instead of a negative one, and the assertions below pin it rather than
                /// leaving it to be inferred.
                func inBedNight(dayOffset: Int, onset: (Int, Int), wake: (Int, Int)) -> SleepSession {
                    let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
                    return SleepSession(
                        date: day,
                        startTime: calendar.date(
                            bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!,
                        endTime: calendar.date(
                            bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!)
                }

                // Two nights inside the default window: 11 PM→7 AM on the day before the anchor, and
                // 10:30 PM→6:15 AM on the anchor's own day. The second carries minutes so one column's
                // two labels are the eight-character strings the view's `minimumScaleFactor` exists for.
                let bedWeek = MetricWeek(
                    endingOn: TypicalRangeTests.weekAnchor,
                    sleep: [
                        inBedNight(dayOffset: 1, onset: (23, 0), wake: (7, 0)),
                        inBedNight(dayOffset: 0, onset: (22, 30), wake: (6, 15)),
                    ])

                if let series = TimeInBedWeek(week: bedWeek) {
                    assertTest(
                        series.nights.map(\.slot) == [5, 6],
                        "The nights plot in slot order, the anchor's own night last — so the column under "
                            + "the chip is the day the page is showing, and a night is placed by the "
                            + "frame's slot rather than by its own date "
                            + "(got \(series.nights.map(\.slot)))")
                    assertTest(
                        series.nights.map(\.spanMinutes) == [480, 465],
                        "…and each column's height is its night's own span, derived from the two "
                            + "boundaries rather than stored beside them: 11 PM→7 AM is eight hours and "
                            + "10:30 PM→6:15 AM is seven hours forty-five "
                            + "(got \(series.nights.map(\.spanMinutes)))")
                    assertTest(
                        series.nights.first?.onsetText == "11 PM"
                            && series.nights.first?.wakeText == "7 AM"
                            && series.nights.last?.onsetText == "10:30 PM"
                            && series.nights.last?.wakeText == "6:15 AM",
                        "Both ends of every column are labelled, and both are a **clock time** rather "
                            + "than a duration — which is the whole reason the card carries two figures "
                            + "per column: reading either as minutes in bed states an eight-hour night as "
                            + "`11:00` (got \(series.nights.map { "\($0.onsetText)–\($0.wakeText)" }))")

                    assertTest(
                        series.axis.startMinutes == 420 && series.axis.endMinutes == 1380,
                        "A week whose nights sit inside the reference window keeps the reference window: "
                            + "7 PM to 11 AM, sixteen hours "
                            + "(got \(series.axis.startMinutes)–\(series.axis.endMinutes))")
                    assertTest(
                        series.axis.labels.map(\.text) == ["7 PM", "11 PM", "3 AM", "7 AM", "11 AM"],
                        "…and its five ticks land on whole hours, which is the frame the five-night "
                            + "consistency card above also draws against — one shared axis, so the two "
                            + "charts cannot come to disagree about where eleven at night is "
                            + "(got \(series.axis.labels.map(\.text)))")
                    assertTest(
                        series.nights.allSatisfy {
                            series.axis.fraction($0.onsetMinutes) < series.axis.fraction($0.wakeMinutes)
                        } && TypicalRangeTests.near(series.axis.fraction(660), 0.25)
                            && TypicalRangeTests.near(series.axis.fraction(1140), 0.75),
                        "…and a night is drawn downwards from its onset to its wake, so the top of every "
                            + "bar is the bedtime on the left of the label above it. 11 PM is a quarter "
                            + "of the way down a 7 PM–11 AM axis and 7 AM is three quarters")

                    // The widening. 16:15 is **above** the default top on the night clock — 256, where
                    // the axis opens at 420 — so this night is the one case that moves it, and it is
                    // measured as a real row before it is used as a fixture (see the export block below).
                    let longNight = inBedNight(dayOffset: 0, onset: (16, 15), wake: (8, 0))
                    let longOnset = SleepConsistencyMath.nightClockMinutes(
                        longNight.startTime, calendar: calendar)
                    assertTest(
                        longOnset < SleepClockAxis.defaultStartMinutes,
                        "…and a 16:15 bedtime is really outside the default window rather than "
                            + "conveniently inside it, which is what makes the fixture below a test of the "
                            + "widening rule and not of the default one (onset \(longOnset) against a top "
                            + "of \(SleepClockAxis.defaultStartMinutes))")
                    if let widened = TimeInBedWeek(week: MetricWeek(
                        endingOn: TypicalRangeTests.weekAnchor, sleep: [longNight])) {
                        assertTest(
                            widened.axis.startMinutes == 240,
                            "The axis **widens in whole hours** to hold a boundary outside it — 16:15 "
                                + "pushes the top out to 4 PM and no further — rather than clipping the "
                                + "night to the frame, which would draw a bar at a position it does not "
                                + "have (got \(widened.axis.startMinutes))")
                        assertTest(
                            widened.axis.labels.first?.text == "4 PM",
                            "…and the widened end is a labelled tick like any other, so the frame a "
                                + "reader measures against is a clock and not an edge "
                                + "(got \(String(describing: widened.axis.labels.first?.text)))")
                        assertTest(
                            (0...1).contains(widened.axis.fraction(longOnset)),
                            "…and the night that moved it is drawn inside the frame it moved, which is "
                                + "the failure a widening rule that rounded the wrong way would have: "
                                + "`floor` to 16:15's own hour leaves the onset at the very top edge, and "
                                + "a `ceil` would put it above the top")
                    } else {
                        assertTest(false, "The 16-hour night produced no series")
                    }

                    // The refused span: 11 AM to 1 PM contains noon, which the night clock has no seam
                    // to cross. Its own boundaries are deliberately **loud** — an 11:00 onset and a
                    // 13:00 wake are night-clock 1380 and 60, so including them would drag the axis'
                    // top from 420 down to 60 and the assertion below would see it.
                    let afternoon = inBedNight(dayOffset: 0, onset: (11, 0), wake: (13, 0))
                    let mixedWeek = MetricWeek(
                        endingOn: TypicalRangeTests.weekAnchor,
                        sleep: [
                            inBedNight(dayOffset: 1, onset: (23, 0), wake: (7, 0)),
                            afternoon,
                        ])
                    if let mixed = TimeInBedWeek(week: mixedWeek) {
                        assertTest(
                            mixed.nights.map(\.slot) == [5],
                            "A span the frame cannot draw costs **its own column** and not the card: the "
                                + "honest night still plots, where the five-night consistency card above "
                                + "refuses the whole chart for the same row — its five columns are one "
                                + "unit and these seven are seven readings "
                                + "(got \(mixed.nights.map(\.slot)))")
                        assertTest(
                            mixed.axis.startMinutes == 420,
                            "…and the refused night's own boundaries are left out of the axis as well as "
                                + "off the plot, so a corrupt row cannot move the scale the honest nights "
                                + "are read against. This is the assertion that sees it: the 11 AM onset "
                                + "is night-clock 1380 and would have pulled the top down to 1 AM "
                                + "(got \(mixed.axis.startMinutes))")
                    } else {
                        assertTest(false, "A week with one drawable night and one refused span drew nothing")
                    }
                    assertTest(
                        TimeInBedWeek(week: MetricWeek(endingOn: TypicalRangeTests.weekAnchor, sleep: [afternoon])) == nil,
                        "…but a week whose **only** night is refused draws no card at all, because seven "
                            + "empty columns are not a picture of a week — the rule every chart in this "
                            + "app follows")
                    assertTest(
                        TimeInBedWeek(week: MetricWeek(endingOn: TypicalRangeTests.weekAnchor)) == nil,
                        "…and a week with no nights is absent for the same reason, not an empty plot")

                    assertTest(
                        series.nights.map(\.isAnchor) == [false, true],
                        "The anchor is the night on the page's own day, recorded at the join where the "
                            + "dates are — the sentence below reads it, and the drawing does not need it "
                            + "because the frame already tints that column "
                            + "(got \(series.nights.map(\.isAnchor)))")
                    let anchorless = TimeInBedWeek(week: MetricWeek(
                        endingOn: TypicalRangeTests.weekAnchor,
                        sleep: [inBedNight(dayOffset: 1, onset: (23, 0), wake: (7, 0))]))
                    assertTest(
                        anchorless?.nights.allSatisfy { !$0.isAnchor } == true,
                        "…and on a week whose own day carries no night, no column is marked as the anchor "
                            + "— a fresh install's first day, which is exactly the case this card's gate "
                            + "is built for")
                    assertTest(
                        series.spokenSentence
                            == "Time in bed for the last seven days, 2 of 7 nights measured, "
                                + "last night 10:30 PM to 6:15 AM",
                        "The card's words count the nights it draws and name **the anchor's own two "
                            + "times**, not a range over the week: a week's earliest bedtime and latest "
                            + "waketime are two clock times with no relation to each other, and "
                            + "`from 10:30 PM to 7 AM` would read as one very long night "
                            + "(got \"\(series.spokenSentence)\")")
                    assertTest(
                        anchorless?.spokenSentence
                            == "Time in bed for the last seven days, 1 of 7 nights measured, "
                                + "no night on the day shown",
                        "…and a week whose own day has no night says so rather than borrowing a "
                            + "neighbouring column's times, which would put a night the page is not about "
                            + "under the heading of the night it is "
                            + "(got \"\(anchorless?.spokenSentence ?? "nil")\")")
                } else {
                    assertTest(false, "A week of two drawable nights produced no series")
                }

                // The pair reaching the week, in the model's own frame. `660` is 11 PM and `1140` is
                // 7 AM on the noon pivot; minutes past midnight would be `1380` and `420`, and the two
                // pairs are twelve hours apart rather than near each other — which is the whole of why
                // the fields are named for the frame they are in.
                assertTest(
                    bedWeek.days[5].sleepOnsetMinutes == 660 && bedWeek.days[5].sleepWakeMinutes == 1140,
                    "A night's two boundaries reach a `MetricDay` as the **night clock's** minutes: an "
                        + "11 PM onset is `660` and a 7 AM wake is `1140`, where minutes past midnight "
                        + "would be `1380` and `420` (got "
                        + "\(String(describing: bedWeek.days[5].sleepOnsetMinutes))–"
                        + "\(String(describing: bedWeek.days[5].sleepWakeMinutes)))")
                assertTest(
                    MetricWeek(endingOn: TypicalRangeTests.weekAnchor).days.allSatisfy {
                        $0.sleepOnsetMinutes == nil && $0.sleepWakeMinutes == nil
                    },
                    "A day with no classified night carries neither boundary, which is the absence the "
                        + "chart's per-column `nil` reads through — and the pair is absent *together*, "
                        + "because both are read off the one night row")
            }
        }
    }
}
