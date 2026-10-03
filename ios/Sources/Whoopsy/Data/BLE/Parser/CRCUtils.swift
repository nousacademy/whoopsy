import Foundation

/// Cyclic Redundancy Check (CRC) utilities for WHOOP packet framing.
public enum CRCUtils {
    /// Standard CRC-8 polynomial 0x07 (Dallas/Maxim 0x31 or standard 0x07)
    public static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0x00
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    /// CRC-16 Modbus (Polynomial 0xA001, Init 0xFFFF)
    public static func crc16Modbus(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// IEEE 802.3 standard CRC-32
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = (crc ^ UInt32(byte)) & 0xFF
            var cur = index
            for _ in 0..<8 {
                if (cur & 1) != 0 {
                    cur = (cur >> 1) ^ 0xEDB88320
                } else {
                    cur >>= 1
                }
            }
            crc = (crc >> 8) ^ cur
        }
        return crc ^ 0xFFFFFFFF
    }
}
