import Foundation
import SwiftUI
import Whoopsy

enum ActivityOverflowAndDeleteTests {
    static func run() async throws {
        // MARK: - A fast's nights through the database

        // Everything above hands `FastingRecovery` a history directly, which is what lets it pin literals —
        // and it means nothing so far has proved **the page's own read**. This block drives the real
        // `ActivityDetailViewModel` over an in-memory database: the fifth init parameter, the window
        // `loadFastingRecovery()` asks for, and the trim that moves it.
        //
        // The trim is the reason this block exists rather than a flourish at the end of it. `save(_:)` re-runs
        // the whole of `load()` on purpose, so a trim that moves the nights the fast enclosed has to move the
        // figures above the chart. Nothing else in this suite can see that: `simctl` drops the synthetic drag
        // that would move a handle, so a screenshot of a trimmed fast proves nothing about whether the page
        // re-derived its nights.
        //
        // **Which trim can do it is a fact about `ActivityEditDraft` rather than a choice**, and this block
        // asserts both halves of it: the enclosure rule reads the start's *day*, and `latestStart` is bounded
        // by `original.startedAt.endOfDay`, so no trim the sheet permits can move that boundary — while
        // `setEnd` is bounded only by `original.endedAt`, so the end is the boundary a trim can move.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let workoutRepository = GRDBWorkoutRepository(db: db)
            let recoveryRepository = GRDBRecoveryRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            // Three measured days before the fast, then the three nights it ran through — 40/60/80, so the
            // mean is a figure the three scores can be checked against by hand. The window's spread clears
            // `minimumCoefficientOfVariation` (10 ms around a mean of 70, against a floor of 3.5), which is the
            // trap the value blocks record: on a narrower window the floor becomes the denominator and every
            // z-score downstream moves.
            let storedHistory = [
                ActivityDetailTests.night(-6, score: 50, hrv: 60, rhr: 50),
                ActivityDetailTests.night(-5, score: 50, hrv: 70, rhr: 60),
                ActivityDetailTests.night(-4, score: 50, hrv: 80, rhr: 70),
                ActivityDetailTests.night(0, score: 40, hrv: 60, rhr: 70),
                ActivityDetailTests.night(1, score: 60, hrv: 70, rhr: 50),
                ActivityDetailTests.night(2, score: 80, hrv: 80, rhr: 60),
            ]
            for entry in storedHistory {
                try await recoveryRepository.saveRecovery(entry, source: nil)
            }

            // 21:00 the day before through 11:00 on D+2, so the mornings it ran through are the three nights
            // above — and the day it started on is not among them, since that night had already ended.
            let fastingSession = ActivityDetailTests.fast(from: ActivityDetailTests.day(-1, hour: 21), to: ActivityDetailTests.day(2, hour: 11))
            try await workoutRepository.save(fastingSession)

            let page = await MainActor.run {
                ActivityDetailViewModel(
                    session: fastingSession,
                    workoutRepository: workoutRepository,
                    userProfileRepository: profileRepository,
                    biometricRepository: GRDBBiometricRepository(db: db),
                    recoveryRepository: recoveryRepository,
                    offlineMaps: SpyOfflineMaps())
            }
            await page.load()
            let loaded = await MainActor.run { page.fastingRecovery }

            assertTest(
                loaded?.nights.count == 3 && loaded?.scoredNightCount == 3,
                "A fast's page finds the three nights it covered, **read off the database** rather than handed "
                    + "in — the fifth init parameter, the lookback-plus-span window and the enclosure filter in "
                    + "one path (\(ActivityDetailTests.shown(loaded?.nights.count)) found)")

            assertTest(
                loaded?.meanScore == 60 && loaded?.hrvMetric == .rmssd,
                "…and the figure above the chart is the mean of their own stored scores, 40/60/80, with the "
                    + "quantity in force named beside it (\(ActivityDetailTests.shown(loaded?.meanScore)))")

            assertTest(
                loaded?.baselineObservationCount == 3,
                "…and the baseline is the three measured days **before** the fast began rather than its own "
                    + "nights — a window that counted them would score the fast against itself "
                    + "(\(ActivityDetailTests.shown(loaded?.baselineObservationCount)) days)")

            // The start boundary first, because it is the one the sheet **cannot** move across a day:
            // `ActivityEditDraft.latestStart` is `min(end − minimumDuration, original.startedAt.endOfDay)`,
            // so no trim the edit surface permits puts a fast's start on another calendar day. Pinning that
            // here rather than discovering it is the point — the enclosure rule's left-hand side is the
            // start's day, so a fast's covered mornings are invariant under a start trim, and the honest
            // assertion is the one that says so.
            var startDraft = ActivityEditDraft(fastingSession)
            startDraft.setStart(ActivityDetailTests.day(-1, hour: 23))
            let startSaved = await page.save(startDraft)
            let afterStartTrim = await MainActor.run { page.fastingRecovery }
            let startTrimmedSession = await MainActor.run { page.session }

            assertTest(
                startSaved && startTrimmedSession.startedAt == ActivityDetailTests.day(-1, hour: 23)
                    && afterStartTrim?.nights.count == 3 && afterStartTrim?.meanScore == 60,
                "**A start trim inside the fast's own day moves the window and leaves the nights exactly "
                    + "where they were**: the start reaches 23:00, so `latestStart`'s end-of-day bound is "
                    + "what it is there for, and the enclosure rule reads the start's *day* — which no "
                    + "permitted start trim can change. The figures are re-derived from the saved session "
                    + "all the same, which is what makes this a statement about the re-read and not about "
                    + "a page that never looked (\(ActivityDetailTests.shown(startTrimmedSession.startedAt)))")

            // …and the end boundary is the one that **can**, because `setEnd` is bounded by
            // `original.endedAt` and by nothing on its own day. Bringing the end back to D+1 23:00 drops the
            // morning of D+2 out of the fast, so the nights go 40/60/80 → 40/60 and the mean 60 → 50.
            var endDraft = ActivityEditDraft(startTrimmedSession)
            endDraft.setEnd(ActivityDetailTests.day(1, hour: 23))
            let endSaved = await page.save(endDraft)
            let afterEndTrim = await MainActor.run { page.fastingRecovery }

            assertTest(
                endSaved && afterEndTrim?.nights.count == 2 && afterEndTrim?.meanScore == 50,
                "**A trim moves the mornings a fast covered, and the figures above the chart move with "
                    + "them.** Ending it on D+1 takes the D+2 morning out, so two nights average 50 where "
                    + "three averaged 60 — the assertion that fails if `loadFastingRecovery()` is left out "
                    + "of `save(_:)`'s re-read (\(ActivityDetailTests.shown(afterEndTrim?.nights.count)) nights at "
                    + "\(ActivityDetailTests.shown(afterEndTrim?.meanScore)))")

            assertTest(
                afterEndTrim?.baselineObservationCount == 3
                    && afterEndTrim?.hrvMetric == .rmssd,
                "…and the baseline window does **not** move with either trim, because a night inside the "
                    + "fast was never in a window taken before it started, and the quantity in force is read "
                    + "off the newest enclosed night rather than from the window "
                    + "(\(ActivityDetailTests.shown(afterEndTrim?.baselineObservationCount)) days)")

            // Read on the fast's **start** day and not on `day(0)`: `workouts` is keyed on `id` with `date` an
            // ordinary column snapped to the start, so the row is filed where the fast began and a read on any
            // morning it merely ran through returns nothing — which is the same one-day-off shape the covering
            // read exists beside, and the reason this fetch names the day it was written on.
            let trimmedRow = try await workoutRepository.getWorkouts(for: ActivityDetailTests.day(-1))
                .first { $0.id == fastingSession.id }
            assertTest(
                trimmedRow?.startedAt == ActivityDetailTests.day(-1, hour: 23) && trimmedRow?.endedAt == ActivityDetailTests.day(1, hour: 23),
                "…and both trimmed instants are on **disk**, read back through the repository rather than "
                    + "off the view model that has just written them — the same write/read pair the `steps` "
                    + "block makes, and the one that fails if the page re-derived its nights without "
                    + "persisting the edit (\(ActivityDetailTests.shown(trimmedRow?.startedAt)) to \(ActivityDetailTests.shown(trimmedRow?.endedAt)))")

            // A fast with no recovery history behind it at all. That is the state 152 of the 170 bundled fasts
            // are in, and it is reached here through a real read of an empty window rather than through an
            // empty array handed in — which is the difference between the page's absence branch and a fixture.
            let earlyFast = ActivityDetailTests.fast(from: ActivityDetailTests.day(-400, hour: 21), to: ActivityDetailTests.day(-397, hour: 11))
            let earlyPage = await MainActor.run {
                ActivityDetailViewModel(
                    session: earlyFast,
                    workoutRepository: workoutRepository,
                    userProfileRepository: profileRepository,
                    biometricRepository: GRDBBiometricRepository(db: db),
                    recoveryRepository: recoveryRepository,
                    offlineMaps: SpyOfflineMaps())
            }
            await earlyPage.load()
            let earlyRecovery = await MainActor.run { earlyPage.fastingRecovery }
            assertTest(
                earlyRecovery == nil,
                "…and a fast the recovery record does not reach has **no** summary rather than an empty chart, "
                    + "so the chart's slot draws the absence line and not a frame with nothing in it")

            // The gate, asserted at the page and not only at the value: a measured session's page carries no
            // fasting summary at all, so the ordinary layout can never be handed a fast's figure to draw.
            let ordinaryPage = await MainActor.run {
                ActivityDetailViewModel(
                    session: ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 3_600, strain: 12.4),
                    workoutRepository: workoutRepository,
                    userProfileRepository: profileRepository,
                    biometricRepository: GRDBBiometricRepository(db: db),
                    recoveryRepository: recoveryRepository,
                    offlineMaps: SpyOfflineMaps())
            }
            await ordinaryPage.load()
            let ordinaryRecovery = await MainActor.run { ordinaryPage.fastingRecovery }
            assertTest(
                ordinaryRecovery == nil,
                "…and a session that measured a strain loads with no fasting summary, which is the gate read "
                    + "through the page rather than through `ActivityFigure.isFast` alone")
        } catch {
            assertTest(false, "The fasting database round trip threw: \(error)")
        }

        // MARK: - `workout.steps` through the database

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBWorkoutRepository(db: db)
            let measured = ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 600, steps: 693)
            let unmeasured = ActivityDetailTests.session("Basketball", startOffset: 3600, durationSeconds: 600)
            try await repository.save(measured)
            try await repository.save(unmeasured)

            // Each session is read off **its own** day rather than off one shared anchor, so a time zone
            // that puts the two either side of midnight narrows this instead of making the second read
            // return nothing and the `nil` comparison below pass for the wrong reason.
            let readMeasured = try await repository.getWorkouts(for: measured.startedAt)
                .first { $0.id == measured.id }
            let readUnmeasured = try await repository.getWorkouts(for: unmeasured.startedAt)
                .first { $0.id == unmeasured.id }

            assertTest(
                readMeasured?.steps == 693,
                "A recorded step count round-trips through `v17`'s column in both directions — the "
                    + "`save` and the `makeSessions` — so the figure the page prints is the one the "
                    + "session accumulated (\(String(describing: readMeasured?.steps)))")
            assertTest(
                readUnmeasured?.steps == nil,
                "…and an **unrecorded** one comes back `nil` rather than `0`. The column is nullable and "
                    + "undefaulted, which is the only shape in which NULL reads as *not measured* — the "
                    + "same distinction `source` documents, and the reason this row draws a dash on all "
                    + "673 imported sessions")
            assertTest(
                readMeasured != nil && readUnmeasured != nil,
                "…and both were found on their own day, which is what makes the two assertions above a "
                    + "statement about the value rather than about a missing row")
        } catch {
            assertTest(false, "The `workout.steps` round trip threw: \(error)")
        }

        // MARK: - The `•••` menu's rows

        // The menu is a pure value with no database behind it, so it asserts here — above the delete block
        // and above every `LocalDatabaseManager` below it. **What is asserted is the rows and not the
        // drawing**: the runner has no renderer and `simctl` drops a synthetic tap, so the menu's scrim, its
        // full-width rows and its animation are the user's to check. What the value can say is which rows
        // there are, in which order, what each one does and which of them is the destructive one — and that
        // is what a hand-built menu can get wrong in a way that still looks like a working menu.
        assertTest(
            ActivityOverflowMenu.entries().map(\.title) == ["Edit", "Delete", "Cancel"],
            "The `•••` menu holds exactly three rows, in the reference's own order: Edit, Delete, Cancel. "
                + "The order is pinned rather than left to the drawing because it is the one thing about a "
                + "hand-built menu a screenshot of a different build cannot check "
                + "(\(ActivityOverflowMenu.entries().map(\.title)))")
        assertTest(
            ActivityOverflowMenu.entries().map(\.action) == [.edit, .delete, .cancel],
            "…and each row carries the action its title names, so a row renamed without its case being "
                + "moved fails here rather than becoming a menu where *Delete* closes the sheet and "
                + "*Cancel* removes the session")
        assertTest(
            ActivityOverflowMenu.entries().filter(\.isDestructive).map(\.title) == ["Delete"],
            "**Exactly one row is destructive, and it is `Delete`.** This is the assertion that fails if a "
                + "second destructive row is added without anyone deciding to — and it is a property of the "
                + "value rather than of the drawing, which matters because the tint is what tells a reader "
                + "which row cannot be undone")
        assertTest(
            ActivityOverflowMenu.entries().first { $0.action == .delete }?.tint == Theme.recoveryRed
                && ActivityOverflowMenu.entries().filter { $0.action != .delete }
                    .allSatisfy { $0.tint == Theme.actionTint },
            "…and the destructive row is the only one drawn in the red. `Theme.recoveryRed` is the app's "
                + "only red and `Theme.actionTint` is the role-named blue the other two take: `strainRing` "
                + "is deliberately **not** borrowed here, because it is the strain figure's colour and is "
                + "drawn a few inches above this menu, so one colour would be saying two things")
        assertTest(
            ActivityOverflowMenu.scrimOpacity > 0 && ActivityOverflowMenu.scrimOpacity < 1,
            "The scrim is partial — `\(ActivityOverflowMenu.scrimOpacity)`, Home's own number — so the page "
                + "the menu belongs to stays legible behind it. A menu that blacked the screen out would "
                + "read as a different kind of modal from the calendar and the `+` menu, which are the same "
                + "arrangement at the opposite edge")
        assertTest(
            ActivityOverflowMenu.groups().map { $0.map(\.title) } == [["Edit", "Delete"], ["Cancel"]],
            "**The rows are split into two cards, and the split is what puts the gap between `Delete` and "
                + "`Cancel` and nowhere else.** The page draws one card per group and separates them by "
                + "`groupSpacing`, so this shape is the gap's position: a third row moved into the first "
                + "group, or `Cancel` listed with the two above it, draws a menu with no separation at all "
                + "and every other assertion in this block still passes "
                + "(\(ActivityOverflowMenu.groups().map { $0.map(\.title) }))")
        assertTest(
            ActivityOverflowMenu.groupSpacing > 0
                && ActivityOverflowMenu.groupSpacing < ActivityOverflowMenu.rowHeight,
            "The separation is a small space: positive, so the two cards are genuinely apart, and shorter "
                + "than a row (\(ActivityOverflowMenu.groupSpacing) pt against "
                + "\(ActivityOverflowMenu.rowHeight) pt), because a gap the height of a row reads as a "
                + "fourth, empty button rather than as a division")
        assertTest(
            ActivityOverflowMenu.rowHeight >= 44,
            "Every row clears the 44 pt minimum tap target "
                + "(\(ActivityOverflowMenu.rowHeight) pt), which is a fact about the drawing that nothing "
                + "on a screen can be asked to confirm — and `Cancel` is one of those rows: it is the same "
                + "height and the same full width as the two above it, and the gap is the whole of what "
                + "sets it apart")
        assertTest(
            ActivityOverflowMenu.cardCornerRadius > 0
                && ActivityOverflowMenu.cardCornerRadius < ActivityOverflowMenu.rowHeight,
            "Both cards are rounded by one radius — `\(ActivityOverflowMenu.cardCornerRadius)` pt — at "
                + "every one of their eight corners. **One value and not two is the assertion**: a card "
                + "rounded at a different radius from its neighbour is the one defect in this menu that "
                + "nothing else can see, because both cards still look rounded and only their corners "
                + "disagree. It is held under `rowHeight` so a radius can never eat a whole row's edge, and "
                + "over zero so the rounding is really there — at `0` the menu would be a rectangle and a "
                + "card's end would be invisible")

        // ---- The live fast's menu: one row, one card, and no second destructive one ----
        //
        // A running fast's page is the ordinary fasting layout with `END FAST` where the `•••` was, so this
        // menu's live shape is reachable only from that page — and like every other menu here it is a value,
        // because the runner has no renderer and a row written into a `body` is a row nothing can assert.
        //
        // **`isDestructive` staying `Delete` alone is the assertion that matters most**, and it is the one
        // a live menu could plausibly break: `End Fast` is a verb that ends something, and marking it red
        // would put two red rows on one screen's vocabulary while §19's own count above says there is one.
        let liveTitles = ActivityOverflowMenu.entries(isLive: true).map(\.title)
        assertTest(
            liveTitles == ["End Fast", "Cancel"],
            "A running fast's menu holds two rows — `End Fast`, then the `Cancel` every menu here carries "
                + "— rather than the three a stored session's does, and the assertion is on the whole list "
                + "because a live menu that kept `Edit` would offer to re-time a session with no stored row "
                + "to write (\(liveTitles))")

        assertTest(
            ActivityOverflowMenu.entries(isLive: true).map(\.action) == [.endFast, .cancel],
            "…and `End Fast` carries `.endFast` and not `.delete`, which is what makes it a distinct case at "
                + "`ActivityDetailView`'s exhaustive switch rather than a delete under another title")

        assertTest(
            ActivityOverflowMenu.entries(isLive: true).filter(\.isDestructive).isEmpty
                && ActivityOverflowMenu.entries().filter(\.isDestructive).map(\.title) == ["Delete"],
            "…and **not one row of the live menu is destructive**, where the stored menu has exactly one. "
                + "Ending a fast writes a row rather than removing one, so a red `End Fast` would be this "
                + "menu telling the reader a session is about to be lost when it is about to be kept")

        assertTest(
            ActivityOverflowMenu.groups(isLive: true).map { $0.map(\.title) } == [["End Fast"], ["Cancel"]],
            "…and it is still two cards, so `groupSpacing` puts its gap between `End Fast` and `Cancel` and "
                + "nowhere else. The grouping is what makes `Cancel` its own row here too — a live menu drawn "
                + "as one card would put the way out of the menu flush against the way out of the fast "
                + "(\(ActivityOverflowMenu.groups(isLive: true).map { $0.map(\.title) }))")

        assertTest(
            ActivityOverflowMenu.groups().count == ActivityOverflowMenu.groups(isLive: true).count
                && ActivityOverflowMenu.entries().count != ActivityOverflowMenu.entries(isLive: true).count,
            "…and the live flag moves the **rows** without moving the card count, which is the pair that "
                + "keeps `isLive` from being read as a second menu — it withholds two rows and changes no "
                + "layout constant")

        // MARK: - Delete

        // The app's first destructive operation, reached from the `•••` menu. **What is asserted here is
        // the storage path, not the menu**: the runner has no renderer and `simctl` drops a synthetic tap —
        // so the rows' appearance and their taps are not something this suite can see, and the block above
        // is the whole of what it can say about them. What it can see is everything Delete does, and the
        // discriminations below are the ones a passing delete would otherwise hide.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBWorkoutRepository(db: db)

            /// The same session, carrying a route and a split.
            ///
            /// Children matter here in a way they do not anywhere else in this section: they live in their
            /// own tables behind a `workout_id` filter, and **every reader in the app fetches them per
            /// session** — so an orphan is never read, never drawn and never noticed. A row count is the
            /// only place it can surface, which is why the assertions below read the tables directly rather
            /// than through `WorkoutRepository`, where they would be invisible.
            func withChildren(_ base: WorkoutSession) -> WorkoutSession {
                WorkoutSession(
                    id: base.id,
                    startedAt: base.startedAt,
                    endedAt: base.endedAt,
                    strain: base.strain,
                    averageHeartRate: base.averageHeartRate,
                    maxHeartRate: base.maxHeartRate,
                    route: [
                        WorkoutRoutePoint(
                            latitude: 51.50, longitude: -0.12,
                            timestamp: base.startedAt, heartRate: 120),
                        WorkoutRoutePoint(
                            latitude: 51.51, longitude: -0.13,
                            timestamp: base.endedAt, heartRate: 150),
                    ],
                    splits: [
                        WorkoutSplit(elapsed: 300, strain: 2.5),
                        WorkoutSplit(elapsed: 600, strain: 5.0),
                    ],
                    activityName: base.activityName)
            }

            // Two sessions **on one day**, which is the fixture this whole block rests on: `workouts` is
            // keyed on `id` precisely because a day holds several, and a neighbour on the same day is what
            // makes a table-wide wipe visible.
            let doomed = withChildren(ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 600))
            let survivor = withChildren(ActivityDetailTests.session("Basketball", startOffset: 3600, durationSeconds: 900))
            try await repository.save(doomed)
            try await repository.save(survivor)

            // `LocalDatabaseManager` is an actor, so the child reads are awaited into locals rather than
            // called inside the assertion.
            let stored = try await repository.getWorkouts(for: doomed.startedAt)
            let doomedPointsBefore = try await db.getRoutePoints(for: doomed.id.uuidString).count
            let doomedSplitsBefore = try await db.getSplits(for: doomed.id.uuidString).count
            let survivorPointsBefore = try await db.getRoutePoints(for: survivor.id.uuidString).count
            let survivorSplitsBefore = try await db.getSplits(for: survivor.id.uuidString).count
            assertTest(
                stored.count == 2
                    && doomedPointsBefore == 2 && doomedSplitsBefore == 2
                    && survivorPointsBefore == 2 && survivorSplitsBefore == 2,
                "Two sessions on one day are stored, each with its own two route points and two splits — "
                    + "the fixture every assertion below reads (sessions: \(stored.count))")

            let removed = try await repository.delete(doomed.id)
            assertTest(
                removed,
                "Deleting a session reports that a row really went. The `Bool` is the store's "
                    + "affected-row count and not *did it throw*: an id that matched nothing would "
                    + "otherwise report success, and the page would dismiss over a row still on disk")

            let afterDelete = try await repository.getWorkouts(for: doomed.startedAt)
            assertTest(
                !afterDelete.contains { $0.id == doomed.id },
                "…and it is gone from the day's list, which is the read Home's ACTIVITIES card is built "
                    + "from (\(afterDelete.count) sessions left)")

            let doomedPointsAfter = try await db.getRoutePoints(for: doomed.id.uuidString)
            let doomedSplitsAfter = try await db.getSplits(for: doomed.id.uuidString)
            assertTest(
                doomedPointsAfter.isEmpty && doomedSplitsAfter.isEmpty,
                "…and **its route points and splits went with it**. Read off the tables directly rather "
                    + "than through `WorkoutRepository`, which fetches children per session and could "
                    + "never see an orphan: a deleted session leaving its route behind would be invisible "
                    + "to every reader in the app")

            // The survivor is the assertion that catches a table-wide `deleteAll` on either child table —
            // the failure a repository-level read cannot see, because both sessions would still be
            // reported as present and the survivor would simply come back with an empty route.
            assertTest(
                afterDelete.contains { $0.id == survivor.id },
                "…and the session beside it on the same day is untouched (\(afterDelete.count) left)")
            let survivorPointsAfter = try await db.getRoutePoints(for: survivor.id.uuidString).count
            let survivorSplitsAfter = try await db.getSplits(for: survivor.id.uuidString).count
            assertTest(
                survivorPointsAfter == 2 && survivorSplitsAfter == 2,
                "…**including its own route points and splits**. This is the pair that fails if the "
                    + "worker deletes the children by table rather than by `workout_id`: that wipe takes "
                    + "the neighbour's route with it, and nothing short of counting the surviving "
                    + "session's children can see it")

            // Deleting something that is not there is an ordinary answer rather than an error — the same
            // shape every reader in this app gives an absent row.
            let removedAgain = try await repository.delete(doomed.id)
            assertTest(
                !removedAgain,
                "Deleting an id that is already gone does not throw and reports `false` — an absent row "
                    + "is not a failure, but it is not a success either, so the page must not dismiss on it")

            // The id no longer round-trips, so the page's own guard is the second half of that rule: a
            // delete is only worth dismissing on when the store says a row went.
            assertTest(
                (try await repository.getWorkouts(for: doomed.startedAt))
                    .allSatisfy { $0.id != doomed.id },
                "…and a second delete left the day exactly as the first one did")
        } catch {
            assertTest(false, "The delete round trip threw: \(error)")
        }

        // MARK: - The edit, through the database

        // `Edit`'s destination, and the block that proves the save is an **update and not an insert**. The
        // distinction is the whole feature: an imported row's `id` is a function of its own two instants, so
        // an edit that minted a new id would leave the file's row on disk and put the edit beside it — one
        // session on the day before the edit and two after — and every read in the app would draw both.
        // `WorkoutRepository.save` is INSERT-or-UPDATE by primary key, which is what makes the id the
        // carrying half of this; nothing else here would notice a second row, since both would read back.
        //
        // **The fixture is anchored at local noon**, and that is not tidiness: this is the one block that
        // trims a window and then reads the day back, so a session near either midnight would let the trim
        // change the day key and the assertion would be about the time zone rather than about the edit.
        // §1's clamp forbids that, and the two together are why a fixed offset from `anchor` is not enough
        // — `anchor` is 22:13 UTC in a zone this suite does not pick.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBWorkoutRepository(db: db)

            let noon = Calendar.current.startOfDay(for: ActivityDetailTests.anchor).addingTimeInterval(12 * 3600)
            let fixture = WorkoutSession(
                startedAt: noon,
                endedAt: noon.addingTimeInterval(1_200),
                strain: 5.2,
                averageHeartRate: 121,
                maxHeartRate: 164,
                route: [
                    WorkoutRoutePoint(
                        latitude: 51.50, longitude: -0.12, timestamp: noon, heartRate: 120),
                    WorkoutRoutePoint(
                        latitude: 51.51, longitude: -0.13,
                        timestamp: noon.addingTimeInterval(1_200), heartRate: 150),
                ],
                splits: [
                    WorkoutSplit(elapsed: 300, strain: 2.5),
                    WorkoutSplit(elapsed: 600, strain: 5.0),
                ],
                source: WhoopExportImporter.sourceLabel,
                activityName: "Basketball",
                hrZonePercents: [12, 26, 34, 18, 4],
                steps: 693)
            try await repository.save(fixture)
            let dayBefore = try await repository.getWorkouts(for: noon)

            var draft = ActivityEditDraft(fixture)
            draft.setName("Walking")
            draft.setStart(noon.addingTimeInterval(120))
            draft.setEnd(noon.addingTimeInterval(1_020))
            let edited = draft.applying(to: fixture)
            try await repository.save(edited)

            let dayAfter = try await repository.getWorkouts(for: noon)
            assertTest(
                dayBefore.count == 1 && dayAfter.count == 1,
                "**An edit leaves the day holding the same number of sessions.** One before, "
                    + "\(dayAfter.count) after — so the save updated the row it was handed rather than "
                    + "inserting a second one beside it, which is the failure that would double every "
                    + "imported session the moment anyone edited it")

            let stored = dayAfter.first { $0.id == fixture.id }
            assertTest(
                stored != nil && dayAfter.first?.id == fixture.id,
                "…and the row it updated is **found by the id the fixture was saved under** — the edit did "
                    + "not mint a new one, which is what keeps the edited session the same session to "
                    + "everything downstream: the day's list, the pushed page's `navigationDestination`, "
                    + "and the import's own skip on the next press of the button")
            assertTest(
                stored?.activityName == "Walking"
                    && stored?.startedAt == noon.addingTimeInterval(120)
                    && stored?.endedAt == noon.addingTimeInterval(1_020),
                "…with the new name and both trimmed boundaries read back off disk — "
                    + "\(stored?.activityName ?? "nil") over "
                    + "\(Int(stored?.durationSeconds ?? 0)) s against the file's 1200 s")

            assertTest(
                stored?.strain == 5.2 && stored?.averageHeartRate == 121
                    && stored?.maxHeartRate == 164 && stored?.steps == 693
                    && stored?.source == WhoopExportImporter.sourceLabel
                    && stored?.hrZonePercents == [12, 26, 34, 18, 4],
                "…and **everything the sheet does not touch survives the write**: the strain, the two "
                    + "heart rates, the step count, the provenance label and WHOOP's own five zone shares. "
                    + "`applying(to:)` builds the new session from the old one rather than from a fresh "
                    + "initialiser, so a field nobody edited cannot take an initialiser's default — "
                    + "`steps` would otherwise come back `nil` on an edit that only renamed the session")

            let pointsAfter = try await db.getRoutePoints(for: fixture.id.uuidString)
            let splitsAfter = try await db.getSplits(for: fixture.id.uuidString)
            assertTest(
                pointsAfter.count == 2 && splitsAfter.count == 2,
                "…and the children are **still exactly the two that were stored, not four**. The child "
                    + "tables are written per `workout_id` on every save (`saveWorkout` mirrors the delete "
                    + "rather than trusting a cascade), so an update that inserted instead of replaced "
                    + "would leave the session with a duplicated route — invisible to every reader in the "
                    + "app, because they all fetch by session rather than by table")
            assertTest(
                pointsAfter.first?.heartRate == 120 && pointsAfter.last?.heartRate == 150
                    && splitsAfter.first?.elapsed == 300 && splitsAfter.last?.strain == 5.0,
                "…and they are the **same** two rather than two replacements, read off their own fields: "
                    + "timestamps and heart rates, elapsed and strain. A count alone would pass for a "
                    + "delete-and-reinsert that lost the order, and the route's order is its shape")

            // The user's decision on a trim, as one assertion: WHOOP's own five percentages are kept and
            // the seconds recompute against the shorter span. `ActivityZoneRow` derives each row's time as
            // `percent / 100 × durationSeconds`, so the two figures on a row cannot contradict each other
            // before or after an edit — which is the whole reason keeping the share is safe.
            assertTest(
                fixture.zoneSeconds(.zone1) == 144 && stored?.zoneSeconds(.zone1) == 108,
                "**A trim rescales the zone times against the unchanged share.** Zone 1 is 12% of the "
                    + "session both before and after: 12% of 1200 s is "
                    + "\(fixture.zoneSeconds(.zone1) ?? -1) s, and 12% of the trimmed 900 s is "
                    + "\(stored?.zoneSeconds(.zone1) ?? -1) s. The percentage is WHOOP's and cannot be "
                    + "recomputed from a shorter window — the strap was in zone 1 for the time it was, and "
                    + "trimming the ends does not move that — so it is kept and the derived figure moves "
                    + "with the span it is a share of")
            assertTest(
                stored?.zone1to3Seconds == 108 + 234 + 306 && stored?.zone4to5Seconds == 162 + 36,
                "…and the two aggregate rows follow, so the pair of figures the page prints under them "
                    + "cannot disagree with the five rows above either "
                    + "(\(stored?.zone4to5Seconds ?? -1) s across zones 4 and 5)")
        } catch {
            assertTest(false, "The edit round trip threw: \(error)")
        }

        // MARK: - Home drops the row without re-reading the day

        // `removeWorkout` is what stops Home drawing a session the user just deleted: the deletion happens
        // on a pushed page, and whether a `.task` re-fires when that page pops is undocumented and
        // version-dependent, so nothing may depend on it. No other figure on Home is built from a workout,
        // so a local removal is exact — and it is asserted here because a closure calling `load(for:)`
        // instead would be un-assertable and would race whatever else is loading.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let home = await MainActor.run {
                HomeViewModel(
                    recoveryRepository: GRDBRecoveryRepository(db: db),
                    sleepRepository: GRDBSleepRepository(db: db),
                    strainRepository: GRDBStrainRepository(db: db),
                    workoutRepository: GRDBWorkoutRepository(db: db),
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    stepRepository: GRDBStepRepository(db: db),
                    analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                        biometricRepository: GRDBBiometricRepository(db: db)))
            }
            let doomed = ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 600)
            let survivor = ActivityDetailTests.session("Basketball", startOffset: 3600, durationSeconds: 900)
            await MainActor.run {
                home.workouts = [doomed, survivor]
                home.removeWorkout(doomed.id)
            }
            let left = await MainActor.run { home.workouts }
            assertTest(
                left.count == 1 && left.first?.id == survivor.id,
                "Home drops exactly the deleted session and leaves the rest of the day (\(left.count) "
                    + "of 2 left)")

            await MainActor.run { home.removeWorkout(UUID()) }
            let stillThere = await MainActor.run { home.workouts }
            assertTest(
                stillThere.count == 1 && stillThere.first?.id == survivor.id,
                "…and removing an id that is not in the list is a no-op rather than a fault, which is "
                    + "what a day re-read without it looks like")
        }

        // MARK: - Two readers on one motion stream

        // The app really does run two: `TrackStepsUseCase` fills the day's tile and `LiveSessionUseCase`
        // counts the session's own. `motionStream` is multicast, so attaching the second must not starve
        // the first — and the failure if anyone replaces the registry with a single continuation is
        // **silent**, because one reader's `for await` simply stops receiving, which is indistinguishable
        // from a strap that went quiet. The discriminating assertion below is the day's row: the session
        // registers first, so a single-continuation registry would hand it every batch and leave the
        // day's counter frozen rather than erroring.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let telemetry = ScriptedTelemetryRepository()
            let stepRepository = GRDBStepRepository(db: db)
            let workoutRepository = GRDBWorkoutRepository(db: db)
            let trackSteps = TrackStepsUseCase(bleRepository: telemetry, stepRepository: stepRepository)
            let day = Date()

            let session = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: StreamBiometricsUseCase(
                    bleRepository: telemetry, biometricRepository: EmptyBiometricStore()),
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: GRDBUserProfileRepository(db: db),
                bleRepository: telemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())

            await session.start()
            assertTest(
                await waitUntil { telemetry.motionSubscriberCount == 1 },
                "A live session attaches one reader to the strap's motion stream, where before this page "
                    + "`TrackStepsUseCase` was its only reader")

            // Three one-second samples at 150 bpm, which is what `end()` needs to have a strain, an
            // average and a maximum to write. Without them the session records nothing at all and the
            // step count below would have no row to land on.
            for index in 0..<3 {
                telemetry.yield(BiometricSample(
                    timestamp: day.addingTimeInterval(Double(index)), heartRate: 150))
            }
            assertTest(
                await waitUntil { await session.snapshot?.sampleCount == 3 },
                "…and its telemetry reader is running, which is what makes the session recordable at all")

            // The day's counter, started second — the ordering `MainContainerView` gives it, where the
            // app-level `.task` starts it once and never from `HomeViewModel.load(for:)`.
            let dayReader = Task { await trackSteps.start() }
            assertTest(
                await waitUntil { telemetry.motionSubscriberCount == 2 },
                "…and the day's own counter attaches a **second**, which is the count a "
                    + "single-continuation registry cannot reach: it would report 1 while one of the two "
                    + "`for await` loops sat silent")

            telemetry.yieldMotion(motionBatch(startingAt: day, bumps: 12))

            // The day's row is the barrier *and* the discriminating assertion: it is written by the
            // reader that registered last, so it cannot appear at all if the batch went to the first
            // continuation alone.
            assertTest(
                await waitUntil {
                    ((try? await stepRepository.getStepCount(for: day)) ?? nil)?.stepCount == 12
                },
                "One batch reaches the **day's** reader while a session is also attached, so the second "
                    + "subscriber took nothing from the first "
                    + "\(String(describing: (try? await stepRepository.getStepCount(for: day)) ?? nil))")

            // A second barrier, and it is about ordering rather than about delivery: the sample below is
            // yielded *after* the motion batch, and the session's two consumers are both main-actor
            // tasks, so waiting for the telemetry one to catch up is what keeps `end()` from cancelling
            // the motion consumer with a batch still undrained.
            telemetry.yield(BiometricSample(timestamp: day.addingTimeInterval(3), heartRate: 150))
            _ = await waitUntil { await session.snapshot?.sampleCount == 4 }

            await session.end()
            let saved = try await workoutRepository.getWorkouts(for: day).first
            assertTest(
                saved?.steps == 12,
                "…and the **same** batch reached the session's own reader, so ending the session writes "
                    + "the count it accumulated rather than `nil` "
                    + "(\(String(describing: saved?.steps)))")
            assertTest(
                await waitUntil { telemetry.motionSubscriberCount == 1 },
                "Ending the session releases its motion reader — the registry's other half: a stream that "
                    + "accumulates consumers nothing feeds is the same defect from the other side")

            dayReader.cancel()
        } catch {
            assertTest(false, "The two-reader motion block threw: \(error)")
        }

        // MARK: - The export, as a property

        // Read through the parser rather than through the importer, on §17's shape: the property being
        // asserted — every percent whole, five derived durations summing to at most the workout's own
        // span, and the all-zero rows reading back as **measured** zeroes — needs the parser and
        // `ActivityZoneRow.rows(for:zones:)` and nothing else.
        let workoutsURL = whoopExportURL().deletingLastPathComponent()
            .appendingPathComponent("workouts.csv")
        let exported = ((try? WhoopExportParser.parseWorkouts(at: workoutsURL)) ?? []).compactMap {
            row -> WorkoutSession? in
            guard let start = row.workoutStart, let end = row.workoutEnd else { return nil }
            // The three figures are `nil` and not `0`, which they were written as before `v18`. Nothing in
            // this block reads any of them — it is the zone rows under test — so the choice is about what
            // the fixture *says*: a `0` is a claim that something measured a strain of zero and a heart
            // rate of zero, and `nil` is the honest filler for a field the fixture does not care about.
            return WorkoutSession(
                startedAt: start,
                endedAt: end,
                strain: nil,
                averageHeartRate: nil,
                maxHeartRate: nil,
                route: [],
                splits: [],
                activityName: row.activityName,
                hrZonePercents: row.hrZonePercents)
        }
        let exportRows = exported.map { ActivityZoneRow.rows(for: $0, zones: ActivityDetailTests.zones) }

        assertTest(
            exported.count == 673 && exportRows.allSatisfy { $0.count == 5 },
            "All 673 of the export's workouts yield five zone rows — no row is short a band, and none "
                + "answers an empty list (\(exported.count))")
        assertTest(
            exportRows.allSatisfy { $0.allSatisfy { $0.percent != nil } }
                && exportRows.allSatisfy { rows in
                    rows.allSatisfy { ($0.percent ?? 1) == ($0.percent ?? 1).rounded() }
                },
            "…and every one of the 3,365 figures is a whole percent, which is the property that makes a "
                + "row's two figures one answer divided once rather than two that can disagree")
        assertTest(
            zip(exported, exportRows).allSatisfy { session, rows in
                rows.compactMap(\.seconds).reduce(0, +) <= session.durationSeconds + 1e-6
            },
            "…and the five times sum to at most the workout's own length on **every** row: the remainder "
                + "is time below zone 1, which WHOOP publishes no column for, so zones 1–3 plus 4–5 is "
                + "deliberately not the workout's duration")
        assertTest(
            zip(exported, exportRows).allSatisfy { _, rows in
                rows.allSatisfy { ($0.percent != 0) || $0.seconds == 0 }
            },
            "**A stored `0` percent implies exactly `0` seconds across the whole file.** This is the "
                + "property the reference cannot state and this app can: the mockup's `ZONE 1 … 0% · "
                + "0:00:12` is unreachable here, because the two figures come from one share of one span")

        let zeroExportRows = zip(exported, exportRows).filter { _, rows in
            rows.allSatisfy { $0.percent == 0 }
        }
        assertTest(
            zeroExportRows.count == 45,
            "…45 of the 673 read `0` in every band — measured workouts that never reached zone 1, the "
                + "count §17 owns on the raw file, which this page's rows must not change "
                + "(\(zeroExportRows.count))")
        assertTest(
            zeroExportRows.allSatisfy { _, rows in
                rows.allSatisfy { $0.percentText == "0%" && $0.secondsText == "0:00:00" }
            },
            "…and each of those reads back a **measured** `0%` beside `0:00:00` rather than the dash an "
                + "absent block draws — 45 sessions this app would otherwise report as having no zone "
                + "data at all")
    }
}
