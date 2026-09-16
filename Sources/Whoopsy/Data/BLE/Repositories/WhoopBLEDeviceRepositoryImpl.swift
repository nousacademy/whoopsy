import Foundation

/// Adapter implementing the domain `WhoopBLEDeviceRepository` protocol using `WhoopBLEManager` or `WhoopMockBLEManager`.
public final class WhoopBLEDeviceRepositoryImpl: WhoopBLEDeviceRepository, @unchecked Sendable {
    private let realBleManager: WhoopBLEManager?
    private let mockBleManager: WhoopMockBLEManager?
    private let isMockMode: Bool

    public init(useMock: Bool = true, strapModelRepository: (any StrapModelRepository)? = nil) {
        self.isMockMode = useMock
        if useMock {
            self.mockBleManager = WhoopMockBLEManager()
            self.realBleManager = nil
        } else {
            self.realBleManager = WhoopBLEManager(strapModelRepository: strapModelRepository)
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
            // Prime the model cache *before* discovery. `didDiscover` is a synchronous CoreBluetooth
            // callback and cannot await, so a cache loaded any later would leave the first discovery
            // resolving on the name heuristic alone — and the first discovery is the one that decides
            // which strap the user is looking at.
            await realBleManager!.refreshStrapModels()
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

    /// Both senders take the same three-step shape, and each step is a real refusal rather than a
    /// formality: no manager (mock mode) means no wire, **no profile means this strap's envelope is
    /// not implemented and the frame must not be built at all**, and `nil` from the builder means the
    /// same. `WhoopBLEManager.sendCommand` guards the profile again at the write.
    public func sendHapticAlert(durationSeconds: Int, pattern: Int) async throws {
        guard !isMockMode, let manager = realBleManager, let profile = manager.currentProfile,
              let cmdData = WhoopPacketEncoder.hapticAlarmCommand(
                  profile: profile,
                  seq: manager.commandSequence.next(),
                  durationSeconds: durationSeconds,
                  pattern: pattern)
        else { return }
        manager.sendCommand(cmdData)
    }

    public func requestHistoricalSync(from startDate: Date, to endDate: Date) async throws {
        let s = UInt32(startDate.timeIntervalSince1970)
        let e = UInt32(endDate.timeIntervalSince1970)
        guard !isMockMode, let manager = realBleManager, let profile = manager.currentProfile,
              let cmd = WhoopPacketEncoder.requestHistoricalSync(
                  profile: profile, seq: manager.commandSequence.next(), startEpoch: s, endEpoch: e)
        else { return }
        manager.sendCommand(cmd)
    }

    public func refreshStrapModel() async {
        await realBleManager?.refreshStrapModels()
    }

    public func getCurrentDevice() async -> WhoopDevice? {
        if isMockMode {
            return mockBleManager?.getCurrentDevice()
        } else {
            return realBleManager?.getCurrentDevice()
        }
    }
}
