import Foundation

public protocol BiometricRepository: Sendable {
    /// Save a batch of biometric samples locally
    func saveSamples(_ samples: [BiometricSample]) async throws

    /// Retrieve raw biometric samples for a given time range
    func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample]

    /// Fetch the most recent sample
    func getLatestSample() async throws -> BiometricSample?

    /// Delete all local biometric data (user privacy action)
    func clearAllBiometricData() async throws
}
