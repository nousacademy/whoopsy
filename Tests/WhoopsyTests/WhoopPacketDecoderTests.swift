import XCTest
import Foundation
@testable import Whoopsy

final class WhoopPacketDecoderTests: XCTestCase {
    let decoder = WhoopPacketDecoder()

    func testDecodeStandardHeartRate() {
        // Flags: 0x10 (has RR intervals, 8-bit HR)
        // HR: 72 BPM
        // RR: 0x0350 (848 in 1/1024s -> ~828.1 ms)
        let rawData = Data([0x10, 72, 0x50, 0x03])
        let result = decoder.decodeStandardHeartRate(data: rawData)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.heartRate, 72)
        XCTAssertEqual(result?.rrIntervalsMs.count, 1)
        if let rr = result?.rrIntervalsMs.first {
            XCTAssertTrue(rr > 800 && rr < 850)
        }
    }

    func testDecodeProprietaryLiveTelemetry() {
        var frame = Data([0xAA, 0x01, 16, 0x00])
        let payload = Data([
            0xE8, 0x03, 0x00, 0x00, // timestamp 1000
            68,                     // HR
            0x72, 0x03,             // RR = 882ms
            0x00, 0x00,             // Ax
            0x00, 0x00,             // Ay
            0x00, 0x20,             // Az = 8192 (1.0g)
            0x42, 0x0E,             // Temp = 3650 (36.5C)
            98                      // SpO2
        ])
        frame.append(payload)

        let decoded = decoder.decodeProprietaryFrame(data: frame)
        XCTAssertNotNil(decoded)

        if case .liveBiometric(let sample) = decoded {
            XCTAssertEqual(sample.heartRate, 68)
            XCTAssertEqual(sample.rrIntervalMs, 882.0)
            XCTAssertEqual(sample.spO2Percentage, 98.0)
            XCTAssertEqual(sample.skinTemperatureCelsius, 36.5)
            XCTAssertEqual(sample.accelerometerZ, 1.0)
        } else {
            XCTFail("Expected .liveBiometric payload")
        }
    }

    func testPacketEncoder() {
        let packet = WhoopPacketEncoder.hapticAlarmCommand(durationSeconds: 3, pattern: 1)
        XCTAssertGreaterThanOrEqual(packet.count, 4)
        XCTAssertEqual(packet[0], 0xAA)
        XCTAssertEqual(packet[1], 0x10) // Alarm cmd
    }
}
