import Foundation

/// The only path that writes to the sync API, and it runs once per Eastern day.
///
/// **Saves no longer mirror.** Every decorated repository used to push a row as it was written, which
/// for step counts meant a request per second of motion; this use case replaces that with one run over
/// the days since the last successful one. Local writes are always immediate and never wait for it.
///
/// **A failed run does not mark the day.** The marker is saved only after the engine returns, so a
/// launch later in the evening retries rather than treating a failure as done. A run before 18:00
/// Eastern cannot start at all — `SyncSchedule.isDue` answers false and the engine refuses.
///
/// **The app must be running for the timer to fire**, and iOS may suspend it. The foreground
/// catch-up in `MainContainerView` is what makes the schedule reliable: opening the app after 18:00
/// on a day whose marker is older runs it immediately, once.
public actor DailySyncUseCase {

    /// The gap below which a second attempt is skipped.
    ///
    /// **A failed run is retried on the next foreground, and that is a thrash this bounds.** The
    /// marker is saved only on success, so an evening whose upload keeps failing — a cancelled request
    /// when the screen locks is the ordinary way — would otherwise re-read two days of seven resources
    /// and re-issue the whole upload on every unlock. Those reads share the one `DatabaseQueue` with
    /// whatever screen is drawing, which is what a blank Home for the first seconds after foregrounding
    /// looked like on 2026-10-24. Fifteen minutes keeps a real retry inside the evening while making
    /// an unlock loop stop costing anything.
    public static let retryInterval: TimeInterval = 15 * 60

    /// When the last attempt began, successful or not. Actor state, because two foregrounds may race.
    private var lastAttemptAt: Date?

    private let engine: SyncEngine
    private let settingsStore: any SyncSettingsRepository
    private let now: @Sendable () -> Date

    public init(
        engine: SyncEngine,
        settingsStore: any SyncSettingsRepository,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.settingsStore = settingsStore
        self.now = now
    }

    /// Runs the day's upload if the destination is the API and today's run is still owed.
    public func runIfDue() async {
        let settings = await settingsStore.load()
        guard settings.destination == .cloud else { return }

        let current = now()
        guard SyncSchedule.isDue(lastRunDay: settings.lastDailySyncDay, now: current) else { return }
        if let lastAttemptAt,
           current.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            return
        }
        lastAttemptAt = current

        let calendar = SyncSchedule.calendar()
        let today = SyncSchedule.dayKey(for: current)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        // A year is the catch-up bound. Beyond it the run would read more than it could send in one
        // pass, and the server's own window is the smaller constraint.
        let oldest = calendar.date(byAdding: .day, value: -365, to: today) ?? today
        let from = Swift.max(
            SyncSchedule.dayKey(for: settings.lastDailySyncDay ?? yesterday), oldest)
        guard let to = calendar.date(byAdding: .day, value: 1, to: today) else { return }

        do {
            _ = try await engine.run(over: SyncSettings.SyncRange(from: from, to: to))
            var updated = settings
            updated.lastDailySyncDay = today
            await settingsStore.save(updated)
            AppLogger.database.notice("""
                Daily sync: sent \(from.description, privacy: .public) → \
                \(to.description, privacy: .public)
                """)
        } catch {
            // The marker stays unset, so the next launch in the window retries. Nothing is lost: every
            // row is still on the phone and the engine's writes are upserts.
            AppLogger.database.notice(
                "Daily sync skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sleeps until the next 18:00 Eastern, runs, and repeats. Started once for the app's life.
    public func runLoop() async {
        await runIfDue()
        while !Task.isCancelled {
            let current = now()
            let next = SyncSchedule.nextWindowStart(after: current)
            let delay = next.timeIntervalSince(current)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                // A clock that moved backwards while sleeping: wait a minute rather than spin.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            await runIfDue()
        }
    }
}
