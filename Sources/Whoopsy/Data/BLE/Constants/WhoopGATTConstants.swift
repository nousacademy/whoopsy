import Foundation
import CoreBluetooth

/// GATT UUIDs for WHOOP® 4.0, WHOOP® 5.0/MG, and standard Bluetooth SIG profiles.
public enum WhoopGATTConstants: Sendable {
    // MARK: - Standard Bluetooth SIG Profiles
    /// Standard Heart Rate Service
    public static var heartRateServiceUUID: CBUUID { CBUUID(string: "180D") }
    /// Standard Heart Rate Measurement Characteristic (Live BPM + R-R)
    public static var heartRateMeasurementCharacteristicUUID: CBUUID { CBUUID(string: "2A37") }
    
    /// Standard Battery Service
    public static var batteryServiceUUID: CBUUID { CBUUID(string: "180F") }
    /// Standard Battery Level Characteristic (0-100%)
    public static var batteryLevelCharacteristicUUID: CBUUID { CBUUID(string: "2A19") }
    
    /// Standard Device Information Service
    public static var deviceInformationServiceUUID: CBUUID { CBUUID(string: "180A") }
    public static var manufacturerNameUUID: CBUUID { CBUUID(string: "2A29") }
    public static var modelNumberUUID: CBUUID { CBUUID(string: "2A24") }
    public static var firmwareRevisionUUID: CBUUID { CBUUID(string: "2A26") }
    public static var serialNumberUUID: CBUUID { CBUUID(string: "2A25") }

    // MARK: - Proprietary WHOOP 4.0 Service & Characteristics
    /// Primary custom service UUID for WHOOP 4.0
    public static var whoop4ServiceUUID: CBUUID { CBUUID(string: "61080001-8D6D-82A5-4E40-1CA360B95B30") }
    public static var whoop4CommandUUID: CBUUID { CBUUID(string: "61080002-8D6D-82A5-4E40-1CA360B95B30") }
    public static var whoop4ResponseUUID: CBUUID { CBUUID(string: "61080003-8D6D-82A5-4E40-1CA360B95B30") }
    public static var whoop4EventsUUID: CBUUID { CBUUID(string: "61080004-8D6D-82A5-4E40-1CA360B95B30") }
    public static var whoop4DataStreamUUID: CBUUID { CBUUID(string: "61080005-8D6D-82A5-4E40-1CA360B95B30") }
    public static var whoop4MemfaultDiagnosticsUUID: CBUUID { CBUUID(string: "61080007-8D6D-82A5-4E40-1CA360B95B30") }

    // MARK: - Proprietary WHOOP 5.0 / MG Service & Characteristics
    /// Primary custom service UUID for WHOOP 5.0 / Member Gift (MG)
    public static var whoop5ServiceUUID: CBUUID { CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A") }
    public static var whoop5CommandUUID: CBUUID { CBUUID(string: "FD4B0002-CCE1-4033-93CE-002D5875F58A") }
    public static var whoop5ResponseUUID: CBUUID { CBUUID(string: "FD4B0003-CCE1-4033-93CE-002D5875F58A") }
    public static var whoop5EventsUUID: CBUUID { CBUUID(string: "FD4B0004-CCE1-4033-93CE-002D5875F58A") }
    public static var whoop5DataStreamUUID: CBUUID { CBUUID(string: "FD4B0005-CCE1-4033-93CE-002D5875F58A") }

    /// List of all scannable primary service UUIDs
    public static var scannableServiceUUIDs: [CBUUID] {
        [
            whoop4ServiceUUID,
            whoop5ServiceUUID,
            heartRateServiceUUID
        ]
    }
}
