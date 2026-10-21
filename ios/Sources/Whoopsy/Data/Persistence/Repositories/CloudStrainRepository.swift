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
    private let status: any SyncStatus
    private let calendar: Calendar

    public init(
        local: any StrainRepository,
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository,
        status: any SyncStatus,
        calendar: Calendar = .current
    ) {
        self.local = local
        self.cloud = cloud
        self.settingsStore = settingsStore
        self.status = status
        self.calendar = calendar
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

    public func saveStrain(_ strain: StrainScore, source: String?) async throws {
        try await local.saveStrain(strain, source: source)
        guard await storesInCloud() else { return }
        do {
            try await cloud.writeStrain(StrainSyncRow(strain, source: source))
            await status.clear(strain.date)
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
        }
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

    private func storesInCloud() async -> Bool {
        await settingsStore.load().destination == .cloud
    }
}
