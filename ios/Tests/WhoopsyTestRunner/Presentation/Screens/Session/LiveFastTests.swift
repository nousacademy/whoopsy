import Foundation
import Whoopsy

// MARK: - 18. The fast, end to end

/// A file of §18's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `LiveSessionTests.run()` calls it, in the order the section ran it in.

/// The fast half of the same block, given a `do { } catch { }` of its own because the cut
/// lands inside the single one the section used to have. It takes four of the five threads,
/// never naming the database directly.
enum LiveFastTests {
    static func run(
        profileRepository: GRDBUserProfileRepository,
        workoutRepository: GRDBWorkoutRepository,
        telemetry: ScriptedTelemetryRepository,
        stream: StreamBiometricsUseCase
    ) async throws {
        do {
            // ---- The fast: the second live session, and the only one that is persisted ----
            //
            // **A fast is a live session that measures nothing**, which is the whole of why it is this
            // shape: no accumulator, no BLE consumer, no step consumer, no route, no lock-screen card —
            // because there is no figure any of them could produce that a fast would store. What is left
            // is one instant, and one instant is the thing that can be persisted *honestly*.
            //
            // Both halves of that are asserted here: that the live state behaves (idempotent to start, one
            // row out of `endFast()`, nothing out of a fast that never ran), and that the store is written
            // and read exactly once per transition. The store is a spy and never
            // `UserDefaultsActiveFastRepository`, because the restore happens in `LiveSessionUseCase`'s
            // initialiser — a session built over `.standard` would read, and on `startFast()` overwrite,
            // the fast belonging to whoever is running this suite.

            // The store's own behaviour first, as a value with no session behind it: an absent key is
            // `nil` rather than a fast at the unix epoch, which is the one subtlety the real
            // implementation's `object(forKey:)` exists for.
            let bareStore = SpyActiveFastRepository()
            assertTest(
                bareStore.load() == nil,
                "An empty store has no fast, and `nil` is the honest answer rather than a zero instant — "
                    + "a fast started at the epoch would draw a bar counting fifty-six years")
            let seededStore = SpyActiveFastRepository(
                seed: ActiveFast(startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
            assertTest(
                seededStore.load()?.startedAt == Date(timeIntervalSince1970: 1_700_000_000),
                "…and a stored instant comes back as the fast it was, which is the whole of what a "
                    + "relaunch has to restore")

            let fastStore = SpyActiveFastRepository()
            let fastSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: fastStore,
                offlineMaps: SpyOfflineMaps())

            // **The restore, asserted without a relaunch.** A fresh use case built over a store that
            // already holds a fast reports it after `restoreFast()` and nothing else — which is the same
            // read `MainContainerView.init` makes at the first main-actor moment, so the bar is correct on
            // Home's first body evaluation rather than a frame late.
            fastStore.save(ActiveFast(startedAt: Date().addingTimeInterval(-3600)))
            await MainActor.run { fastSession.restoreFast() }
            assertTest(
                await fastSession.activeFast != nil,
                "A use case built over a store that holds a fast restores it — the relaunch, made to "
                    + "happen on a running process (\(await fastSession.activeFast.map { "\($0.startedAt)" } ?? "nil"))")
            let restoredStart = await fastSession.activeFast?.startedAt
            let savesAfterRestore = fastStore.saves

            // Idempotent, on `start()`'s pattern and for a sharper reason: a fast has exactly one piece of
            // state, so a second call that overwrote `startedAt` would silently restart a three-day fast
            // from zero with nothing on screen to say so. The store's write count is captured either side,
            // because the seed above already wrote once — a bare `saves == 1` here could not tell a
            // re-write from the write that put the fast there.
            await fastSession.startFast()
            assertTest(
                await fastSession.activeFast?.startedAt == restoredStart
                    && fastStore.saves == savesAfterRestore,
                "…and `startFast()` on a fast already running changes neither the instant nor the store "
                    + "(\(savesAfterRestore) writes before, \(fastStore.saves) after), which is what stops a "
                    + "second tap restarting a three-day fast from zero")

            // A second use case over a store that is already empty finds nothing, so `restoreFast()` cannot
            // resurrect a fast the user ended.
            let emptyStore = SpyActiveFastRepository()
            let emptySession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: emptyStore,
                offlineMaps: SpyOfflineMaps())
            await MainActor.run { emptySession.restoreFast() }
            assertTest(
                await emptySession.activeFast == nil,
                "…and a store with nothing in it restores nothing, which is why a relaunch after END FAST "
                    + "does not bring the fast back")

            // The start, on a session with no fast: one instant in memory, one write to the store, and the
            // store written *after* the slot so the bar appears on the tap rather than a disk write later.
            let freshStore = SpyActiveFastRepository()
            let freshSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: freshStore,
                offlineMaps: SpyOfflineMaps())
            await freshSession.startFast()
            let freshFast = await freshSession.activeFast
            assertTest(
                freshFast != nil && freshStore.saved == freshFast && freshStore.saves == 1,
                "Starting a fast fills the slot and writes the store exactly once, with the same instant "
                    + "in both (\(freshStore.saves) write(s))")

            // ---- The row a fast becomes ----
            //
            // `endFast()` returns the row it wrote and the store is cleared, so what is asserted here is
            // the whole of a fast's storage: one `workouts` row, carrying the five measured fields as
            // absences rather than as zeroes, named and labelled as a fast.
            //
            // **Its fast is restored 25 hours back rather than started a moment ago**, and that is not
            // tidiness. `endFast()` refuses a fast it cannot show to have run (`now > startedAt`), and
            // `startFast()` stamps `Date()` — so a fast started and ended in the same breath is a
            // sub-microsecond race that would pass or fail by the clock's resolution. A seeded instant is
            // the same code path with the variable removed, and it is also the state a real user is in:
            // every fast anyone ends has been running for hours, because that is what a fast is.
            let rowStore = SpyActiveFastRepository()
            let rowSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: rowStore,
                offlineMaps: SpyOfflineMaps())
            let rowStart = Date().addingTimeInterval(-90_000)
            rowStore.save(ActiveFast(startedAt: rowStart))
            await MainActor.run { rowSession.restoreFast() }
            let endedFast = await rowSession.endFast()
            guard let endedFast else {
                assertTest(false, "A fast 25 hours long produces a row")
                return
            }
            assertTest(
                await rowSession.activeFast == nil && rowStore.saved == nil && rowStore.clears == 1,
                "…and ending it clears the live state and the store together, so a relaunch afterwards "
                    + "cannot bring back a fast that is already a row")

