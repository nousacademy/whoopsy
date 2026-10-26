import Foundation
import Whoopsy

/// §16's coordinator block: the two things a drain trigger must get right, and neither is visible in a
/// screenshot or a log.
///
/// **Single-flight.** A drain supersedes the one before it — the manager concludes the interrupted
/// session as `.aborted` — so two triggers firing at once would leave neither finished. The fixture
/// counts how many times the strap was asked, which is the only way to see it.
///
/// **The retry is for silence, not for emptiness.** `0 record(s) in 1 batch(es)` is the strap saying
/// its buffer is empty; zero batches is the strap saying nothing at all, and only the second is worth
/// asking again. Both are scripted rather than simulated, because the difference is in the sequence.
enum DrainCoordinatorTests {

    private static func outcome(records: Int, batches: Int) -> HistoricalSyncOutcome {
        HistoricalSyncOutcome(
            recordCount: records,
            batchCount: batches,
            ending: .caughtUpToLiveEdge,
            oldestRecord: nil,
            newestRecord: nil)
    }

    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)
        let strainRepository = GRDBStrainRepository(db: db)
        let biometrics = OvernightBiometricStore(samples: [])
        let profiles = GRDBUserProfileRepository(db: db)

        func coordinator(_ repository: ScriptedTelemetryRepository) -> DrainCoordinator {
            DrainCoordinator(
                sync: SyncHistoricalDataUseCase(
                    bleRepository: repository, biometricRepository: biometrics),
                strain: fixtureRefreshStrain(
                    strainRepository: strainRepository,
                    biometricRepository: biometrics,
                    userProfileRepository: profiles),
                // Milliseconds: the retry path is what is under test, not the wait, and ten real
                // seconds there would spend the runner's 30-second budget for the whole suite.
                retryDelay: .milliseconds(10))
        }

        // ---- A silent strap is retried, and a second attempt that answers stops the loop ----
        do {
            let strap = ScriptedTelemetryRepository()
            strap.scriptDrain([
                .outcome(outcome(records: 0, batches: 0)),
                .outcome(outcome(records: 60, batches: 1)),
            ])
            let result = await coordinator(strap).drain()
            assertTest(
                strap.drainRequestCount == 2 && result?.recordCount == 60,
                "A drain that answered with **zero batches** — no frames at all — is retried, and the "
                    + "second answer is returned: 2 requests, 60 records "
                    + "(\(strap.drainRequestCount) requests, \(String(describing: result?.recordCount)) records)")
        }

        // ---- An answered-empty drain is not retried ----
        do {
            let strap = ScriptedTelemetryRepository()
            strap.scriptDrain([.outcome(outcome(records: 0, batches: 1))])
            _ = await coordinator(strap).drain()
            assertTest(
                strap.drainRequestCount == 1,
                "…while `0 record(s) in 1 batch(es)` is an answer — the buffer is empty — and is not "
                    + "asked again, because a retry there would re-read a strap that has already "
                    + "spoken (\(strap.drainRequestCount) request(s))")
        }

        // ---- A failure is retried to the cap, and the cap is three ----
        do {
            let strap = ScriptedTelemetryRepository()
            strap.scriptDrain([.failure, .failure, .failure, .outcome(outcome(records: 9, batches: 1))])
            _ = await coordinator(strap).drain()
            assertTest(
                strap.drainRequestCount == DrainCoordinator.maximumAttempts,
                "A drain that throws is retried, and **stops at the cap rather than the script's "
                    + "fourth answer**: \(DrainCoordinator.maximumAttempts) requests, not 4 "
                    + "(\(strap.drainRequestCount))")
        }

        // ---- Two triggers, one drain ----
        do {
            let strap = ScriptedTelemetryRepository()
            strap.scriptDrain([.outcome(outcome(records: 120, batches: 2))])
            let gate = coordinator(strap)
            async let first = gate.drain()
            async let second = gate.drain()
            let results = await [first, second]
            assertTest(
                strap.drainRequestCount == 1,
                "**Two triggers firing together produce one drain.** The second caller is answered "
                    + "`nil` rather than starting a request that would supersede the first — a manager "
                    + "concludes the interrupted session as `.aborted` and neither would finish "
                    + "(\(strap.drainRequestCount) request(s))")
            assertTest(
                results.compactMap { $0 }.count == 1,
                "…and exactly one caller receives an outcome; the other's `nil` means *did nothing*, "
                    + "which is not an error and not a result "
                    + "(\(results.map { $0 == nil ? "nil" : "outcome" }))")
        }
    }
}
