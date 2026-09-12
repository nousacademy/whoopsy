import XCTest
import Foundation
@testable import Whoopsy

final class CRCUtilsTests: XCTestCase {
    func testCRC8() {
        let data = Data([0x01, 0x10, 0x00])
        let crc = CRCUtils.crc8(data)
        XCTAssertGreaterThanOrEqual(crc, 0)
    }

    func testCRC16Modbus() {
        let data = Data([0xAA, 0x01, 0x04, 0x00])
        let crc = CRCUtils.crc16Modbus(data)
        XCTAssertNotEqual(crc, 0)
    }

    func testCRC32() {
        let data = "WHOOP4_TELEMETRY".data(using: .utf8)!
        let crc = CRCUtils.crc32(data)
        XCTAssertNotEqual(crc, 0)
    }
}
