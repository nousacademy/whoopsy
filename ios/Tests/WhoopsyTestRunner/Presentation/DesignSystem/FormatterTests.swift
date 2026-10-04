import Foundation
import Whoopsy

// MARK: - 8. HRV Metric Isolation & Baseline Guards

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum FormatterTests {
    static func run() async throws {
        func day(_ offset: Int) -> Date {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86_400)
        }
        func metric(_ hrv: Double, _ kind: HRVMetric, _ rhr: Int, _ offset: Int) -> RecoveryMetric {
            RecoveryMetric(
                date: day(offset), score: 50, hrvValueMs: hrv, hrvMetric: kind, restingHeartRate: rhr)
        }

        // SDNN and RMSSD must never share a baseline. Ten RMSSD days at ~65 ms and ten SDNN days at
        // ~40 ms, scored as SDNN, must produce an SDNN baseline — not a mean of the two populations.
        var history: [RecoveryMetric] = []
        for i in 0..<10 {
            history.append(metric(65.0 + Double(i % 3), .rmssd, 54, -(i + 1)))
            history.append(metric(40.0 + Double(i % 3), .sdnn, 54, -(i + 20)))
        }

        let sdnnScored = RecoveryScoring.score(
            RecoveryScoring.Input(
                history: history, todayHrvValueMs: 41.0, todayHrvMetric: .sdnn,
                todayRestingHeartRate: 54, sleepPerformance: 0.9,
                fallbackRestingHeartRateBaseline: 54.0))
        assertTest(
            sdnnScored.hrvBaselineMeanMs >= 40.0 && sdnnScored.hrvBaselineMeanMs <= 42.0,
            "SDNN baseline excludes RMSSD days (mean \(String(format: "%.1f", sdnnScored.hrvBaselineMeanMs)))")

        let rmssdScored = RecoveryScoring.score(
            RecoveryScoring.Input(
                history: history, todayHrvValueMs: 66.0, todayHrvMetric: .rmssd,
                todayRestingHeartRate: 54, sleepPerformance: 0.9,
                fallbackRestingHeartRateBaseline: 54.0))
        assertTest(
            rmssdScored.hrvBaselineMeanMs >= 65.0 && rmssdScored.hrvBaselineMeanMs <= 67.0,
            "RMSSD baseline excludes SDNN days (mean \(String(format: "%.1f", rmssdScored.hrvBaselineMeanMs)))")

        // A zero-variance window must not make every difference infinitely many sigma. Without the
        // coefficient-of-variation floor, a 0.5 ms gap against a constant baseline scored ~500 sigma
        // and pinned the result to the clamp on data that was in fact perfectly average.
        let constant = (0..<10).map { metric(65.5, .rmssd, 54, -($0 + 1)) }
        let degenerate = RecoveryScoring.score(
            RecoveryScoring.Input(
                history: constant, todayHrvValueMs: 65.0, todayHrvMetric: .rmssd,
                todayRestingHeartRate: 54, sleepPerformance: 0.9,
                fallbackRestingHeartRateBaseline: 54.0))
        assertTest(
            degenerate.score > 40 && degenerate.score < 60,
            "A 0.5 ms gap on a zero-variance baseline stays near the midpoint (got \(degenerate.score))")

        // The z-score ceiling still bounds genuine outliers, so one wild reading cannot max the score.
        let wild = RecoveryScoring.score(
            RecoveryScoring.Input(
                history: constant, todayHrvValueMs: 900.0, todayHrvMetric: .rmssd,
                todayRestingHeartRate: 54, sleepPerformance: 0.9,
                fallbackRestingHeartRateBaseline: 54.0))
        assertTest(wild.score == 99, "An extreme outlier saturates at the 99 ceiling, not above it")

        // ── The scoring window, and the baselines a screen reads back off it ─────────────────────────
        //
        // `RecoveryScoring.baselines` exists so that a screen printing a day's figure against "its
        // baseline" prints the numbers the score above it was computed from, rather than an average of
        // its own taken over some neighbouring window. These assertions are what keep the two from
        // drifting: the first pins the window rule, the middle ones pin the display gate that stops a
        // cold-start constant being printed as a measurement, and the last pins `score` and `baselines`
        // to one answer.
        //
        // Every fixture below is built **oldest first**, which is the order `baselineWindow` documents
        // and the order the repositories return (`order(Column("date").asc)`). A newest-first array
        // would make `suffix` take the *oldest* thirty and the window would be a month adrift.
        let scoringWindowDays = RecoveryScoring.baselineWindowDays
        let dense = (0..<(scoringWindowDays + 5)).map { metric(60.0, .rmssd, 54, -((scoringWindowDays + 5) - $0)) }
        let windowed = RecoveryScoring.baselineWindow(before: day(0), in: dense)
        assertTest(
            windowed.count == scoringWindowDays,
            "The scoring window holds \(scoringWindowDays) days (got \(windowed.count))")
        assertTest(
            windowed.allSatisfy { $0.date < day(0) },
            "The scoring window is strictly before the day it scores")
        assertTest(
            windowed.last?.date == day(-1),
            "Its newest day is the day before, so a day never contributes to its own baseline")

        // The cap applies **after** the strictly-before filter, and the two orders disagree the moment
        // the series contains the day being scored — which it ordinarily does, since a caller reads a
        // window that ends on or after it. Slicing first takes the day itself out of the thirty and
        // returns twenty-nine; the mean then shifts by a day nobody can see.
        let withToday = (0..<scoringWindowDays).map { metric(60.0, .rmssd, 54, -(scoringWindowDays - $0)) }
            + [metric(60.0, .rmssd, 54, 0)]
        let filteredWindow = RecoveryScoring.baselineWindow(before: day(0), in: withToday)
        assertTest(
            filteredWindow.count == scoringWindowDays,
            "The cap is applied after the filter, not before (got \(filteredWindow.count) of \(scoringWindowDays))")
        assertTest(
            !filteredWindow.contains { $0.date == day(0) },
            "…and the day being scored is not inside its own baseline")

        // **The anchor the real screen passes is an instant, and every fixture above is snapped** — which
        // is how the day came to be inside its own baseline on the Recovery page while these assertions
        // passed. `RecoveryViewModel.loadBaselines` hands `RecoveryScoring.baselineWindow` the `Date` it
        // is displaying, which is `Date()` or the day a caller seeded, and on every day this app runs that
        // is some hours after midnight — so a raw `< day` let the day's own `startOfDay` row through and
        // the printed mean was taken over a different set of days than the score above it. Measured on
        // the simulator: 2026-08-17 printed an HRV baseline of 53 and a sleep-performance baseline of 80,
        // where the strictly-before window gives 52 and 78. The 2026-08-22 screenshot both windows agree
        // on is the reason it went unnoticed — they diverge on roughly one day in fifteen.
        let midMorning = day(0).addingTimeInterval(9 * 3600 + 37 * 60)
        assertTest(
            !RecoveryScoring.baselineWindow(before: midMorning, in: withToday)
                .contains { $0.date == day(0) },
            "An instant anchor mid-way through the day still excludes that day's own row — the anchor is "
                + "snapped to the calendar day, so the screen and the importer cannot disagree about "
                + "which days the mean covers")
        assertTest(
            RecoveryScoring.baselineWindow(before: midMorning, in: withToday).count == scoringWindowDays,
            "…and the window it returns is still the full \(scoringWindowDays) days, so snapping the "
                + "anchor drops the day rather than the oldest observation")

        // The lookback a reader has to fetch. It must exceed the window, because the window is of the
        // last thirty days *that have rows* — a history with a gap reaches back further than a month to
        // fill, so a reader that fetched exactly `baselineWindowDays` would silently build the printed
        // baseline from a different set of days than the score used.
        assertTest(
            RecoveryScoring.baselineWindowLookbackDays > scoringWindowDays,
            "The lookback exceeds the window it has to fill (\(RecoveryScoring.baselineWindowLookbackDays) > \(scoringWindowDays))")

        // The display gate. `BaselineStatisticsMath.baseline` substitutes a cold-start **constant** when
        // it is handed nothing, which is right for scoring a first day and wrong to print: a screen
        // showing those numbers as "your baseline" would be presenting a profile default as a
        // measurement. So the constant must survive for the score and be withheld from the screen.
        let emptyWindow = RecoveryScoring.baselines(history: [], todayHrvMetric: .rmssd)
        assertTest(
            emptyWindow.hrvMeanMs == HRVMetric.rmssd.coldStartMeanMs,
            "An empty window still yields a scoring baseline — the cold start")
        assertTest(
            emptyWindow.displayed.hrvMs == nil,
            "…and that cold-start HRV is not printed as a baseline")
        assertTest(
            emptyWindow.displayed.restingHeartRate == nil,
            "…nor is the cold-start resting heart rate")

        let twoDays = (0..<2).map { metric(60.0, .rmssd, 54, -($0 + 1)) }
        assertTest(
            RecoveryScoring.baselines(history: twoDays, todayHrvMetric: .rmssd).displayed.hrvMs == nil,
            "Two measured days do not make a printed baseline")
        let threeDays = (0..<3).map { metric(60.0, .rmssd, 54, -($0 + 1)) }
        assertTest(
            RecoveryScoring.baselines(history: threeDays, todayHrvMetric: .rmssd).displayed.hrvMs == 60.0,
            "Three do — the floor is \(RecoveryScoring.minimumBaselineDays)")

        // The never-mix rule reaches the screen too. A window holding both quantities prints a mean of
        // the day's own metric only; an unfiltered mean here would be 55, a statistic about neither.
        let mixedWindow =
            (0..<5).map { metric(40.0, .sdnn, 54, -($0 + 1)) }
            + (0..<5).map { metric(70.0, .rmssd, 54, -($0 + 6)) }
        assertTest(
            RecoveryScoring.baselines(history: mixedWindow, todayHrvMetric: .rmssd).displayed.hrvMs == 70.0,
            "The printed HRV baseline is narrowed to the day's own metric, not a mean across both")

        // Respiratory rate comes off the recovery row and is absent far more often than it is present —
        // the strap has no sensor for it — so its mean is over the days that carry one, or nothing.
        let withRates = (0..<4).map { offset in
            RecoveryMetric(
                date: day(-(offset + 1)), score: 50, hrvValueMs: 60, hrvMetric: .rmssd,
                restingHeartRate: 54, respiratoryRate: 14.0 + Double(offset))
        }
        assertTest(
            RecoveryScoring.baselines(history: withRates, todayHrvMetric: .rmssd)
                .displayed.respiratoryRate == 15.5,
            "The respiratory baseline is the mean of the days that measured one")

        // Sleep performance is derived per night from asleep-over-need, so its baseline is a mean of
        // ratios rather than of minutes: three nights at 4, 5 and 6 hours against an 8-hour need are
        // 50%, 62.5% and 75%.
        func night(_ offset: Int, asleepHours: Double) -> SleepSession {
            SleepSession(
                date: day(offset),
                startTime: day(offset).addingTimeInterval(-8 * 3600),
                endTime: day(offset),
                targetSleepNeedSeconds: 8 * 3600,
                lightSleepSeconds: asleepHours * 3600)
        }
        //
        // Two things are pinned here, and the first is the one that would otherwise be a silent
        // inconsistency on screen. A night at five hours against an eight-hour need is 62.5%, which
        // `SleepSession` reports as **63** — and the baseline is the mean of that printed figure, not of
        // the ratio behind it. Averaging the unrounded ratio would print a mean beneath a value that the
        // row above could never equal.
        let fiveHourNights = [night(-3, asleepHours: 5), night(-2, asleepHours: 5), night(-1, asleepHours: 5)]
        let roundedBaseline = RecoveryScoring.baselines(
            history: [], todayHrvMetric: .rmssd, sleepingNights: fiveHourNights).displayed.sleepPerformance
        assertTest(
            roundedBaseline.map { abs($0 - 0.63) < 0.0001 } == true,
            "The sleep-performance baseline averages the printed percentage, not the raw ratio (got \(roundedBaseline.map { String(format: "%.4f", $0) } ?? "nil"), not 0.625)")

        // And a plain mean over nights that do land on whole percents: 75%, 50% and 25%.
        let nights = [night(-3, asleepHours: 6), night(-2, asleepHours: 4), night(-1, asleepHours: 2)]
        assertTest(
            RecoveryScoring.baselines(history: [], todayHrvMetric: .rmssd, sleepingNights: nights)
                .displayed.sleepPerformance == 0.5,
            "The sleep-performance baseline is the mean of the nights it was given")

        // A night's own day is not in its window, the same rule the recovery overload applies — and it
        // is the rule a caller gets wrong by writing `filter` at the call site instead of using this.
        let nightsPlusToday = nights + [night(0, asleepHours: 8)]
        assertTest(
            RecoveryScoring.baselineWindow(before: day(0), in: nightsPlusToday).count == 3,
            "The night window is strictly before the day as well (got \(RecoveryScoring.baselineWindow(before: day(0), in: nightsPlusToday).count))")
        assertTest(
            RecoveryScoring.baselineWindow(before: midMorning, in: nightsPlusToday).count == 3,
            "…and it stays strictly before under the instant anchor the screen actually passes (got "
                + "\(RecoveryScoring.baselineWindow(before: midMorning, in: nightsPlusToday).count)) — "
                + "this overload is the one that carried the sleep-performance row's printed mean, which "
                + "read 80 on a day the strictly-before window makes 78")

        // The guarantee the detail screen rests on: what `score` used and what a reader gets back are
        // one computation, not two that agree today.
        let scoredWithHistory = RecoveryScoring.score(
            RecoveryScoring.Input(
                history: history, todayHrvValueMs: 66.0, todayHrvMetric: .rmssd,
                todayRestingHeartRate: 54, sleepPerformance: 0.9,
                fallbackRestingHeartRateBaseline: 54.0))
        let baselinesForHistory = RecoveryScoring.baselines(
            history: history, todayHrvMetric: .rmssd, fallbackRestingHeartRateBaseline: 54.0)
        assertTest(
            scoredWithHistory.hrvBaselineMeanMs == baselinesForHistory.hrvMeanMs
                && scoredWithHistory.rhrBaselineMean == baselinesForHistory.restingHeartRateMean,
            "The baseline a screen reads back is the one the score was computed from")

        // Formatters. `formattedHoursMinutes` is a behavioural reconstruction of a file that was
        // overwritten without being read; these assertions pin the contract its call sites rely on,
        // including the "0h 45m" literal the sleep screens fall back to.
        assertTest(2700.0.formattedHoursMinutes() == "0h 45m", "2700s formats as 0h 45m")
        assertTest(9900.0.formattedHoursMinutes() == "2h 45m", "9900s formats as 2h 45m")
        assertTest(28_800.0.formattedHoursMinutes() == "8h 0m", "28800s formats as 8h 0m")
        assertTest(62.5.formattedOneDecimal() == "62.5", "62.5 formats as one decimal")
        assertTest(62.0.formattedOneDecimal() == "62.0", "62 formats with a trailing decimal")
        assertTest(62.456.rounded(toPlaces: 2) == 62.46, "rounded(toPlaces:) rounds half up")
    }
}
