import Foundation

public final class ManageBLEConnectionUseCase: Sendable {
    private let bleRepository: any WhoopBLEDeviceRepository

    public init(bleRepository: any WhoopBLEDeviceRepository) {
        self.bleRepository = bleRepository
    }

    public var deviceStream: AsyncStream<WhoopDevice> {
        bleRepository.deviceStream
    }

    public func startScanning() async throws {
        try await bleRepository.startScanning()
    }

    public func stopScanning() async {
        await bleRepository.stopScanning()
    }

    public func connect(to deviceId: String) async throws {
        try await bleRepository.connect(to: deviceId)
    }

    public func disconnect() async {
        await bleRepository.disconnect()
    }

    public func triggerHapticAlarm(durationSeconds: Int = 3, pattern: Int = 1) async throws {
        try await bleRepository.sendHapticAlert(durationSeconds: durationSeconds, pattern: pattern)
    }

    public func getCurrentDevice() async -> WhoopDevice? {
        await bleRepository.getCurrentDevice()
    }
}
