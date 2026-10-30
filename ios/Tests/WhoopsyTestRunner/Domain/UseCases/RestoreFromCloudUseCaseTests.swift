import Foundation
import Whoopsy

/// §22.6 — the one path that reads the API, and the guarantee that nothing else does.
///
/// **The read path was the defect this replaces.** The seven decorators used to answer a local miss from
/// the database, unconditionally for the three history windows, so a screen's content could depend on a
/// request — and a Home load measured 32–39 s on 2026-10-27 was never waiting on the network to justify
/// it. `DIContainer` now constructs every decorator with a closed read window, and a fresh install is
/// filled by this use case instead. The blocks below pin the replacement's contract: what it asks for,
/// what it writes, the one state in which it must ask for nothing at all, and the window that stops the
/// automatic path but not the explicit press.
enum RestoreFromCloudUseCaseTests {

    static func run() async throws {
        let calendar = SyncSchedule.calendar()
        let today = calendar.startOfDay(for: Date())
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        let recovery = RecoverySyncRow(
            date: day(-1), recoveryScore: 71, restingHeartRate: 52,
            hrvValueMs: 68.4, hrvMetric: .rmssd)
        let profile = UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55)

        /// A use case over a real in-memory database and the spy cloud, wired exactly as `DIContainer`
        /// wires it — the seven stores are the database itself.
        @MainActor
        func make(
            _ db: LocalDatabaseManager,
            _ spy: SpyCloudSync,
            _ settings: InMemorySyncSettingsRepository,
            windowOpen: Bool = true
        ) -> RestoreFromCloudUseCase {
            RestoreFromCloudUseCase(
                cloud: spy,
                settingsStore: settings,
                profileStore: db,
                inactivityStore: db,
                recoveryStore: db,
                sleepStore: db,
                stepCountStore: db,
                strainStore: db,
                workoutStore: db,
                isCallWindowOpen: { windowOpen })
        }

        // MARK: It asks for all seven and writes what it finds

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync(rows: [recovery], profile: profile)
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = await make(db, spy, settings)

            // Subscribed before the restore, because the point of the announcement is a screen that is
            // already up when the rows land.
            final class Box: @unchecked Sendable {
                private let lock = NSLock()
                private var value: Int?
                func set(_ new: Int) { lock.lock(); value = new; lock.unlock() }
                var read: Int? { lock.lock(); defer { lock.unlock() }; return value }
            }
            let announced = Box()
            let listener = Task {
                for await rows in useCase.completions {
                    announced.set(rows)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(200))

            let report = try await useCase.restore(now: Date())
            let announcedArrived = await waitUntil { announced.read != nil }
            _ = await listener.value

            assertTest(
                report.rows[.recoveries] == 1 && report.restoredProfile,
                "A restore writes the rows the database holds and the profile it has never seen "
                    + "(recoveries \(report.rows[.recoveries] ?? -1), profile \(report.restoredProfile))")

            let stored = try await db.syncRows(from: day(-2), to: day(0))
            assertTest(
                stored.count == 1 && stored.first?.recoveryScore == 71,
                "…into the phone's own table, so every screen after this one is reading local rows "
                    + "(\(stored.count) row(s))")

            let calls = await spy.calls
            let asked = Set(calls.map { call -> String in
                switch call {
                case .recoveries: return "recoveries"
                case .strains: return "strains"
                case .sleeps: return "sleeps"
                case .stepCounts: return "stepCounts"
                case .workouts: return "workouts"
                case .receptiveInactivities: return "inactivities"
                case .profile: return "profile"
                default: return "other"
                }
            })
            assertTest(
                asked.isSuperset(of: ["recoveries", "strains", "sleeps", "stepCounts", "workouts",
                                      "inactivities", "profile"]),
                "…and it asks every one of the seven resources plus the profile, rather than a subset "
                    + "that would leave a resource's section empty on a restored phone (\(asked.sorted()))")
            assertTest(
                announcedArrived && announced.read == report.totalRows,
                "…and announces the rows it wrote — the report's own total, profile included — so a "
                    + "screen already on the day behind the pane reloads instead of drawing what it "
                    + "read before the restore (\(String(describing: announced.read)) of "
                    + "\(report.totalRows))")
            assertTest(
                SyncStorageViewModel.restoredSentence(report)
                    == "Restored 2 rows over 30 days — recoveries 1 · profile 1.",
                "…and the pane's sentence names what landed rather than only how many rows: a reader "
                    + "looking at a blank ring is asking which resource came back, and a total cannot "
                    + "tell a lost night from one that was never uploaded "
                    + "(\(SyncStorageViewModel.restoredSentence(report)))")
            assertTest(
                SyncStorageViewModel.restoredSentence(.empty(days: 30))
                    == "The database holds nothing for the last 30 days.",
                "…and a window the database answered with nothing keeps its own sentence, which is "
                    + "the absence rather than a report of zeroes")
            assertTest(
                !calls.contains { call in
                    switch call {
                    case .writeRecovery, .writeRecoveries, .writeStrain, .writeStrains, .writeWorkout,
                         .writeWorkouts, .writeSleep, .writeSleeps, .writeStepCount, .writeStepCounts,
                         .writeReceptiveInactivity, .writeReceptiveInactivities, .writeProfile:
                        return true
                    default:
                        return false
                    }
                },
                "…and writes nothing back to the database: a restore is a download, and an upload "
                    + "hidden inside it is the one thing the pane's switch does not promise")
        }

