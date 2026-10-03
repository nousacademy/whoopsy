import Foundation

/// Naps the app knows about. Its own protocol rather than a member of `SleepRepository`, because the
/// two answer different questions about a day — `getSleepSession(for:)` returns one night or `nil`,
/// this returns an array that is legitimately empty, and merging them would make "no nap today" and
/// "no night recorded" the same return value.
public protocol NapRepository: Sendable {
    /// The naps taken on `date`'s day, earliest first. Empty is an ordinary answer and means the user
    /// did not nap — not that the day is missing.
    func getNaps(on date: Date) async throws -> [SleepNap]

    /// Save a nap, labelling its provenance — see `RecoveryRepository.saveRecovery(_:source:)`.
    func saveNap(_ nap: SleepNap, source: String?) async throws
}

extension NapRepository {
    /// Saves with no provenance label, for a caller that is its own source.
    public func saveNap(_ nap: SleepNap) async throws {
        try await saveNap(nap, source: nil)
    }
}
