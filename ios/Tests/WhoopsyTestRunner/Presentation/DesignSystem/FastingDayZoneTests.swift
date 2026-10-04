import Foundation
import Whoopsy

// MARK: - 20. The pill follows the day, and the row follows the fast

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.
enum FastingDayZoneTests {
    static func run() async throws {
        // MARK: - C2b. The pill follows the day, and the row follows the fast

        // Everything above is about a session's **own** zone — what `durationSeconds` answers. From here
        // down the question is the one Home actually asks, which is day-scoped: a fast that was underway
        // on the day the user is looking at draws a pill naming the zone it had **reached by the end of
        // that day**. That makes an 86-hour fast draw five different pills, and it is the user's own
        // choice over marking the unfinished days `IN PROGRESS`.
        //
        // **Every day below is built through `dayCalendar`, never through the `utc(...)` helper.** §20
        // already documents the reason at the `expectedDays` block above: a `Date` computed in another
        // zone does not *shift* a day key, it *splits* it. `elapsedSeconds(byEndOf:)` snaps with
        // `Calendar.current` — correctly, so that it agrees with the `date` column `saveWorkout` wrote —
        // so an assertion built on a UTC instant passes at UTC and fails in America/New_York.
        // Re-derived here rather than carried over: the bundled file is immutable and the
        // parser is pure, so this is the same 170 rows the parser block asserted.
        let dayCalendar = ZeroFastingImportTests.dayCalendar
        let rows = (try? ZeroFastingParser.parseFasts(at: zeroFastingURL())) ?? []


        // The shape of the longest fast in `fasts.json` — which runs 2024-10-06 21:00 → 2024-10-10 11:01,
        // 86.01 h. This fixture is the round 86 h at the same clock time, so the five day-ends land on
        // whole hours and the literals below can be read at a glance rather than derived. Days 1–4 end
        // while it is still running, so their elapsed is the whole day; day 5 ends after it, so its
        // elapsed is the clamp — the assertion that catches a missing `min`.
        let longFast = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 10, 6, 21, 0), seconds: 86 * 3600)
        let longFastDays = (0..<5).compactMap {
            dayCalendar.date(byAdding: .day, value: $0, to: longFast.startedAt.startOfDay)
        }
        let expectedDayElapsed: [TimeInterval] = [3 * 3600, 27 * 3600, 51 * 3600, 75 * 3600, 86 * 3600]
        var elapsedMismatches: [String] = []
        for (index, day) in longFastDays.enumerated() {
            let got = longFast.elapsedSeconds(byEndOf: day)
            // A one-second tolerance rather than exact equality, so a device zone whose midnight shift
            // lands inside these five days moves nothing — the literals are hours apart and any of the
            // three ways this arithmetic can be wrong (no snap, no floor, no clamp) misses by far more.
            if abs(got - expectedDayElapsed[index]) > 1 {
                elapsedMismatches.append(
                    "day \(index + 1) gave \(Int(got / 3600))h, expected \(Int(expectedDayElapsed[index] / 3600))h")
            }
        }
        assertTest(
            elapsedMismatches.isEmpty,
            "An 86-hour fast's elapsed time at the end of each of its five days is 3 h, 27 h, 51 h, 75 h "
                + "and **86 h** — the last one is the clamp, since that day's own end is after `endedAt` "
                + "and without the `min` it would keep climbing (mismatches: "
                + "\(elapsedMismatches.joined(separator: "; ")))")

        // A single-day fast is untouched by all of this, which is the claim that says the change is
        // confined to the fasts that actually cross a boundary: its own end is inside its own day, so the
        // clamp returns exactly its duration and the pill it draws is the one it drew before.
        //
        // **06:00 for 15 h, and both numbers are chosen.** The end lands on 21:00 of the same day, which
        // is what makes this a single-day fast at all — 18 h would end at exactly midnight and so be a
        // two-day one, and the assertion would pass while testing the crossing case under a comment
        // claiming it did not. And 15 h is `catabolic`, not `anabolic`: the two rules agreeing on the
        // *first* zone would be a weaker claim than agreeing on a zone that has thresholds on both sides.
        let sameDayFast = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 10, 6, 6, 0), seconds: 15 * 3600)
        assertTest(
            abs(sameDayFast.elapsedSeconds(byEndOf: sameDayFast.startedAt) - sameDayFast.durationSeconds) < 1
                && ActivityFigure.fastingZone(for: sameDayFast, on: sameDayFast.startedAt)
                    == FastingZone.zone(forDurationSeconds: sameDayFast.durationSeconds),
            "A fast that starts and ends on one day is **unaffected**: its own end is inside its own day, "
                + "so the clamp returns its duration exactly and its pill is the one the whole-duration "
                + "table above gives it (got "
                + "\(Int(sameDayFast.elapsedSeconds(byEndOf: sameDayFast.startedAt) / 3600))h against a "
                + "\(Int(sameDayFast.durationSeconds / 3600))h fast)")

        // The two days outside the fast read **different** answers, and the asymmetry is the design rather
        // than an oversight. Before the start the subtraction would go negative, so the `max` floor returns
        // `0` — without it `zone(forDurationSeconds:)` is handed a number below its first threshold, which
        // is not a zone at all. After the end the `min` clamps to `endedAt`, which is *earlier* than that
        // day's own end, so the answer is the fast's whole duration. **That second one is load-bearing**:
        // it is exactly why a session left on a day it no longer covers draws the fast's *overall* zone in
        // the pill, which is what `HomeViewModel.updateWorkout`'s drop branch exists to prevent — so this
        // assertion is the mechanism behind that branch, pinned where it can be seen.
        let dayBefore = dayCalendar.date(byAdding: .day, value: -1, to: longFastDays[0]) ?? longFastDays[0]
        let dayAfter = dayCalendar.date(byAdding: .day, value: 1, to: longFastDays[4]) ?? longFastDays[4]
        assertTest(
            longFast.elapsedSeconds(byEndOf: dayBefore) == 0
                && abs(longFast.elapsedSeconds(byEndOf: dayAfter) - longFast.durationSeconds) < 1,
            "A day before the fast starts reads `0` elapsed, the `max` floor that stops the zone scale "
                + "running backwards — while a day after it ended reads the fast's **whole duration**, "
                + "because the `min` clamps to `endedAt`, which is earlier than that day's own end. The "
                + "second answer is why a row left on a day the session does not cover draws the overall "
                + "zone, and so is the reason `HomeViewModel.updateWorkout` filters by `covers(_:)` (before: "
                + "\(longFast.elapsedSeconds(byEndOf: dayBefore)), after: "
                + "\(Int(longFast.elapsedSeconds(byEndOf: dayAfter) / 3600))h against an "
                + "\(Int(longFast.durationSeconds / 3600))h fast)")

        // **The user's decision, made assertable.** This is the one thing a screenshot of a single day
        // cannot see, and the monotonic progression is the tell that the day-scoped rule is the intended
        // reading: the alternative — the fast's overall zone on day 1 and the reached zone after it —
        // would draw `DEEP KETOSIS` above `KETOSIS`.
        let longFastPills = longFastDays.map { ActivityFigure.fastingZone(for: longFast, on: $0) }
        assertTest(
            longFastPills == [.anabolic, .ketosis, .ketosis, .deepKetosis, .deepKetosis],
            "The 86-hour fast reads `ANABOLIC → KETOSIS → KETOSIS → DEEP KETOSIS → DEEP KETOSIS` down its "
                + "five days, and **not** the same pill five times or the fast's own `DEEP KETOSIS` on "
                + "every one of them (got \(longFastPills.map { $0?.rawValue ?? "nil" }))")
        // Monotonic in the zone scale's own order. Read off `allCases`, which is declaration order and is
        // therefore the published progression — a `FastingZone` carries no rank of its own and does not
        // need one, since the ordering it would state is already this array's.
        let pillRanks = longFastPills.map { pill in
            pill.flatMap { FastingZone.allCases.firstIndex(of: $0) } ?? -1
        }
        assertTest(
            zip(pillRanks, pillRanks.dropFirst()).allSatisfy { $0 <= $1 },
            "…and the five are monotonic, which is the property that rules out the alternative rule: a "
                + "zone that moved backwards down the week would mean the start day was drawing the whole "
                + "fast's zone while the days after it drew a smaller one (got "
                + "\(longFastPills.map { $0?.rawValue ?? "nil" }))")

        // The snapping requirement, asserted as an invariance. `HomeDashboardView.selectedDate` is seeded
        // with `Date()`, stepped by `Calendar.date(byAdding:.day,…)` and written by the month calendar —
        // **none of them snap** — so the day Home hands this function on first load is `today at 14:23`.
        // Nothing else in the suite can see the difference: with `self + 1 day` instead of
        // `startOfDay + 1 day` a mid-fast day inflates by up to 24 h and a day after the fast's end
        // clamps the error away entirely, so the feature would silently no-op on the days it exists for.
        let midAfternoon = ZeroFastingImportTests.localInstant(2024, 10, 8, 14, 23)
        assertTest(
            longFast.elapsedSeconds(byEndOf: midAfternoon)
                == longFast.elapsedSeconds(byEndOf: midAfternoon.startOfDay),
            "The elapsed time for a day is the same whether the day is handed in as midnight or as "
                + "`14:23` — the shape `HomeDashboardView.selectedDate` actually holds — because "
                + "`startOfNextDay` snaps before it adds a day. Without that snap the day would end at "
                + "tomorrow 14:23 and this day would read "
                + "\(Int((midAfternoon.addingTimeInterval(86400).timeIntervalSince(longFast.startedAt)) / 3600))h "
                + "instead of \(Int(longFast.elapsedSeconds(byEndOf: midAfternoon) / 3600))h")

        // The one-second edge, which is the `startOfNextDay`-versus-`endOfDay` decision made visible.
        // `Date.endOfDay` is 23:59:59, so a boundary built on it under-counts every day by exactly one
        // second — and on the real file that flips four fast-days sitting exactly on a zone edge, three
        // of them a whole zone early.
        let onTheEdge = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 10, 7, 20, 0), seconds: 30 * 3600)
        let aSecondLater = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 10, 7, 20, 0, 1), seconds: 30 * 3600)
        assertTest(
            ActivityFigure.fastingZone(for: onTheEdge, on: onTheEdge.startedAt) == .catabolic
                && ActivityFigure.fastingZone(for: aSecondLater, on: aSecondLater.startedAt) == .anabolic,
            "A fast starting at exactly `20:00:00` has run exactly 4 h by its day's end and opens "
                + "`CATABOLIC`; one starting at `20:00:01` has run 3 h 59 m 59 s and stays `ANABOLIC`. That "
                + "pair is the whole of the `startOfNextDay` decision — against `endOfDay` both would read "
                + "`ANABOLIC`, and nothing else in this suite can see a one-second under-count (got "
                + "\(String(describing: ActivityFigure.fastingZone(for: onTheEdge, on: onTheEdge.startedAt))) "
                + "and \(String(describing: ActivityFigure.fastingZone(for: aSecondLater, on: aSecondLater.startedAt))))")

        // The boundary, on real data rather than on a fixture, in the style of the 16-hour canary above.
        // The rule is already swept above as arithmetic; what this adds is that the edges are **reached**
        // by day-appearances in `fasts.json`, so the one-second decision above is load-bearing on the
        // file a user actually imports rather than on a hypothetical.
        // The elapsed figure here is the rule stated out rather than `endedAt − day.startOfDay`, which is
        // a different number on every day but the fast's last: the quantity that decides the pill is
        // cumulative from the fast's own start, so it is `min(endedAt, the day's end) − startedAt`. The
        // two agree only when a fast starts at midnight, which none of these does.
        var dayAppearances: [(day: Date, elapsed: TimeInterval)] = []
        for row in rows {
            var day = dayCalendar.startOfDay(for: row.startedAt)
            let last = dayCalendar.startOfDay(for: row.endedAt)
            while day <= last {
                let dayEnd = dayCalendar.date(byAdding: .day, value: 1, to: day) ?? day
                dayAppearances.append((day, min(row.endedAt, dayEnd).timeIntervalSince(row.startedAt)))
                day = dayEnd
            }
        }
        let exactFourHourDays = dayAppearances.filter { abs($0.elapsed - 4 * 3600) < 1 }
        let exactSixteenHourDays = dayAppearances.filter { abs($0.elapsed - 16 * 3600) < 1 }
        assertTest(
            exactFourHourDays.count >= 3 && exactSixteenHourDays.count >= 1,
            "The bundled file genuinely reaches those edges — measured, three day-appearances land on "
                + "exactly 4 h and one on exactly 16 h. Asserting the *counts* are at least these rather "
                + "than pinning which days, because the number of day-appearances a fast has moves with the "
                + "device's midnight and a pinned list of dates is a test that fails on someone else's "
                + "machine (got \(exactFourHourDays.count) at 4 h, \(exactSixteenHourDays.count) at 16 h)")
        // **And this is what makes them load-bearing**, which the count above cannot say: a boundary built
        // on `Date.endOfDay` is `23:59:59`, so the elapsed comes out one second short and every one of
        // these day-appearances lands in the band *below* the edge it actually sits on. Stated as a count
        // of flips rather than as "the zone is correct", because the latter is a tautology —
        // `zone(forDurationSeconds: 4 * 3600)` is `.catabolic` by definition and cannot fail.
        let wouldFlipUnderEndOfDay = (exactFourHourDays + exactSixteenHourDays).filter {
            FastingZone.zone(forDurationSeconds: $0.elapsed - 1)
                != FastingZone.zone(forDurationSeconds: $0.elapsed)
        }
        let edgeDayCount = exactFourHourDays.count + exactSixteenHourDays.count
        assertTest(
            wouldFlipUnderEndOfDay.count == edgeDayCount,
            "…and every one of them would draw a **different** zone against `endOfDay`, which is the "
                + "whole reason `startOfNextDay` exists: one second short, each lands a band below the edge "
                + "it sits on — \(wouldFlipUnderEndOfDay.count) of \(edgeDayCount) would flip. This is the "
                + "assertion that fails if a half-open bound is ever built on `endOfDay` (did not flip: "
                + "\(edgeDayCount - wouldFlipUnderEndOfDay.count))")

        // The per-day distribution over the whole file, and the reason it is a *property* rather than a
        // literal: **it is zone-dependent.** How many days a fast spans moves with the device's midnight,
        // so `[catabolic: 185, fatBurning: 76, anabolic: 55, ketosis: 8, deepKetosis: 2]` is one machine's
        // answer and not the file's — §11's rule, and the same shape §13's and §15's export guards take.
        let fileFasts = rows.compactMap { row -> WorkoutSession? in
            guard let id = UUID(uuidString: row.fastID) else { return nil }
            return WorkoutSession(
                id: id, startedAt: row.startedAt, endedAt: row.endedAt,
                strain: nil, averageHeartRate: nil, maxHeartRate: nil,
                route: [], splits: [],
                source: ZeroFastingImporter.sourceLabel, activityName: "Fast")
        }
        var perDayZoneCounts: [FastingZone: Int] = [:]
        for fast in fileFasts {
            for pill in ZeroFastingImportTests.coveredDayCandidates(of: fast)
                .compactMap({ ActivityFigure.fastingZone(for: fast, on: $0) }) {
                perDayZoneCounts[pill, default: 0] += 1
            }
        }
        // The bridge between the per-day scale and the session scale. A fast's **last** day is the only day
        // whose elapsed reaches its whole span, so it is the one day whose pill must equal the zone the
        // whole-duration table above gives — and that equality is the clamp's `min` and nothing else.
        // Without it the last day reads past `endedAt`, so a 15 h fast ending at 21:00 draws the zone of a
        // 24 h one. **Do not restate this as "every fast draws a pill"**: `fastingZone` returns non-`nil`
        // for every session that is a fast with no strain, so a presence check is a tautology that cannot
        // fail. It also closes the gap `coveredDayCandidates` leaves open — that walk over-counts a fast
        // ending exactly at midnight, and this says such a day still answers the fast's own zone.
        let wholeDurationPillMismatches = fileFasts.compactMap { fast -> String? in
            let lastDay = dayCalendar.startOfDay(for: fast.endedAt)
            guard let pill = ActivityFigure.fastingZone(for: fast, on: lastDay) else {
                return "\(lastDay) drew no pill on the fast's own last day"
            }
            let whole = FastingZone.zone(forDurationSeconds: fast.durationSeconds)
            return pill == whole
                ? nil
                : "\(lastDay): \(pill.rawValue) against a whole-duration \(whole.rawValue)"
        }
        assertTest(
            wholeDurationPillMismatches.isEmpty,
            "…and every fast's **last** day draws exactly the pill its whole duration scores, which is what "
                + "the `min` in the elapsed clamp buys and the only place the per-day scale is tied back to "
                + "the session scale (wrong: \(wholeDurationPillMismatches))")
        assertTest(
            perDayZoneCounts[.anabolic] != nil,
            "**The red Anabolic pill stops being unreachable.** It is absent from the whole-duration table "
                + "above and present here, because a start day now scores a few hours — measured, it is the "
                + "third most common pill per-day. This is the assertion that fails if the pill ever goes "
                + "back to the session's whole duration (got "
                + "\(String(describing: perDayZoneCounts[.anabolic])))")
        assertTest(
            perDayZoneCounts.values.reduce(0, +) > fileFasts.count,
            "…and there are now more day-appearances than fasts, which is the whole of what this change "
                + "buys: \((perDayZoneCounts.values.reduce(0, +))) appearances over \(fileFasts.count) fasts "
                + "(got \(perDayZoneCounts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")))")

        // Both days of the block's own 16 h 40 m fixture, deliberately. The two gate assertions above are
        // handed its **end** day so their literals survive on every device; this states the day-dependence
        // itself, so the fact that the start day answers `.catabolic` is asserted rather than incidental —
        // and so nobody "simplifies" the two reads back into one on the strength of the end-day literals.
        //
        // Re-derived rather than carried over from the `// MARK: - C.` block that declared it, on the same
        // argument as `longFast` above: `session(_:strain:durationSeconds:)` is a pure function of its
        // arguments, so a fresh call is the same session the figures block asserted against — and unlike
        // `fileFasts` below, this one is not a row of the bundled file but a fixture this section builds.
        let fast = ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 16 * 3600 + 40 * 60)
        assertTest(
            ActivityFigure.fastingZone(for: fast, on: fast.startedAt) == .catabolic,
            "The same 16 h 40 m fast draws a *different* pill on its start day than on its end day, which "
                + "is the deliberate rewrite of every multi-day fast's first row: only 5 h 47 m of it had "
                + "happened by that day's end, so it reads `CATABOLIC` where it used to read the whole "
                + "fast's `FAT BURNING` (got "
                + "\(String(describing: ActivityFigure.fastingZone(for: fast, on: fast.startedAt))))")
    }
}
