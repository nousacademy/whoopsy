import Foundation

/// The local-first decorator for `strains`: a save mirrors to the database and a missed day is asked of
/// it, on `CloudRecoveryRepository`'s rule — the second resource (beside recoveries) whose `CloudSync`
/// surface is read *and* written.
///
/// **The routing is a destination and never a boundary.** The phone's copy is read first because it
/// costs nothing; a day the phone does not hold is asked of the database exactly once and only under
/// `.cloud`, and `.unreachable` degrades to `nil` plus a `SyncStatus` mark rather than presenting an
/// unanswerable question as a measured nothing.
public struct CloudStrainRepository: StrainRepository {

    private let local: any StrainRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    /// Injected so the runner is not a function of the hour it runs. `DIContainer` passes
    /// `SyncSchedule.isOpen`; the default keeps every test and preview open.
    private let isCallWindowOpen: @Sendable () -> Bool
    private let status: any SyncStatus
    private let calendar: Calendar

    public init(
        local: any StrainRepository,
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

    public func getStrain(for date: Date) async throws -> StrainScore? {
        if let stored = try await local.getStrain(for: date) { return stored }
        guard await storesInCloud() else { return nil }
        do {
            let row = try await cloud.strain(on: date)
            await status.clear(date)
            return row?.score
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
            await status.markUnavailable(date)
            return nil
        }
    }

    /// **Local only and never routed.** See `StrainRepository.getLocalStrain(for:)` — this is the read a
    /// repair decision is allowed to make.
    public func getLocalStrain(for date: Date) async throws -> StrainScore? {
        try await local.getLocalStrain(for: date)
    }

    /// **Local only** — the daily run writes the database copy. See `SyncSchedule`.
    public func saveStrain(_ strain: StrainScore, source: String?) async throws {
        try await local.saveStrain(strain, source: source)
    }

    public func getStrainHistory(days: Int, endingOn: Date) async throws -> [StrainScore] {
        let stored = try await local.getStrainHistory(days: days, endingOn: endingOn)
        guard await storesInCloud() else { return stored }

        let last = endingOn.startOfDay
        guard let first = calendar.date(byAdding: .day, value: -days, to: last) else { return stored }
        let fetched = try await cloud.strains(from: first, to: last.startOfNextDay).map(\.score)
        return Self.merged(cloud: fetched, local: stored)
    }

    /// The two answers as one ascending window, with the phone's row winning on a day both hold — the
    /// same precedence `CloudRecoveryRepository.merged` applies, keyed on `startOfDay` so two producers
    /// that wrote the same day at slightly different instants do not file it twice.
    private static func merged(cloud: [StrainScore], local: [StrainScore]) -> [StrainScore] {
        var byDay: [Date: StrainScore] = [:]
        for score in cloud { byDay[score.date.startOfDay] = score }
        for score in local { byDay[score.date.startOfDay] = score }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// **Local only and never routed**, for `getLocalStrain`'s reason: which days this phone imported is
    /// a question about its own history, and the repair rule must not depend on a reachable server.
    public func getNewestImportedStrainDay() async throws -> Date? {
        try await local.getNewestImportedStrainDay()
    }

    private func storesInCloud() async -> Bool {
        guard await settingsStore.load().destination == .cloud else { return false }
        return isCallWindowOpen()
    }
}
