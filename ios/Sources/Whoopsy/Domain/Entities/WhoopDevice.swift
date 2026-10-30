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

    /// The model's name **on a screen**, which is a different thing from its raw value.
    ///
    /// **The raw value is the storage key** — `UserDefaultsStrapModelRepository` persists the chosen
    /// model as `rawValue` — so it keeps its shipped spelling even where that spelled a brand. This is
    /// what a view draws: the model alone, with the make implied by the app.
    public var displayName: String {
        switch self {
        case .whoop4: return "4.0"
        case .whoop5: return "5.0"
        case .whoop5MG: return "5.0 MG"
        case .standardBleHR: return "Standard BLE Heart Rate"
        case .simulator: return "Strap Simulator"
        }
    }

    /// The model a strap's own Device Information Service reports, or `nil` when the string names
    /// none of them.
    ///
    /// **This is hardware evidence, and it is better than the advertised name in both directions.**
    /// The name is whatever the owner called the strap — *"Alex WHOOP"* has no digit in it at all, so
    /// the heuristic called a 5.0 a 4.0 — and it cannot distinguish the MG, because the two advertise
    /// the same way. `0x2A24` is written by the strap and read from it: a 5.0 answers `5.0` (measured
    /// on this project's own strap on 2026-10-25, alongside `WG50_r52` for the hardware revision and
    /// `50.42.1.0` for the firmware), and the MG's own string is expected to carry `MG`.
    ///
    /// **`MG` is tested before the digits**, because `5.0 MG` contains both and the digits would
    /// otherwise answer 5.0 — the one distinction the service list cannot make and this string can.
    /// A model string this build does not recognise returns `nil` rather than a guess, which leaves
    /// the caller's precedence to the rungs below it.
    public static func from(modelNumber: String) -> WhoopHardwareGeneration? {
        let text = modelNumber.uppercased()
        if text.contains("MG") { return .whoop5MG }
        if text.contains("4") { return .whoop4 }
        if text.contains("5") { return .whoop5 }
        return nil
    }

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

    /// The name the **strap** says it has stored, or `nil` before it has been asked.
    ///
    /// Different from `name`, which is what the peripheral advertises — and that can be CoreBluetooth's
    /// cached copy of an older advertisement. This one comes from `GET_ADVERTISING_NAME` and is the
    /// only value a rename can be checked against.
    public let advertisingName: String?
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
        serialNumber: String? = nil,
        advertisingName: String? = nil,
        connectionState: WhoopConnectionState? = nil
    ) -> WhoopDevice {
        WhoopDevice(
            id: id,
            name: name,
            hardwareGeneration: hardwareGeneration,
            batteryPercentage: batteryPercentage ?? self.batteryPercentage,
            // A battery value handed in through `updating` is the one place a real read arrives, so
            // it is what marks the figure measured. Nothing else may.
            batteryIsMeasured: batteryPercentage != nil ? true : self.batteryIsMeasured,
            // **`connectionState` is for the manager's link transitions and is never passed by a
            // notification.** A battery read cannot change whether the strap is linked, and a
            // notification allowed to set this would let a stale field decide the dot's colour.
            connectionState: connectionState ?? self.connectionState,
            isOnBody: isOnBody ?? self.isOnBody,
            isCharging: isCharging ?? self.isCharging,
            firmwareVersion: firmwareVersion ?? self.firmwareVersion,
            serialNumber: serialNumber ?? self.serialNumber,
            advertisingName: advertisingName ?? self.advertisingName,
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
        advertisingName: String? = nil,
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
        self.advertisingName = advertisingName
        self.signalStrengthRssi = signalStrengthRssi
        self.lastSyncTime = lastSyncTime
    }
}
