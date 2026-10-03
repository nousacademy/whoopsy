import Foundation

public final class SyncHistoricalDataUseCase: Sendable {
    private let bleRepository: any WhoopBLEDeviceRepository
    private let biometricRepository: any BiometricRepository

    public init(
        bleRepository: any WhoopBLEDeviceRepository,
        biometricRepository: any BiometricRepository
    ) {
        self.bleRepository = bleRepository
        self.biometricRepository = biometricRepository
    }

    /// Drains the strap's flash buffer back to the last sample this app holds, and returns what the
    /// drain did.
    ///
    /// The window's start is the most recent stored sample, which is a **resumed** cursor rather than
    /// a fresh one: the strap keeps its read pointer across connections, so a drain that stopped early
    /// continues from where it stopped instead of fetching the same records again. A day is the
    /// fallback when nothing is stored, which is a first sync rather than an incremental one.
    @discardableResult
    public func execute() async throws -> HistoricalSyncOutcome {
        let latestSample = try await biometricRepository.getLatestSample()
        let startDate = latestSample?.timestamp ?? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let endDate = Date()

        return try await bleRepository.requestHistoricalSync(from: startDate, to: endDate)
    }
}
