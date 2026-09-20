import Foundation
import GRDB

public final class GRDBStepRepository: StepRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// A day the strap did not measure has no steps — `nil`, not a substituted zero.
    public func getStepCount(for date: Date) async throws -> StepCount? {
        try await db.getStepCount(for: date).map(Self.makeStepCount)
    }

    public func saveStepCount(_ stepCount: StepCount) async throws {
        try await db.saveStepCount(
            StepCountRecord(
                date: stepCount.date,
                stepCount: stepCount.stepCount,
                measuredSeconds: stepCount.measuredSeconds))
    }

    public func getStepCountHistory(days: Int, endingOn: Date) async throws -> [StepCount] {
        try await db.getStepCountHistory(days: days, endingOn: endingOn).map(Self.makeStepCount)
    }

    /// The record is read straight across, with no re-derivation — and that is the point.
    ///
    /// There is nothing to recompute from: the motion the count came from was never stored, so a
    /// reader that "recalculated" would have no input and a reader that inferred a measurement from
    /// `stepCount > 0` would call a measured day of no walking unmeasured. `measuredSeconds` is the
    /// column that answers that question and it is carried through unchanged.
    private static func makeStepCount(from record: StepCountRecord) -> StepCount {
        StepCount(
            date: record.date,
            stepCount: record.stepCount,
            measuredSeconds: record.measuredSeconds)
    }
}
