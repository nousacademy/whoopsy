import Foundation
import Whoopsy

// MARK: - 16. Event 29 — the strap's own backlog report

/// The block that answers "how much history does this strap actually hold?" without wearing it for a
/// fortnight.
///
/// **What it pins is an offset agreement, not a measurement.** `STRAP_CONDITION_REPORT` is a reported
/// layout — one reference describes it and no capture here has confirmed it — so the assertions below
/// fix which byte means which, and the type itself stays a log line rather than a figure a screen
/// draws. The one thing they *do* prove against another decoder: `StrapConditionReport` and
/// `StrapEventDecoder` read the same header, so the body offset cannot drift away from the timestamp
/// offset while both keep compiling.
enum StrapConditionReportTests {
    static func run() async throws {
        func writeUInt32(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt32) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8((value >> 8) & 0xFF)
            frame[frameOffset + 2] = UInt8((value >> 16) & 0xFF)
            frame[frameOffset + 3] = UInt8((value >> 24) & 0xFF)
        }
        func writeUInt16(_ frame: inout [UInt8], frameOffset: Int, _ value: UInt16) {
            frame[frameOffset] = UInt8(value & 0xFF)
            frame[frameOffset + 1] = UInt8((value >> 8) & 0xFF)
        }

        /// A 5.0 event 29: the number at frame 10 (`inner[2]`), the unix at frame 12 (payload 1), the
        /// declared body length at frame 18 (payload 7), and the eleven-byte body at frame 20
        /// (payload 9). The payload is `9 + 11 = 20` bytes, which is the shortest a real one can be.
        func conditionReport(
            pages: UInt32 = 4321,
            backlogTenths: UInt16 = 456,
            socTenths: UInt16 = 872,
            flash: UInt8 = 3,
            charging: UInt8 = 1,
            wrist: UInt8 = 2,
            declaredBody: UInt16 = 11,
            payloadBytes: Int = 20
        ) -> [UInt8] {
            var frame = StepTests.fiveFrame(
                type: WhoopProtocolProfile.whoop5.packetTypes.event, payloadBytes: payloadBytes)
            frame[10] = StrapConditionReport.eventNumber
            writeUInt32(&frame, frameOffset: 12, 1_786_000_123)
            writeUInt16(&frame, frameOffset: 18, declaredBody)
            // Frame 20 is payload 9: the 5.0 payload origin is frame 11, and the body starts nine
            // bytes into it. Written only when the caller asked for a payload that can hold it.
            let body = 11 + StrapConditionReport.bodyOffset
            if payloadBytes >= StrapConditionReport.bodyOffset + StrapConditionReport.bodyBytes {
                writeUInt32(&frame, frameOffset: body, pages)
                writeUInt16(&frame, frameOffset: body + 4, backlogTenths)
                writeUInt16(&frame, frameOffset: body + 6, socTenths)
                frame[body + 8] = flash
                frame[body + 9] = charging
                frame[body + 10] = wrist
            }
            StepTests.sealFive(&frame)
            return frame
        }

        assertTest(
            StrapConditionReport.eventNumber == 29
                && StrapConditionReport.bodyOffset == 9
                && StrapConditionReport.bodyBytes == 11,
            "Event 29's body is **eleven bytes at payload 9**: three bytes of event header sit inside "
                + "the payload before it, which is why the body offset is not zero and why a reader "
                + "starting at payload 0 decodes the timestamp's low byte as a page backlog")

        let decoded = decoder.decodeProprietaryFrame(
            data: Data(conditionReport()), profile: .whoop5)
            .flatMap { StrapConditionReport.decode($0) }
        assertTest(
            decoded == StrapConditionReport(
                pageBacklog: 4321,
                backlogHours: 45.6,
                batteryPercentage: 87.2,
                flashState: 3,
                isCharging: true,
                wristState: 2),
            "…and it decodes to the reference's worked example: 4321 pages, **45.6 h** of backlog, "
                + "87.2 % charge, charging, wrist state 2 "
                + "(\(decoded.map { "\($0.pageBacklog) pages, \($0.backlogHours) h" } ?? "nil"))")

        let event = decoder.decodeProprietaryFrame(
            data: Data(conditionReport()), profile: .whoop5)
            .flatMap { StrapEventDecoder.decode(frame: $0) }
        assertTest(
            event?.rawEvent == 29
                && event?.timestamp == Date(timeIntervalSince1970: 1_786_000_123),
            "The two decoders read **one header**: the same frame yields event 29 with the unix from "
                + "payload 1, which is the offset agreement that keeps the body's start from drifting")

        let short = decoder.decodeProprietaryFrame(
            data: Data(conditionReport(payloadBytes: 19)), profile: .whoop5)
            .flatMap { StrapConditionReport.decode($0) }
        assertTest(
            short == nil,
            "A payload one byte short of the body is refused rather than read off its end")

        let wrongLength = decoder.decodeProprietaryFrame(
            data: Data(conditionReport(declaredBody: 5)), profile: .whoop5)
            .flatMap { StrapConditionReport.decode($0) }
        assertTest(
            wrongLength == nil,
            "…and so is a declared body of five bytes: a number that cannot hold eleven means this is "
                + "some other event wearing the same identifier")

        var four = StepTests.fourFrame(
            type: WhoopProtocolProfile.whoop4.packetTypes.event, payloadBytes: 20)
        four[6] = StrapConditionReport.eventNumber
        StepTests.sealFour(&four)
        let fourDecoded = decoder.decodeProprietaryFrame(data: Data(four), profile: .whoop4)
            .flatMap { StrapConditionReport.decode($0) }
        assertTest(
            fourDecoded == nil,
            "**The 4.0 is refused**, not decoded with different offsets: the reference scopes this body "
                + "to the 5.0/MG, and the same event number on the older envelope carries a shape "
                + "nobody has published")
    }
}
