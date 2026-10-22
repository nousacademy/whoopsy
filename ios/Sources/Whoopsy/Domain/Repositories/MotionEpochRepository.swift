import Foundation

/// The strap's recorded motion, one 30-second window at a time.
///
/// **Local-only, like the biometric samples it sits beside.** Motion is not a synced resource: it is
/// an input to the sleep classifier on this phone, and a row's meaning is tied to the sampling the
/// strap delivered, so it has no wire shape (`shared/openapi.json` has no motion resource and the
/// seven synced resources do not include it).
public protocol MotionEpochRepository: Sendable {
    /// Upserts the epoch's own 30-second window. A second save for the same `start` replaces the
    /// first, which is what lets the recorder write a growing window as its batches arrive.
    func saveMotionEpoch(_ epoch: MotionEpoch) async throws

    /// Epochs whose **start** falls in `[from, to)`.
    func getMotionEpochs(from: Date, to: Date) async throws -> [MotionEpoch]
}
