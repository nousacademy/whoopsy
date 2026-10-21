import Foundation
import CoreBluetooth

/// Which Device Information Service characteristic a read came from.
///
/// **The five standard fields, and only two of them have a home on `WhoopDevice`.** Firmware revision
/// fills `firmwareVersion` and serial number fills `serialNumber`; model, hardware revision and
/// manufacturer have no field and are log-only, because inventing one would put a display string where
/// the entity has no column. The enum exists so the manager's `switch` is over a named case rather than
/// five UUID literals.
public enum DeviceInformationField: String, Sendable, Equatable {
    case model
    case serial
    case firmware
    case hardwareRevision
    case manufacturer

    public init?(uuid: CBUUID) {
        switch uuid {
        case WhoopGATTConstants.modelNumberUUID: self = .model
        case WhoopGATTConstants.serialNumberUUID: self = .serial
        case WhoopGATTConstants.firmwareRevisionUUID: self = .firmware
        case WhoopGATTConstants.hardwareRevisionUUID: self = .hardwareRevision
        case WhoopGATTConstants.manufacturerNameUUID: self = .manufacturer
        default: return nil
        }
    }
}

/// Turns a DIS characteristic's bytes into the string the strap shipped.
///
/// **A DIS read is a UTF-8 string with no length prefix**, and straps have been seen to pad it with NULs
/// to a fixed width — so the trim is part of the decode rather than cosmetic. A value that is empty
/// after trimming returns `nil` rather than `""`: an empty serial is an absent one, and storing `""`
/// would let the device page print a blank where it should print a dash.
public enum DeviceInformationPayload {
    public static func text(from data: Data) -> String? {
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0")
            .union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }
}