            // Found on **its own day**, not by `latest()`. `latest()` orders by `started_at` descending, and
            // this fast began 25 hours ago — so it is not the newest row in this database and asking for
            // the newest would hand back Session A's session and assert nothing about the fast. The day-key
            // read is also the read the screens use, which makes this the storage half of the same claim
            // §18's first block makes about the session: a row written by `saveWorkoutUseCase` is a row
            // `getWorkouts(for:)` finds.
            let fastDay = try await workoutRepository.getWorkouts(for: rowStart)
            let storedFast = fastDay.first { $0.id == endedFast.workout.id }
            assertTest(
                storedFast != nil && fastDay.count == 1,
                "The row `endFast()` handed back is on the fast's own day and is the only row there — a "
                    + "summary is what the writer says and a stored row is what the screens read "
                    + "(\(fastDay.count) row(s) that day)")
            guard let storedFast else { return }
            assertTest(
                storedFast.source == ActiveFast.sourceLabel
                    && ActiveFast.fastSourceValues.contains(storedFast.source ?? ""),
                "**A fast carries a `source` and never `nil`.** `WhoopExportImporter.recordedWorkoutDays()` "
                    + "skips any day that already holds a workout, so a hand-ended fast written with `nil` "
                    + "would make its start day read as already recorded and silently drop the export's "
                    + "rows for that day — the 16-of-673 defect, re-opened from the other side "
                    + "(\(storedFast.source ?? "nil"))")
            assertTest(
                storedFast.strain == nil && storedFast.averageHeartRate == nil
                    && storedFast.maxHeartRate == nil && storedFast.hrZonePercents == nil
                    && storedFast.steps == nil,
                "…and it measures nothing: no strain, no heart rate, no zone block and no step count. A "
                    + "`0` in any of those would read as a measurement, which is the fabrication every "
                    + "absence rule in this app forbids")
            assertTest(
                storedFast.activityName == WhoopActivityCatalog.fastingName
                    && ActivityFigure.isFast(storedFast),
                "…and it is named `Fast`, which is what `ActivityFigure.isFast` reads to draw the fasting "
                    + "layout and the zone pill — so the row this use case writes is one its own readers "
                    + "recognise (\(storedFast.activityName ?? "nil"))")
            assertTest(
                storedFast.endedAt > storedFast.startedAt,
                "…with a real span, since a fast of no length is not a fast that happened")

