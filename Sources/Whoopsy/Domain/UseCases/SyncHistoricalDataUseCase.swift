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

    public func execute() async throws {
        let latestSample = try await biometricRepository.getLatestSample()
        let startDate = latestSample?.timestamp ?? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let endDate = Date()

        try await bleRepository.requestHistoricalSync(from: startDate, to: endDate)
    }
}
