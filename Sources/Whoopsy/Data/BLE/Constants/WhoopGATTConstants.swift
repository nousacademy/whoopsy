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
    //
    // The base half `8D6D-82B8-614A-1C8CB0F8DCC6` is the one every independent reference client uses
    // (noop's Swift, Kotlin and Python clients, OpenStrap, atria, Whoopless, WhoopBLE). It is not a
    // detail to re-derive: a wrong service UUID advertises nothing this app filters on, so it
    // presents as **no device found** rather than as a decode error, and no assertion downstream of
    // discovery can see it. §1 of the suite pins these against the reference literals for that
    // reason. `docs/BLE_PROTOCOL.md` §1 carries the provenance.
    /// Primary custom service UUID for WHOOP 4.0
    public static var whoop4ServiceUUID: CBUUID { CBUUID(string: "61080001-8D6D-82B8-614A-1C8CB0F8DCC6") }
    /// Command write (client → strap)
    public static var whoop4CommandUUID: CBUUID { CBUUID(string: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6") }
    /// Command responses (strap → client)
    public static var whoop4ResponseUUID: CBUUID { CBUUID(string: "61080003-8D6D-82B8-614A-1C8CB0F8DCC6") }
    /// Events notification — wear state, battery, tap
    public static var whoop4EventsUUID: CBUUID { CBUUID(string: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6") }
    /// Raw sensor data stream
    public static var whoop4DataStreamUUID: CBUUID { CBUUID(string: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6") }
    /// Memfault diagnostics.
    ///
    /// **The characteristic number is unattested** — no reference in hand carries a `…0006` or
    /// `…0007` on this base, so only the base half above is sourced and the role is this project's
    /// own note. Nothing consumes this constant; it is kept because `docs/BLE_PROTOCOL.md` §1's
    /// characteristic map lists the role. Delete it if nothing ever does.
    public static var whoop4MemfaultDiagnosticsUUID: CBUUID { CBUUID(string: "61080007-8D6D-82B8-614A-1C8CB0F8DCC6") }

    // MARK: - Proprietary WHOOP 5.0 / MG Service & Characteristics
    /// Primary custom service UUID for WHOOP 5.0 / Medical Grade (MG)
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