            // **The page and the row are one function**, which is the claim `projectedSession(now:)`'s
            // doc makes and the one thing a live fast's page depends on: it is handed a projection, and
            // the row it becomes must be the same construction rather than a second one that agrees today.
            // The two ids differ by construction — `WorkoutSession.init` mints a fresh `UUID()` — and that
            // is the only field that may.
            let reprojected = ActiveFast(startedAt: storedFast.startedAt)
                .projectedSession(now: storedFast.endedAt)
            assertTest(
                reprojected.startedAt == storedFast.startedAt
                    && reprojected.endedAt == storedFast.endedAt
                    && reprojected.strain == storedFast.strain
                    && reprojected.averageHeartRate == storedFast.averageHeartRate
                    && reprojected.maxHeartRate == storedFast.maxHeartRate
                    && reprojected.hrZonePercents == storedFast.hrZonePercents
                    && reprojected.steps == storedFast.steps
                    && reprojected.source == storedFast.source
                    && reprojected.activityName == storedFast.activityName
                    && reprojected.route.isEmpty && storedFast.route.isEmpty
                    && reprojected.splits.isEmpty && storedFast.splits.isEmpty,
                "Re-projecting the fast on the row's own end instant reproduces it field for field, so the "
                    + "page the user was looking at and the row they end with are one construction — the "
                    + "fresh `UUID` each `WorkoutSession` mints is the only field that differs")

            // ---- A fast that never ran, and a write held open ----
            //
            // Two guards that no happy path reaches. The first is `endFast()` on a fast whose start is
            // still ahead of the clock: it returns `nil` and writes nothing, which is the same guard that
            // covers END FAST pressed in the same instant as the start — a row of zero length is not a
            // fast that happened. It is driven with a *future* start rather than by racing the clock,
            // because a race is exactly what makes an assertion say something different tomorrow.
            let unbornStore = SpyActiveFastRepository()
            let unbornSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: unbornStore,
                offlineMaps: SpyOfflineMaps())
            unbornStore.save(ActiveFast(startedAt: Date().addingTimeInterval(3600)))
            await MainActor.run { unbornSession.restoreFast() }
            let unbornSummary = await unbornSession.endFast()
            let unbornStillRunning = await unbornSession.activeFast != nil
            assertTest(
                unbornSummary == nil && unbornStillRunning,
                "`endFast()` on a fast that has not started yet writes nothing **and leaves it running** — "
                    + "a row of zero length is not a fast that happened, and clearing the live state over a "
                    + "write that never happened would lose the fast")

            assertTest(
                await emptySession.endFast() == nil && emptyStore.clears == 0,
                "…and `endFast()` with no fast at all is inert: it returns nothing and does not touch the "
                    + "store, so it cannot clear a fast this session never had")

            // The second is the ordering, and it is the one property in this block that is invisible
            // against a real repository — the save returns before any assertion can run, so the window it
            // opens is a window nothing can look into. Holding the write open is what makes it observable.
            let gatedStore = SpyActiveFastRepository()
            let gatedRepository = GatedWorkoutRepository()
            let gatedSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: gatedRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: gatedStore,
                offlineMaps: SpyOfflineMaps())
            await gatedSession.startFast()
            let endingFast = Task { await gatedSession.endFast() }
            await gatedRepository.awaitSaveEntered()
            let liveDuringWrite = await gatedSession.activeFast
            assertTest(
                liveDuringWrite == nil && gatedStore.saved == nil,
                "**`endFast()` clears the live fast and the stored one above its first `await`.** Asserted "
                    + "while the write is parked mid-flight, which is the only moment the ordering is "
                    + "visible: the bar is drawn from `activeFast`, so clearing it below the save would "
                    + "leave it counting over Home for the length of a SQLite write — and would leave a "
                    + "second END FAST callable in that window")
            await gatedRepository.open()
            let gatedSummary = await endingFast.value
            assertTest(
                gatedSummary != nil && gatedSummary?.calories == nil,
                "…and the write it was waiting on still completes, handing back the row — with no calorie "
                    + "figure, because a fast burns nothing this app measured")
        } catch {
            assertTest(false, "The fast's round trip threw: \(error)")
        }
    }
}
