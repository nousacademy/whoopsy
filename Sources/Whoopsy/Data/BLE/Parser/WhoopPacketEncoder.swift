import Foundation

/// Binary packet encoder for constructing commands sent to the WHOOP strap.
public enum WhoopPacketEncoder {
    public static let startOfFrame: UInt8 = 0xAA

    /// Builds a framed command packet with CRC8 header and CRC32 payload checksum.
    public static func buildPacket(cmd: UInt8, payload: Data = Data()) -> Data {
        var frame = Data()
        frame.append(startOfFrame)
        frame.append(cmd)

        let length = UInt16(payload.count)
        let lengthLow = UInt8(length & 0xFF)
        let lengthHigh = UInt8((length >> 8) & 0xFF)

        // CRC8 computed over cmd + length bytes
        let headerData = Data([cmd, lengthLow, lengthHigh])
        let headerCrc = CRCUtils.crc8(headerData)

        frame.append(lengthLow)
        frame.append(headerCrc)

        if !payload.isEmpty {
            frame.append(payload)
            // CRC32 trailer (little endian)
            let payloadCrc = CRCUtils.crc32(payload)
            var crcLe = payloadCrc.littleEndian
            frame.append(Data(bytes: &crcLe, count: MemoryLayout<UInt32>.size))
        }

        return frame
    }

    /// Ping / Keep-alive packet
    public static func pingCommand() -> Data {
        buildPacket(cmd: 0x20)
    }

    /// Haptic vibration alert command
    public static func hapticAlarmCommand(durationSeconds: Int = 3, pattern: Int = 1) -> Data {
        var payload = Data()
        payload.append(UInt8(max(1, min(30, durationSeconds))))
        payload.append(UInt8(max(1, min(10, pattern))))
        return buildPacket(cmd: 0x10, payload: payload)
    }

    /// Real-time high-speed telemetry enable command
    public static func enableLiveTelemetry(enable: Bool = true) -> Data {
        return buildPacket(cmd: 0x05, payload: Data([enable ? 0x01 : 0x00]))
    }

    /// Flash buffer historical sync request
    public static func requestHistoricalSync(startEpoch: UInt32, endEpoch: UInt32) -> Data {
        var payload = Data()
        var s = startEpoch.littleEndian
        var e = endEpoch.littleEndian
        payload.append(Data(bytes: &s, count: 4))
        payload.append(Data(bytes: &e, count: 4))
        return buildPacket(cmd: 0x30, payload: payload)
    }
}
