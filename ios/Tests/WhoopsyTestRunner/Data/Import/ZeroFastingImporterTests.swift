import Foundation
import Whoopsy

// MARK: - 20. The import, against an in-memory database

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.

/// Takes the repository rather than building one: §6.2 — the covering-read block in
/// `WorkoutCoveringReadTests` reads what this block wrote, so the two must share the
/// object and the database behind it.
enum ZeroFastingImporterTests {
    static func run(repository: GRDBWorkoutRepository) async throws {
        // MARK: - B. The import, against an in-memory database

        // Two of the parser block's values, re-derived rather than carried over. `parseFasts`
        // is a pure function of a file that is immutable once shipped, so this is the same 170
        // rows that block asserted — §16's `walking` precedent, and §14's `Calendar.current`.
        // §6.2's rule against recreating shared things is about what *accumulates*, and a
        // parsed immutable file is not.
        let fastsURL = zeroFastingURL()
        let rows = (try? ZeroFastingParser.parseFasts(at: fastsURL)) ?? []

        /// The whole export importer, built the way §17 builds it, so the two walks this block compares
        /// run through the same repositories over the same database.
        func makeExportImporter(db: LocalDatabaseManager, calendar: Calendar) -> WhoopExportImporter {
            WhoopExportImporter(
                recoveryRepository: GRDBRecoveryRepository(db: db),
                sleepRepository: GRDBSleepRepository(db: db),
                strainRepository: GRDBStrainRepository(db: db),
                napRepository: GRDBNapRepository(db: db),
                workoutRepository: GRDBWorkoutRepository(db: db),
                userProfileRepository: GRDBUserProfileRepository(db: db),
                calendar: calendar)
        }

        let workoutsURL = whoopExportURL().deletingLastPathComponent()
            .appendingPathComponent("workouts.csv")

        // The repository arrives as a parameter — §6.2. The import below writes into it and the
        // covering-read block later reads what it wrote, so both must be the same object over
        // the same database. Rebuilding it here would leave every assertion in this file green
        // while deleting the guarantee, because the covering read would find an empty database.

        let importer = ZeroFastingImporter(workoutRepository: repository)

        let summary = try? await importer.importFasts(at: fastsURL)
        assertTest(
            summary?.fastsWritten == 170 && summary?.rowsInFile == 170 && summary?.rowsUnreadable == 0,
            "All 170 fasts are written and none is refused: a row reaches the importer only with a "
                + "UUID id and two placeable instants, and both are properties of the file asserted above "
                + "(wrote \(summary?.fastsWritten ?? -1), unreadable \(summary?.rowsUnreadable ?? -1))")

        // The day count is **recomputed here** rather than pinned as a literal. 136 is the UTC answer and
        // the two instants either side of midnight move with the device zone, so a hardcoded count is a
        // test that fails on someone else's machine — §11's rule, and the reason it derives its day keys.
        let dayCalendar = ZeroFastingImportTests.dayCalendar
        let expectedDays = Set(rows.map { dayCalendar.startOfDay(for: $0.startedAt) })
        assertTest(
            summary?.daysWritten == expectedDays.count,
            "…and they land on \(expectedDays.count) distinct start days, recomputed from the parsed rows "
                + "in this device's own calendar rather than pinned — the count is the day each fast "
                + "**started** on, so a fast crossing midnight is filed under the evening it began")

        let firstDay = rows.map(\.startedAt).min().map(dayCalendar.startOfDay)
        let earliest = rows.min { $0.startedAt < $1.startedAt }
        let stored = (try? await repository.getWorkouts(for: firstDay ?? Date())) ?? []
        let fastRow = stored.first { $0.id.uuidString == earliest?.fastID }
        assertTest(
            fastRow != nil,
            "The earliest fast is read back through `getWorkouts(for:)` — the day-keyed reader Home's "
                + "`ACTIVITIES` card is built from — which asks for the day the fast **started** on and "
                + "gets the row whose id is the file's own `FastID` rather than a freshly minted one "
                + "(\(stored.count) rows on that day)")
        assertTest(
            fastRow?.strain == nil && fastRow?.averageHeartRate == nil && fastRow?.maxHeartRate == nil,
            "…and the three figures come back **`nil` and not `0`** — the whole of `v18`, asserted on a "
                + "row read out of the database rather than on the value `makeSession` built, so a record "
                + "or a mapper that decoded NULL as `0` fails here (strain \(String(describing: fastRow?.strain)))")
        assertTest(
            fastRow?.hrZonePercents == nil && fastRow?.steps == nil,
            "…as do the two optional columns beside them, which a fast also has nothing to say about — "
                + "a `0` in either would draw a measured `0:00` zone row and a measured step count on the "
                + "activity detail page")
        assertTest(
            fastRow?.route.isEmpty == true && fastRow?.splits.isEmpty == true,
            "…and the route and the split list are empty rather than absent, because a fasting window was "
                + "not walked and has no laps — there is no producer of either for this row and no way for "
                + "one to appear")
        assertTest(
            fastRow?.source == ZeroFastingImporter.sourceLabel,
            "…and the row is labelled `\(ZeroFastingImporter.sourceLabel)`, the app's **second** `source` "
                + "value. It is the label `recordedWorkoutDays()` excludes and the only way a reader can "
                + "tell a fast from a session something measured (got \(fastRow?.source ?? "nil"))")
        assertTest(
            fastRow?.activityName == WhoopActivityCatalog.fastingName
                && WhoopActivityCatalog.fastingName == "Fast",
            "…and it is named `Fast`, which is the name the picker's recovery section leads with, the one "
                + "`ActivityGlyph` draws as a pair, and the label Home's row uppercases to `FAST` (got "
                + "\(fastRow?.activityName ?? "nil"))")

        // ── The second producer of a fast, asserted against this one ────────────────────────────────────
        //
        // A fast now reaches `workouts` two ways: this importer, and `LiveSessionUseCase.endFast()` writing
        // `ActiveFast.projectedSession(now:)` for one the user started by picking `Fast`. The section above
        // pins the imported shape; **what is asserted here is that the hand-recorded one is the same row**,
        // which is the claim that makes Home's pill, the detail page's fasting layout and the export's day
        // skip work on both without any of them learning about a second producer.
        //
        // It is asserted **here**, in the import section, rather than only in §18's live-session block,
        // because the comparison is against a real imported row and there is no other place in the suite
        // where both are in hand.
        let liveFastRow = ActiveFast(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            .projectedSession(now: Date(timeIntervalSince1970: 1_700_007_200))
        assertTest(
            liveFastRow.strain == nil && liveFastRow.averageHeartRate == nil
                && liveFastRow.maxHeartRate == nil && liveFastRow.hrZonePercents == nil
                && liveFastRow.steps == nil && liveFastRow.route.isEmpty && liveFastRow.splits.isEmpty,
            "A fast this app recorded itself carries the **same five absences and the same two empty "
                + "lists** as one read out of Zero's export — so `v18`'s nullable trio, the zone block and "
                + "the route reach a hand-recorded fast without a second set of decisions about what a fast "
                + "has, and the fasting layout draws one shape rather than two")
        assertTest(
            liveFastRow.activityName == fastRow?.activityName
                && liveFastRow.activityName == WhoopActivityCatalog.fastingName,
            "…and the same name, which is what `ActivityFigure.isFast` and `ActivityGlyph.mark(for:)` both "
                + "key on — a hand-recorded fast named anything else would draw the ordinary layout while "
                + "the export's 170 drew the fasting one (got \(liveFastRow.activityName ?? "nil") against "
                + "\(fastRow?.activityName ?? "nil"))")

        // **The two producers do *not* share a `source`, and that is the deliberate correction to this
        // plan's own first draft.** `source` answers *which producer wrote this row*, and a fast the user
        // started is not an import — `nil` already means *recorded live by this app* and `zero_fasting`
        // means *an importer read it out of a file*, so a hand-recorded fast is a fourth thing and says so.
        // What the two share is the *consequence*: the export's day skip must leave both alone, and that is
        // `ActiveFast.fastSourceValues` — one set in `Domain`, because the importer is `Data` and the fast
        // is the thing being described, and neither may own the other's literal.
        assertTest(
            liveFastRow.source == ActiveFast.sourceLabel
                && fastRow?.source == ZeroFastingImporter.sourceLabel
                && liveFastRow.source != fastRow?.source,
            "A hand-recorded fast and an imported one carry **different** `source` values — `"
                + "\(ActiveFast.sourceLabel)` against `\(ZeroFastingImporter.sourceLabel)` — because the "
                + "column answers *which producer* and one of these is a button and the other a file "
                + "(\(liveFastRow.source ?? "nil") against \(fastRow?.source ?? "nil"))")
        assertTest(
            ActiveFast.fastSourceValues.contains(liveFastRow.source ?? "")
                && ActiveFast.fastSourceValues.contains(fastRow?.source ?? "")
                && !ActiveFast.fastSourceValues.contains("")
                && !ActiveFast.fastSourceValues.contains(WhoopExportImporter.sourceLabel),
            "…and **both labels are members of `ActiveFast.fastSourceValues`**, which is the whole of what "
                + "the two share: the export's day skip filters against that one set, so a fast's start day "
                + "is left alone whichever producer wrote it. `nil`-as-a-string and the export's own label "
                + "are asserted out of the set, because either one inside it would make the skip refuse "
                + "every day this app ever exported — the failure running the other way "
                + "(\(ActiveFast.fastSourceValues.sorted()))")

        // Idempotence. GRDB's `save` is INSERT-or-UPDATE **by primary key**, and the id is the file's own
        // `FastID` — so a second press rewrites the same 170 rows. A `UUID()` minted per run would append
        // 170 more and read back perfectly well, which is why the count is asserted and not the return.
        let secondSummary = try? await importer.importFasts(at: fastsURL)
        let afterSecondImport = (try? await repository.getWorkoutHistory(days: 4000, endingOn: Date())) ?? []
        assertTest(
            secondSummary?.fastsWritten == 170 && afterSecondImport.count == 170,
            "A second import reports the same 170 and the table still holds 170 rows — the id is the "
                + "producer's own, so this is an update rather than an append (wrote "
                + "\(secondSummary?.fastsWritten ?? -1), table \(afterSecondImport.count))")

        // ── The day-skip fix, which is the pair of assertions this whole block exists for ──────────────
        //
        // A fast is a `workouts` row, and `recordedWorkoutDays()` refuses every export row landing on a
        // day that already holds one. Without the `source` filter a fast's start day reads as recorded and
        // the export's rows for it are dropped — measured, 16 rows over 10 days. **Asserted from both
        // directions**, because an order-dependent bug passes whichever single order a test happens to run.
        let fastsFirstDB = LocalDatabaseManager(inMemory: true)
        let fastsFirstRepo = GRDBWorkoutRepository(db: fastsFirstDB)
        _ = try? await ZeroFastingImporter(workoutRepository: fastsFirstRepo).importFasts(at: fastsURL)
        let exportAfterFasts = try? await makeExportImporter(db: fastsFirstDB, calendar: dayCalendar)
            .importWorkouts(at: workoutsURL)
        assertTest(
            exportAfterFasts == 673,
            "With 170 fasts already in `workouts`, the export still writes all **673** of its rows — the "
                + "day-already-recorded skip filters `zero_fasting` out, so a fast's start day does not "
                + "read as a day the export must leave alone. **`673` is the assertion and the shortfall is "
                + "not**, deliberately: without the filter this writes 657 in UTC and 656 in this device's "
                + "zone, because how many export rows share a day with a fast depends on where midnight "
                + "falls (measured: 16 rows over 10 days at UTC, 17 over 12 at UTC−4). The number that holds "
                + "everywhere is the one asserted — every row is written — and a suite that pinned the "
                + "shortfall would fail on someone else's machine, which is §11's rule about hardcoded "
                + "counts (wrote \(exportAfterFasts.map(String.init) ?? "nil"))")

        let exportFirstDB = LocalDatabaseManager(inMemory: true)
        let exportFirstRepo = GRDBWorkoutRepository(db: exportFirstDB)
        let exportBeforeFasts = try? await makeExportImporter(db: exportFirstDB, calendar: dayCalendar)
            .importWorkouts(at: workoutsURL)
        _ = try? await ZeroFastingImporter(workoutRepository: exportFirstRepo).importFasts(at: fastsURL)
        let fastsFirstTotal = ((try? await fastsFirstRepo.getWorkoutHistory(days: 4000, endingOn: Date())) ?? []).count
        let exportFirstTotal = ((try? await exportFirstRepo.getWorkoutHistory(days: 4000, endingOn: Date())) ?? []).count
        assertTest(
            exportBeforeFasts == 673,
            "…and in the other order the export also writes 673 on its own, before any fast exists — the "
                + "baseline the line below compares against (wrote \(exportBeforeFasts.map(String.init) ?? "nil"))")
        assertTest(
            fastsFirstTotal == 843 && exportFirstTotal == 843,
            "**The two buttons are order-independent**: fasts-then-export and export-then-fasts both leave "
                + "843 rows — 170 fasts plus 673 export workouts — because a fast's id is Zero's own "
                + "`FastID`, disjoint from every other producer's, so the second import can only add to a "
                + "day rather than skip it (got \(fastsFirstTotal) and \(exportFirstTotal))")

        // The same pair seen from a day's side rather than the table's, which is what a reader of Home's
        // card actually sees: a day the two files share carries one of each.
        // Parsed **once**, above the closure — an earlier draft called `parseWorkouts` inside `.first`'s
        // predicate and re-read the whole 673-row file once per fast start day, which is the sort of thing
        // that shows up as a suite that outgrows the runner's timeout rather than as a failure.
        let exportDays = Set(
            ((try? WhoopExportParser.parseWorkouts(at: workoutsURL)) ?? [])
                .compactMap { $0.workoutStart.map(dayCalendar.startOfDay) })
        let sharedDay = rows.map { dayCalendar.startOfDay(for: $0.startedAt) }
            .first { exportDays.contains($0) }
        let sharedRows = (try? await fastsFirstRepo.getWorkouts(for: sharedDay ?? Date())) ?? []
        assertTest(
            sharedRows.count >= 2
                && sharedRows.contains { $0.source == ZeroFastingImporter.sourceLabel }
                && sharedRows.contains { $0.source != ZeroFastingImporter.sourceLabel },
            "A day the two files share draws **both** rows on Home's `ACTIVITIES` card — the fast and the "
                + "export's workout beside it, not one replacing the other, which is the visible form of "
                + "the fix (\(sharedRows.count) rows on \(sharedDay.map(String.init(describing:)) ?? "nil"))")

        // An edit survives the other import, and does **not** survive a re-import of its own source. Both
        // halves are recorded rather than left to be discovered: the Settings caption promises the first
        // and warns about the second.
        let editedDB = LocalDatabaseManager(inMemory: true)
        let editedRepo = GRDBWorkoutRepository(db: editedDB)
        let editedImporter = ZeroFastingImporter(workoutRepository: editedRepo)
        _ = try? await editedImporter.importFasts(at: fastsURL)
        let editTargetDay = rows.map { dayCalendar.startOfDay(for: $0.startedAt) }.min() ?? Date()
        if let original = ((try? await editedRepo.getWorkouts(for: editTargetDay)) ?? [])
            .first(where: { $0.source == ZeroFastingImporter.sourceLabel }) {
            var draft = ActivityEditDraft(original)
            draft.setName("Yoga")
            let edited = draft.applying(to: original)
            try? await editedRepo.save(edited)

            _ = try? await makeExportImporter(db: editedDB, calendar: dayCalendar)
                .importWorkouts(at: workoutsURL)
            let afterExport = (try? await editedRepo.getWorkouts(for: editTargetDay)) ?? []
            assertTest(
                afterExport.contains { $0.id == original.id && $0.activityName == "Yoga" },
                "An edit to a fast **survives** the export import — the export skips a day that already "
                    + "holds a workout once the fast is filtered out of that set, and its own row for the "
                    + "day is a different primary key entirely, so the two cannot overwrite each other")

            _ = try? await editedImporter.importFasts(at: fastsURL)
            let afterReimport = (try? await editedRepo.getWorkouts(for: editTargetDay)) ?? []
            assertTest(
                afterReimport.contains { $0.id == original.id && $0.activityName == "Fast" },
                "…and **does not** survive a re-import of the fasts, because the import has no skip at "
                    + "all and rewrites the row from the file. Asserted so the behaviour is recorded: the "
                    + "Settings caption beside the button says a deleted fast comes back, and this is the "
                    + "same fact one step further — an edited one reverts")
        } else {
            assertTest(false, "A fast was readable on its own start day, which the blocks above assert")
        }

        // An absence this section deliberately does **not** re-assert: `LiveSessionUseCase.end()` writing
        // nothing for a session with no samples is §18's, and it is a different rule about a different
        // producer. What §20 owns is the other side — a session written with no *measurement* while still
        // carrying a span, which is a row that exists and reports nothing.
    }
}
