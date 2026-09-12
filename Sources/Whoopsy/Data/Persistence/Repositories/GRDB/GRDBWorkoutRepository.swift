import Foundation
import GRDB

/// Recorded workouts, persisted. Replaces `LocalWorkoutRepository`, which held sessions in an actor's
/// array and lost every one of them at the next launch — the bug this type exists to fix.
///
/// A session is stored as three rows in three tables (see `WorkoutRecord`), and read back as one
/// value: the route and the splits are fetched per workout rather than joined, because a join would
/// multiply the session row by its route points and the caller wants a session, not a flat table.
public final class GRDBWorkoutRepository: WorkoutRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    public func save(_ workout: WorkoutSession) async throws {
        let id = workout.id.uuidString
        // `date` is the day key the record carries; `LocalDatabaseManager.saveWorkout` snaps it to
        // `startOfDay`, which is what `getWorkouts(for:)` matches on.
        let record = WorkoutRecord(
            id: id,
            date: workout.startedAt,
            startedAt: workout.startedAt,
            endedAt: workout.endedAt,
            strain: workout.strain,
            averageHeartRate: workout.averageHeartRate,
            maxHeartRate: workout.maxHeartRate
        )
        let route = workout.route.map {
            WorkoutRoutePointRecord(
                id: $0.id.uuidString,
                workoutId: id,
                latitude: $0.latitude,
                longitude: $0.longitude,
                timestamp: $0.timestamp,
                heartRate: $0.heartRate
            )
        }
        let splits = workout.splits.map {
            WorkoutSplitRecord(
                id: $0.id.uuidString,
                workoutId: id,
                elapsed: $0.elapsed,
                strain: $0.strain
            )
        }
        try await db.saveWorkout(record, route: route, splits: splits)
    }

    public func getWorkouts(for date: Date) async throws -> [WorkoutSession] {
        let records = try await db.getWorkouts(on: date)
        return try await Self.makeSessions(from: records, db: db)
    }

    public func latest() async throws -> WorkoutSession? {
        guard let record = try await db.getLatestWorkout() else { return nil }
        return try await Self.makeSessions(from: [record], db: db).first
    }

    /// Route and splits are read per workout. A row whose `id` is not a UUID is skipped rather than
    /// given a fresh one: `WorkoutSession.id` must be a UUID, and inventing an identity for a row
    /// we cannot address would hand the caller a session that does not correspond to anything
    /// stored — the same reason this codebase renders a missing measurement as a dash.
    private static func makeSessions(
        from records: [WorkoutRecord], db: LocalDatabaseManager
    ) async throws -> [WorkoutSession] {
        var sessions: [WorkoutSession] = []
        for record in records {
            guard let id = UUID(uuidString: record.id) else { continue }

            let points = try await db.getRoutePoints(for: record.id).map {
                WorkoutRoutePoint(
                    // A route point whose id will not parse is still a real fix at a real place, so
                    // it is kept with its own identity rather than dropped — its `id` is not part of
                    // any lookup, unlike the session's.
                    id: UUID(uuidString: $0.id) ?? UUID(),
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    timestamp: $0.timestamp,
                    heartRate: $0.heartRate
                )
            }
            let splits = try await db.getSplits(for: record.id).map {
                WorkoutSplit(
                    id: UUID(uuidString: $0.id) ?? UUID(),
                    elapsed: $0.elapsed,
                    strain: $0.strain
                )
            }

            sessions.append(
                WorkoutSession(
                    id: id,
                    startedAt: record.startedAt,
                    endedAt: record.endedAt,
                    strain: record.strain,
                    averageHeartRate: record.averageHeartRate,
                    maxHeartRate: record.maxHeartRate,
                    route: points,
                    splits: splits
                )
            )
        }
        return sessions
    }
}
