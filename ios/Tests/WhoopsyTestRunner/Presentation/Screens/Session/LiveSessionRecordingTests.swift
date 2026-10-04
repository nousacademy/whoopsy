import Foundation
import Whoopsy

// MARK: - 18. The session, end to end

/// A file of §18's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `LiveSessionTests.run()` calls it, in the order the section ran it in.

/// The five values the block used to build for itself arrive as parameters, built once in
/// `LiveSessionTests.run()`. Rebuilding the database here would make `fastDay.count == 1`
/// pass because the database is empty rather than because the fast landed where it should.
enum LiveSessionRecordingTests {
    static func run(
        db: LocalDatabaseManager,
        profileRepository: GRDBUserProfileRepository,
        workoutRepository: GRDBWorkoutRepository,
        telemetry: ScriptedTelemetryRepository,
        stream: StreamBiometricsUseCase
    ) async throws {
        // ---- The session, end to end ----
        //
        // Everything above is a value. This is the path: a scripted stream in, a `workouts` row out, and
        // a card requested, updated on a throttle and ended. It is the only block in the suite that
        // drives `LiveSessionUseCase`, and it is where the app's one recording path is pinned.

        do {
            // Re-declared rather than threaded: `Date(timeIntervalSinceReferenceDate: 0)` is a pure
            // value, so a fresh one here is the same value the accumulator's file holds — unlike the
            // five parameters above, which accumulate and so are built once and shared.
            let t0 = Date(timeIntervalSinceReferenceDate: 0)
            let spy = SpyLiveActivityController()
            let location = SpyLocationTracking()
            let session = LiveSessionUseCase(
                controller: spy,
                locationTracking: location,
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())

            // ---- Session A: no weight on file, sixty samples a quarter-second apart ----
            //
            // The weight's absence is the point of running it first: `GRDBUserProfileRepository` falls
            // back to a cold-start 190/60 pair with **no** `weightKg`, so this session is what a fresh
            // install produces and its calorie figure must be absent.

            await session.start()
            assertTest(
                await MainActor.run { spy.startCount } == 1,
                "Starting a session requests exactly one lock-screen card")
            assertTest(
                await MainActor.run { session.isLiveActivityActive },
                "…and the card is reported active, so the screen knows whether to explain its absence")
            assertTest(await session.isRunning, "…and the session is recording")

            assertTest(
                await waitUntil { telemetry.subscriberCount == 1 },
                "…and it has attached exactly one reader to the telemetry stream, which is what makes "
                    + "the samples below reach it")

            // Sixty samples a quarter-second apart: a 14.75-second span. 0.25 is exact in binary, so
            // every one-second boundary the throttle tests falls on a representable instant.
            let sampleCount = 60
            for index in 0..<sampleCount {
                telemetry.yield(BiometricSample(
                    timestamp: t0.addingTimeInterval(Double(index) * 0.25),
                    heartRate: 150))
            }

            assertTest(
                await waitUntil { await session.snapshot?.sampleCount == sampleCount },
                "All \(sampleCount) samples reached the session's accumulator")

            // `pushCard` hands the controller's `update` to an unstructured `Task`, so the count lags the
            // ingest by however long those tasks take to reach the main actor. This waits for them to
            // drain before reading — and it can only ever *under*-count, never over: the throttle runs
            // synchronously inside `ingest`, so exactly fifteen push tasks exist and no more. The wait is
            // therefore a barrier, and the assertion below is still the one that decides.
            _ = await waitUntil { await MainActor.run { spy.updateCount } >= 15 }
            let pushed = await MainActor.run { spy.updateCount }
            assertTest(
                pushed == 15,
                "…and the card was pushed 15 times, not 60: the first sample, then at most one push "
                    + "per second, so a quarter-second stream is throttled to its one-second crossings "
                    + "(\(pushed) pushes)")

            let sessionASnapshot = await session.snapshot
            assertTest(
                sessionASnapshot?.zonePercents[1] == 100.0,
                "150 bpm on a 190/60 table is zone 2 for the whole session, so the band row reads "
                    + "`100%` there and nothing elsewhere "
                    + "(\(sessionASnapshot.map { $0.zonePercents.description } ?? "no snapshot"))")

            let summaryA = await session.end()
            guard let summaryA else {
                assertTest(false, "A session that measured something produces a summary")
                return
            }
            assertTest(
                summaryA.calories == nil,
                "…with no calorie figure, because no body weight is on file — the absence rule rather "
                    + "than a figure scaled by 75 kg this app invented")
            assertTest(await session.isRunning == false, "…and the session has stopped")
            assertTest(
                await LiveSessionBar.subject(
                    isActivityRunning: session.isRunning,
                    activityName: session.activityName,
                    activityStartedAt: session.startedAt,
                    activeFast: nil) == nil,
                "…which is what takes the recording bar off Home, and it is the `isRunning` half of the "
                    + "gate that does it — `end()` clears that flag before its first await rather than "
                    + "after its last, so the bar does not outlive the END press by a database write")
            assertTest(
                await session.snapshot == nil,
                "…and its state is dropped, so a second session cannot inherit the first one's samples")
            assertTest(
                await MainActor.run { spy.endCount } == 1,
                "…having ended the card exactly once")
            assertTest(
                await MainActor.run { spy.pushedStates.last?.isRunning } == false,
                "…with the final state marked not running, because `Activity.content` cannot be replaced "
                    + "after `end` and a card left reading live would count up for four hours")

            // The subscription is released. Left attached, a reader accumulates on a stream nothing
            // feeds — the silent failure this protocol's multicast registry exists to avoid.
            assertTest(
                await waitUntil { telemetry.subscriberCount == 0 },
                "…and its reader is released from the telemetry stream")

            // ---- Session B: a weight on file, a longer and harder effort ----

            try await profileRepository.saveUserProfile(
                UserProfile(maxHeartRate: 190, restingHeartRate: 60, weightKg: 75.0))

            await session.start()
            assertTest(
                await waitUntil { telemetry.subscriberCount == 1 },
                "A second session attaches its own reader")

            // 61 samples ten seconds apart, all at 170 bpm: zone 4 (164…177, weight 9.0) and 301
            // measured seconds — `1.0 + 60 × 5.0`. The load is exactly `9.0 × 301.0`, which the pinned
            // figure below is the exponential of.
            for index in 0..<61 {
                telemetry.yield(BiometricSample(
                    timestamp: t0.addingTimeInterval(Double(index) * 10),
                    heartRate: 170))
            }
            assertTest(
                await waitUntil { await session.snapshot?.sampleCount == 61 },
                "The second session took all 61 of its samples")

            let hardSnapshot = await session.snapshot
            assertTest(
                hardSnapshot?.measuredSeconds == 301.0,
                "…spanning 301 measured seconds (\(hardSnapshot.map { $0.measuredSeconds } ?? -1.0))")
            assertTest(
                hardSnapshot?.strain == 2.4,
                "…for a strain of `2.4`: 9.0 × 301.0 of weighted load through "
                    + "`21 × (1 − e^(−0.000045 × load))`, rounded to one decimal "
                    + "(\(hardSnapshot.map { snap in snap.strain.map { "\($0)" } ?? "nil" } ?? "no snapshot"))")
            assertTest(
                hardSnapshot?.maxHeartRate == 170 && hardSnapshot?.averageHeartRate == 170,
                "…and both heart-rate figures are the samples', not a window's")

            let summaryB = await session.end()
            guard let recorded = summaryB?.workout else {
                assertTest(false, "The second session produced an activity")
                return
            }

            // Two of these fields are `nil` deliberately and the third is a word. `source: nil` is
            // documented on the entity as the value for a session this app recorded itself;
            // `hrZonePercents` is WHOOP's own `HR Zone n %` block out of `workouts.csv`, and writing this
            // app's computed zones into it is precisely the two-producer defect the `source` column exists
            // to prevent. `activityName` is the word WHOOP's own classifier abstains to rather than an
            // absence — see the assertion below.
            //
            // **Each is compared after unwrapping, and that is not style.** `recorded?.source == nil` is
            // `String??` against `nil`, which Swift resolves to the `_OptionalNilComparisonType` overload
            // — so it asks whether `recorded` itself is nil and answers `false` for every one of these,
            // passing whatever the field holds.
            assertTest(
                recorded.source == nil,
                "…carrying no `source`, which is what marks it as this app's own recording rather than "
                    + "an imported one")
            // The name is a label and not a measurement, which is why this is a string rather than a
            // `nil`. **The name now comes from the picker**, so the claim has two halves and this session
            // covers only the first: this app does not *classify* a session — it cannot, and nothing here
            // infers an activity from the data — so when the user was asked and chose, the row carries
            // their word, and when they were not asked it carries WHOOP's own answer to that case, a word
            // rather than an absence — 197 rows of the bundled export read exactly `Activity`.
            // `ActivityGlyph` holds no entry for the abstention string on purpose, so that chip falls back
            // exactly as it did for `nil` and no screen moved.
            assertTest(
                recorded.activityName == "Activity",
                "…and named with WHOOP's own abstention word rather than left NULL when the picker chose "
                    + "nothing, which its export writes on 197 rows (\(recorded.activityName ?? "nil"))")

            // **The other half, and it needs its own session.** `start(name:)` defaults to the abstention
            // word, so every assertion above passes whether the name is threaded through or dropped on the
            // floor — a recording that silently discarded the picker's answer and wrote `Activity` over it
            // would fail nothing here. This is the assertion that fails in that case, and it is also what
            // makes the recording bar's own sentence honest: the bar reads `activityName`, so a bar saying
            // `Basketball` over a row saying `Activity` is the two-producer defect in miniature.
            // It gets its own card and GPS, so the counters session A's block pins are untouched — and it
            // is fed nothing, so it measures nothing, writes nothing, and leaves the day's row count where
            // the two assertions below expect it. It attaches a reader to the scripted stream and releases
            // it again on the way out.
            let namedSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())
            await namedSession.start(name: "Basketball")
            assertTest(
                await namedSession.activityName == "Basketball",
                "A session started with a picked name reports it back, which is what the recording bar "
                    + "speaks (\(await namedSession.activityName ?? "nil"))")
            let namedEnded = await namedSession.end()
            let namedNameAfterEnd = await namedSession.activityName
            assertTest(
                namedEnded == nil && namedNameAfterEnd == nil,
                "…and ending it drops the name with the rest of the session, so a second recording cannot "
                    + "inherit the first one's label the way `reset()` stops it inheriting its samples")
            assertTest(
                recorded.hrZonePercents == nil,
                "…and no zone block: that column is WHOOP's own, and this app's zones are a different "
                    + "producer's answer to a different question")
            // The route half of this sentence used to read *"this build has no GPS"*, which was true when
            // nothing called the location seam and is false now that the screen has a toggle. What is
            // still true is why this route is empty: **the toggle was never touched**, and route
            // recording is opt-in per session rather than implied by starting one. The split half is
            // unchanged and unconditional — there is still no lap model and no control that creates a
            // split, so an empty list stays the honest answer rather than an invented one.
            assertTest(
                recorded.route.isEmpty && recorded.splits.isEmpty,
                "…and an empty route because the toggle was never turned on, beside an empty split list "
                    + "that has no producer at all — neither is a dropped column "
                    + "(\(recorded.route.count) points, \(recorded.splits.count) splits)")
            let routeStartsWithoutToggle = await MainActor.run { location.startCount }
            assertTest(
                routeStartsWithoutToggle == 0,
                "…and the GPS was never started for it, so an opt-in the user did not take does not wake "
                    + "the radio (started \(routeStartsWithoutToggle) times)")

            // `(170 − 60) × 0.014 × 75 × 0.07` is 8.085 kcal/min, and the accumulator scales it by the
            // session's own `measuredSeconds / 60` — 301 seconds — not by a sample count.
            let expectedB = (170.0 - 60.0) * 0.014 * 75.0 * 0.07 * (301.0 / 60.0)
            assertTest(
                abs((summaryB?.calories ?? -1.0) - expectedB) < 1e-9,
                "…with a calorie figure now that a weight is on file "
                    + "(\(summaryB.map { s in s.calories.map { "\($0)" } ?? "nil" } ?? "no summary") against \(expectedB))")

            // ---- What END leaves behind ----

            let today = try await workoutRepository.getWorkouts(for: Date())
            assertTest(
                today.count == 2,
                "Both sessions are on the day they were recorded, found by the same read Home's "
                    + "`ACTIVITIES` row uses (\(today.count) held)")
            assertTest(
                today.contains { $0.strain == 2.4 },
                "…including the one that scored, read back with its strain intact")

            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            assertTest(
                try await workoutRepository.getWorkouts(for: yesterday).isEmpty,
                "…and neither is on the day before, which is the day-key snap `saveWorkout` applies "
                    + "centrally")

            // A session that measured nothing writes nothing. `WorkoutSession` has no optional strain,
            // average or maximum, so a row here would mean inventing all three — the rule is that a
            // writer may persist a row only when it produced a measurement.
            await session.start()
            assertTest(
                await waitUntil { telemetry.subscriberCount == 1 },
                "A third session starts and attaches its reader")
            let emptySummary = await session.end()
            assertTest(
                emptySummary == nil,
                "A session with no samples produces no activity at all — not a `0.0`-strain row")
            assertTest(
                try await workoutRepository.getWorkouts(for: Date()).count == 2,
                "…and writes no row: a START followed by an END with no strap on the body leaves the "
                    + "day exactly as it found it")

            // ---- A card the system refuses ----
            //
            // Live Activities can be switched off per-app, the system caps how many an app may have, and
            // a build without `NSSupportsLiveActivities` is refused outright. All three are properties of
            // the device or the build, and none is a reason to stop recording.

            let refusingSpy = SpyLiveActivityController()
            await MainActor.run { refusingSpy.refusesStart = true }
            let refusingSession = LiveSessionUseCase(
                controller: refusingSpy,
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())

            await refusingSession.start()
            assertTest(
                await refusingSession.liveActivityError != nil,
                "A refused card is reported as an error rather than swallowed — the screen has a "
                    + "sentence to draw from it")
            assertTest(
                await MainActor.run { refusingSession.isLiveActivityActive } == false,
                "…and no card is claimed to be up")
            assertTest(
                await refusingSession.isRunning,
                "…while the session records anyway: a card that cannot be shown is a missing card, not "
                    + "a missing session")
            assertTest(
                await waitUntil { telemetry.subscriberCount == 1 },
                "…and it is reading the strap like any other session")

            await refusingSession.end()
            assertTest(
                await waitUntil { telemetry.subscriberCount == 0 },
                "…and releases it when it ends")

            // ---- The orphan sweep ----
            //
            // A card outlives the process that requested it, so an app killed mid-session leaves the
            // lock screen counting up from a start instant nothing is recording. This build has no BLE
            // state restoration and no in-flight persistence, so a relaunch cannot adopt one — it can
            // only end it, which is what `MainContainerView`'s root task does.

            let sweepSpy = SpyLiveActivityController()
            let sweepSession = LiveSessionUseCase(
                controller: sweepSpy,
                locationTracking: SpyLocationTracking(),
                streamBiometricsUseCase: stream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                userProfileRepository: profileRepository,
                bleRepository: telemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())

            await sweepSession.endOrphanedLiveActivities()
            assertTest(
                await MainActor.run { sweepSpy.endOrphansCount } == 1,
                "The launch sweep ends the cards a dead process left behind")

            await sweepSession.start()
            await sweepSession.endOrphanedLiveActivities()
            assertTest(
                await MainActor.run { sweepSpy.endOrphansCount } == 1,
                "…and does nothing while a session is running, so it cannot end the card this process "
                    + "is actively updating")
            _ = await sweepSession.end()
            assertTest(
                await waitUntil { telemetry.subscriberCount == 0 },
                "The last session's reader is released")

            // ---- The GPS route ----
            //
            // `recorded.route` above is empty because the toggle was never touched, and the assertion
            // beside it says why. This is the other half of that sentence: what the route holds when the
            // toggle *is* turned on. It gets its own in-memory database, its own scripted stream and its
            // own spies, so nothing here can move the reader counts above.
            //
            // **The two halves of the split are asserted in different places on purpose.** "Is this
            // coordinate a place at all" is a pure value and is asserted first, with no session behind it
            // — that is the `isPlausible` rule's whole reason for living on the entity rather than inside
            // the CoreLocation callback, since the runner has no `CLLocationManager` and must not build
            // one. "Does the session stamp and keep it" needs the session, and is asserted below.
            //
            // **Nothing here is evidence about a real fix.** The spy substitutes for CoreLocation; what is
            // pinned is the filtering, the stamping, the refusal path, the lifecycle pairing and the
            // storage round trip.

            assertTest(
                WorkoutRoutePoint(latitude: 40.7411, longitude: -73.9897, heartRate: 0).isPlausible
                    && !WorkoutRoutePoint(latitude: 0, longitude: 0, heartRate: 0).isPlausible,
                "A real fix is a place and `(0, 0)` is not — that pair is a heuristic, because Null "
                    + "Island is both the placeholder CoreLocation returns for an unresolved fix and a "
                    + "real point in the Gulf of Guinea, and the trade is taken knowingly")
            assertTest(
                !WorkoutRoutePoint(latitude: 91, longitude: 0, heartRate: 0).isPlausible
                    && !WorkoutRoutePoint(latitude: 0, longitude: -181, heartRate: 0).isPlausible
                    && !WorkoutRoutePoint(latitude: .nan, longitude: 0, heartRate: 0).isPlausible,
                "…and this half is definitional rather than a heuristic: a latitude outside ±90, a "
                    + "longitude outside ±180 or a NaN is not a coordinate, which is what catches a fix "
                    + "built from arithmetic that went wrong")

            let routeDB = LocalDatabaseManager(inMemory: true)
            let routeWorkouts = GRDBWorkoutRepository(db: routeDB)
            let routeProfile = GRDBUserProfileRepository(db: routeDB)
            let routeTelemetry = ScriptedTelemetryRepository()
            let routeStream = StreamBiometricsUseCase(
                bleRepository: routeTelemetry, biometricRepository: EmptyBiometricStore())
            let gps = SpyLocationTracking()
            await MainActor.run { gps.permission = .undetermined }
            let routeSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: gps,
                streamBiometricsUseCase: routeStream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: routeWorkouts),
                userProfileRepository: routeProfile,
                bleRepository: routeTelemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())

            await routeSession.start()
            assertTest(
                await routeSession.isRecordingRoute == false,
                "A session records no route until the toggle is turned on — an indoor session must not "
                    + "put a blue location indicator on the screen because it was started")
            assertTest(
                await MainActor.run { gps.startCount } == 0,
                "…and starting a session does not touch the GPS at all")

            await routeSession.setRouteRecording(true)
            assertTest(
                await routeSession.isRecordingRoute,
                "…and turning the toggle on starts the route")
            let prompted = await MainActor.run { gps.requestPermissionCount }
            assertTest(
                prompted == 1,
                "…asking for permission first, because nobody had been asked (`permission` was "
                    + "`.undetermined`), exactly once — \(prompted) prompt(s)")
            assertTest(
                await waitUntil { await MainActor.run { gps.startCount } == 1 },
                "…and handing the session the one stream it will read fixes from")

            // Two fixes before the strap has said anything, one after, and one that is not a place. The
            // first pair is the case the sentinel exists for.
            _ = await MainActor.run { gps.yield(latitude: 40.7411, longitude: -73.9897, timestamp: t0) }
            _ = await MainActor.run {
                gps.yield(latitude: 40.7420, longitude: -73.9888, timestamp: t0.addingTimeInterval(5))
            }

            routeTelemetry.yield(BiometricSample(timestamp: t0.addingTimeInterval(10), heartRate: 150))
            assertTest(
                await waitUntil { await routeSession.snapshot?.latestHeartRate == 150 },
                "…and the session has a reading in force before the fixes that follow it arrive")

            _ = await MainActor.run {
                gps.yield(latitude: 40.7430, longitude: -73.9899, timestamp: t0.addingTimeInterval(15))
            }
            let placeholderDelivered = await MainActor.run {
                gps.yield(latitude: 0, longitude: 0, timestamp: t0.addingTimeInterval(20))
            }
            assertTest(
                placeholderDelivered,
                "A `(0, 0)` fix is delivered rather than refused at the seam, so the filter that drops it "
                    + "is the session's own and is asserted below rather than assumed")

            // ---- Turning it off, and back on ----

            await routeSession.setRouteRecording(false)
            assertTest(
                await routeSession.isRecordingRoute == false,
                "Turning the toggle off stops the route")
            let stopsAtToggleOff = await MainActor.run { gps.stopCount }
            assertTest(
                stopsAtToggleOff == 1,
                "…releasing the GPS exactly once (\(stopsAtToggleOff) stop(s))")
            assertTest(
                await MainActor.run {
                    gps.yield(latitude: 40.75, longitude: -73.98, timestamp: t0.addingTimeInterval(25))
                } == false,
                "…and delivery really ended, rather than a flag being flipped over a stream that still "
                    + "runs — a stopped GPS that keeps yielding is the blue indicator staying up")

            await routeSession.setRouteRecording(true)
            assertTest(
                await waitUntil { await MainActor.run { gps.startCount } == 2 },
                "Turning it back on starts a second stream, so the fixes already collected are kept "
                    + "beside the new ones rather than lost with the first")
            let promptedTwice = await MainActor.run { gps.requestPermissionCount }
            assertTest(
                promptedTwice == 1,
                "…without asking for permission a second time, because the answer is already on file "
                    + "(\(promptedTwice) prompt(s) across both starts)")
            _ = await MainActor.run {
                gps.yield(latitude: 40.7440, longitude: -73.9905, timestamp: t0.addingTimeInterval(30))
            }

            let routeSummary = await routeSession.end()
            guard let routeRecorded = routeSummary?.workout else {
                assertTest(false, "A session that recorded a route produced an activity")
                return
            }
            assertTest(
                routeRecorded.route.count == 4,
                "Four of the five fixes are stored: the two before the first reading, the one after it "
                    + "and the one after the toggle came back — and not the `(0, 0)` placeholder "
                    + "(\(routeRecorded.route.count) kept)")
            assertTest(
                routeRecorded.route.map(\.heartRate) == [0, 0, 150, 150],
                "…each stamped with the reading in force when it arrived, so the two before the first "
                    + "sample carry the documented `0` sentinel and the two after carry 150 — the "
                    + "stamp is the session's, not the location service's literal "
                    + "(\(routeRecorded.route.map(\.heartRate)))")
            assertTest(
                routeRecorded.route.map(\.timestamp)
                    == [t0, t0.addingTimeInterval(5), t0.addingTimeInterval(15), t0.addingTimeInterval(30)],
                "…in the order they arrived, with the dropped placeholder leaving no gap in the list")
            assertTest(
                routeRecorded.splits.isEmpty,
                "…and still no splits: the route path adds a producer for one of the two empty lists and "
                    + "none for the other, because there is still no lap model")

            // The summary carries the array; this is the row. §14 pins the route's round trip through
            // `GRDBWorkoutRepository` on a fixture, and this is the same round trip through the write path
            // the app actually drives — which is the thing a summary-level assertion cannot see.
            let storedRoute = try await routeWorkouts.getWorkouts(for: Date()).first?.route ?? []
            assertTest(
                storedRoute.count == 4 && storedRoute.map(\.heartRate) == [0, 0, 150, 150],
                "…and the same four fixes read back off `GRDBWorkoutRepository`, which is what proves they "
                    + "reached `workout_route_points` rather than only the summary "
                    + "(\(storedRoute.count) read back)")

            let stopsAfterEnd = await MainActor.run { gps.stopCount }
            assertTest(
                stopsAfterEnd > stopsAtToggleOff,
                "…and END released the GPS as well as the toggle did — the instance the toggle started is "
                    + "the one END stopped, which is the pairing a service built fresh per read would "
                    + "break (\(stopsAtToggleOff) stop(s) at the toggle, \(stopsAfterEnd) after END)")
            assertTest(
                await MainActor.run { gps.yield(latitude: 40.76, longitude: -73.97, timestamp: t0) } == false,
                "…leaving nothing delivering fixes into a session that has ended")

            // ---- A permission the user refused ----
            //
            // The absence rule applied to a capability, in the three-part shape the refused card above
            // already uses: the refusal is reported, the capability is not claimed, and the core function
            // is untouched. A route that cannot be recorded is a missing route, not a missing session.

            let deniedTelemetry = ScriptedTelemetryRepository()
            let deniedGPS = SpyLocationTracking()
            await MainActor.run {
                deniedGPS.permission = .undetermined
                deniedGPS.permissionAfterRequest = .denied
            }
            let deniedSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: deniedGPS,
                streamBiometricsUseCase: StreamBiometricsUseCase(
                    bleRepository: deniedTelemetry, biometricRepository: EmptyBiometricStore()),
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: routeWorkouts),
                userProfileRepository: routeProfile,
                bleRepository: deniedTelemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())

            await deniedSession.start()
            await deniedSession.setRouteRecording(true)
            let deniedRecording = await deniedSession.isRecordingRoute
            let deniedStarts = await MainActor.run { deniedGPS.startCount }
            assertTest(
                deniedRecording == false && deniedStarts == 0,
                "A refused permission leaves the toggle off and never starts the GPS — the capability is "
                    + "absent rather than the request being ignored")
            let deniedError = await deniedSession.routeError
            assertTest(
                deniedError?.contains("Settings") == true,
                "…and the refusal is reported as a sentence naming where to change it, rather than "
                    + "swallowed (\(deniedError ?? "nil"))")
            assertTest(
                await deniedSession.isRunning,
                "…while the session records anyway: a route that cannot be recorded is a missing route, "
                    + "not a missing session")
            assertTest(
                await waitUntil { deniedTelemetry.subscriberCount == 1 },
                "…and it is reading the strap like any other session")

            deniedTelemetry.yield(BiometricSample(timestamp: t0, heartRate: 120))
            assertTest(
                await waitUntil { await deniedSession.snapshot?.sampleCount == 1 },
                "…and it takes samples")
            let deniedSummary = await deniedSession.end()
            assertTest(
                deniedSummary?.workout.route.isEmpty == true,
                "…ending with a row that carries an empty route, which is what a session with no route "
                    + "should look like rather than no row at all")

            // The *other* refusal, and the reason the two are separate sentences rather than one generic
            // one: still `.undetermined` after a request means Location Services are off for the whole
            // device, which the user fixes on a different screen entirely. A single message would send
            // them to a per-app setting that is not the problem.
            let offGPS = SpyLocationTracking()
            await MainActor.run {
                offGPS.permission = .undetermined
                offGPS.permissionAfterRequest = .undetermined
            }
            let offSession = LiveSessionUseCase(
                controller: SpyLiveActivityController(),
                locationTracking: offGPS,
                streamBiometricsUseCase: routeStream,
                saveWorkoutUseCase: SaveWorkoutUseCase(repository: routeWorkouts),
                userProfileRepository: routeProfile,
                bleRepository: routeTelemetry,
                activeFastRepository: SpyActiveFastRepository(),
                offlineMaps: SpyOfflineMaps())
            await offSession.setRouteRecording(true)
            let offError = await offSession.routeError
            assertTest(
                offError != nil && offError?.contains("Settings") == false,
                "…and a device with Location Services switched off gets the other sentence, which does "
                    + "not point at a per-app setting that is not the problem (\(offError ?? "nil"))")

            // ---- What Home draws from those rows ----
            //
            // `getWorkouts(for:)` above proves the row is *stored*; this proves it reaches the screen the
            // row is for — Home's `ACTIVITIES` list under `My Day` — through the view model that draws it
            // rather than through the repository directly. The repo keeps those two apart on purpose: §16
            // and §17 pin one table read through two view models with two separate gates, and a reader that
            // forgot a gate is invisible to an assertion made against the repository.
            //
            // The view model is handed a **throwaway** telemetry repository. `load(for:)` ends by
            // subscribing to its stream, and handing it §18's scripted `telemetry` would move
            // `telemetry.subscriberCount` out from under the reader-count assertions above.
            let home = await MainActor.run {
                HomeViewModel(
                    recoveryRepository: GRDBRecoveryRepository(db: db),
                    sleepRepository: GRDBSleepRepository(db: db),
                    strainRepository: GRDBStrainRepository(db: db),
                    workoutRepository: workoutRepository,
                    userProfileRepository: profileRepository,
                    stepRepository: GRDBStepRepository(db: db),
                    analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: ScriptedTelemetryRepository(),
                        biometricRepository: EmptyBiometricStore()))
            }
            await home.load(for: Date())
            let homeWorkouts = await MainActor.run { home.workouts }

            assertTest(
                homeWorkouts.count == 2,
                "Home's `ACTIVITIES` list holds both of the day's sessions (\(homeWorkouts.count) held)")
            assertTest(
                homeWorkouts.contains { $0.activityName == "Activity" },
                "…and the one this app recorded carries the abstention name all the way to the card, not "
                    + "just into the row (\(homeWorkouts.map { $0.activityName ?? "nil" }))")
        } catch {
            assertTest(false, "The live session's round trip threw: \(error)")
        }
    }
}
