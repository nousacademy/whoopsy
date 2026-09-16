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

    /// Re-reads the stored per-strap model and re-resolves the connected strap's generation.
    ///
    /// The generation decides which envelope a command is framed with and whether one can be framed
    /// at all, so a change to it has to reach the BLE layer before the next command is sent. This is
    /// what the device screen calls the moment the user picks a model — without it the choice would
    /// not take effect until the strap was rediscovered.
    func refreshStrapModel() async
}
