import Foundation

/// Which strap a device is — and, for the two the app can address by name, which model the user says
/// they own.
///
/// **5.0 and 5.0 MG are separate cases on purpose.** They were one (`"WHOOP 5.0 / MG"`) while nothing
/// read the distinction, but the user owns both and `docs/BLE_PROTOCOL.md` §7 lists as an open question
/// whether the two agree with each other on the wire — so collapsing them would make the one choice
/// that matters unrepresentable. `selectableModels` is what a picker offers; `allCases` is not, since
/// it also holds the two non-strap transports.
public enum WhoopHardwareGeneration: String, CaseIterable, Identifiable, Sendable {
    case whoop4 = "WHOOP 4.0"
    case whoop5 = "WHOOP 5.0"
    case whoop5MG = "WHOOP 5.0 MG"
    case standardBleHR = "Standard BLE Heart Rate"
    case simulator = "Whoop Simulator"

    public var id: String { rawValue }

    /// The models a user may assign to a strap.
    ///
    /// Derived from the cases rather than listed beside them, so a model added to the enum is a
    /// decision about whether it is selectable rather than a silent omission from the picker.
    public static var selectableModels: [WhoopHardwareGeneration] {
        [.whoop4, .whoop5, .whoop5MG]
    }
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

    /// Whether `batteryPercentage` came off the strap's `0x2A19` or is the literal `100`.
    ///
    /// **This is the flag that stops a fabricated figure reaching the badge.** The percentage is not
    /// optional and discovery writes `100`, so a connected strap that has never answered a battery
    /// read was drawing a confident `100%` — measured on 2026-10-21, the owner read it as "the app
    /// says 100% when it is not connected" and the truth was worse: it said `100%` while connected
    /// and never having read the battery. `batteryReading` gates on this as well as on the link, so
    /// the badge draws no figure until a real value arrives.
    public let batteryIsMeasured: Bool
    public let connectionState: WhoopConnectionState
    public let isOnBody: Bool
    public let isCharging: Bool
    public let firmwareVersion: String?
    public let serialNumber: String?
    public let signalStrengthRssi: Int?
    public let lastSyncTime: Date?

    /// A copy with some fields replaced — **the only safe way to change one field on a device.**
    ///
    /// Constructing a fresh `WhoopDevice` instead applies every default, which silently resets firmware,
    /// serial, RSSI and last-sync: a battery notification would then erase the DIS values the strap
    /// just reported, and the screen would show the loss as "not read yet". A `nil` argument keeps the
    /// current value, so this cannot clear an optional field — no producer here needs to, and an empty
    /// DIS string is rejected before it reaches this function.
    public func updating(
        batteryPercentage: Int? = nil,
        isOnBody: Bool? = nil,
        isCharging: Bool? = nil,
        firmwareVersion: String? = nil,
        serialNumber: String? = nil
    ) -> WhoopDevice {
        WhoopDevice(
            id: id,
            name: name,
            hardwareGeneration: hardwareGeneration,
            batteryPercentage: batteryPercentage ?? self.batteryPercentage,
            // A battery value handed in through `updating` is the one place a real read arrives, so
            // it is what marks the figure measured. Nothing else may.
            batteryIsMeasured: batteryPercentage != nil ? true : self.batteryIsMeasured,
            connectionState: connectionState,
            isOnBody: isOnBody ?? self.isOnBody,
            isCharging: isCharging ?? self.isCharging,
            firmwareVersion: firmwareVersion ?? self.firmwareVersion,
            serialNumber: serialNumber ?? self.serialNumber,
            signalStrengthRssi: signalStrengthRssi,
            lastSyncTime: lastSyncTime)
    }

    public init(
        id: String,
        name: String = "WHOOP Strap",
        hardwareGeneration: WhoopHardwareGeneration = .whoop4,
        batteryPercentage: Int = 100,
        batteryIsMeasured: Bool = false,
        connectionState: WhoopConnectionState = .disconnected,
        isOnBody: Bool = true,
        isCharging: Bool = false,
        firmwareVersion: String? = nil,
        serialNumber: String? = nil,
        signalStrengthRssi: Int? = -65,
        lastSyncTime: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hardwareGeneration = hardwareGeneration
        self.batteryPercentage = max(0, min(100, batteryPercentage))
        self.batteryIsMeasured = batteryIsMeasured
        self.connectionState = connectionState
        self.isOnBody = isOnBody
        self.isCharging = isCharging
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.signalStrengthRssi = signalStrengthRssi
        self.lastSyncTime = lastSyncTime
    }
}
