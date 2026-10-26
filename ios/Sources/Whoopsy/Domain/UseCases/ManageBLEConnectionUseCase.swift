import Foundation

public final class ManageBLEConnectionUseCase: Sendable {
    private let bleRepository: any WhoopBLEDeviceRepository

    public init(bleRepository: any WhoopBLEDeviceRepository) {
        self.bleRepository = bleRepository
    }

    public var deviceStream: AsyncStream<WhoopDevice> {
        bleRepository.deviceStream
    }

    /// The strap's live heart rate and R-R notifications, for the Device page's pulse reading.
    ///
    /// Forwarded rather than copied, exactly as `deviceStream` is: the BLE layer's registry is
    /// multicast, so this is a second subscriber beside `StreamBiometricsUseCase`'s rather than a
    /// competing reader of one continuation.
    public var liveTelemetryStream: AsyncStream<BiometricSample> {
        bleRepository.liveTelemetryStream
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

    /// Re-arms the link when the root view sees the app come back to the foreground. See
    /// `WhoopBLEDeviceRepository.rearmConnection` for why this is not a second `startScanning()`.
    public func rearmConnection() async {
        await bleRepository.rearmConnection()
    }

    public func triggerHapticAlarm(durationSeconds: Int = 3, pattern: Int = 1) async throws {
        try await bleRepository.sendHapticAlert(durationSeconds: durationSeconds, pattern: pattern)
    }

    /// Restarts the strap's firmware — `0x1D`. Throws when this build cannot frame the command.
    public func rebootStrap() async throws {
        try await bleRepository.rebootStrap()
    }

    /// Sends the 5.0/MG's persistent-recording toggle. See
    /// `WhoopBLEDeviceRepository.setPersistentRecording(_:)` — it is an experiment, not a setting,
    /// and the strap's ACK does not confirm it.
    public func setPersistentRecording(_ enabled: Bool) async throws {
        try await bleRepository.setPersistentRecording(enabled)
    }

    /// Asks the strap to advertise a different name. See
    /// `WhoopBLEDeviceRepository.setAdvertisingName(_:)` — unconfirmed on both generations.
    public func setAdvertisingName(_ name: String) async throws {
        try await bleRepository.setAdvertisingName(name)
    }

    /// Asks the strap for the name it has stored — a log-and-capture read, not a decoded answer.
    public func requestAdvertisingName() async {
        await bleRepository.requestAdvertisingName()
    }

    public func getCurrentDevice() async -> WhoopDevice? {
        await bleRepository.getCurrentDevice()
    }

    /// Re-resolves the connected strap's generation from the stored model choices.
    ///
    /// Called after the user picks a model on the device screen. The generation selects the wire
    /// envelope, so a saved choice that never reaches here would be a preference with no effect.
    public func refreshStrapModel() async {
        await bleRepository.refreshStrapModel()
    }
}
