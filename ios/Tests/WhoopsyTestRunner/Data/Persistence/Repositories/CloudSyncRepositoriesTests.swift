import Foundation
import Whoopsy

// MARK: - 22.3b The six sibling decorators: no mirroring, and read-back for the two that can

/// **The no-write-through half of `CloudRecoveryRepository`, carried across the other six resources**,
/// and the read-back for the two of them whose `CloudSync` port has a read.
///
/// `CloudRecoveryRepositoryTests` drives the routing in full — local-first, one fallback request,
/// `.unreachable` degradation, the `.rejected`/`.malformed` propagation — because it is the reference
/// decorator. What this file adds is the *coverage*: that **a save of any of the seven resources never
/// touches the database**, whatever the destination, because the once-a-day run is the only uploader;
/// and that a missed strain or workout day is still fetched back. The four write-only resources
/// (sleeps, steps, entries, the profile) have no read to fall back to, so their blocks assert only
/// the absence of a write.
enum CloudSyncRepositoriesTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        // MARK: No write-through — a save stays on the phone under `.cloud`

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudSleepRepository(
                local: GRDBSleepRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: SyncStatusLog())
            try await repo.saveSleepSession(
                SleepSession(date: day(-3), startTime: day(-3), endTime: day(-3).addingTimeInterval(7 * 3600)),
                source: "whoop_export")
            let sent = await spy.writtenSleeps
            assertTest(sent.isEmpty, "A save stays on the phone; the daily run is the only uploader")
            let stored = try await GRDBSleepRepository(db: db).getSleepSession(for: day(-3))
            assertTest(stored != nil, "…and the night is on the phone, which is where it was going")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudStrainRepository(
                local: GRDBStrainRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: SyncStatusLog())
            try await repo.saveStrain(
                StrainScore(date: day(-3), score: 8.0, hasMeasurement: true, activeCalories: 100,
                            averageHeartRate: 70, maxHeartRate: 110),
                source: "whoop_export")
            let sent = await spy.writtenStrains
            assertTest(sent.isEmpty, "A save stays on the phone; the daily run is the only uploader")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudWorkoutRepository(
                local: GRDBWorkoutRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                calendar: calendar)
            try await repo.save(WorkoutSession(
                startedAt: day(-3).addingTimeInterval(3600),
                endedAt: day(-3).addingTimeInterval(3600 + 1200),
                strain: 5.0, averageHeartRate: 120, maxHeartRate: 150,
                route: [], splits: [], source: "whoop_export"))
            let sent = await spy.writtenWorkouts
            assertTest(sent.isEmpty, "A save stays on the phone; the daily run is the only uploader")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudStepRepository(
                local: GRDBStepRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: SyncStatusLog())
            try await repo.saveStepCount(StepCount(date: day(-3), stepCount: 5000, measuredSeconds: 3600))
            // This is the row that made the rule: a count is saved once a second while the strap
            // moves, so a mirror here is the call volume the daily schedule exists to remove.
            let sent = await spy.writtenStepCounts
            assertTest(sent.isEmpty, "A save stays on the phone; the daily run is the only uploader")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudReceptiveInactivityRepository(
                local: GRDBReceptiveInactivityRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)))
            try await repo.save(ReceptiveInactivity(date: day(-3), name: "Dream", note: "long"))
            let sent = await spy.writtenInactivities
            assertTest(sent.isEmpty, "A save stays on the phone; the daily run is the only uploader")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudUserProfileRepository(
                local: GRDBUserProfileRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)))
            try await repo.saveUserProfile(UserProfile(maxHeartRate: 190, restingHeartRate: 60, weightKg: 75))
            let sent = await spy.writtenProfiles
            assertTest(sent.isEmpty, "A save stays on the phone; the daily run is the only uploader")
        }

        // MARK: Under `.device` nothing leaves the phone

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudSleepRepository(
                local: GRDBSleepRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings()),
                status: SyncStatusLog())
            try await repo.saveSleepSession(
                SleepSession(date: day(-3), startTime: day(-3), endTime: day(-3).addingTimeInterval(7 * 3600)),
                source: nil)
            let untouched = await spy.calls.isEmpty
            assertTest(untouched, "Under `.device` a save reaches the phone and nothing else")
        }

        // MARK: A save does not consult the database, so neither failure reaches it

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync()
            let repo = CloudStepRepository(
                local: GRDBStepRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: SyncStatusLog())
            await spy.fail(with: .unreachable(message: "offline"))
            try await repo.saveStepCount(StepCount(date: day(-3), stepCount: 5000, measuredSeconds: 3600))
            let saved = try await GRDBStepRepository(db: db).getStepCount(for: day(-3))
            assertTest(saved?.stepCount == 5000,
                       "An unreachable database does not fail a local write")

            await spy.fail(with: .rejected(code: "bad", message: "refused"))
            try await repo.saveStepCount(StepCount(date: day(-2), stepCount: 1, measuredSeconds: 60))
            let second = try await GRDBStepRepository(db: db).getStepCount(for: day(-2))
            assertTest(second?.stepCount == 1,
                       "…and neither does a refusing one, because the save makes no request")

            let calls = await spy.calls.count
            assertTest(calls == 0, "…which is the assertion that fails if mirroring comes back")
        }

        // MARK: Read-back — a missed strain day is the database's, fetched once and not cached

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let localStore = GRDBStrainRepository(db: db)
            let spy = SpyCloudSync(strains: [StrainSyncRow(
                date: day(-3), strainScore: 8.0, kilojoules: 418.4,
                averageHeartRate: 70, maxHeartRate: 110, hasMeasurement: true, source: "whoop_export")])
            let status = SyncStatusLog()
            let repo = CloudStrainRepository(
                local: localStore, cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: status)

            let fetched = try await repo.getStrain(for: day(-3))
            assertTest(fetched?.score == 8.0, "A day the phone does not hold is fetched from the database")
            let asked = await spy.readStrainDays
            assertTest(asked == [day(-3)], "…as a day, once, not as a range")

            let notCached = try await localStore.getStrain(for: day(-3))
            assertTest(notCached == nil, "…and it is not written to the phone, because a read is a read")
        }

        // MARK: Read-back — a missed workout day maps to the range read

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let workout = WorkoutSession(
                startedAt: day(-3).addingTimeInterval(3600),
                endedAt: day(-3).addingTimeInterval(3600 + 1200),
                strain: 5.0, averageHeartRate: 120, maxHeartRate: 150,
                route: [], splits: [], source: "whoop_export")
            let spy = SpyCloudSync(workouts: [WorkoutSyncRow(workout, calendar: calendar)])
            let repo = CloudWorkoutRepository(
                local: GRDBWorkoutRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                calendar: calendar)

            let fetched = try await repo.getWorkouts(for: day(-3))
            assertTest(fetched.count == 1, "A day the phone does not hold is fetched from the database")
            let ranges = await spy.readWorkoutRanges
            assertTest(ranges.count == 1, "…as one range, not one request per session")
        }

        // MARK: Read-back — the four write-through resources now read too

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let localStore = GRDBSleepRepository(db: db)
            let night = SleepSyncRow(
                SleepSession(date: day(-3), startTime: day(-3), endTime: day(-3).addingTimeInterval(7 * 3600)),
                source: "whoop_export")
            let spy = SpyCloudSync(sleeps: [night])
            let repo = CloudSleepRepository(
                local: localStore, cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: SyncStatusLog(), calendar: calendar)

            let fetched = try await repo.getSleepSession(for: day(-3))
            assertTest(fetched != nil, "A night the phone does not hold is fetched from the database")
            let asked = await spy.readSleepDays
            assertTest(asked == [day(-3)], "…as a day, once")
            let notCached = try await localStore.getSleepSession(for: day(-3))
            assertTest(notCached == nil, "…and it is not written to the phone")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let localStore = GRDBStepRepository(db: db)
            let spy = SpyCloudSync(stepCounts: [StepCountSyncRow(
                date: day(-3), stepCount: 5000, measuredSeconds: 3600)])
            let repo = CloudStepRepository(
                local: localStore, cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)),
                status: SyncStatusLog(), calendar: calendar)

            let fetched = try await repo.getStepCount(for: day(-3))
            assertTest(fetched?.stepCount == 5000, "A day the phone does not hold is fetched from the database")
            let asked = await spy.readStepCountDays
            assertTest(asked == [day(-3)], "…as a day, once")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let entry = ReceptiveInactivitySyncRow(
                id: UUID().uuidString, date: day(-3), name: "Dream", note: nil, startedAt: nil)
            let spy = SpyCloudSync(inactivities: [entry])
            let repo = CloudReceptiveInactivityRepository(
                local: GRDBReceptiveInactivityRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)))

            let fetched = try await repo.getReceptiveInactivities(for: day(-3))
            assertTest(fetched.count == 1, "A day's entries the phone does not hold are fetched from the database")
            let ranges = await spy.readInactivityRanges
            assertTest(ranges.count == 1, "…as one range, not one request per entry")
        }

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let spy = SpyCloudSync(profile: UserProfileSyncRow(
                maxHeartRate: 185, restingHeartRate: 55, weightKg: 72))
            let repo = CloudUserProfileRepository(
                local: GRDBUserProfileRepository(db: db), cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(SyncSettings(destination: .cloud)))

            let fetched = try await repo.getUserProfile()
            assertTest(fetched.maxHeartRate == 185, "A phone with no stored profile fetches it from the database")
            assertTest(fetched.weightKg == 72, "…with its body facts")
            let count = await spy.readProfileCount
            assertTest(count == 1, "…asked once")
        }

        // MARK: The durable destination falls back to the Keychain on a fresh install

        do {
            let defaults = UserDefaults(suiteName: "org.whoopsy.tests.cloudsync")!
            defaults.removePersistentDomain(forName: "org.whoopsy.tests.cloudsync")
            let fake = FakeDestinationStore(.cloud)
            let repo = UserDefaultsSyncSettingsRepository(defaults: defaults, keychain: fake)
            let loaded = await repo.load()
            assertTest(loaded.destination == .cloud,
                       "A fresh install with a Keychain `.cloud` restores `.cloud` rather than `.device`")

            let empty = UserDefaultsSyncSettingsRepository(defaults: defaults, keychain: FakeDestinationStore(nil))
            let fallback = await empty.load()
            assertTest(fallback.destination == .device,
                       "…and with no Keychain value it stays `.device`, the state that sends nothing")
        }
    }
}

/// A `DestinationStore` that answers a fixed value — the Keychain in a box, so the fallback can be
/// asserted without touching the real Keychain on the machine.
private actor FakeDestinationStore: DestinationStore {
    private var value: SyncSettings.Destination?

    init(_ value: SyncSettings.Destination?) {
        self.value = value
    }

    func load() async -> SyncSettings.Destination? { value }

    func save(_ destination: SyncSettings.Destination) async { value = destination }
}
