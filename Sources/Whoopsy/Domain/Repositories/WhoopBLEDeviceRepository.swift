import Foundation

public protocol WhoopBLEDeviceRepository: Sendable {
    /// Stream of peripheral device status changes
    var deviceStream: AsyncStream<WhoopDevice> { get }

    /// Stream of incoming decoded biometric samples
    var liveTelemetryStream: AsyncStream<BiometricSample> { get }

    /// Scan for nearby WHOOP straps
    func startScanning() async throws

    /// Stop scanning
    func stopScanning() async

    /// Connect to a specific WHOOP device ID
    func connect(to deviceId: String) async throws

    /// Disconnect from the current strap
    func disconnect() async

    /// Send a haptic vibration alert command to the strap
    func sendHapticAlert(durationSeconds: Int, pattern: Int) async throws

    /// Request historical flash buffer sync
    func requestHistoricalSync(from startDate: Date, to endDate: Date) async throws

    /// Get the current connected device state
    func getCurrentDevice() async -> WhoopDevice?
}
