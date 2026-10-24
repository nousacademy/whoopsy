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
public struct DailySyncUseCase: Sendable {

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
