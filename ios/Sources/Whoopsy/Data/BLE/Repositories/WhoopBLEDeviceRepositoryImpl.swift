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

    public var motionStream: AsyncStream<MotionBatch> {
        if isMockMode {
            return mockBleManager!.motionStream
        } else {
            return realBleManager!.motionStream
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

    /// Runs a drain to its conclusion and reports what it did.
    ///
    /// **This is the call the whole Phase-3 wiring exists for, and its shape is the point: it awaits.**
    /// The request frame is built by `WhoopCommandFrames` from the profile's own table — the 4.0 gets
    /// `0x16`, the 5.0 and MG get their own byte under their own envelope — and then the manager's
    /// drain loop owns everything until the strap says it is done. Nothing here polls and nothing here
    /// guesses; the `HistoricalSyncOutcome` is read off the finished session.
    ///
    /// Two refusals are stated rather than swallowed. Mock mode and an unbuildable profile both mean
    /// **nothing was sent**, which is `WhoopSyncError.noCommandPath` rather than a quiet return: a
    /// caller that printed "complete" over either would be reporting a sync that never started.
    public func requestHistoricalSync(from startDate: Date, to endDate: Date) async throws -> HistoricalSyncOutcome {
        guard !isMockMode, let manager = realBleManager else {
            throw WhoopSyncError.noCommandPath(generation: "simulated")
        }
        let generation = manager.getCurrentDevice()?.hardwareGeneration ?? .whoop4
        guard let profile = manager.currentProfile, profile.canTransmitCommands else {
            throw WhoopSyncError.noCommandPath(generation: generation.rawValue)
        }

        // **The dates stop here, and that is the correction rather than a simplification.** Neither
        // generation's request carries a window — both send a single `00` byte — so there is no field
        // on the wire for this pair to reach. It was previously encoded as an eight-byte
        // `[u32 start][u32 end]` payload, which was this app's own invention; see
        // `WhoopPacketEncoder.requestHistoricalSync`. A bounded drain is a read-pointer seek
        // (`0x21`), not a request body.
        guard let session = await manager.drainHistoricalData() else {
            throw WhoopSyncError.noCommandPath(generation: generation.rawValue)
        }

        let outcome = HistoricalSyncOutcome(
            recordCount: session.recordCount,
            batchCount: session.batchCount,
            ending: Self.ending(for: session.finishReason)
        )

        // An ending this side caused is thrown rather than returned, because the two callers that
        // exist both want the same thing from it: a sentence saying the sync did not finish. The
        // counts travel with the error so the message can say how far it got.
        guard outcome.ending.isStrapConfirmed else {
            throw WhoopSyncError.endedWithoutConfirmation(
                records: outcome.recordCount, batches: outcome.batchCount)
        }
        return outcome
    }

    /// Maps the BLE layer's finish reason onto the domain's.
    ///
    /// `nil` — a session that ended without recording why — becomes `.aborted`, which is the only
    /// ending that claims nothing about the strap.
    private static func ending(
        for reason: HistoricalDrainSession.FinishReason?
    ) -> HistoricalSyncOutcome.Ending {
        switch reason {
        case .complete: return .strapReportedComplete
        case .liveEdge: return .caughtUpToLiveEdge
        case .idleTimeout: return .idleTimeout
        case .aborted, nil: return .aborted
        }
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
