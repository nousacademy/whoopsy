import Foundation
import Whoopsy

// MARK: - 25. When a day is scored, and when it is not

/// `RefreshRecoveryUseCase.isOwed`, and the column that let the rule survive a relaunch.
///
/// **The old gate could never converge and then it could not persist.** `RecoveryViewModel.shouldCompute`
/// recomputed today while a night existed and the stored row was RMSSD — and a recompute writes an
/// RMSSD row — so every push of the ring re-read the night's samples and a thirty-day baseline. The
/// gate moved to a foreground writer, which remembered the night it had scored in a dictionary — so the
/// first foreground of **every launch** re-scored today to reproduce a row already on disk. `v39` gave
/// `recoveries` the pair `strains` and `sleeps` already had, `algorithm` and `scored_through`, and this
/// block pins the rule those two answer.
enum RefreshRecoveryUseCaseTests {

    /// Counts the night reads a calculation would make — the one fact that says it ran.
    final class CountingBiometricStore: BiometricRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0

        var readsSoFar: Int { lock.lock(); defer { lock.unlock() }; return reads }

        func saveSamples(_ samples: [BiometricSample]) async throws {}

        func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
            lock.lock(); reads += 1; lock.unlock()
            return []
        }

        func getLatestSample() async throws -> BiometricSample? { nil }

        func clearAllBiometricData() async throws {}
    }

    static func run() async throws {
        let edge = Date(timeIntervalSinceReferenceDate: 1_000)

        // MARK: The rule, as two questions rather than one

        assertTest(
            !RefreshRecoveryUseCase.isOwed(edge: edge, storedEdge: edge, algorithm: .current),
            "A row that names the current formula and a watermark at or past the night's edge is not "
                + "owed anything — this is the assertion that has to hold after a relaunch, because a "
                + "process can no longer remember what it scored")

        assertTest(
            RefreshRecoveryUseCase.isOwed(
                edge: edge.addingTimeInterval(600), storedEdge: edge, algorithm: .current),
            "…while a night a drain has since rewritten — its watermark moved — earns exactly one more, "
                + "because the night a day is scored from has genuinely changed")

        assertTest(
            RefreshRecoveryUseCase.isOwed(edge: edge, storedEdge: nil, algorithm: .current),
            "A row that cannot say what input it saw is owed: `nil` is the safe direction, and it is "
                + "every row written before `v39`")

        assertTest(
            RefreshRecoveryUseCase.isOwed(edge: edge, storedEdge: edge, algorithm: nil),
            "…and a row that cannot name its formula is owed whatever its watermark says — a "
                + "correction to the scorer must re-score its rows rather than trust them")

        // MARK: Over a real database, and across what a relaunch looks like

        let db = LocalDatabaseManager(inMemory: true)
        let recoveries = GRDBRecoveryRepository(db: db)
        let nights = GRDBSleepRepository(db: db)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())

        func night(scoredThrough: Date) -> SleepSession {
            SleepSession(
                date: day,
                startTime: day.addingTimeInterval(-9 * 3600),
                endTime: day.addingTimeInterval(-1 * 3600),
                targetSleepNeedSeconds: 8 * 3600,
                lightSleepSeconds: 4 * 3600,
                deepSleepSeconds: 1.5 * 3600,
                remSleepSeconds: 1.5 * 3600,
                awakeSeconds: 600,
                algorithm: .current,
                scoredThrough: scoredThrough)
        }

        try await nights.saveSleepSession(night(scoredThrough: edge))
        try await recoveries.saveRecovery(
            RecoveryMetric(
                date: day, score: 70, hrvValueMs: 61.2, restingHeartRate: 52,
                source: RecoveryMetric.strapSource,
                algorithm: .current, scoredThrough: edge),
            source: RecoveryMetric.strapSource)

        let stored = try await recoveries.getLocalRecovery(for: day)
        assertTest(
            stored?.algorithm == .current && stored?.scoredThrough == edge,
            "The two audit fields survive the round trip through `recoveries` — `scored_through` is "
                + "snake_case because this record declares its `CodingKeys`, and a camelCase column "
                + "would be written nowhere and read as absent forever")

        let counter = CountingBiometricStore()
        let calculate = CalculateRecoveryUseCase(
            biometricRepository: counter,
            recoveryRepository: recoveries,
            sleepRepository: nights,
            userProfileRepository: GRDBUserProfileRepository(db: db))

        // A **fresh instance** is what a relaunch is: nothing in memory has ever seen this day.
        let relaunched = RefreshRecoveryUseCase(
            calculate: calculate, repository: recoveries, sleepRepository: nights)
        let first = await relaunched.refreshToday(now: day)

        assertTest(
            first == nil && counter.readsSoFar == 0,
            "The first foreground after a relaunch scores nothing and reads no samples: the row on "
                + "disk already names the night, and that is the whole point of storing the watermark "
                + "(reads \(counter.readsSoFar))")

        // A drain rewrites the night. The row's watermark is now behind the input.
        try await nights.saveSleepSession(night(scoredThrough: edge.addingTimeInterval(600)))
        _ = await relaunched.refreshToday(now: day)

        assertTest(
            counter.readsSoFar > 0,
            "…and a night whose watermark moved earns one calculation — the stored row has to be "
                + "replaced, so the calculator is reached (reads \(counter.readsSoFar))")
    }
}
