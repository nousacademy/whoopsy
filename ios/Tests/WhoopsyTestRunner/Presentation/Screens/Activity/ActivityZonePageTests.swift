import Foundation
import Whoopsy

/// §19's database block for the zone rows: a recorded session's own time-in-zone, and the grey
/// average taken over the prior sessions of the same activity.
///
/// Everything above this file hands `ActivityZoneRow` a fold directly. This drives the real
/// `ActivityDetailViewModel` over an in-memory database, so three things are proven end to end that no
/// value block can see: that the page folds the samples it already plots, that the prior average is
/// taken from **samples** rather than from an imported percentage block, and that a page with no zone
/// figure of its own pays for no prior reads at all.
enum ActivityZonePageTests {

    /// Counts the sample windows a page asks for, so "read once, two readers" is an assertion rather
    /// than a claim about the code's shape.
    actor CountingBiometrics: BiometricRepository {
        private let inner: any BiometricRepository
        private(set) var windows: [(start: Date, end: Date)] = []

        init(_ inner: any BiometricRepository) {
            self.inner = inner
        }

        func saveSamples(_ samples: [BiometricSample]) async throws {
            try await inner.saveSamples(samples)
        }

        func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
            windows.append((startDate, endDate))
            return try await inner.getSamples(from: startDate, to: endDate)
        }

        func getLatestSample() async throws -> BiometricSample? {
            try await inner.getLatestSample()
        }