        // MARK: The window belongs to the automatic path, and only to it

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync(rows: [recovery])
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = await make(db, spy, settings, windowOpen: false)

            // The launch-time repair is the app deciding to call out, so it obeys the same
            // 18:00–midnight schedule as the daily upload — a fresh install at three in the morning
            // waits for the evening rather than opening a socket the app promised not to open.
            await useCase.restoreIfNeeded(now: Date())
            let closedCalls = await spy.calls
            assertTest(
                closedCalls.isEmpty,
                "A closed window stops the automatic repair before it reads anything — the launch "
                    + "path keeps the schedule every other background call obeys")

            // The pane's button is a person, not a schedule. Measured 2026-10-27, a restore pressed at
            // 14:50 Eastern reported `Nothing was found in the database` for a request the app had
            // refused to make; the fix is not a better sentence but the request.
            let report = try await useCase.restore(now: Date())
            let pressedCalls = await spy.calls
            assertTest(
                report.skipped == nil && report.rows[.recoveries] == 1 && !pressedCalls.isEmpty,
                "…and does not stop the explicit press: RESTORE is the one control that reaches the "
                    + "database outside the window, because a phone missing days needs it at whatever "
                    + "hour the user notices (skipped \(String(describing: report.skipped)), "
                    + "\(pressedCalls.count) call(s))")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync(rows: [recovery])
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .device))
            let useCase = await make(db, spy, settings)

            let deviceReport = try await useCase.restore(now: Date())
            assertTest(
                deviceReport.skipped == .deviceDestination,
                "A `.device` install is refused with its own reason rather than reported as empty")
            await useCase.restoreIfNeeded(now: Date())
            let deviceCalls = await spy.calls
            assertTest(
                deviceCalls.isEmpty,
                "A phone whose destination is storage asks for nothing: the destination is a switch, "
                    + "and an install that never opened the pane never makes a request")
        }

        do {
            // The guarded entry point on a phone that holds a day — the ordinary case, and the one that
            // must stay free.
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncRows([recovery])
            let spy = SpyCloudSync(rows: [recovery], profile: profile)
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = await make(db, spy, settings)

            await useCase.restoreIfNeeded(now: Date())
            let filledCalls = await spy.calls
            assertTest(
                filledCalls.isEmpty,
                "…and a phone that already holds a day is not restored over, however empty the rest of "
                    + "it looks: a merge would replace days this app computed with the database's copy")
        }

        // MARK: A profile this phone already has is never replaced

        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncRows([recovery])
            try await db.saveSyncProfileRow(
                UserProfileSyncRow(maxHeartRate: 200, restingHeartRate: 48, name: "Local"))
            let spy = SpyCloudSync(rows: [recovery], profile: profile)
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = await make(db, spy, settings)

            let report = try await useCase.restore(now: Date())
            let kept = try await db.syncProfileRow()
            assertTest(
                !report.restoredProfile && kept?.name == "Local",
                "A restore over an existing profile leaves it alone — the one row carrying fields the "
                    + "wire cannot express, and the upsert that would erase them "
                    + "(\(String(describing: kept?.name)))")
        }
    }
}
