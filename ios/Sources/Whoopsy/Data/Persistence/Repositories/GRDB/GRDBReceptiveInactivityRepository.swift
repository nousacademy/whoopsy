import Foundation
import GRDB

/// Receptive inactivities, persisted.
///
/// **One table and no children**, which is the whole of why this is a short file: a receptive inactivity
/// carries no route and no splits, because there is nothing on one to file. That is unlike
/// `GRDBWorkoutRepository`, whose mapper exists mainly to fetch the two child tables per session.
///
/// **Every field is carried in both directions, and a one-way carry is silent rather than loud.** There
/// are exactly two places a column can be lost — `save(_:)`, which builds the record, and
/// `makeActivities(from:)`, which rebuilds the value — and neither is a compile error when it is
/// shortened: the record's initialiser would simply take its default and the column would read back
/// `nil` forever. `note` is the third field with that shape, so the pair is worth checking whenever a
/// fourth arrives.
public final class GRDBReceptiveInactivityRepository: ReceptiveInactivityRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// The record's `date` is the value's own snapped day, and `LocalDatabaseManager` snaps it again
    /// on the way in. Both are cheap and neither is load-bearing for the other; see
    /// `ReceptiveInactivity` for why the entity snaps at construction as well.
    public func save(_ activity: ReceptiveInactivity) async throws {
        let record = ReceptiveInactivityRecord(
            id: activity.id.uuidString,
            date: activity.date,
            name: activity.name,
            note: activity.note,
            startedAt: activity.startedAt
        )
        try await db.saveReceptiveInactivity(record)
    }

    public func getReceptiveInactivities(for date: Date) async throws -> [ReceptiveInactivity] {
        let records = try await db.getReceptiveInactivities(on: date)
        return Self.makeActivities(from: records)
    }

    /// The store's affected-row count is what makes this answer honest — see `delete(_:)`'s doc on
    /// `ReceptiveInactivityRepository`. A delete that matched nothing returns `false` and throws
    /// nothing, because an absent row is an ordinary answer rather than an error.
    public func delete(_ id: UUID) async throws -> Bool {
        try await db.deleteReceptiveInactivity(id: id.uuidString) > 0
    }

    /// A row whose `id` is not a UUID is skipped rather than given a fresh one, on
    /// `GRDBWorkoutRepository.makeSessions`'s rule: `ReceptiveInactivity.id` must be a UUID, and
    /// inventing an identity for a row we cannot address would hand the caller an entry that does not
    /// correspond to anything stored. Nothing in this app writes such a row — the sheet's draft mints
    /// a `UUID` — but the mapper is the boundary, and a boundary that assumes its input is the one
    /// that tears when the input changes.
    private static func makeActivities(from records: [ReceptiveInactivityRecord]) -> [ReceptiveInactivity] {
        records.compactMap { record in
            guard let id = UUID(uuidString: record.id) else { return nil }
            return ReceptiveInactivity(
                id: id,
                date: record.date,
                name: record.name,
                note: record.note,
                startedAt: record.startedAt
            )
        }
    }
}
