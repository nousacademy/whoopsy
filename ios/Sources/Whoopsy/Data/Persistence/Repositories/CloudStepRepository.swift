import Foundation

/// The local-first decorator for `stepCounts`: a save mirrors to the database and a missed day is asked
/// of it, on `CloudRecoveryRepository`'s rule.
///
/// **The routing is a destination and never a boundary.** The phone's copy is read first because it
/// costs nothing; a day the phone does not hold is asked of the database exactly once and only under
/// `.cloud`, and `.unreachable` degrades to `nil` plus a `SyncStatus` mark. `steps` has no `source`
/// column, so the row is the entity itself and nothing is supplied by the caller.
public struct CloudStepRepository: StepRepository {

    private let local: any StepRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    /// Injected so the runner is not a function of the hour it runs. `DIContainer` passes
    /// `SyncSchedule.isOpen`; the default keeps every test and preview open.
    private let isCallWindowOpen: @Sendable () -> Bool
    private let status: any SyncStatus
    private let calendar: Calendar

    public init(
        local: any StepRepository,
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

    public func getStepCount(for date: Date) async throws -> StepCount? {
        if let stored = try await local.getStepCount(for: date) { return stored }
        guard await storesInCloud() else { return nil }
        do {
            let row = try await cloud.stepCount(on: date)
            await status.clear(date)
            return row?.count
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
            await status.markUnavailable(date)
            return nil
        }
    }

    public func getStepCountHistory(days: Int, endingOn: Date) async throws -> [StepCount] {
        let stored = try await local.getStepCountHistory(days: days, endingOn: endingOn)
        guard await storesInCloud() else { return stored }

        let last = endingOn.startOfDay
        guard let first = calendar.date(byAdding: .day, value: -days, to: last) else { return stored }
        let fetched = try await cloud.stepCounts(from: first, to: last.startOfNextDay).map(\.count)
        return Self.merged(cloud: fetched, local: stored)
    }

    /// **Local only, and this is the row that made the rule necessary.** A step count is saved once
    /// a second while the strap moves; mirroring each one is what exhausted the call budget. The
    /// daily run writes the database copy. See `SyncSchedule`.
    public func saveStepCount(_ stepCount: StepCount) async throws {
        try await local.saveStepCount(stepCount)
    }

    /// The two answers as one ascending window, with the phone's day winning on a day both hold.
    private static func merged(cloud: [StepCount], local: [StepCount]) -> [StepCount] {
        var byDay: [Date: StepCount] = [:]
        for count in cloud { byDay[count.date.startOfDay] = count }
        for count in local { byDay[count.date.startOfDay] = count }
        return byDay.values.sorted { $0.date < $1.date }
    }

    private func storesInCloud() async -> Bool {
        guard await settingsStore.load().destination == .cloud else { return false }
        return isCallWindowOpen()
    }
}
