import Foundation

public protocol RecoveryRepository: Sendable {
    /// Get calculated recovery for a specific day
    func getRecovery(for date: Date) async throws -> RecoveryMetric?

    /// Save or update a recovery score, labelling its provenance.
    ///
    /// `source` is a free-form label for a column nothing reads yet: `nil` means the app measured
    /// this row itself, which is what the strap path and the HealthKit importer both are. Only a
    /// bulk import of externally-recorded history needs to name itself, so that hundreds of rows it
    /// wrote stay distinguishable from local measurements. Callers that are their own source use the
    /// single-argument form below.
    func saveRecovery(_ recovery: RecoveryMetric, source: String?) async throws

    /// Fetch historical recovery scores over the window ending on `endingOn`, most recent last.
    ///
    /// The end of the window is a parameter rather than an assumption of "now" because the day-keyed
    /// screens show a day the user picked. A caller with no day of its own — the scoring baseline, the
    /// JSON exporter — uses the single-argument form below, which means today.
    func getRecoveryHistory(days: Int, endingOn: Date) async throws -> [RecoveryMetric]

    /// The row stored **locally** for `date`, or nil if there is none.
    ///
    /// Every implementation now answers from local storage only, so this reads the same as
    /// `getRecovery(for:)`. It survives as a separate name because the two callers are asking
    /// different questions and only the name says which: a caller about to *write* must know what is
    /// already on disk, and treating a stored row as absent would overwrite a measurement. Keeping
    /// the intent at the call site is what stops a future non-local implementation from leaking a
    /// synthesised row into that decision.
    ///
    /// Returns the row rather than a `Bool` because "a row exists" and "a measurement exists" are
    /// different questions, and only the caller knows which it is asking. A day the strap left
    /// unworn has no row at all now that `CalculateRecoveryUseCase` returns `nil` rather than storing
    /// a placeholder — but rows written before that change are still on disk in the placeholder shape
    /// (see `RecoveryMetric.hasMeasurement`), and a later import may legitimately fill one of those.
    func getLocalRecovery(for date: Date) async throws -> RecoveryMetric?
}

extension RecoveryRepository {
    /// Saves with no provenance label. This is the form for a caller that *is* the source — the
    /// strap path and the HealthKit import both measure what they write, so there is nothing for
    /// them to record.
    public func saveRecovery(_ recovery: RecoveryMetric) async throws {
        try await saveRecovery(recovery, source: nil)
    }

    /// The last `days` days from now — for a caller that has no day of its own.
    public func getRecoveryHistory(days: Int) async throws -> [RecoveryMetric] {
        try await getRecoveryHistory(days: days, endingOn: Date())
    }
}
