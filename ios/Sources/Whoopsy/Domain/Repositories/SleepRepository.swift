import Foundation

public protocol SleepRepository: Sendable {
    /// Get sleep session for a specific morning
    func getSleepSession(for date: Date) async throws -> SleepSession?

    /// Save sleep session, labelling its provenance — see `RecoveryRepository.saveRecovery(_:source:)`.
    func saveSleepSession(_ session: SleepSession, source: String?) async throws

    /// Fetch sleep sessions over the window ending on `endingOn` —
    /// see `RecoveryRepository.getRecoveryHistory(days:endingOn:)` for why the end is a parameter.
    func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession]

    /// Removes a night this app classified, when a re-analysis now says there was no night at all.
    ///
    /// **A requirement with no default implementation, and that is the fix rather than a tidy-up.**
    /// It used to carry an empty default "because most readers of this protocol do not own storage" —
    /// and the store's own implementation did not win over that default through an existential, so the
    /// sleep page's delete silently did nothing while the screen reported the night as gone. The
    /// compiler now makes every conformer answer: a spy that owns nothing says so in one line, and a
    /// store that owns rows implements it.
    func deleteSleepSession(for date: Date) async throws
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

    /// The cloud half deliberately has no delete endpoint; the decorator removes the local copy only,
    /// which is why it supplies its own implementation rather than inheriting one.
}
