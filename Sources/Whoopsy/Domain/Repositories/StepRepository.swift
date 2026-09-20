import Foundation

/// One day's step count, read and written by day key.
///
/// A day-keyed table like `strains` and `sleeps` — one row per day, primary-keyed on the snapped
/// date — because a step count is a daily total and not a series. The 100 Hz motion it is derived
/// from is **not** stored: a day of it is ~26M samples, and `StepAccumulator` consumes each batch as
/// it arrives and keeps only the running count. That is why this protocol hands back a number rather
/// than a curve, and why no reader can recompute what it reads.
///
/// There is no `source` parameter on the write, deliberately. `StrainRepository` carries one because
/// two producers write that table — the strap and the CSV import — and a reader has to be able to
/// tell them apart. Steps have **one** producer: the strap, whether the batches arrived live over
/// `0x2B`/43 or were drained banked from type 47. Both are the same measurement of the same motion by
/// the same sensor, and a single day is routinely fed by both — so a per-row provenance label could
/// not be written honestly even if something wanted to read it.
public protocol StepRepository: Sendable {
    /// The day's count, or `nil` when that day was never measured.
    ///
    /// `nil` is the absence — there is no reserved-zero row. A day with a row and a count of `0` is a
    /// measured day the user did not walk; see `StepCount.hasMeasurement`.
    func getStepCount(for date: Date) async throws -> StepCount?

    /// Writes the day's count. Replaces the row for that day rather than appending — see
    /// `LocalDatabaseManager.saveStepCount` for the snap that makes that true.
    func saveStepCount(_ stepCount: StepCount) async throws

    /// The counts over the window ending on `endingOn`, oldest first — see
    /// `RecoveryRepository.getRecoveryHistory(days:endingOn:)` for why the end is a parameter.
    func getStepCountHistory(days: Int, endingOn: Date) async throws -> [StepCount]
}

extension StepRepository {
    /// The last `days` days from now — for a caller that has no day of its own.
    public func getStepCountHistory(days: Int) async throws -> [StepCount] {
        try await getStepCountHistory(days: days, endingOn: Date())
    }
}
