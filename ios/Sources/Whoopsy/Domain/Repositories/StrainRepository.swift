import Foundation

public protocol StrainRepository: Sendable {
    /// Get strain score for a specific day
    func getStrain(for date: Date) async throws -> StrainScore?

    /// The day's row as this phone holds it, **without asking the cloud**.
    ///
    /// **The refresh's decision read, and it is separate from `getStrain` on purpose.** Under the
    /// `.cloud` destination a miss on `getStrain` reaches the database, and an unreachable one marks the
    /// day in `SyncStatus` — but a backfill deciding whether a day is repairable must answer from what
    /// this phone actually read. A network round trip there would turn a transient failure into a day
    /// the refresh believes it has never scored, and a WHOOP-imported row fetched over the wire is
    /// exactly the row that must not be recomputed.
    func getLocalStrain(for date: Date) async throws -> StrainScore?

    /// Save or update strain score, labelling its provenance — see
    /// `RecoveryRepository.saveRecovery(_:source:)`.
    func saveStrain(_ strain: StrainScore, source: String?) async throws

    /// The newest day this phone holds a **WHOOP-imported** strain for, or `nil`.
    ///
    /// **The backfill's outer bound.** An imported day is WHOOP's own figure and must never be replaced
    /// by this app's estimate; the export is a contiguous span, so a day *before* the newest imported
    /// one is inside that span too. Skipping only the exact imported rows would leave the gaps between
    /// them — days the export had no strain for — open to being filled with this app's number, which is
    /// precisely the crossing `AnalyzeSleepUseCase` refuses between a computed and an imported need.
    func getNewestImportedStrainDay() async throws -> Date?

    /// Fetch historical strain scores over the window ending on `endingOn` —
    /// see `RecoveryRepository.getRecoveryHistory(days:endingOn:)` for why the end is a parameter.
    func getStrainHistory(days: Int, endingOn: Date) async throws -> [StrainScore]
}

extension StrainRepository {
    /// Saves with no provenance label, for a caller that is its own source.
    public func saveStrain(_ strain: StrainScore) async throws {
        try await saveStrain(strain, source: nil)
    }

    /// The last `days` days from now — for a caller that has no day of its own.
    public func getStrainHistory(days: Int) async throws -> [StrainScore] {
        try await getStrainHistory(days: days, endingOn: Date())
    }
}
