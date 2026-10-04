import Foundation
import Whoopsy

// MARK: - 20. The end clock a fast's row prints, and what "in progress" means

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.
enum FastingEndTextTests {
    static func run() async throws {
        // MARK: - C2c. The end clock a fast's row prints, and what "in progress" means

        // Re-derived per file rather than hoisted: each of these is a pure function of the
        // builders on `ZeroFastingImportTests` and of an immutable bundled file, so every
        // consumer gets the same value — and re-deriving costs six lines here where hoisting
        // would have rewritten some thirty-five call sites in the block above.
        let dayCalendar = ZeroFastingImportTests.dayCalendar
        let rows = (try? ZeroFastingParser.parseFasts(at: zeroFastingURL())) ?? []
        let longFast = ZeroFastingImportTests.fastSession(
            startingAt: ZeroFastingImportTests.localInstant(2024, 10, 6, 21, 0), seconds: 86 * 3600)
        let longFastDays = (0..<5).compactMap {
            dayCalendar.date(byAdding: .day, value: $0, to: longFast.startedAt.startOfDay)
        }
        let sameDayFast = ZeroFastingImportTests.fastSession(
            startingAt: ZeroFastingImportTests.localInstant(2024, 10, 6, 6, 0), seconds: 15 * 3600)
        let fileFasts = rows.compactMap { row -> WorkoutSession? in
            guard let id = UUID(uuidString: row.fastID) else { return nil }
            return WorkoutSession(
                id: id, startedAt: row.startedAt, endedAt: row.endedAt,
                strain: nil, averageHeartRate: nil, maxHeartRate: nil,
                route: [], splits: [],
                source: ZeroFastingImporter.sourceLabel, activityName: "Fast")
        }

        // The other half of the same day-scoped rule, and the user's own second request:
        //
        //     a day the fast ran to the end of   →  `11:59 PM`, that day's own last minute
        //     the day it is running on right now →  `ACTIVE`
        //     the day it ended on, and every single-day fast → its own end clock, unchanged
        //
        // The reason it is a rule at all: without it a covered day prints the fast's **own end clock**, so a
        // fast that ended at 11:01 on its last day claims to have ended at 11:01 on each of the four days
        // before it too — four rows stating a finished fast on days it was still running.
        //
        // **`now` is handed in everywhere below rather than read inside the function**, which is
        // `DayBarRules`' reason: a rule about "in progress" that read `Date()` would assert something
        // different tomorrow, and this one is asserted as a *pair* of `now` values where the only thing
        // that moves is whether the fast is running.
        let longAfter = ZeroFastingImportTests.localInstant(2030, 1, 1, 12, 0)
        assertTest(
            (rows.map(\.endedAt).max() ?? .distantFuture) < longAfter,
            "Pinning `now` to 2030 puts every fast in the bundled file in the past, which is what makes the "
                + "whole-day rule the only one in play in the assertions below and makes "
                + "`ActivityFigure.inProgressText` unreachable from the file — it is reachable only from the "
                + "fixture further down. The file's last fast ends "
                + "\(rows.map(\.endedAt).max().map { $0.formattedShortDate() } ?? "nil")")
        let longFastEndTexts = longFastDays.map {
            ActivityFigure.fastingEndText(for: longFast, on: $0, now: longAfter)
        }
        assertTest(
            longFastEndTexts == ["11:59 PM", "11:59 PM", "11:59 PM", "11:59 PM", nil],
            "The 86-hour fast prints `11:59 PM` on each of the four days it was still running at the end of, "
                + "and `nil` on the fifth — the one day it ended on, where the row falls back to the fast's "
                + "own end clock. `nil` is the *absent override* rather than an absence: it is what hands "
                + "the trailing half back to `timeRange`, which is the shared drawing every other row on the "
                + "card uses (got "
                + "\(longFastEndTexts.map { $0 ?? "the real end" }))")
        // The row as it is actually composed: `HomeDashboardView.timeRange` prints
        // `"\(start.formattedHourMinute()) / \(endText ?? end.formattedHourMinute())"`, so this is the
        // string a reader sees on the first day — the user's own example, `Sun 9:00 PM / 11:59`, with this
        // fixture's Sunday. It also pins the *left* half, which must not move: the start clock and the
        // weekday badge stay the fast's own on every day it covers.
        let firstDayRow = "\(longFast.startedAt.formattedHourMinute()) / "
            + (longFastEndTexts[0] ?? longFast.endedAt.formattedHourMinute())
        assertTest(
            firstDayRow == "9:00 PM / 11:59 PM",
            "…and the row for that first day reads `9:00 PM / 11:59 PM` — the fast's own start clock on the "
                + "left, unchanged, and that day's last minute instead of the fast's `11:00 AM` end on the "
                + "right (got \(firstDayRow))")
        let lastDayRow = "\(longFast.startedAt.formattedHourMinute()) / "
            + (longFastEndTexts[4] ?? longFast.endedAt.formattedHourMinute())
        assertTest(
            lastDayRow == "9:00 PM / 11:00 AM",
            "…while the day the fast actually ended on still prints the fast's own end, so the five rows "
                + "read as one fast shortening to its real end rather than as five identical claims (got "
                + "\(lastDayRow))")

        // The in-progress branch. It needs a fixture because the bundled file cannot produce one — every
        // fast in it has ended, which the assertion above records — and it is asserted as a **pair** of the
        // same session under two `now` values, so what flips the text is the fast's state and not the day
        // being drawn.
        let now = ZeroFastingImportTests.localInstant(2026, 3, 11, 10, 0)
        let running = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2026, 3, 9, 21, 0), seconds: 60 * 3600)
        let runningDays = ZeroFastingImportTests.coveredDayCandidates(of: running).filter { running.covers($0) }
        let runningTexts = runningDays.map {
            ActivityFigure.fastingEndText(for: running, on: $0, now: now)
        }
        assertTest(
            runningTexts == ["11:59 PM", "11:59 PM", "ACTIVE", nil],
            "A fast that started on the 9th at 21:00 and runs 60 hours reads `ACTIVE` on the day it is "
                + "running *now* — and `11:59 PM` on the two days behind it, and its own end clock on the "
                + "day it will end on. Both halves matter: an `ACTIVE` on every covered day would say the "
                + "fast is still running on days that are over, and an `11:59 PM` on today would claim an "
                + "end it has not reached (got \(runningTexts.map { $0 ?? "the real end" }))")
        let afterItEnded = runningDays.map {
            ActivityFigure.fastingEndText(for: running, on: $0, now: ZeroFastingImportTests.localInstant(2026, 3, 13, 10, 0))
        }
        assertTest(
            afterItEnded == ["11:59 PM", "11:59 PM", "11:59 PM", nil],
            "…and the **same session** two days later reads `11:59 PM` on that third day, so `ACTIVE` is a "
                + "fact about the fast still running and not about which day the card happens to be drawing. "
                + "This is the pair the branch is asserted as, and neither half alone can tell the two rules "
                + "apart (got \(afterItEnded.map { $0 ?? "the real end" }))")

        // The day it stopped on. A fast that ended this morning is not in progress, so today's row prints
        // its real end rather than `ACTIVE` — the "running" test is `now < endedAt` and not "the card is
        // showing today".
        let endedThisMorning = ZeroFastingImportTests.fastSession(
            startingAt: ZeroFastingImportTests.localInstant(2026, 3, 10, 20, 0), seconds: 13 * 3600)
        let endedTexts = ZeroFastingImportTests.coveredDayCandidates(of: endedThisMorning)
            .filter { endedThisMorning.covers($0) }
            .map { ActivityFigure.fastingEndText(for: endedThisMorning, on: $0, now: now) }
        assertTest(
            endedTexts == ["11:59 PM", nil],
            "A fast that ended at 09:00 this morning reads `11:59 PM` on yesterday and its own `9:00 AM` "
                + "end on today — *not* `ACTIVE`. A rule keyed on the day being today rather than on the "
                + "fast still running would say a finished fast is in progress for the whole of the day it "
                + "ended on, which is the failure this pair exists to catch (got "
                + "\(endedTexts.map { $0 ?? "the real end" }))")
        assertTest(
            ActivityFigure.fastingEndText(for: endedThisMorning, on: now.startOfDay, now: now) == nil,
            "…stated once more on its own so the `nil` is unambiguous: today's row for a fast that stopped "
                + "this morning is the absent override, which is what makes `timeRange` print the fast's own "
                + "end clock (got "
                + "\(String(describing: ActivityFigure.fastingEndText(for: endedThisMorning, on: now.startOfDay, now: now))))")

        // The single-day fast, which is the 19 of the 170 the pill's block above shows are untouched — and
        // it is untouched here for the same reason: its own end is inside its own day, so the override is
        // never reached and the row prints `6:00 AM / 9:00 PM` exactly as it always has.
        assertTest(
            ActivityFigure.fastingEndText(for: sameDayFast, on: sameDayFast.startedAt, now: longAfter) == nil,
            "A fast that starts and ends on one day gets no override at all, so the change is confined to "
                + "the fasts that actually cross a midnight — the same claim the pill's block makes, asserted "
                + "on the other half of the row (got "
                + "\(String(describing: ActivityFigure.fastingEndText(for: sameDayFast, on: sameDayFast.startedAt, now: longAfter))))")

        // The one case where `>=` and `>` differ, and it is the half-open convention again: a fast ending at
        // exactly `00:00:00` ran to the day's last instant, so the day reads `11:59 PM`. Under `>` the row
        // would print `12:00 AM` — a clock time belonging to a day the covering read excludes, so no row
        // anywhere would be about it.
        let midnightFast = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 5, 1, 23, 0), seconds: 3600)
        assertTest(
            ActivityFigure.fastingEndText(
                for: midnightFast, on: dayCalendar.startOfDay(for: midnightFast.startedAt), now: longAfter
            ) == "11:59 PM",
            "A fast ending at exactly `00:00:00` reads `11:59 PM` on the day it ran to the last instant of, "
                + "rather than `12:00 AM` — the `>=` in the day-end comparison, and the boundary case that "
                + "decides it (got "
                + "\(String(describing: ActivityFigure.fastingEndText(for: midnightFast, on: dayCalendar.startOfDay(for: midnightFast.startedAt), now: longAfter))))")

        // The gate, and it is `fastingZone`'s gate rather than a second one: this app holds **one**
        // definition of which rows are fasts, so the two rules cannot come to disagree about a row that is
        // drawn with a pill on one half and a day-end clock on the other.
        let measuredLongFast = WorkoutSession(
            startedAt: longFast.startedAt, endedAt: longFast.endedAt,
            strain: 7.4, averageHeartRate: 121, maxHeartRate: 164,
            route: [], splits: [],
            source: ZeroFastingImporter.sourceLabel, activityName: "Fast")
        assertTest(
            ActivityFigure.fastingEndText(for: measuredLongFast, on: longFastDays[0], now: longAfter) == nil
                && ActivityFigure.fastingZone(for: measuredLongFast, on: longFastDays[0]) == nil,
            "A session named `Fast` that **measured a strain** gets neither the pill nor the day-end clock: "
                + "its headline is the strain and its range is its own two clock times, exactly as before "
                + "`v18`. Two gates that could drift would let a row draw a pill over a figure it is not "
                + "drawing, or claim a fast's day-span on a row that is being drawn as a measured session "
                + "(end text "
                + "\(String(describing: ActivityFigure.fastingEndText(for: measuredLongFast, on: longFastDays[0], now: longAfter))), "
                + "pill \(String(describing: ActivityFigure.fastingZone(for: measuredLongFast, on: longFastDays[0]))))")
        // …and the name gate, on a session with **the same span**, so the only thing differing from
        // `longFast` is what it is called. A day on which the rule would otherwise fire is the only place
        // this can be tested: a short session is `nil` for the span reason and would pass either way.
        let longWalk = WorkoutSession(
            startedAt: longFast.startedAt, endedAt: longFast.endedAt,
            strain: nil, averageHeartRate: nil, maxHeartRate: nil,
            route: [], splits: [],
            source: "whoop_export", activityName: "Walking")
        assertTest(
            longFastDays.allSatisfy {
                ActivityFigure.fastingEndText(for: longWalk, on: $0, now: longAfter) == nil
            },
            "…while an identically-spanning session that is not a fast prints its own end on every one of "
                + "those days, so the rule is keyed on the row being a fast and not on a session merely "
                + "being long. That is the user's scope — *home screen **fasting** activity update* — and it "
                + "is what keeps the export's three cross-midnight workouts, the `SLEEP` row and every "
                + "measured row printing their own two clock times (got "
                + "\(longFastDays.map { ActivityFigure.fastingEndText(for: longWalk, on: $0, now: longAfter) ?? "the real end" }))")

        // The property over the real file, in this section's shape: a pinned count would break on a device
        // zone that merges two day keys, so the claim is stated as a shape every fast must have.
        //
        // **The day it printed its own end on is exactly one per fast** — the day it ended on — and every
        // other day it covers reads the day's own last minute. That is stated without calling the function
        // under test to derive the expectation: the covering population comes from `covers(_:)`, which is
        // §20's own statement of the half-open rule and the twin of the SQL read.
        var endTextProblems: [String] = []
        for fast in fileFasts {
            let covered = ZeroFastingImportTests.coveredDayCandidates(of: fast).filter { fast.covers($0) }
            let texts = covered.map { ActivityFigure.fastingEndText(for: fast, on: $0, now: longAfter) }
            let ownEndDays = texts.filter { $0 == nil }.count
            if ownEndDays != 1 {
                endTextProblems.append(
                    "\(fast.startedAt.startOfDay): \(ownEndDays) days printed its own end, expected 1")
            }
            for (day, text) in zip(covered, texts) where text != nil && text != "11:59 PM" {
                endTextProblems.append("\(day.startOfDay) read \(text ?? "nil")")
            }
        }
        assertTest(
            endTextProblems.isEmpty,
            "Over all 170 fasts and every day one covers, each fast hands back the override on every day "
                + "but the one it ended on, and the override it hands back is always the day's own last "
                + "minute — the whole rule as a property rather than a pinned count, since how many days a "
                + "fast covers moves with the device's midnight (problems: "
                + "\(endTextProblems.sorted().prefix(5).joined(separator: "; ")))")
    }
}
