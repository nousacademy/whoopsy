import Foundation

public final class GRDBNapRepository: NapRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// A day with no nap returns `[]`, which is the honest answer rather than an absence — see
    /// `NapRepository`.
    public func getNaps(on date: Date) async throws -> [SleepNap] {
        try await db.getNaps(on: date).map(Self.makeNap)
    }

    public func saveNap(_ nap: SleepNap, source: String?) async throws {
        let record = NapRecord(
            id: nap.id,
            date: nap.date,
            startedAt: nap.startTime,
            endedAt: nap.endTime,
            asleepSeconds: nap.asleepSeconds,
            source: source
        )
        try await db.saveNap(record)
    }

    private static func makeNap(from record: NapRecord) -> SleepNap {
        SleepNap(
            id: record.id,
            date: record.date,
            startTime: record.startedAt,
            endTime: record.endedAt,
            asleepSeconds: record.asleepSeconds)
    }
}
