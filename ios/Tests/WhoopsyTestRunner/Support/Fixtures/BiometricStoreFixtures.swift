import Foundation
import Whoopsy

struct EmptyBiometricStore: BiometricRepository {
    func saveSamples(_ samples: [BiometricSample]) async throws {}
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] { [] }
    func getLatestSample() async throws -> BiometricSample? { nil }
    func clearAllBiometricData() async throws {}
}

// ── A strap that recorded something ──────────────────────────────────────────────────────────

/// A strap that recorded an actual night — `EmptyBiometricStore`'s counterpart.
/// `AnalyzeSleepUseCase` only refuses a night when the window holds fewer than
/// `minimumEpochSamples` (30) samples, so a fixture with enough of them inside the window is a night
/// as far as the use case is concerned. Everything about the samples below is chosen to clear one
/// guard and no more: 60 one-minute samples read as two 30-second epochs, and a heart rate of 52
/// against a default resting rate of 60 is below `restHR * 0.92`, so the epochs classify as deep
/// sleep — a stage, and therefore a session, rather than an absence.
struct OvernightBiometricStore: BiometricRepository {
    let samples: [BiometricSample]

    func saveSamples(_ samples: [BiometricSample]) async throws {}
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
        samples.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }
    func getLatestSample() async throws -> BiometricSample? { samples.last }
    func clearAllBiometricData() async throws {}
}

/// A `biometric_samples` source that answers from an array.
///
/// `EmptyBiometricStore`'s counterpart, and needed for the same reason `OvernightBiometricStore` was:
/// `AnalyzeStressUseCase` returns `nil` the moment its store is empty, so the empty store can prove
/// the no-measurement rule and nothing else. Every measured-path assertion below needs a store that
/// actually holds samples.
struct DaytimeBiometricStore: BiometricRepository {
    var samples: [BiometricSample] = []
    func saveSamples(_ samples: [BiometricSample]) async throws {}
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
        samples.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }
    func getLatestSample() async throws -> BiometricSample? { nil }
    func clearAllBiometricData() async throws {}
}