        func clearAllBiometricData() async throws {
            try await inner.clearAllBiometricData()
        }
    }

    /// A profile repository that cannot answer, so the page's profile-threw arm is exercised.
    struct ThrowingProfile: UserProfileRepository {
        struct Failure: Error {}
        func getUserProfile() async throws -> UserProfile { throw Failure() }
        func getLocalUserProfile() async throws -> UserProfile? { nil }
        func saveUserProfile(_ profile: UserProfile) async throws {}
    }

    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)
        let workouts = GRDBWorkoutRepository(db: db)
        let profiles = GRDBUserProfileRepository(db: db)
        let biometrics = GRDBBiometricRepository(db: db)
        let recovery = GRDBRecoveryRepository(db: db)

        // 190 / 60 is the cold-start table every other zone block pins: zone 3 is 151–164 bpm, so a
        // session at 160 is entirely zone 3, and zone 2 is 138–151, so a prior at 150 is entirely
        // zone 2. Two bands make the average's shape checkable by hand.
        try await profiles.saveUserProfile(
            UserProfile(maxHeartRate: 190, restingHeartRate: 60, weightKg: 75))

        // The session under test: ten minutes at 160 bpm, one sample a second, so the fold is
        // 1 s for the first reading and 1 s for each of the other 599 — 600 seconds in zone 3.
        let session = ActivityDetailTests.session(
            "Football", startOffset: 100_000, durationSeconds: 600)
        try await workouts.save(session)
        try await biometrics.saveSamples(
            StrainTests.samples(from: session.startedAt, count: 600, heartRate: 160))

        // Three priors of the same activity, five minutes at 150 bpm each — the floor's exact edge.
        for index in 0..<3 {
            let prior = ActivityDetailTests.session(
                "Football", startOffset: Double(index) * 10_000, durationSeconds: 300)
            try await workouts.save(prior)
            try await biometrics.saveSamples(
                StrainTests.samples(from: prior.startedAt, count: 300, heartRate: 150))
        }

        // A second activity with only two measured priors, which must draw no grey mark.
        // A different start offset, so the counting assertion below can tell this page's read from the
        // Football page's — two sessions sharing a window would make "read once" unprovable.
        let thin = ActivityDetailTests.session(
            "Rugby", startOffset: 120_000, durationSeconds: 600)
        try await workouts.save(thin)
        try await biometrics.saveSamples(
            StrainTests.samples(from: thin.startedAt, count: 600, heartRate: 160))
        for index in 0..<2 {
            let prior = ActivityDetailTests.session(
                "Rugby", startOffset: Double(index) * 10_000, durationSeconds: 300)
            try await workouts.save(prior)
            try await biometrics.saveSamples(
                StrainTests.samples(from: prior.startedAt, count: 300, heartRate: 150))
        }

        let counting = CountingBiometrics(biometrics)

        @MainActor
        func page(_ subject: WorkoutSession, profile: any UserProfileRepository)
            -> ActivityDetailViewModel
        {
            ActivityDetailViewModel(
                session: subject,
                workoutRepository: workouts,
                userProfileRepository: profile,
                biometricRepository: counting,
                recoveryRepository: recovery,
                offlineMaps: SpyOfflineMaps())
        }

        let loaded = await MainActor.run { page(session, profile: profiles) }
        await loaded.load()
        let rows = await MainActor.run { loaded.zoneRows }
        let source = await MainActor.run { loaded.zoneSource }
        let series = await MainActor.run { loaded.heartRateSeries }

        assertTest(
            source == .measured && rows.map(\.seconds) == [0, 0, 600, 0, 0],
            "A session this app recorded draws **its own measured time** — hardest band first, so the "
                + "600 seconds at 160 bpm land in zone 3 and the others are measured zeroes "
                + "(\(String(describing: source)), \(rows.map(\.seconds)))")
        assertTest(
            rows[2].secondsText == "0:10:00" && rows[0].secondsText == "0:00:00",
            "…and the row prints that as `0:10:00`, while a band the session never entered prints "
                + "`0:00:00` rather than the dash an absent measurement draws "
                + "(\(rows.map(\.secondsText)))")
        assertTest(
            rows[3].averageSeconds == 300 && rows[3].averageSessionCount == 3,
            "…and the grey mark is the mean over the three prior Football sessions, each five minutes "
                + "in zone 2 — a fold of **their samples**, not of an imported percentage block "
                + "(\(String(describing: rows[3].averageSeconds)), "
                + "\(String(describing: rows[3].averageSessionCount)))")
        assertTest(
            rows.allSatisfy { $0.scaleSeconds == 600 },
            "…with every row on the block's one scale, so the bar and the marker are drawn against the "
                + "same span (\(rows.map(\.scaleSeconds)))")

        assertTest(
            series != nil,
            "…and the chart is still built from the same read, so the zone rows cost the page no second "
                + "pass over the samples")

        let windows = await counting.windows
        let sessionWindows = windows.filter { $0.start == session.startedAt }
        assertTest(
            sessionWindows.count == 1,
            "**The session's own window is read exactly once** and feeds both the chart and the zone "
                + "fold — the assertion that fails if a later edit reads the samples again for the rows "
                + "(\(sessionWindows.count) reads)")

        let thinPage = await MainActor.run { page(thin, profile: profiles) }
        await thinPage.load()
        let thinRows = await MainActor.run { thinPage.zoneRows }
        assertTest(
            thinRows.allSatisfy { $0.seconds != nil && $0.averageSeconds == nil },
            "Two measured priors is below `RecoveryScoring.minimumBaselineDays`, so the grey mark is "
                + "**absent while the session's own times are not** — the page withholds the "
                + "comparison, never the measurement")

        let blind = await MainActor.run { page(session, profile: ThrowingProfile()) }
        await blind.load()
        let blindRows = await MainActor.run { blind.zoneRows }
        let blindSeries = await MainActor.run { blind.heartRateSeries }
        let allBlindWindows = await counting.windows
        let blindWindows = allBlindWindows.filter { $0.start == session.startedAt }
        assertTest(
            blindRows.isEmpty,
            "A profile that cannot answer leaves **no zone table**, so the block is absent rather than "
                + "five invented bands")
        assertTest(
            blindSeries != nil,
            "…and the chart is unaffected, because its samples are read independently of the profile")
        assertTest(
            blindWindows.count == 2,
            "…and the no-table page reads the session's window once and no prior window at all — the "
                + "gate that keeps a page with nothing to compare from paying for ten reads "
                + "(\(blindWindows.count) reads across two pages)")
    }
}
