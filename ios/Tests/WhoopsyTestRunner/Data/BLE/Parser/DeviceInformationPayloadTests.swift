import Foundation
import CoreBluetooth
import Whoopsy

// MARK: - 16. The Device Information Service strings

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved verbatim.
/// `StepTests.run()` calls it after `StrapEventDecoderTests`, because it is the last of the frame
/// walks and the only one that produces a string rather than a sample.
///
/// **What it proves is the two decisions the parser makes, because both are silent when wrong.** The
/// UUID → field mapping is what routes `2A26` to `firmwareVersion` and `2A25` to `serialNumber`, and a
/// transposed pair would store the serial as the firmware — plausible text in the wrong slot, which no
/// screen would question. The trim is what keeps a NUL-padded read from drawing a blank, because a
/// printed `""` is indistinguishable from a value that has not been read.
enum DeviceInformationPayloadTests {
    static func run() async throws {
        let pairs: [(CBUUID, DeviceInformationField)] = [
            (WhoopGATTConstants.modelNumberUUID, .model),
            (WhoopGATTConstants.serialNumberUUID, .serial),
            (WhoopGATTConstants.firmwareRevisionUUID, .firmware),
            (WhoopGATTConstants.hardwareRevisionUUID, .hardwareRevision),
            (WhoopGATTConstants.manufacturerNameUUID, .manufacturer),
        ]
        for (uuid, expected) in pairs {
            assertTest(
                DeviceInformationField(uuid: uuid) == expected,
                "DIS \(uuid.uuidString) maps to \(expected) — one field per standard characteristic, and "
                    + "the two that reach `WhoopDevice` are `2A26` firmware and `2A25` serial")
        }
        assertTest(
            DeviceInformationField(uuid: WhoopGATTConstants.batteryLevelCharacteristicUUID) == nil
                && DeviceInformationField(uuid: WhoopGATTConstants.heartRateMeasurementCharacteristicUUID) == nil,
            "…and a characteristic outside the service maps to nothing: the manager's branch tests this "
                + "rather than the service alone, so a battery read cannot be parsed as a DIS string")
        assertTest(
            Set(WhoopGATTConstants.deviceInformationCharacteristicUUIDs).count == 5
                && Set(WhoopGATTConstants.deviceInformationCharacteristicUUIDs)
                    == Set(pairs.map(\.0)),
            "The read list holds exactly the five characteristics this parser names, so discovery, the "
                + "read pass and the decode cannot disagree about the set")

        assertTest(
            DeviceInformationPayload.text(from: Data("41.14.2.0".utf8)) == "41.14.2.0",
            "A plain UTF-8 string is returned unchanged")
        assertTest(
            DeviceInformationPayload.text(from: Data([0x34, 0x31, 0x00, 0x00, 0x00])) == "41",
            "A fixed-width read padded with NULs is trimmed to the text: the padding is part of the "
                + "decode, not cosmetic, because a stored `\"41\\0\\0\\0\"` is not a version any screen "
                + "can compare")
        assertTest(
            DeviceInformationPayload.text(from: Data("  S1234567  \n".utf8)) == "S1234567",
            "…and so is surrounding whitespace, which a strap may pad a serial with rather than NULs")
        assertTest(
            DeviceInformationPayload.text(from: Data([0x00, 0x00])) == nil
                && DeviceInformationPayload.text(from: Data()) == nil,
            "An all-padding or empty read is `nil`, not `\"\"`: an empty serial is an absent one, and "
                + "storing the empty string would let the page print a blank where its dash belongs")
        assertTest(
            DeviceInformationPayload.text(from: Data([0xFF, 0xFE, 0xFD])) == nil,
            "Invalid UTF-8 is refused rather than replaced: a string with substitution characters is not "
                + "what the strap sent, and storing it would make the loss invisible")
    }
}
