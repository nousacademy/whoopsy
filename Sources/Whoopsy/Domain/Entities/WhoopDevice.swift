import Foundation

public enum WhoopHardwareGeneration: String, CaseIterable, Sendable {
    case whoop4 = "WHOOP 4.0"
    case whoop5 = "WHOOP 5.0 / MG"
    case standardBleHR = "Standard BLE Heart Rate"
    case simulator = "Whoop Simulator"
}

public enum WhoopConnectionState: String, Sendable {
    case disconnected = "Disconnected"
    case scanning = "Scanning"
    case connecting = "Connecting"
    case connected = "Connected"
    case syncing = "Syncing History"
    case error = "Error"
}

/// Metadata and real-time connection status for a WHOOP strap.
public struct WhoopDevice: Identifiable, Equatable, Sendable {
    public let id: String // Peripheral UUID string
    public let name: String
    public let hardwareGeneration: WhoopHardwareGeneration
    public let batteryPercentage: Int
    public let connectionState: WhoopConnectionState
    public let isOnBody: Bool
    public let isCharging: Bool
    public let firmwareVersion: String?
    public let serialNumber: String?
    public let signalStrengthRssi: Int?
    public let lastSyncTime: Date?

    public init(
        id: String,
        name: String = "WHOOP Strap",
        hardwareGeneration: WhoopHardwareGeneration = .whoop4,
        batteryPercentage: Int = 100,
        connectionState: WhoopConnectionState = .disconnected,
        isOnBody: Bool = true,
        isCharging: Bool = false,
        firmwareVersion: String? = "41.14.2.0",
        serialNumber: String? = nil,
        signalStrengthRssi: Int? = -65,
        lastSyncTime: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hardwareGeneration = hardwareGeneration
        self.batteryPercentage = max(0, min(100, batteryPercentage))
        self.connectionState = connectionState
        self.isOnBody = isOnBody
        self.isCharging = isCharging
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.signalStrengthRssi = signalStrengthRssi
        self.lastSyncTime = lastSyncTime
    }
}
