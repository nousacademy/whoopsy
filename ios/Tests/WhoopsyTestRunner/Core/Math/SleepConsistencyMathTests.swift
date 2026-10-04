import Foundation
import Whoopsy

enum SleepConsistencyMathTests {
    static func run() async throws {
        // ── 6. The average boundaries ────────────────────────────────────────────────────────────────
        //
        // The two dashed rules on the consistency card. They are a recency-weighted **circular** mean of
        // the four priors' onsets and wakes, and the first assertion below is the one that fails if
        // anyone replaces the circular form with a straight average: on the night clock the two wakes
        // `1410` and `30` straddle the frame's own pivot, so their arithmetic mean is midnight and their
        // circular mean is noon. Twelve hours apart, on a rule a reader checks against the bars.
        assertTest(
            SleepConsistencyMath.circularMean([1410, 30]).map { TypicalRangeTests.near($0, 0) || TypicalRangeTests.near($0, 1440) } == true,
            "Two wakes 11:30 AM and 12:30 PM — night-clock 1410 and 30 — have a circular mean of noon. "
                + "The straight average of the same pair is 720, which on this frame is midnight: the "
                + "twelve-hour error circular averaging exists to remove "
                + "(got \(String(describing: SleepConsistencyMath.circularMean([1410, 30]))) )")

        // The same pair the score's own midnight assertion uses, on the other side of the pivot: a mean
        // that must *not* move. Both answers are 720 here, and the frames are what differ — which is why
        // the demonstration of the twelve-hour error is the formatted one at the end of this block.
        assertTest(
            SleepConsistencyMath.circularMean([710, 730]).map { TypicalRangeTests.near($0, 720) } == true,
            "23:50 and 00:10 are night-clock 710 and 730 and their circular mean is 720 — midnight, four "
                + "hours from either sample rather than twelve")

        // The weighting's direction, which a flat mean cannot see: the same four onsets, weighted, move
        // toward the two the weights favour. 715.9979 is the 4:3:2:1 sum of unit vectors at 177.5° and
        // 182.5° — `atan2(4·sin 2.5°, −10·cos 2.5°)` — computed by hand rather than by this code.
        let weightedMean = SleepConsistencyMath.circularMean(
            [710, 710, 730, 730], weights: [4, 3, 2, 1])
        assertTest(
            weightedMean.map { TypicalRangeTests.near($0, 715.9979) } == true
                && SleepConsistencyMath.circularMean([710, 710, 730, 730]).map { TypicalRangeTests.near($0, 720) } == true,
            "The recency weights move the rule toward the newer pair: the same four onsets average 720 "
                + "flat and 715.9979 weighted 4:3:2:1, which is the 23:50 side "
                + "(got \(String(describing: weightedMean)) )")

        // The degenerate inputs. The first is the one a component-wise guard gets wrong: `sin(.pi)` is
        // `1.2e-16` rather than `0`, so `x != 0 || y != 0` passes a true cancellation and answers six in
        // the morning. The rest are the ordinary absences.
        assertTest(
            SleepConsistencyMath.circularMean([0, 720]) == nil,
            "Two boundaries exactly twelve hours apart have no mean — a cancellation whose resultant is "
                + "the rounding error of the sum, and `nil` rather than an arbitrary one of the two")
        assertTest(
            SleepConsistencyMath.circularMean([]) == nil
                && SleepConsistencyMath.circularMean([1, 2], weights: [1]) == nil
                && SleepConsistencyMath.circularMean([1, 2], weights: [0, 0]) == nil,
            "An empty set, a weight count that does not match, and a set whose weights are all zero are "
                + "each `nil` — no rule rather than a rule through nothing")
        assertTest(
            SleepConsistencyMath.circularMean([1, .nan]).map { TypicalRangeTests.near($0, 1) } == true,
            "A non-finite sample is dropped rather than poisoning the sum, so the one real sample is "
                + "its own mean")

        // ── 7. The frame conversion ──────────────────────────────────────────────────────────────────
        //
        // `clockMinutes(fromNightClock:)` is the inverse the two callouts and the spoken description all
        // read through, and the frame is the one thing on this card a reader cannot check by eye. The two
        // literals are the card's own values.
        assertTest(
            TypicalRangeTests.near(SleepConsistencyMath.clockMinutes(fromNightClock: 714), 1434)
                && TypicalRangeTests.near(SleepConsistencyMath.clockMinutes(fromNightClock: 1196), 476),
            "Night-clock 714 is 11:54 PM and 1196 is 7:56 AM — the pair the card's two callouts print")
        assertTest(
            Date.formattedClock(minutesOfDay: 1434) == "11:54 PM"
                && Date.formattedClock(minutesOfDay: 476) == "7:56 AM",
            "The two callout strings themselves")
        // The formatter reads **minutes past midnight**, so the five axis ticks reach it already converted
        // — 1140 for the 7 PM the axis starts on, and so on — and these are the strings the gutter shows.
        assertTest(
            Date.formattedClock(minutesOfDay: 1140) == "7 PM"
                && Date.formattedClock(minutesOfDay: 1380) == "11 PM"
                && Date.formattedClock(minutesOfDay: 180) == "3 AM"
                && Date.formattedClock(minutesOfDay: 420) == "7 AM"
                && Date.formattedClock(minutesOfDay: 660) == "11 AM"
                && Date.formattedClock(minutesOfDay: 0) == "12 AM"
                && Date.formattedClock(minutesOfDay: 720) == "12 PM"
                && Date.formattedClock(minutesOfDay: 1440) == "12 AM"
                && Date.formattedClock(minutesOfDay: -30) == "11:30 PM",
            "Whole hours drop their `:00` — the five axis ticks are times of night and `:00` is three "
                + "characters of noise five times down a 40pt gutter — while a minute is printed, "
                + "midnight is `12 AM` and not `0 AM`, noon is `12 PM`, and a negative count wraps rather "
                + "than printing `-1:-30 PM` "
                + "(got 1140 → \(Date.formattedClock(minutesOfDay: 1140)), "
                + "180 → \(Date.formattedClock(minutesOfDay: 180)), "
                + "-30 → \(Date.formattedClock(minutesOfDay: -30)))")

        // The twelve-hour error, end to end and in the open. Reading the *naive* mean of the two clocks
        // through the formatter gives noon; reading the circular mean through the frame gives midnight.
        assertTest(
            Date.formattedClock(minutesOfDay: (1430 + 10) / 2) == "12 PM"
                && Date.formattedClock(
                    minutesOfDay: SleepConsistencyMath.clockMinutes(
                        fromNightClock: SleepConsistencyMath.circularMean([710, 730]) ?? .nan))
                    == "12 AM",
            "A bedtime of 11:50 PM and a mean of 00:10 — the naive average of 1430 and 10 minutes past "
                + "midnight is 720, which prints as `12 PM`; the circular mean on the night clock, "
                + "read back through the frame, prints `12 AM`. One of those is the middle of the night "
                + "and the other is lunchtime")

        // The inverse is an inverse, over every hour of the day and through a real `Date` rather than
        // through its own arithmetic restated. An hour the day does not have — a spring-forward gap — is
        // skipped rather than asserted against.
        let roundTrip: Bool = {
            let calendar = Calendar.current
            let base = calendar.startOfDay(for: Date())
            return (0..<24).allSatisfy { hour -> Bool in
                guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base),
                      calendar.component(.hour, from: date) == hour
                else { return true }
                return TypicalRangeTests.near(
                    SleepConsistencyMath.clockMinutes(
                        fromNightClock: SleepConsistencyMath.nightClockMinutes(date, calendar: calendar)),
                    Double(hour * 60))
            }
        }()
        assertTest(
            roundTrip,
            "Every hour of the day survives `nightClockMinutes` → `clockMinutes` unchanged, so the "
                + "conversion and its inverse cannot disagree at any hour a user can go to bed")

    }
}


