import Foundation

public protocol BiometricRepository: Sendable {
    /// Save a batch of biometric samples locally
    func saveSamples(_ samples: [BiometricSample]) async throws

    /// Retrieve raw biometric samples for a given time range
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample]

    /// Fetch the most recent sample
    func getLatestSample() async throws -> BiometricSample?

    /// The instant of the newest sample whose timestamp falls in `[from, to)`, or `nil`.
    ///
    /// **A watermark read, not a data read.** `RefreshStrainUseCase` asks this every few minutes to
    /// decide whether a day has anything new to score, and reading the day back to answer it would cost
    /// a full recomputation's worth of rows — around 86,000 on a worn strap — to avoid a recomputation.
    /// The GRDB implementation is one indexed `ORDER BY … DESC LIMIT 1`; the default below is the
    /// correct-but-slow shape for a fixture with a handful of samples.
    func getLatestSampleTimestamp(from: Date, to: Date) async throws -> Date?

    /// Delete all local biometric data (user privacy action)
    func clearAllBiometricData() async throws
}

extension BiometricRepository {
    public func getLatestSampleTimestamp(from startDate: Date, to endDate: Date) async throws -> Date? {
        try await getSamples(from: startDate, to: endDate).last?.timestamp
    }
}
