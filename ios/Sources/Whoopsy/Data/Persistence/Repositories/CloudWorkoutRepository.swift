import Foundation

/// The local-first decorator for `workouts`: a save mirrors to the database and a missed day is asked
/// of it, on `CloudRecoveryRepository`'s rule — the third resource (beside recoveries and strains)
/// whose `CloudSync` surface is read *and* written.
///
/// **The day reads map to the range read.** `WorkoutRepository` reads sessions by day or by history
/// window, while `CloudSync` answers `workout(id:)` and `workouts(from:to:)` — so the fallback is the
/// range read over the day/window the local store was asked for. `latest()` and `getWorkouts(covering:)`
/// stay local-only: the port has no "latest" and no "underway" read, so there is nothing to fall back
/// to and the local store is the whole answer.
public struct CloudWorkoutRepository: WorkoutRepository {

    private let local: any WorkoutRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    private let calendar: Calendar

    public init(
        local: any WorkoutRepository,
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository,
        calendar: Calendar = .current
    ) {
        self.local = local
        self.cloud = cloud
        self.settingsStore = settingsStore
        self.calendar = calendar
    }

    public func save(_ workout: WorkoutSession) async throws {
        try await local.save(workout)
        guard await storesInCloud() else { return }
        do {
            try await cloud.writeWorkout(WorkoutSyncRow(workout, calendar: calendar))
        } catch let error as CloudSyncError {
            // A failed push never fails the local write, on `CloudSleepRepository`'s argument.
            guard case .unreachable = error else { throw error }
        }
    }

    public func latest() async throws -> WorkoutSession? {
        try await local.latest()
    }

    public func getWorkouts(for date: Date) async throws -> [WorkoutSession] {
        let stored = try await local.getWorkouts(for: date)
        guard await storesInCloud() else { return stored }
        let fetched = try await cloud.workouts(
            from: date.startOfDay, to: date.startOfNextDay).map(\.session)
        return Self.merged(cloud: fetched, local: stored)
    }

    public func getWorkouts(covering date: Date) async throws -> [WorkoutSession] {
        try await local.getWorkouts(covering: date)
    }

    public func getWorkoutHistory(days: Int, endingOn: Date) async throws -> [WorkoutSession] {
        let stored = try await local.getWorkoutHistory(days: days, endingOn: endingOn)
        guard await storesInCloud() else { return stored }

        let last = endingOn.startOfDay
        guard let first = calendar.date(byAdding: .day, value: -days, to: last) else { return stored }
        let fetched = try await cloud.workouts(from: first, to: last.startOfNextDay).map(\.session)
        return Self.merged(cloud: fetched, local: stored)
    }

    public func delete(_ id: UUID) async throws -> Bool {
        try await local.delete(id)
    }

    /// The two answers as one list, with the phone's session winning on an id both hold. Keyed on the
    /// session's `UUID` rather than on a day, because a day holds several and the id is what the wire
    /// upserts on.
    private static func merged(cloud: [WorkoutSession], local: [WorkoutSession]) -> [WorkoutSession] {
        var byId: [UUID: WorkoutSession] = [:]
        for session in cloud { byId[session.id] = session }
        for session in local { byId[session.id] = session }
        return byId.values.sorted { $0.startedAt < $1.startedAt }
    }

    private func storesInCloud() async -> Bool {
        await settingsStore.load().destination == .cloud
    }
}
