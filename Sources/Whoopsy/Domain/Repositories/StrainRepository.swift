import Foundation

public protocol StrainRepository: Sendable {
    /// Get strain score for a specific day
    func getStrain(for date: Date) async throws -> StrainScore?

    /// Save or update strain score, labelling its provenance — see
    /// `RecoveryRepository.saveRecovery(_:source:)`.
    func saveStrain(_ strain: StrainScore, source: String?) async throws

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
