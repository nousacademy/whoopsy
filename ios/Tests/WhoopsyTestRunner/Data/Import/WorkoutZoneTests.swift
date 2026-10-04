import Foundation
import SwiftUI
import Whoopsy

// MARK: - 17. Heart-rate zone time out of `workouts.csv`

/// The strain page's two `HEART RATE ZONES` rows, and the file they are read out of.
///
/// **What this section is evidence for, and what it is not.** It reads a CSV that ships inside the
/// app bundle, derives a stable identity for each of its 673 rows, stores five percentages in a JSON
/// text column and sums them by day. It touches no BLE path and no heart rate: the figures on the
/// screen are WHOOP's own zone percentages out of WHOOP's own export, scaled by each workout's span.
/// `biometric_samples` holds **0 rows** in every database on this machine, so a passing run here is
/// not evidence that a strap produces a zone, and no screenshot may be offered as one.
///
/// The section is built around three things a wrong implementation gets silently right elsewhere:
/// the parser's refusal to read the wrong file, the id's determinism (a `UUID()` writes 673 more rows
/// on every press and reads back perfectly well), and the difference between a measured `0:00` and an
/// absent block — the bundled file holds 45 rows of the first kind.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum WorkoutZoneTests {
    static func run() async throws {
        // The receptive inactivity vocabulary runs **first and above the CSV read**, so it still asserts
        // if the file below it throws — §14's `+`-menu block placed the same way inside its own section,
        // and for the same reason. It is the activity-name path's second catalogue and it shares
        // `ActivityGlyph` and `ActivityName.normalised` with the first, which is why it lives in this
        // section rather than beside the card it draws on.
        try await ReceptiveInactivityCatalogTests.run()

        let workoutsURL = whoopExportURL().deletingLastPathComponent()
            .appendingPathComponent("workouts.csv")

        // MARK: The parser

        let rows = (try? WhoopExportParser.parseWorkouts(at: workoutsURL)) ?? []
        assertTest(
            rows.count == 673,
            "The bundled `workouts.csv` parses to its 673 rows — every one of which is a workout, so "
                + "unlike the naps there is nothing to filter (got \(rows.count))")
        assertTest(
            rows.allSatisfy { $0.workoutStart != nil && $0.workoutEnd != nil },
            "Every row carries both instants: `parseWorkouts` requires `Workout start time` and "
                + "`Workout end time` as columns, and a row whose cells were empty would leave the "
                + "importer with a start and no end rather than with a parse failure")
        assertTest(
            rows.allSatisfy { $0.hrZonePercents.map(\.count) == 5 || $0.hrZonePercents == nil },
            "…and the zone block is **five values or none** on every row, which is `zonePercents()`'s "
                + "whole rule: a row short by even one cell reads as no block at all rather than as a "
                + "partial set summing to a confident figure")

        // The file's own resolution, asserted as a property rather than as a count so a device time zone
        // that merges two day keys cannot break it. The five sum to **at most** 100 and often well below
        // it — the remainder is time below zone 1, which WHOOP publishes no column for — so a reader that
        // treated the pair as the workout's whole duration is wrong in a way nothing on screen says.
        let blocks = rows.compactMap(\.hrZonePercents)
        assertTest(
            blocks.allSatisfy { block in block.allSatisfy { $0 >= 0 && $0 <= 100 } },
            "Every zone percentage in the file is within 0…100 — the guard on a figure that will be "
                + "multiplied by a span and drawn as a duration")
        assertTest(
            blocks.allSatisfy { $0.reduce(0, +) <= 100.0 + 1e-9 },
            "…and the five sum to at most 100 on every row, so zone 1–3 plus zone 4–5 can never exceed "
                + "the workout they are drawn against")
        assertTest(
            blocks.contains { $0.reduce(0, +) < 100.0 },
            "…and at least one row is a **strict** shortfall, which is what keeps the tail of each "
                + "workout — the part below zone 1 — a fact about the file rather than a case someone "
                + "imagined")
        let allZeroBlocks = blocks.filter { $0.allSatisfy { $0 == 0 } }
        assertTest(
            !allZeroBlocks.isEmpty,
            "…and \(allZeroBlocks.count) rows read `0` in every band. Those are **measured workouts that "
                + "never reached zone 1**, not absences: they must draw a real `0:00` and a dash for them "
                + "would be a different claim about the day")

        // The parser's refusal is the assertion that fails if the two column sets are ever merged.
        // `requiredColumns` includes `Wake onset`, which this file does not carry, so pointing the cycle
        // parser here — or this one at the cycle file — has to throw rather than read the whole file,
        // filter to zero rows and report a successful import of nothing.
        let wrongFileThrew: Bool
        do {
            _ = try WhoopExportParser.parseWorkouts(at: whoopExportURL())
            wrongFileThrew = false
        } catch WhoopExportError.missingColumns(let names) {
            wrongFileThrew = names.contains("Workout start time") && names.contains("Workout end time")
        } catch {
            wrongFileThrew = false
        }
        assertTest(
            wrongFileThrew,
            "`parseWorkouts` pointed at `physiological_cycles.csv` throws `missingColumns` naming the two "
                + "workout columns — the failure shape that makes a mis-wired bundle a loud error instead "
                + "of an import of nothing that reports success")

        // MARK: The activity name, and the glyph it draws

        // The name is the one field of this file the app reads **without requiring it** — the reasoning is
        // on `WhoopExportRow.activityName`. These assertions are shaped by that: the column is present on
        // every row here, so the data never exercises the fallback and it has to be asserted directly.
        let names = rows.compactMap(\.activityName)
        assertTest(
            names.count == rows.count && names.allSatisfy { !$0.isEmpty },
            "All \(rows.count) rows carry a non-empty `Activity name` — the column is present on this "
                + "file, which is what makes reading it without requiring it free (got \(names.count))")
        // **The name the file's biking rows carry — the one claim in this block that is not a count or a
        // sweep.** Renaming those rows back to `Mountain Biking` moves neither the row total nor the glyph
        // sweep, because that name has a table entry of its own too. It is however the one name the user
        // has ruled on: they renamed these rows in the export and want the app to hold what the export
        // says, and that is the whole of the export-side reason `Road Biking` is in
        // `WhoopActivityCatalog`. `WhoopExportImporter.makeWorkout` passes this column straight through
        // with no vocabulary check, so the string below is exactly what `workouts.activity_name` will hold
        // after an import — on a fresh install, which is the only case the skip rule lets it be written.
        //
        // **It sits above the distinct-name count because that count is the blunter instrument for the same
        // defect**, and the runner halts on the first failure: a half-done rename leaves both names in the
        // file, so the count would read 22 and report a number rather than a bike. And the pair is ordered
        // absent-half first so that **both** halves are reachable — a file that had lost its biking rows
        // entirely passes the first and fails the second, where a present-half-first ordering would leave
        // the absent half unreachable in every case.
        let mountainBikingRows = names.filter { ActivityName.matches($0, "Mountain Biking") }
        assertTest(
            mountainBikingRows.isEmpty,
            "The bundled export carries **no** `Mountain Biking` row (found \(mountainBikingRows.count)), "
                + "because the user renamed them: this file is the producer, so its spelling is the "
                + "convention. A partial rename would leave one ride filed under two names, splitting a "
                + "single history across two entries in the picker")
        let roadBikingRows = names.filter { ActivityName.matches($0, "Road Biking") }
        assertTest(
            !roadBikingRows.isEmpty,
            "…and it names those rows `Road Biking` — **\(roadBikingRows.count)** of its \(rows.count) — "
                + "which is the export-side half of the pair the catalogue answers on the picker side: a "
                + "name the file writes is a name the picker has to be able to offer back, and the import "
                + "stores it verbatim. `Mountain Biking` stays in the catalogue regardless, because WHOOP "
                + "publishes it and a user may go and do it — a different question from what this file "
                + "contains")

        let distinctNames = Set(names)
        assertTest(
            distinctNames.count == 21,
            "…in \(distinctNames.count) distinct names, read as a property rather than as a list so a "
                + "device time zone cannot break it. The screen's whole change is that most of these 673 "
                + "rows now draw their own name where one shared label stood")

        // **A wrong SF Symbol name is not an error** — it draws an empty chip, which is indistinguishable
        // from a glyph that loaded slowly and from one this build's iOS is too old for. Nothing else in
        // this suite can see `ActivityGlyph`'s table, so this block is the whole of its coverage **for the
        // names the file holds** — §19 sweeps the catalogue's own vocabulary beside it, and neither sweep
        // can see the other's names. It asserts over the names the file actually holds rather than over a
        // list typed a second time.
        //
        // **`symbols.allSatisfy` rather than `!symbol.isEmpty` because a mark is now a `Drawing` that may
        // hold two symbols.** On every name below it is a one-element array, so the assertion is exactly
        // what it was — but the catalogue sweep in §19 covers `Fast`, the one mark with a second half,
        // and a `!isEmpty` on the array would have passed for a pair whose knife was an empty string.
        assertTest(
            distinctNames.allSatisfy { ActivityGlyph.mark(for: $0).symbols.allSatisfy { !$0.isEmpty } },
            "Every one of the file's \(distinctNames.count) names resolves to a non-empty symbol, so no "
                + "imported row can draw a blank chip")
        assertTest(
            ActivityGlyph.mark(for: nil).symbols.allSatisfy { !$0.isEmpty }
                && ActivityGlyph.mark(for: "").symbols.allSatisfy { !$0.isEmpty }
                && ActivityGlyph.mark(for: "   ").symbols.allSatisfy { !$0.isEmpty }
                && ActivityGlyph.mark(for: "Paintball").symbols.allSatisfy { !$0.isEmpty }
                && ActivityGlyph.mark(for: "Some Sport Invented Later").symbols.allSatisfy { !$0.isEmpty },
            "…and so does every input the table does not hold — `nil`, which is a session this app "
                + "recorded itself and every row written before `v15`; an empty and a whitespace-only "
                + "name; `Paintball`, the one bundled name with no entry of its own; and a name a future "
                + "export might add")
        assertTest(
            ActivityGlyph.mark(for: "Activity") == ActivityGlyph.mark(for: nil)
                && ActivityGlyph.mark(for: "Other") == ActivityGlyph.mark(for: nil),
            "WHOOP's own two words for an uncategorised activity take the fallback rather than a glyph of "
                + "their own — 208 rows of this file are named `Activity` or `Other`, and neither is an "
                + "activity a table could name. They draw exactly what every workout row drew before this "
                + "change, which is what keeps an unrecognised activity a missing nicety rather than a "
                + "regression")
        assertTest(
            ActivityGlyph.mark(for: "walking") == ActivityGlyph.mark(for: "Walking")
                && ActivityGlyph.mark(for: "  Walking  ") == ActivityGlyph.mark(for: "Walking"),
            "…and the lookup is case- and whitespace-insensitive, so a future export that changes a "
                + "name's casing or pads a cell lands on the same glyph instead of silently falling back")
        assertTest(
            ActivityGlyph.mark(for: "Walking") == .single("figure.walk")
                && ActivityGlyph.mark(for: "Yoga") == .single("figure.yoga")
                && ActivityGlyph.mark(for: "Ice Skating") == .single("figure.skating")
                && ActivityGlyph.mark(for: "Yard Work/Gardening") == .single("leaf.fill"),
            "…and the table names the symbols it means, pinned **by literal** — the two halves of the "
                + "mapping are otherwise unobservable, since a name that resolves to a symbol that does "
                + "not exist is still non-empty. `Ice Skating` is the one that pins the deployment "
                + "target: SF Symbols' `figure.ice.skating` is iOS 18 and would draw nothing here")

        // MARK: The derived id, driven through the real import

        // **The assertions here are made on what comes back out of the database, not on the id helper.**
        // That is the stronger form and it is also the only one available: `makeWorkout` and `workoutID`
        // are `internal`, and widening them for a test would put the id's arithmetic on the module's
        // surface. Every property below is observable through `importWorkouts(at:)` and a read.
        let db = LocalDatabaseManager(inMemory: true)
        let repository = GRDBWorkoutRepository(db: db)
        let importer = WhoopExportImporter(
            recoveryRepository: GRDBRecoveryRepository(db: db),
            sleepRepository: GRDBSleepRepository(db: db),
            strainRepository: GRDBStrainRepository(db: db),
            napRepository: GRDBNapRepository(db: db),
            workoutRepository: repository,
            userProfileRepository: GRDBUserProfileRepository(db: db))

        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        do {
            let firstWrite = try await importer.importWorkouts(at: workoutsURL)
            assertTest(
                firstWrite == rows.count,
                "All \(rows.count) parsed rows are written — `makeWorkout` refuses a row missing any of "
                    + "its five required fields, and none is missing on this file, so the optional costs "
                    + "no rows here and is a guard rather than a filter (got \(firstWrite))")

            let imported = try await repository.getWorkoutHistory(days: 4_000, endingOn: Date())
            assertTest(
                imported.count == rows.count,
                "…and all \(rows.count) read back. **This is the assertion that fails if anyone reaches "
                    + "for the string id `SleepNap` uses**: `GRDBWorkoutRepository.makeSessions` skips any "
                    + "row whose `id` is not a UUID, so a string id would write 673 rows, read back none, "
                    + "and report a successful import of nothing (got \(imported.count))")
            assertTest(
                Set(imported.map(\.id)).count == imported.count,
                "No two workouts share an id. The id packs the row's start and end unix seconds, so this "
                    + "is the file's own distinctness doing real work — a duplicated pair would silently "
                    + "merge two sessions onto one row")

            // **This pair used to read `secondWrite == rows.count`.** That was the assertion for a path
            // with no already-recorded skip: a second press re-saved all 673 rows, and the point being
            // made was that GRDB's `save` is INSERT-or-UPDATE by primary key rather than an append. The
            // workouts path now has the skip its three sibling tables always had, so the same property is
            // stated in its stronger form — **nothing is written at all**, rather than that what was
            // written happened to be an update. Both halves matter and they fail for different reasons:
            // `0` alone would also be what a build with no `workouts.csv` reports, so the row count beside
            // it is what says the rows are still there.
            //
            // The weaker statement is not a thing this suite should keep as well. A path that quietly went
            // back to re-saving every row would satisfy it, and re-saving every row is exactly what
            // reverts an edit made on the activity detail page.
            let secondWrite = try await importer.importWorkouts(at: workoutsURL)
            let afterSecond = try await repository.getWorkoutHistory(days: 4_000, endingOn: Date())
            assertTest(
                secondWrite == 0 && afterSecond.count == imported.count,
                "…and a **second import writes nothing at all**, which is the day-already-recorded skip: "
                    + "it reports \(secondWrite) rows written and the table still holds "
                    + "\(afterSecond.count) of \(imported.count). The count is the half that catches a "
                    + "build whose bundle has lost `workouts.csv`, since that also imports "
                    + "\(secondWrite) — and the pair together is what fails if anyone drops the skip, "
                    + "because re-saving all \(rows.count) rows would satisfy a bare row-count check "
                    + "while quietly reverting every edit made on the activity detail page")

            // **The edit survives, and that is the whole reason the skip exists.** Without it this block
            // is the one that fails: a re-import re-saves every row from the file, so the edited name and
            // the trimmed window would both be back to the file's values by the time the read returns —
            // and the page that made the edit would have no way to know.
            //
            // The fixture trims **inward**, which is what the sheet can do and what the draft's clamp
            // enforces, so the day cannot move: both new instants are inside the window the row already
            // had. The inset is a quarter of the session's own length rather than a constant, because
            // `workouts.csv` holds sessions as short as 76 s and a fixed minute at each end would make
            // this fixture a negative-length session on a file whose shortest rows it did not anticipate.
            if let target = afterSecond.first {
                let inset = min(30, target.durationSeconds * 0.25)
                let edited = WorkoutSession(
                    id: target.id,
                    startedAt: target.startedAt.addingTimeInterval(inset),
                    endedAt: target.endedAt.addingTimeInterval(-inset),
                    strain: target.strain,
                    averageHeartRate: target.averageHeartRate,
                    maxHeartRate: target.maxHeartRate,
                    route: target.route,
                    splits: target.splits,
                    source: target.source,
                    activityName: "Basketball",
                    hrZonePercents: target.hrZonePercents,
                    steps: target.steps)
                try await repository.save(edited)

                let thirdWrite = try await importer.importWorkouts(at: workoutsURL)
                let afterThird = try await repository.getWorkoutHistory(days: 4_000, endingOn: Date())
                let stored = afterThird.first { $0.id == target.id }
                assertTest(
                    stored?.activityName == "Basketball"
                        && stored?.startedAt == edited.startedAt
                        && stored?.endedAt == edited.endedAt,
                    "**An edited session survives a re-import** — its new name and both its trimmed "
                        + "boundaries read back as they were saved, where the file's own values for that "
                        + "row are `\(target.activityName ?? "nil")` over "
                        + "\(Int(target.durationSeconds)) s. The day-already-recorded skip is the only "
                        + "thing standing between an edit and this assertion, and it is what makes the "
                        + "Settings caption true: got name "
                        + "\(stored?.activityName ?? "nil"), start \(stored?.startedAt.description ?? "nil")")
                assertTest(
                    thirdWrite == 0 && afterThird.count == afterSecond.count,
                    "…and it survives **in place**: the re-import that would have reverted it wrote "
                        + "\(thirdWrite) rows and the table still holds \(afterThird.count), so the edit "
                        + "was neither overwritten nor duplicated. The `id` is what carries this — it is "
                        + "derived from the row's two original instants, and an edit that minted a new one "
                        + "would leave the file's row to be inserted beside the edit rather than skipped "
                        + "against it")
            }

            assertTest(
                afterSecond.allSatisfy { $0.source == WhoopExportImporter.sourceLabel },
                "Every imported session carries the importer's own `source`, which `save` used to drop — "
                    + "without it an imported session and a live-recorded one are the same row")

            let zoned = afterSecond.filter { $0.hrZonePercents != nil }
            assertTest(
                zoned.count == blocks.count,
                "\(zoned.count) of the \(afterSecond.count) rows carry a zone block and "
                    + "\(afterSecond.count - zoned.count) do not — every parsed block reached the column, "
                    + "and the whole file's blocks are the ones that arrived")
            assertTest(
                zoned.contains { $0.hrZonePercents?.allSatisfy { $0 == 0 } == true },
                "…and a row whose five percentages are all `0` reads back as `[0, 0, 0, 0, 0]` rather "
                    + "than as `nil`: a measured workout that never reached zone 1 is a real `0:00` on "
                    + "the card, and the column has to keep that distinct from an absent block")
            assertTest(
                zoned.allSatisfy { $0.zone1to3Seconds != nil && $0.zone4to5Seconds != nil }
                    && zoned.allSatisfy {
                        ($0.zone1to3Seconds ?? 0) + ($0.zone4to5Seconds ?? 0) <= $0.durationSeconds + 1
                    },
                "…and no imported workout's two zone figures exceed its own span, which is the check "
                    + "that the percentages are scaled by the session's duration and not by anything else")

            let named = afterSecond.filter { $0.activityName != nil }
            assertTest(
                named.count == rows.count,
                "The name survives the storage path: \(named.count) of \(afterSecond.count) sessions read "
                    + "back with an `activityName`. **This is the assertion that fails if the field is "
                    + "dropped anywhere along it** — `save` not passing it into the record, `makeSessions` "
                    + "not passing it back out, or a `CodingKeys` case naming a column the migration did "
                    + "not create (which throws at the write rather than reading back empty)")
            assertTest(
                Set(afterSecond.compactMap(\.activityName)) == distinctNames,
                "…and they are the file's own names, set-for-set — \(distinctNames.count) distinct names "
                    + "parsed and the same \(Set(afterSecond.compactMap(\.activityName)).count) read back, "
                    + "so no row's name was dropped, defaulted, or swapped for another row's")
        } catch {
            assertTest(false, "The import round trip threw: \(error)")
        }

        // MARK: The v14 round trip on a session this app recorded

        do {
            // A day the export does not cover, so the read below holds the live session and nothing else
            // — the whole point being to see what a day with no zone block at all aggregates to.
            let liveDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_000_000_000))
            let live = WorkoutSession(
                startedAt: liveDay.addingTimeInterval(18 * 3600),
                endedAt: liveDay.addingTimeInterval(18 * 3600 + 1200),
                strain: 4.0, averageHeartRate: 110, maxHeartRate: 140,
                route: [], splits: [])
            try await repository.save(live)

            let readBack = try await repository.getWorkouts(for: liveDay)
            assertTest(
                readBack.count == 1 && readBack[0].id == live.id
                    && readBack[0].hrZonePercents == nil && readBack[0].zone1to3Seconds == nil,
                "A session stored with no zone block reads back `nil` and not `[0, 0, 0, 0, 0]` — an "
                    + "absent block draws a dash where a measured all-zero one draws `0:00`, and a "
                    + "default here would collapse the two into the fabricated zero every absence rule "
                    + "in this app exists to prevent (got "
                    + "\(readBack.first.map { $0.hrZonePercents.map(String.init(describing:)) ?? "nil" } ?? "no row"))")
            assertTest(
                WorkoutZoneTime.aggregate(readBack) == nil,
                "…and a day whose only workout carries no block aggregates to `nil` rather than to "
                    + "`0:00` — the live-recording path is the ordinary case on this card, and the user's "
                    + "rule for it is a dash rather than a figure")
        } catch {
            assertTest(false, "The `v14` round trip threw: \(error)")
        }

        // MARK: The window's own edges, on the new overload

        /// One day's aggregate, dated `offset` days from the anchor.
        func aggregateDay(_ offset: Int) -> WorkoutZoneTime {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day
            return WorkoutZoneTime(
                date: date, zone1to3Seconds: 600, zone4to5Seconds: 60)
        }

        let series = (-40...0).map(aggregateDay).sorted { $0.date < $1.date }
        let window = RecoveryScoring.baselineWindow(before: day, in: series)
        assertTest(
            window.count == RecoveryScoring.baselineWindowDays,
            "The window is capped at `baselineWindowDays` — \(series.count) days of history come back as "
                + "\(window.count), so the cap is applied rather than the whole read being averaged")
        assertTest(
            window.allSatisfy { $0.date < day },
            "…and it is **strictly before** the anchor on the calendar day: 40 days of history land on "
                + "1–30 days back, and the anchor's own day is not one of them. A window containing its "
                + "own day is the defect that printed an HRV baseline taken over a different set of days "
                + "than the score above it")
        assertTest(
            RecoveryScoring.baselineWindow(before: day, in: [WorkoutZoneTime]()).isEmpty
                && RecoveryScoring.baselineWindow(before: day, in: [aggregateDay(-50)]).count == 1,
            "An empty series has an empty window, and one day fifty days back is still in it — the window "
                + "is the last thirty days **that have rows**, not the last thirty calendar days")
        assertTest(
            RecoveryScoring.baselineWindow(before: day, in: Array(series.suffix(3))).count == 2,
            "Three days of zone history — the anchor's own plus the two before it — is a window of two, "
                + "below `minimumBaselineDays`, which is what withholds the mean on the screen rather than "
                + "printing a pair of workouts as an average")

        // MARK: The step path's second screen

        // **The strap step path reaches two screens, and this is the one §16 does not cover.** §16's panel
        // block asserts the strain card's `STEPS` row — the figure, the mean, the measured zero and both
        // absences — off the same `stepCounts` table this block reads. What is asserted here is that the
        // *other* reader agrees: Home's tile, which is a different view model, a different property and a
        // different gate on the same repository. §14 asserts the tile's **absence** on an imported day,
        // which is the other half.
        //
        // The two blocks are deliberately not merged. A shared fixture would prove the two screens read
        // one table and would stop proving that either screen's own gate is wired — `HomeViewModel.steps`
        // and `StrainViewModel.steps` are separate properties that could each go through
        // `StepCount.measuredStepCount` while one of them forgot to.
        let homeDB = LocalDatabaseManager(inMemory: true)
        let stepDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        do {
            try await GRDBStepRepository(db: homeDB).saveStepCount(
                StepCount(date: stepDay, stepCount: 8_431, measuredSeconds: 5400))

            let home = await MainActor.run {
                HomeViewModel(
                    recoveryRepository: GRDBRecoveryRepository(db: homeDB),
                    sleepRepository: GRDBSleepRepository(db: homeDB),
                    strainRepository: GRDBStrainRepository(db: homeDB),
                    workoutRepository: GRDBWorkoutRepository(db: homeDB),
                    receptiveInactivityRepository: GRDBReceptiveInactivityRepository(db: homeDB),
                    userProfileRepository: GRDBUserProfileRepository(db: homeDB),
                    stepRepository: GRDBStepRepository(db: homeDB),
                    analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                        biometricRepository: GRDBBiometricRepository(db: homeDB)))
            }
            await home.load(for: stepDay)
            let steps = await MainActor.run { home.steps }
            assertTest(
                steps == 8_431,
                "Home's STEPS tile populates from a stored `stepCounts` row — the tile's positive half, "
                    + "beside §16's assertion of the same table on the strain card's `STEPS` row, so the "
                    + "two screens are pinned to agree (got \(steps.map(String.init) ?? "nil"))")

            // The counterpart, and the reason `StepCount.hasMeasurement` is `measuredSeconds > 0`: a row
            // that a *measured* day of no walking produced is a real `0`, and it must reach the tile as a
            // figure rather than as the dash an unmeasured day draws.
            let measuredZeroDay = Calendar.current.date(byAdding: .day, value: -1, to: stepDay) ?? stepDay
            try await GRDBStepRepository(db: homeDB).saveStepCount(
                StepCount(date: measuredZeroDay, stepCount: 0, measuredSeconds: 3600))
            await home.load(for: measuredZeroDay)
            let zeroSteps = await MainActor.run { home.steps }
            assertTest(
                zeroSteps == 0,
                "…and a measured zero reaches it as `0` rather than as a dash — the row exists with "
                    + "measured time on it, so the day was worn and unwalked, which is a different answer "
                    + "from a strap that was on the charger")
        } catch {
            assertTest(false, "The step path's screen-level round trip threw: \(error)")
        }
    }
}
