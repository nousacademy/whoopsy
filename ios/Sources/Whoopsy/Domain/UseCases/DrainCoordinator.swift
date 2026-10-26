import Foundation

/// The one thing that decides when a drain runs, so two triggers cannot run one at a time badly.
///
/// **A drain has two natural triggers and they are not the same event.** A *connect* starts one — the
/// link came back, so whatever the strap banked should come down. A *foreground* is the other, and it
/// is the one the first trigger misses: a phone that stayed connected all night never reconnects in the
/// morning, so waking up produces no `.connected` transition and an overnight wear would sit in the
/// strap's flash until someone pressed `SYNC HISTORY`. Both paths call `drain()`, and the `isRunning`
/// flag is what keeps them from superseding each other — the manager concludes a drain that a second
/// request interrupts, so two callers racing would leave neither finished.
///
/// **A silent strap is retried, and that is the other half.** A drain that answers `0 record(s) in
/// 1 batch(es)` has answered: the buffer is empty. A drain that ends with **zero batches** has not —
/// the request reached the strap and nothing came back, measured on 2026-10-24 seconds after a live
/// session ended. The same link answers a minute later, so one silent drain is retried before the
/// trigger is abandoned.
public actor DrainCoordinator {

    /// How many times one trigger will ask a strap that keeps answering nothing.
    public static let maximumAttempts = 3

    /// The wait between those attempts. Long enough for a link to settle after a session's teardown,
    /// short enough that nobody watching the screen notices.
    ///
    /// **A default rather than a constant the tests must live with.** The retry path sleeps twice in
    /// the worst case, and a suite that spent ten real seconds there tips the runner's own 30-second
    /// budget — measured on 2026-10-25, where §16 passed alone and the full suite timed out. So this
    /// is injected, and §16 passes milliseconds.
    public static let defaultRetryDelay: Duration = .seconds(5)

    private let sync: SyncHistoricalDataUseCase
    private let strain: RefreshStrainUseCase
    private let retryDelay: Duration
    private var isRunning = false

    public init(
        sync: SyncHistoricalDataUseCase,
        strain: RefreshStrainUseCase,
        retryDelay: Duration = DrainCoordinator.defaultRetryDelay
    ) {
        self.sync = sync
        self.strain = strain
        self.retryDelay = retryDelay
    }

    /// Runs a drain unless one is already running, and reports what it did.
    ///
    /// `nil` means *this call did nothing* — a drain was already in flight — which is not an error and
    /// not a result.
    @discardableResult
    public func drain() async -> HistoricalSyncOutcome? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        for attempt in 1...Self.maximumAttempts {
            var answered = false
            do {
                let outcome = try await sync.execute()
                answered = outcome.batchCount > 0
                AppLogger.ble.notice("""
                    Auto-sync: \(outcome.recordCount, privacy: .public) record(s) in \
                    \(outcome.batchCount, privacy: .public) batch(es), ending \
                    \(String(describing: outcome.ending), privacy: .public) \
                    (attempt \(attempt, privacy: .public) of \(Self.maximumAttempts, privacy: .public))
                    """)
                await strain.refresh(from: outcome.oldestRecord, to: outcome.newestRecord)
                if answered { return outcome }
            } catch {
                AppLogger.ble.warning("""
                    Auto-sync failed (attempt \(attempt, privacy: .public) of \
                    \(Self.maximumAttempts, privacy: .public)): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                // A drain that stopped early still wrote what it read; `endedWithoutConfirmation`
                // carries the range for exactly this.
                if let range = (error as? WhoopSyncError)?.recordRange {
                    await strain.refresh(from: range.oldest, to: range.newest)
                    answered = true
                }
            }
            if answered || attempt == Self.maximumAttempts { break }
            try? await Task.sleep(for: retryDelay)
        }
        return nil
    }
}
