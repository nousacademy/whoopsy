import Foundation

/// The `motionEpochs` store, mapped to the domain entity.
public final class GRDBMotionEpochRepository: MotionEpochRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    public func saveMotionEpoch(_ epoch: MotionEpoch) async throws {
        try await db.saveMotionEpoch(
            MotionEpochRecord(
                start: epoch.start,
                date: epoch.date,
                end: epoch.end,
                meanMagnitudeG: epoch.meanMagnitudeG,
                maxMagnitudeG: epoch.maxMagnitudeG,
                sampleCount: epoch.sampleCount))
    }

    public func getMotionEpochs(from: Date, to: Date) async throws -> [MotionEpoch] {
        try await db.getMotionEpochs(from: from, to: to).map(Self.makeEpoch)
    }

    public func getLatestMotionEpoch(from startDate: Date, to endDate: Date) async throws -> MotionEpoch? {
        try await db.getLatestMotionEpoch(from: startDate, to: endDate).map(Self.makeEpoch)
    }

    private static func makeEpoch(from record: MotionEpochRecord) -> MotionEpoch {
        MotionEpoch(
            start: record.start,
            end: record.end,
            meanMagnitudeG: record.meanMagnitudeG,
            maxMagnitudeG: record.maxMagnitudeG,
            sampleCount: record.sampleCount)
    }
}
