import Foundation

/// The local-first decorator for `receptive_inactivities`: a save mirrors to the database and a missed
/// day's entries are asked of it, on `CloudRecoveryRepository`'s rule.
///
/// **The day read maps to the range read.** `ReceptiveInactivityRepository` reads entries by day, while
/// `CloudSync` answers `receptiveInactivities(from:to:)` — so the fallback is the range read over the
/// day the local store was asked for. `delete` is a local-only operation, on the standing rule that
/// nothing anywhere removes a row.
public struct CloudReceptiveInactivityRepository: ReceptiveInactivityRepository {

    private let local: any ReceptiveInactivityRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository

    public init(
        local: any ReceptiveInactivityRepository,
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository
    ) {
        self.local = local
        self.cloud = cloud
        self.settingsStore = settingsStore
    }

    public func getReceptiveInactivities(for date: Date) async throws -> [ReceptiveInactivity] {
        let stored = try await local.getReceptiveInactivities(for: date)
        guard await storesInCloud() else { return stored }
        let fetched = try await cloud.receptiveInactivities(from: date.startOfDay, to: date.startOfNextDay)
            .compactMap(\.activity)
        return Self.merged(cloud: fetched, local: stored)
    }

    public func delete(_ id: UUID) async throws -> Bool {
        try await local.delete(id)
    }

    public func save(_ activity: ReceptiveInactivity) async throws {
        try await local.save(activity)
        guard await storesInCloud() else { return }
        do {
            try await cloud.writeReceptiveInactivity(ReceptiveInactivitySyncRow(activity))
        } catch let error as CloudSyncError {
            // A failed push never fails the local write, on `CloudSleepRepository`'s argument.
            guard case .unreachable = error else { throw error }
        }
    }

    /// The two answers as one list, with the phone's entry winning on an id both hold — keyed on the id
    /// rather than on a day, because a day holds several and the id is what the wire upserts on.
    private static func merged(cloud: [ReceptiveInactivity], local: [ReceptiveInactivity])
        -> [ReceptiveInactivity] {
        var byId: [UUID: ReceptiveInactivity] = [:]
        for activity in cloud { byId[activity.id] = activity }
        for activity in local { byId[activity.id] = activity }
        return byId.values.sorted { ($0.startedAt ?? $0.date) < ($1.startedAt ?? $1.date) }
    }

    private func storesInCloud() async -> Bool {
        await settingsStore.load().destination == .cloud
    }
}
