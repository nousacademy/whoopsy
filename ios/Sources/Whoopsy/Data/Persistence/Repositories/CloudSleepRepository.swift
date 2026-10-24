import Foundation

/// The local-first decorator for `sleeps`: a save mirrors to the database and a missed night is asked of
/// it, on `CloudRecoveryRepository`'s rule.
///
/// **The routing is a destination and never a boundary.** The phone's copy is read first because it
/// costs nothing; a night the phone does not hold is asked of the database exactly once and only under
/// `.cloud`, and `.unreachable` degrades to `nil` plus a `SyncStatus` mark rather than presenting an
/// unanswerable question as a measured nothing.
public struct CloudSleepRepository: SleepRepository {

    private let local: any SleepRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    /// Injected so the runner is not a function of the hour it runs. `DIContainer` passes
    /// `SyncSchedule.isOpen`; the default keeps every test and preview open.
    private let isCallWindowOpen: @Sendable () -> Bool
    private let status: any SyncStatus
    private let calendar: Calendar

    public init(
        local: any SleepRepository,
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository,
        status: any SyncStatus,
        calendar: Calendar = .current,
        isCallWindowOpen: @escaping @Sendable () -> Bool = { true }
    ) {
        self.local = local
        self.cloud = cloud
        self.settingsStore = settingsStore
        self.status = status
        self.calendar = calendar
        self.isCallWindowOpen = isCallWindowOpen
    }

    /// Local only, deliberately: the Worker has no delete endpoint, and a night this app classified
    /// is this phone's own provisional row rather than a row the database holds an opinion about.
    public func deleteSleepSession(for date: Date) async throws {
        try await local.deleteSleepSession(for: date)
    }

    public func getSleepSession(for date: Date) async throws -> SleepSession? {
        if let stored = try await local.getSleepSession(for: date) { return stored }
        guard await storesInCloud() else { return nil }
        do {
            let row = try await cloud.sleep(on: date)
            await status.clear(date)
            return row?.session
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
            await status.markUnavailable(date)
            return nil
        }
    }

    public func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession] {
        let stored = try await local.getSleepHistory(days: days, endingOn: endingOn)
        guard await storesInCloud() else { return stored }

        let last = endingOn.startOfDay
        guard let first = calendar.date(byAdding: .day, value: -days, to: last) else { return stored }
        let fetched = try await cloud.sleeps(from: first, to: last.startOfNextDay).map(\.session)
        return Self.merged(cloud: fetched, local: stored)
    }

    /// **Local only** — the daily run writes the database copy. A mirror per save is the call volume
    /// `SyncSchedule` exists to remove.
    public func saveSleepSession(_ session: SleepSession, source: String?) async throws {
        try await local.saveSleepSession(session, source: source)
    }

    /// The two answers as one ascending window, with the phone's night winning on a day both hold —
    /// `CloudStrainRepository.merged`'s precedence, keyed on the wake day.
    private static func merged(cloud: [SleepSession], local: [SleepSession]) -> [SleepSession] {
        var byDay: [Date: SleepSession] = [:]
        for session in cloud { byDay[session.date.startOfDay] = session }
        for session in local { byDay[session.date.startOfDay] = session }
        return byDay.values.sorted { $0.date < $1.date }
    }

    private func storesInCloud() async -> Bool {
        guard await settingsStore.load().destination == .cloud else { return false }
        return isCallWindowOpen()
    }
}
