import Foundation

public protocol SleepRepository: Sendable {
    /// Get sleep session for a specific morning
    func getSleepSession(for date: Date) async throws -> SleepSession?

    /// Save sleep session, labelling its provenance — see `RecoveryRepository.saveRecovery(_:source:)`.
    func saveSleepSession(_ session: SleepSession, source: String?) async throws

    /// Fetch sleep sessions over the window ending on `endingOn` —
    /// see `RecoveryRepository.getRecoveryHistory(days:endingOn:)` for why the end is a parameter.
    func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession]
}

extension SleepRepository {
    /// Saves with no provenance label, for a caller that is its own source.
    public func saveSleepSession(_ session: SleepSession) async throws {
        try await saveSleepSession(session, source: nil)
    }

    /// The last `days` days from now — for a caller that has no day of its own.
    public func getSleepHistory(days: Int) async throws -> [SleepSession] {
        try await getSleepHistory(days: days, endingOn: Date())
    }

    /// Removes a night this app classified, when a re-analysis now says there was no night at all.
    ///
    /// **A default no-op**, because most readers of this protocol do not own storage — a use case or
    /// a spy has nothing to delete. The GRDB store and its cloud decorator override it; the cloud
    /// half deliberately has no delete endpoint, so the decorator removes the local copy only.
    public func deleteSleepSession(for date: Date) async throws {}
}
