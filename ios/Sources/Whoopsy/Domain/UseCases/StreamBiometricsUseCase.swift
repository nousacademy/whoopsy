import Foundation

public final class StreamBiometricsUseCase: Sendable {
    private let bleRepository: any WhoopBLEDeviceRepository
    private let biometricRepository: any BiometricRepository

    public init(
        bleRepository: any WhoopBLEDeviceRepository,
        biometricRepository: any BiometricRepository
    ) {
        self.bleRepository = bleRepository
        self.biometricRepository = biometricRepository
    }

    /// Exposes the live biometric stream while asynchronously persisting samples locally in batches.
    public func execute() -> AsyncStream<BiometricSample> {
        let rawStream = bleRepository.liveTelemetryStream
        let bioRepo = self.biometricRepository

        return AsyncStream { continuation in
            let task = Task {
                var buffer: [BiometricSample] = []
                var lastFlushTime = Date()

                for await sample in rawStream {
                    continuation.yield(sample)
                    buffer.append(sample)

                    // Flush buffer every 10 samples or 5 seconds to reduce SQLite write churn
                    if buffer.count >= 10 || Date().timeIntervalSince(lastFlushTime) >= 5.0 {
                        let toSave = buffer
                        buffer.removeAll(keepingCapacity: true)
                        lastFlushTime = Date()
                        do {
                            try await bioRepo.saveSamples(toSave)
                        } catch {
                            AppLogger.database.error("Failed saving biometric batch: \(error.localizedDescription)")
                        }
                    }
                }
                // Flush remaining on stream end
                if !buffer.isEmpty {
                    try? await bioRepo.saveSamples(buffer)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
