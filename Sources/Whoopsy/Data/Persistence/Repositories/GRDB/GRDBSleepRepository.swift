import Foundation
import GRDB

public final class GRDBSleepRepository: SleepRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// A night the strap did not record is `nil` — the caller renders "no data", it does not get a
    /// stand-in night to score.
    public func getSleepSession(for date: Date) async throws -> SleepSession? {
        try await db.getSleep(for: date).map(Self.makeSession)
    }

    public func saveSleepSession(_ session: SleepSession, source: String?) async throws {
        let record = SleepRecord(
            date: session.date,
            startTime: session.startTime,
            endTime: session.endTime,
            // Derived from the session rather than a literal: the column is not read back today, but
            // a fixed 0.85 lying in the table is a fabricated measurement waiting for a reader.
            sleepPerformance: Double(session.sleepPerformancePercentage) / 100.0,
            totalSleepNeeded: session.targetSleepNeedSeconds,
            lightSleep: session.lightSleepSeconds,
            deepSleep: session.deepSleepSeconds,
            remSleep: session.remSleepSeconds,
            awakeTime: session.awakeSeconds,
            respiratoryRate: session.respiratoryRate,
            disturbanceCount: session.disturbanceCount,
            source: source
        )
        try await db.saveSleep(record)
    }

    public func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession] {
        try await db.getSleepHistory(days: days, endingOn: endingOn).map(Self.makeSession)
    }

    private static func makeSession(from record: SleepRecord) -> SleepSession {
        SleepSession(
            date: record.date,
            startTime: record.startTime,
            endTime: record.endTime,
            targetSleepNeedSeconds: record.totalSleepNeeded,
            lightSleepSeconds: record.lightSleep,
            deepSleepSeconds: record.deepSleep,
            remSleepSeconds: record.remSleep,
            awakeSeconds: record.awakeTime,
            disturbanceCount: record.disturbanceCount,
            respiratoryRate: record.respiratoryRate
        )
    }
}