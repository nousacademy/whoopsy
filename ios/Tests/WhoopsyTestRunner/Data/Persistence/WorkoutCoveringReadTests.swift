import Foundation
import Whoopsy

// MARK: - 20. The covering read, and the day-key read it must not be merged with

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.

/// Takes the repository the import above wrote through — §6.2. A fresh one would make
/// the covering read below compare against an empty database and pass.
enum WorkoutCoveringReadTests {
    static func run(repository: GRDBWorkoutRepository) async throws {
        // MARK: - C2d. The covering read, and the day-key read it must not be merged with

        // The same re-derivation. Each of these is a pure function of the builders on
        // `ZeroFastingImportTests` and of an immutable bundled file, so a fresh copy is the
        // same value the block above holds.
        let anchor = ZeroFastingImportTests.anchor
        let dayCalendar = ZeroFastingImportTests.dayCalendar
        let rows = (try? ZeroFastingParser.parseFasts(at: zeroFastingURL())) ?? []
        let longFast = ZeroFastingImportTests.fastSession(
            startingAt: ZeroFastingImportTests.localInstant(2024, 10, 6, 21, 0), seconds: 86 * 3600)
        let longFastDays = (0..<5).compactMap {
            dayCalendar.date(byAdding: .day, value: $0, to: longFast.startedAt.startOfDay)
        }
        let dayBefore = dayCalendar.date(byAdding: .day, value: -1, to: longFastDays[0])
            ?? longFastDays[0]
        let dayAfter = dayCalendar.date(byAdding: .day, value: 1, to: longFastDays[4])
            ?? longFastDays[4]
        let fast = ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 16 * 3600 + 40 * 60)