// MARK: - 13. Sleep Need — the consistency window, scored rather than charted

/// §13's consistency blocks — the window, the recency weights and the four-record rule, all of them
/// about `SleepConsistencyScoring` rather than about the card §15 draws from the same model.
///
/// This file's other enum, `SleepConsistencyMathTests`, is §15's, and covers the chart's own halves
/// of `SleepConsistencyMath` — the average boundaries and the frame conversion. The two sit together
/// because they test one app file, which is the rule this tree is laid out by.
enum SleepConsistencyTests {
    static func run() async throws {
        // ── Sleep Consistency ────────────────────────────────────────────────────────────────────────
        //
        // `SleepConsistencyMath` is the second fitted model in this section and its constants are pinned
        // the same way. The assertions below are the ones that fail if the link function, the weights,
        // the ordering or the window change — each of which was a measured finding, not a preference.
        //
        // Every night here is built on one calendar day and differs only in clock time. `nightClockMinutes`
        // reads hour and minute and nothing else, so which day a date sits on is not part of the model —
        // which is exactly the property that lets an onset before midnight and a wake after it be compared
        // without the caller deciding which day either belongs to.
        //
        // The clock times are set with `bySettingHour:`, not by adding minutes to midnight: `date(byAdding:
        // .minute,)` adds *elapsed* time, so on a spring-forward day 420 minutes after midnight is 08:00
        // on the wall and every literal below would move. The hours used here (22:00–23:59, 06:00–07:59)
        // are outside both the 02:00 gap and the 01:00 fold, so the wall clock is unambiguous all year.
        do {
            let consistencyCalendar = Calendar.current
            let consistencyBase = consistencyCalendar.startOfDay(for: Date())

            /// A clock time, `shift` minutes earlier than `hour`:`minute` on the same wall clock.
            func earlier(_ hour: Int, _ minute: Int, by shift: Int) -> (Int, Int) {
                let total = (hour * 60 + minute - shift + 1440) % 1440
                return (total / 60, total % 60)
            }

            func night(dayOffset: Int, onset: (Int, Int), wake: (Int, Int)) -> SleepConsistencyMath.Night {
                let day = consistencyCalendar.date(
                    byAdding: .day, value: -dayOffset, to: consistencyBase)!
                let onsetDate = consistencyCalendar.date(
                    bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!
                let wakeDate = consistencyCalendar.date(
                    bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!
                return SleepConsistencyMath.Night(day: day, onset: onsetDate, wake: wakeDate)
            }

            // Tonight at 23:00–07:00, and four priors at the same clock times, each shifted later-to-
            // earlier by the given number of minutes on *both* boundaries. The shifts are newest-first.
            func scored(priorsNewestFirst shifts: [Int]) -> Int? {
                let history = shifts.enumerated().map { index, shift in
                    night(
                        dayOffset: index + 1,
                        onset: earlier(23, 0, by: shift),
                        wake: earlier(7, 0, by: shift))
                }
                return SleepConsistencyMath.consistency(
                    for: night(dayOffset: 0, onset: (23, 0), wake: (7, 0)), history: history)
            }

            // ── The formula, pinned to literals ──────────────────────────────────────────────────────
            //
            // P is the recency-weighted mean circular boundary shift in minutes and C = 107.4883 −
            // 1.81848·P^0.60 clipped to 0–100, so each case below is hand-computable from that sentence.
            // Four priors each 30 min off: P = (4+3+2+1)·30·2/10 = 60, raw 86.2754, C = 86. The three
            // newest 30 min off and the oldest on time: P = (4+3+2)·30·2/10 = 54, C = 88. An hour off on
            // every boundary: P = 120, C = 75. No shift at all: raw 107.4883, which the 0–100 clip
            // reduces to a perfect 100.
            let flat = scored(priorsNewestFirst: [0, 0, 0, 0])
            assertTest(
                flat == 100,
                "Four priors at the same clock time score the ceiling — P = 0 gives a raw 107.4883, "
                    + "which clips to 100 (got \(flat.map(String.init) ?? "nil"))")
            let allThirty = scored(priorsNewestFirst: [30, 30, 30, 30])
            assertTest(
                allThirty == 86,
                "Four priors each 30 min off score 86 — P = 60, raw 86.2754 "
                    + "(got \(allThirty.map(String.init) ?? "nil"))")
            let threeRecent = scored(priorsNewestFirst: [30, 30, 30, 0])
            assertTest(
                threeRecent == 88,
                "Three recent priors 30 min off and the oldest on time score 88 — P = 54 "
                    + "(got \(threeRecent.map(String.init) ?? "nil"))")
            let allSixty = scored(priorsNewestFirst: [60, 60, 60, 60])
            assertTest(
                allSixty == 75,
                "An hour of drift on every boundary scores 75 — P = 120 "
                    + "(got \(allSixty.map(String.init) ?? "nil"))")
            assertTest(
                SleepConsistencyMath.shiftInterceptPercent == 107.4883
                    && SleepConsistencyMath.shiftCoefficient == 1.81848
                    && SleepConsistencyMath.shiftExponent == 0.60,
                "The fitted constants are unchanged — they are a least-squares fit over the 891 scorable "
                    + "nights of the bundled export, not a published figure, and the exponent is 0.60 "
                    + "rather than 1 because the score is concave in the mean shift")

            // ── Recency weighting is real, and its direction is the assertion ────────────────────────
            //
            // The same total drift, concentrated in the recent priors or in the old ones, must not score
            // the same. 4:3:2:1 puts (4+3+2)·30 = 270 weighted minutes on the recent arrangement and
            // (1+2+3)·30 = 180 on the old one, so recent drift scores *lower*. An implementation that
            // sorted oldest-first, or that dropped the weights for a flat mean, gets 88 for both — which
            // is why this is a pair and not a single case.
            let oldDrift = scored(priorsNewestFirst: [0, 30, 30, 30])
            assertTest(
                threeRecent == 88 && oldDrift == 92,
                "Drift in the recent nights costs more than the same drift in the old ones "
                    + "(\(threeRecent.map(String.init) ?? "nil") vs \(oldDrift.map(String.init) ?? "nil"))")

            // ── Circular distance, across midnight ───────────────────────────────────────────────────
            //
            // 23:50 and 00:10 are 20 minutes apart, not 1420. 297 of the export's 910 nights have an
            // onset before midnight, so a naive clock subtraction gets 613 of them wrong — and it is
            // wrong by the most exactly where the schedule is most regular.
            assertTest(
                SleepConsistencyMath.circularMinuteDistance(1430, 10) == 20,
                "23:50 and 00:10 are 20 minutes apart, not 1420")
            assertTest(
                SleepConsistencyMath.circularMinuteDistance(10, 1430) == 20,
                "…and the distance is symmetric")
            assertTest(
                SleepConsistencyMath.circularMinuteDistance(0, 720) == 720,
                "The widest possible gap is half a day, not a whole one")

            // The pivot is what makes the pair above 20 rather than 1420: night-clock minutes are
            // measured from noon, so an evening onset and a small-hours onset both land beside the 720
            // mark instead of at opposite ends of a 1440-long day.
            let lateOnset = SleepConsistencyMath.nightClockMinutes(
                night(dayOffset: 0, onset: (23, 50), wake: (7, 0)).onset)
            let earlyOnset = SleepConsistencyMath.nightClockMinutes(
                night(dayOffset: 0, onset: (0, 10), wake: (7, 0)).onset)
            assertTest(
                lateOnset == 710 && earlyOnset == 730,
                "The night clock pivots at noon — 23:50 is 710 and 00:10 is 730, so the two are 20 "
                    + "apart (got \(Int(lateOnset)) and \(Int(earlyOnset)))")

            // A night whose priors sit 20 minutes away across midnight scores near the ceiling. Under a
            // naive minute-of-day difference the same pair differs by 1420 minutes, which the model would
            // clip to 0 — so this single assertion separates the two implementations by 91 points.
            let wrapHistory = (1...4).map { offset in
                night(dayOffset: offset, onset: (0, 10), wake: (7, 10))
            }
            let wrapped = SleepConsistencyMath.consistency(
                for: night(dayOffset: 0, onset: (23, 50), wake: (7, 30)), history: wrapHistory)
            assertTest(
                wrapped == 91,
                "A 23:50 onset against 00:10 priors scores 91 — P = 40, raw 90.8563 "
                    + "(got \(wrapped.map(String.init) ?? "nil"))")

            // ── The window is four nights, counted in records rather than in days ────────────────────
            let baseNight = night(dayOffset: 0, onset: (23, 0), wake: (7, 0))
            for priorCount in 1...3 {
                let short = (1...priorCount).map { night(dayOffset: $0, onset: (23, 0), wake: (7, 0)) }
                assertTest(
                    SleepConsistencyMath.consistency(for: baseNight, history: short) == nil,
                    "\(priorCount) prior night\(priorCount == 1 ? "" : "s") is below the four-night "
                        + "window and scores nothing — there is no partial rendering, because at one "
                        + "prior the model's own MAE is 6.5, worse than saying nothing")
            }
            assertTest(
                SleepConsistencyMath.consistency(
                    for: baseNight,
                    history: (1...4).map { night(dayOffset: $0, onset: (23, 0), wake: (7, 0)) }) != nil,
                "The fourth prior is what makes a night scorable")
            assertTest(
                SleepConsistencyMath.priorNightCount == 4,
                "The window is four priors, not the three WHOOP's own description names — refitting the "
                    + "whole model at each window size peaks at four (MAE 2.749 against 3.119 at three)")
            assertTest(
                SleepConsistencyMath.recencyWeights == [4, 3, 2, 1],
                "The recency weights are 4:3:2:1 (got \(SleepConsistencyMath.recencyWeights))")

            // ── A gap is not four days ───────────────────────────────────────────────────────────────
            //
            // The window is the four most recent *records*, whatever their dates. A night whose fourth
            // predecessor is 10 days back is still scorable. The alternative — deriving the window by
            // subtracting calendar days — is what the export's 137-day recording gap and its 297
            // pre-midnight onsets both break. The caller narrows the read to `historyLookbackDays`; the
            // model itself does not care how far back the record sits.
            let gapHistory = [
                night(dayOffset: 1, onset: (23, 0), wake: (7, 0)),
                night(dayOffset: 2, onset: (23, 0), wake: (7, 0)),
                night(dayOffset: 3, onset: (23, 0), wake: (7, 0)),
                night(dayOffset: 10, onset: (23, 0), wake: (7, 0)),
            ]
            assertTest(
                SleepConsistencyMath.consistency(for: baseNight, history: gapHistory) != nil,
                "A night whose fourth prior is 10 days back is still scored — the window is four "
                    + "records, not four calendar days")
            assertTest(
                SleepConsistencyMath.consistency(for: baseNight, history: Array(gapHistory.prefix(3))) == nil,
                "…and the same history truncated to three records is not, so that assertion is about "
                    + "the fourth record rather than about the gap being forgiven")

            // Ordering is the model's own, not the caller's: the repositories return oldest-first and
            // the importer walks the export in file order, so priors arriving shuffled must score what
            // priors arriving newest-first score.
            let shuffledHistory = [
                night(dayOffset: 3, onset: (23, 30), wake: (7, 30)),
                night(dayOffset: 1, onset: (22, 30), wake: (6, 30)),
                night(dayOffset: 4, onset: (23, 45), wake: (7, 45)),
                night(dayOffset: 2, onset: (23, 0), wake: (7, 0)),
            ]
            assertTest(
                SleepConsistencyMath.consistency(for: baseNight, history: shuffledHistory)
                    == SleepConsistencyMath.consistency(
                        for: baseNight, history: shuffledHistory.sorted { $0.day > $1.day }),
                "The model sorts the history itself — a shuffled array scores what an ordered one does, "
                    + "so the weights land on the right nights either way")

            // A night dated *after* the one being scored is not a predecessor. This is what keeps a
            // forward-dated row — a time-zone artefact, a clock change — from being taken as the most
            // recent prior and given the heaviest weight.
            let futureNight = night(dayOffset: -1, onset: (23, 0), wake: (7, 0))
            assertTest(
                SleepConsistencyMath.consistency(
                    for: baseNight, history: gapHistory + [futureNight]) != nil
                    && SleepConsistencyMath.consistency(
                        for: baseNight, history: Array(gapHistory.prefix(3)) + [futureNight]) == nil,
                "A night dated after the one being scored is not counted as a prior")
        }
    }
}
