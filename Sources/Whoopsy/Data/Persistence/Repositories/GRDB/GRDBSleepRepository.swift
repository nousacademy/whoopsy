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
            sleepConsistency: session.sleepConsistency,
            sleepDebt: session.sleepDebtSeconds,
            // An empty array is stored as NULL, because this column is the night's *timeline* and an
            // empty one is not a timeline. The two producers that pass `[]` — every imported night,
            // and a strap night the classifier could not read — are both saying "nothing was staged",
            // which is what NULL means here. Writing `[]` would put a second, indistinguishable
            // spelling of the same absence in the column and make "was it staged?" unanswerable from
            // the data alone, which is the mistake `SleepSession.hasWhoopSleepNeed` exists to undo.
            sleepStages: session.sleepStages.isEmpty ? nil : session.sleepStages,
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
            respiratoryRate: record.respiratoryRate,
            sleepConsistency: record.sleepConsistency,
            sleepDebtSeconds: record.sleepDebt,
            // The one thing the `source` column is read for, and it is resolved here rather than at a
            // screen because this mapper is where the column exists at all. The comparison is against
            // the importer's own label rather than a literal so the two cannot drift; every other
            // value — a strap night's `nil`, a row written before the column — is "not known to be
            // WHOOP's", which is the answer that withholds a claim rather than making one.
            hasWhoopSleepNeed: record.source == WhoopExportImporter.sourceLabel,
            // The one place a stored timeline becomes a `SleepSession`'s. NULL — which is every
            // imported night and every row older than `v12` — resolves to the entity's own empty
            // default, so a caller that only wants the totals is unaffected and one that draws the
            // timeline reads `isEmpty` rather than unwrapping.
            sleepStages: record.sleepStages ?? []
        )
    }
}