        // The half-open rule at both of its edges, as a Domain value first: `covers(_:)` is the rule the
        // SQL predicate is the index-friendly twin of, and without it the boundary would live only in a
        // query string where the sole coverage is an opaque database fixture.
        let endsAtMidnight = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 5, 1, 23, 0), seconds: 3600)
        // Half a second **past** midnight, not half a second before it. The distinction is the whole of this
        // pair: `seconds: 3599.5` ends at 23:59:59.5 and is a session that never reached the second day at
        // all, which would make the assertion below pass for the wrong reason on a fixture that is not the
        // contrast it claims to be.
        let endsPastMidnight = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 5, 1, 23, 0), seconds: 3600.5)
        let startsAtMidnight = ZeroFastingImportTests.fastSession(startingAt: ZeroFastingImportTests.localInstant(2024, 5, 3, 0, 0), seconds: 3600)
        let may1 = ZeroFastingImportTests.localInstant(2024, 5, 1, 0, 0)
        let may2 = ZeroFastingImportTests.localInstant(2024, 5, 2, 0, 0)
        let may3 = ZeroFastingImportTests.localInstant(2024, 5, 3, 0, 0)
        assertTest(
            endsAtMidnight.covers(may1) && !endsAtMidnight.covers(may2),
            "A session from 23:00 to exactly `00:00:00` covers the day it started on and **not** the day "
                + "it ended at — the half-open upper edge, and the difference between a fast drawn on four "
                + "days and on five (covers 05-01: \(endsAtMidnight.covers(may1)), covers 05-02: "
                + "\(endsAtMidnight.covers(may2)))")
        assertTest(
            endsPastMidnight.covers(may1) && endsPastMidnight.covers(may2),
            "…while half a second **past** midnight is still underway on the second day, which is what makes "
                + "the edge a boundary rather than an off-by-one the other way — the two fixtures differ by "
                + "one second of span and by a whole day of coverage (covers 05-02: "
                + "\(endsPastMidnight.covers(may2)))")
        assertTest(
            startsAtMidnight.covers(may3) && !startsAtMidnight.covers(may2),
            "…and a session starting exactly at `00:00:00` covers that day and not the one before it — "
                + "the lower edge, which an inclusive test would get wrong in the opposite direction "
                + "(covers 05-02: \(startsAtMidnight.covers(may2)), covers 05-03: "
                + "\(startsAtMidnight.covers(may3)))")

        // The twin: for every probe day, the Domain rule and the SQL read must name the same sessions.
        // This is the assertion that keeps the two honest — the SQL is what the app runs, and `covers` is
        // what a test can pin, so a change to either that the other does not follow fails here.
        let edgeDB = LocalDatabaseManager(inMemory: true)
        let edgeRepo = GRDBWorkoutRepository(db: edgeDB)
        let edgeFixtures = [endsAtMidnight, endsPastMidnight, startsAtMidnight]
        for fixture in edgeFixtures { try? await edgeRepo.save(fixture) }
        let probeDays = [may1, may2, may3, ZeroFastingImportTests.localInstant(2024, 4, 30, 12, 0), ZeroFastingImportTests.localInstant(2024, 5, 4, 12, 0)]
        var disagreements: [String] = []
        for day in probeDays {
            let byRule = Set(edgeFixtures.filter { $0.covers(day) }.map(\.id))
            let bySQL = Set(((try? await edgeRepo.getWorkouts(covering: day)) ?? []).map(\.id))
            if byRule != bySQL {
                disagreements.append("\(day.startOfDay): rule \(byRule.count), read \(bySQL.count)")
            }
        }
        assertTest(
            disagreements.isEmpty,
            "`WorkoutSession.covers(_:)` and `getWorkouts(covering:)` return the same sessions on every "
                + "probe day, including the two days outside every fixture — the assertion that keeps the "
                + "Domain rule and the SQL predicate from drifting apart, since only one of the two is what "
                + "the app runs and only the other is what a value-level test can pin (disagreements: "
                + "\(disagreements.joined(separator: "; ")))")

        // **The two reads disagree by design, and this is the assertion that fails if someone simplifies
        // them back into one.** The covering read is Home's; the day-key read is the strain page's, the
        // zone aggregates' and the export's day skip. Merging them would double-count a crossing session's
        // zone block, because `WorkoutSession.zoneSeconds(_:)` scales WHOOP's share by the session's whole
        // span.
        let splitDB = LocalDatabaseManager(inMemory: true)
        let splitRepo = GRDBWorkoutRepository(db: splitDB)
        try? await splitRepo.save(longFast)
        var coveringDays = 0
        var dayKeyDays = 0
        for day in longFastDays {
            if ((try? await splitRepo.getWorkouts(covering: day)) ?? []).contains(where: { $0.id == longFast.id }) {
                coveringDays += 1
            }
            if ((try? await splitRepo.getWorkouts(for: day)) ?? []).contains(where: { $0.id == longFast.id }) {
                dayKeyDays += 1
            }
        }
        assertTest(
            coveringDays == 5 && dayKeyDays == 1,
            "On the 86-hour fast's five covered days the **covering** read returns it on all five while the "
                + "**day-key** read returns it on exactly one — the day it started. Both numbers are the "
                + "point: five is the feature, and one is why the two reads cannot be merged (covering "
                + "\(coveringDays), day-key \(dayKeyDays))")
        // Hoisted out of the assertion rather than awaited inside it: `&&`'s right operand is an
        // `@autoclosure`, which cannot be `async`, so an `await` on either side of it is a compile error.
        let beforeDayCount = ((try? await splitRepo.getWorkouts(covering: dayBefore)) ?? []).count
        let afterDayCount = ((try? await splitRepo.getWorkouts(covering: dayAfter)) ?? []).count
        assertTest(
            beforeDayCount == 0 && afterDayCount == 0,
            "…and the day before it started and the day after it ended are both empty from the covering "
                + "read, so the extra rows are exactly the days it was underway on and not a wider net "
                + "(before: \(beforeDayCount), after: \(afterDayCount))")

        // The same property over the whole file, against the database the import actually wrote. The
        // expected map is derived from the half-open rule stated independently — a day is covered when
        // the fast had started before the day ended and had not ended before the day began — rather than
        // by calling `covers(_:)`, so this compares the app's SQL against a reader's own statement of the
        // rule instead of against itself.
        var expectedCovering: [Date: Set<String>] = [:]
        for row in rows {
            var day = dayCalendar.startOfDay(for: row.startedAt)
            let last = dayCalendar.startOfDay(for: row.endedAt)
            while day <= last {
                let nextDay = dayCalendar.date(byAdding: .day, value: 1, to: day) ?? day
                if row.startedAt < nextDay && row.endedAt > day {
                    expectedCovering[day, default: []].insert(row.fastID)
                }
                day = nextDay
            }
        }
        var coveringMismatches: [String] = []
        for (day, expected) in expectedCovering {
            let actual = Set(((try? await repository.getWorkouts(covering: day)) ?? []).map(\.id.uuidString))
            if actual != expected {
                coveringMismatches.append(
                    "\(day.startOfDay): got \(actual.count), expected \(expected.count)")
            }
        }
        assertTest(
            coveringMismatches.isEmpty,
            "Over all 170 fasts and every day any of them touches (\(expectedCovering.count) days), the "
                + "covering read returns exactly the fasts that were underway on that day — as a property "
                + "rather than a pinned count, because how many days a fast spans and therefore how many "
                + "day-appearances there are moves with the device's midnight (mismatches: "
                + "\(coveringMismatches.sorted().prefix(5).joined(separator: "; ")))")
        assertTest(
            expectedCovering.values.reduce(0) { $0 + $1.count } > rows.count,
            "…and those appearances outnumber the fasts, which is the whole of the change: "
                + "\(expectedCovering.values.reduce(0) { $0 + $1.count }) day-appearances over "
                + "\(rows.count) fasts, on \(expectedCovering.count) distinct days")

        // The fit. `drawnWidth` is a bound from nominal character metrics rather than a measurement, so
        // this proves the arithmetic leaves room and not that a label lands inside the row on a given OS.
        assertTest(
            FastingZonePill.widest == .deepKetosis,
            "The widest label is `DEEP KETOSIS`, which is the one the fit below has to be made against — "
                + "`widest` is computed so a longer label added later moves the assertion with it (got "
                + "\(FastingZonePill.widest.rawValue))")
        let pillWidth = FastingZonePill.drawnWidth(
            of: FastingZonePill.widest, atPointSize: FastingZonePill.fontSize)
        // The slot the pill draws in on the narrowest iPhone this app runs on. The device is 375pt wide,
        // Home insets the card by 16 a side and the card insets its rows by 14, leaving a 315pt row. From
        // that the leading chip takes `chipDiameter`, the `HStack(spacing: 12)` one gap, the
        // `Spacer(minLength: 8)` its floor, and the two-line trailing time range an allowance of 90.
        let pillSlot = CGFloat(375 - 32 - 28) - ActivityGlyph.chipDiameter - 12 - 8 - 90
        assertTest(
            pillWidth < pillSlot,
            "The widest pill fits the slot the figure it replaces occupies, on the narrowest screen this "
                + "app runs on — a label wider than its row is invisible to every build and to any "
                + "screenshot of a different row, which is why the arithmetic is asserted rather than "
                + "looked at (bound \(String(format: "%.1f", pillWidth))pt against a \(String(format: "%.1f", pillSlot))pt slot)")

        // The baseline's third population. `window(for:in:)` is what selects the priors in the app, and
        // these are handed in directly so the block is about `summary`'s own floors.
        let threeFasts = [
            ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 15 * 3600),
            ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 16 * 3600),
            ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 17 * 3600),
        ]
        let fastSummary = ActivityBaseline.summary(
            for: ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 16 * 3600), priorSessions: threeFasts)
        assertTest(
            fastSummary.meanStrain == nil && fastSummary.strainSessionCount == 0,
            "A window of ten fasts withholds the strain rather than reporting `0.0` — the fabricated "
                + "figure `BaselineStatisticsMath.mean([])` would otherwise print, and exactly the claim "
                + "*measured, and no strain at all* that a fast cannot make (mean "
                + "\(fastSummary.meanStrain.map(String.init(describing:)) ?? "nil"))")
        assertTest(
            fastSummary.sessionCount == 3 && fastSummary.typicalDuration != nil,
            "…while the window itself is still counted and still bands, so the page draws and only the "
                + "**strain badge** is withheld — a session's duration and its strain are different "
                + "populations and one being empty says nothing about the other (count "
                + "\(fastSummary.sessionCount))")
        assertTest(
            fastSummary.meanSteps == nil && fastSummary.stepSessionCount == 0,
            "…and the step mean is withheld for its own reason on the same card, which is what makes the "
                + "two independent floors worth asserting apart rather than together")

        let mixedPriors = threeFasts + [
            ZeroFastingImportTests.session("Fast", strain: 6.0), ZeroFastingImportTests.session("Fast", strain: 7.0), ZeroFastingImportTests.session("Fast", strain: 8.0),
            ZeroFastingImportTests.session("Fast", strain: nil), ZeroFastingImportTests.session("Fast", strain: nil), ZeroFastingImportTests.session("Fast", strain: nil),
            ZeroFastingImportTests.session("Fast", strain: nil),
        ]
        let mixedSummary = ActivityBaseline.summary(for: fast, priorSessions: mixedPriors)
        assertTest(
            mixedSummary.meanStrain == 7.0 && mixedSummary.strainSessionCount == 3,
            "Three measured seeds inside ten priors give the mean of the **three** — `7.0`, not the "
                + "`2.1` an average over the whole window with `?? 0` produces, which is the diluted "
                + "figure that would look like a plausible strain and be wrong by a factor of three "
                + "(mean \(mixedSummary.meanStrain.map(String.init(describing:)) ?? "nil"), over "
                + "\(mixedSummary.strainSessionCount))")
        assertTest(
            mixedSummary.sessionCount == 10,
            "…and the count that names the window is still 10, so a fourth of the priors carrying a "
                + "strain does not narrow what the card says it compared against — the same rule "
                + "`stepSessionCount` already follows beside it (count \(mixedSummary.sessionCount))")

        // The zone aggregate, which is the strain detail page's two HR ZONE rows. `aggregate` filters to
        // the sessions carrying a block, so a fast beside a zoned row contributes nothing and does not
        // turn the answer into a `0:00`.
        let zoned = WorkoutSession(
            startedAt: anchor, endedAt: anchor.addingTimeInterval(600),
            strain: 4.0, averageHeartRate: 130, maxHeartRate: 170,
            route: [], splits: [],
            source: "whoop_export", activityName: "Basketball",
            hrZonePercents: [10, 20, 30, 20, 10])
        assertTest(
            WorkoutZoneTime.aggregate([fast]) == nil,
            "A day holding only a fast aggregates to `nil` rather than to `0:00` — `aggregate` filters to "
                + "the sessions that carry a zone block and a fast carries none, so the absent answer is "
                + "the one the reader already knows how to draw as a dash")
        let aggregate = WorkoutZoneTime.aggregate([fast, zoned])
        assertTest(
            aggregate != nil && aggregate?.zone1to3Seconds == zoned.zone1to3Seconds
                && aggregate?.zone4to5Seconds == zoned.zone4to5Seconds,
            "…and a fast beside a zoned session aggregates to the zoned session's own two figures, "
                + "neither diluted by the fast nor doubled by it — the pair `WorkoutZoneTime.aggregate` "
                + "already filtered for and that `v18` gives a second chance to get wrong (got "
                + "\(aggregate.map { "\($0.zone1to3Seconds)/\($0.zone4to5Seconds)" } ?? "nil") against "
                + "\(zoned.zone1to3Seconds.map(String.init(describing:)) ?? "nil")/"
                + "\(zoned.zone4to5Seconds.map(String.init(describing:)) ?? "nil"))")
    }
}
