import Foundation

/// Adapter implementing the domain `WhoopBLEDeviceRepository` protocol using `WhoopBLEManager` or `WhoopMockBLEManager`.
public final class WhoopBLEDeviceRepositoryImpl: WhoopBLEDeviceRepository, @unchecked Sendable {
    private let realBleManager: WhoopBLEManager?
    private let mockBleManager: WhoopMockBLEManager?
    private let isMockMode: Bool

    public init(useMock: Bool = true) {
        self.isMockMode = useMock
        if useMock {
            self.mockBleManager = WhoopMockBLEManager()
            self.realBleManager = nil
        } else {
            self.realBleManager = WhoopBLEManager()
            self.mockBleManager = nil
        }
    }

    public var deviceStream: AsyncStream<WhoopDevice> {
        if isMockMode {
            return mockBleManager!.deviceStream
        } else {
            return realBleManager!.deviceStream
        }
    }

    public var liveTelemetryStream: AsyncStream<BiometricSample> {
        if isMockMode {
            return mockBleManager!.liveTelemetryStream
        } else {
            return realBleManager!.liveTelemetryStream
        }
    }

    public func startScanning() async throws {
        if isMockMode {
            mockBleManager!.startScanning()
        } else {
            realBleManager!.startScanning()
        }
    }

    public func stopScanning() async {
        if isMockMode {
            mockBleManager!.stopScanning()
        } else {
            realBleManager!.stopScanning()
        }
    }

    public func connect(to deviceId: String) async throws {
        if isMockMode {
            mockBleManager!.connect(to: deviceId)
        } else {
            realBleManager!.connect(to: deviceId)
        }
    }

    public func disconnect() async {
        if isMockMode {
            mockBleManager!.disconnect()
        } else {
            realBleManager!.disconnect()
        }
    }

    public func sendHapticAlert(durationSeconds: Int, pattern: Int) async throws {
        let cmdData = WhoopPacketEncoder.hapticAlarmCommand(durationSeconds: durationSeconds, pattern: pattern)
        if !isMockMode {
            realBleManager?.sendCommand(cmdData)
        }
    }

    public func requestHistoricalSync(from startDate: Date, to endDate: Date) async throws {
        let s = UInt32(startDate.timeIntervalSince1970)
        let e = UInt32(endDate.timeIntervalSince1970)
        let cmd = WhoopPacketEncoder.requestHistoricalSync(startEpoch: s, endEpoch: e)
        if !isMockMode {
            realBleManager?.sendCommand(cmd)
        }
    }

    public func getCurrentDevice() async -> WhoopDevice? {
        if isMockMode {
            return mockBleManager?.getCurrentDevice()
        } else {
            return realBleManager?.getCurrentDevice()
        }
    }
}
