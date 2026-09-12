import Foundation

/// High-fidelity WHOOP hardware simulator for SwiftUI Previews, unit testing, and device-free demonstration.
public final class WhoopMockBLEManager: @unchecked Sendable {
    private var isSimulating = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "org.whoopsy.mockble.queue")

    // Keyed by subscriber, for the same reason as `WhoopBLEManager`'s: a single stored continuation
    // is overwritten by each new reader of the stream, silently orphaning the one before it. The mock
    // is what Previews and the test runner drive, so a bug here reads as a bug in the real manager.
    private let continuationLock = NSLock()
    private var deviceContinuations: [UUID: AsyncStream<WhoopDevice>.Continuation] = [:]
    private var telemetryContinuations: [UUID: AsyncStream<BiometricSample>.Continuation] = [:]

    private var currentDevice: WhoopDevice

    public init() {
        self.currentDevice = WhoopDevice(
            id: "MOCK-WHOOP-4-0-DEVICE",
            name: "WHOOP 4.0 (Simulated)",
            hardwareGeneration: .whoop4,
            batteryPercentage: 88,
            connectionState: .connected,
            isOnBody: true,
            isCharging: false,
            firmwareVersion: "41.14.2.0",
            serialNumber: "WP4-984210",
            signalStrengthRssi: -58
        )
    }

    public var deviceStream: AsyncStream<WhoopDevice> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            deviceContinuations[id] = continuation
            continuationLock.unlock()
            continuation.yield(currentDevice)
            continuation.onTermination = { [weak self] _ in
                self?.removeDeviceContinuation(id)
            }
        }
    }

    public var liveTelemetryStream: AsyncStream<BiometricSample> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.lock()
            telemetryContinuations[id] = continuation
            continuationLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeTelemetryContinuation(id)
            }
            // Guarded by `isSimulating`, so a second subscriber attaches to the running generator
            // rather than starting a second one. That guard is what makes the multicast work here:
            // before it, this call was also what made the *first* subscriber's stream live.
            self.startGeneratingMockTelemetry()
        }
    }

    private func removeDeviceContinuation(_ id: UUID) {
        continuationLock.lock()
        deviceContinuations[id] = nil
        continuationLock.unlock()
    }

    private func removeTelemetryContinuation(_ id: UUID) {
        continuationLock.lock()
        telemetryContinuations[id] = nil
        continuationLock.unlock()
    }

    private func yieldDevice(_ device: WhoopDevice) {
        continuationLock.lock()
        let targets = Array(deviceContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(device) }
    }

    private func yieldTelemetry(_ sample: BiometricSample) {
        continuationLock.lock()
        let targets = Array(telemetryContinuations.values)
        continuationLock.unlock()
        for continuation in targets { continuation.yield(sample) }
    }

    public func startScanning() {
        currentDevice = WhoopDevice(
            id: currentDevice.id,
            name: currentDevice.name,
            hardwareGeneration: currentDevice.hardwareGeneration,
            batteryPercentage: currentDevice.batteryPercentage,
            connectionState: .connected,
            isOnBody: currentDevice.isOnBody,
            isCharging: currentDevice.isCharging,
            firmwareVersion: currentDevice.firmwareVersion,
            serialNumber: currentDevice.serialNumber,
            signalStrengthRssi: currentDevice.signalStrengthRssi
        )
        yieldDevice(currentDevice)
    }

    public func stopScanning() {}

    public func connect(to deviceId: String) {
        startScanning()
    }

    public func disconnect() {
        currentDevice = WhoopDevice(
            id: currentDevice.id,
            name: currentDevice.name,
            connectionState: .disconnected
        )
        yieldDevice(currentDevice)
        stopGenerating()
    }

    public func getCurrentDevice() -> WhoopDevice? {
        currentDevice
    }

    public func startGeneratingMockTelemetry() {
        guard !isSimulating else { return }
        isSimulating = true

        Task { [weak self] in
            var phase: Double = 0.0
            var baseHR = 62.0

            while let self = self, self.isSimulating {
                phase += 0.1
                // Circadian & respiratory sinus arrhythmia variation (58 - 76 BPM)
                let hrVariation = sin(phase) * 6.0 + Double.random(in: -2.0...2.0)
                let currentHR = Int(max(45, min(180, (baseHR + hrVariation).rounded())))

                // R-R interval corresponding to instantaneous HR in ms
                let rrMs = (60.0 / Double(currentHR)) * 1000.0 + Double.random(in: -15.0...15.0)

                // Micro accelerometer noise
                let ax = Double.random(in: -0.05...0.05)
                let ay = Double.random(in: -0.05...0.05)
                let az = 1.0 + Double.random(in: -0.05...0.05)

                let tempC = 36.5 + sin(phase * 0.2) * 0.2
                let spo2 = Double.random(in: 97.5...99.5)

                let sample = BiometricSample(
                    timestamp: Date(),
                    heartRate: currentHR,
                    rrIntervalsMs: [rrMs],
                    accelerometerX: ax,
                    accelerometerY: ay,
                    accelerometerZ: az,
                    skinTemperatureCelsius: tempC,
                    spO2Percentage: spo2,
                    isOnBody: true,
                    isCharging: false
                )

                self.yieldTelemetry(sample)

                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 Hz stream
            }
        }
    }

    public func stopGenerating() {
        isSimulating = false
    }
}
