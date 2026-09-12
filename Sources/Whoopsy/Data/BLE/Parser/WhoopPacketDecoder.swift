import Foundation

public enum DecodedPacketPayload: Sendable {
    case liveBiometric(BiometricSample)
    case batteryStatus(batteryPercent: Int, isCharging: Bool, isOnBody: Bool)
    case historicalBatch([BiometricSample])
    case rawData(cmd: UInt8, payload: Data)
}

/// Robust binary packet decoder for WHOOP proprietary 0xAA frames & standard BLE SIG GATT packets.
public final class WhoopPacketDecoder: Sendable {
    public static let startOfFrame: UInt8 = 0xAA

    public init() {}

    /// Decodes standard Bluetooth SIG Heart Rate Measurement (Characteristic 0x2A37).
    public func decodeStandardHeartRate(data: Data) -> (heartRate: Int, rrIntervalsMs: [Double])? {
        guard !data.isEmpty else { return nil }

        let flags = data[0]
        let is16BitHR = (flags & 0x01) != 0
        let hasRRIntervals = (flags & 0x10) != 0

        var offset = 1
        let heartRate: Int
        if is16BitHR {
            guard data.count >= offset + 2 else { return nil }
            heartRate = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
        } else {
            guard data.count >= offset + 1 else { return nil }
            heartRate = Int(data[offset])
            offset += 1
        }

        // Check for energy expended field (bit 3)
        if (flags & 0x08) != 0 {
            offset += 2
        }

        var rrIntervals: [Double] = []
        if hasRRIntervals {
            while offset + 1 < data.count {
                let rawRR = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                let rrMs = (Double(rawRR) / 1024.0) * 1000.0
                rrIntervals.append(rrMs)
                offset += 2
            }
        }

        return (heartRate, rrIntervals)
    }

    /// Decodes proprietary 0xAA binary frames from WHOOP 4.0 / 5.0 data stream.
    public func decodeProprietaryFrame(data: Data) -> DecodedPacketPayload? {
        guard data.count >= 4 else { return nil }

        // 1. Verify Start of Frame
        guard data[0] == Self.startOfFrame else {
            AppLogger.decoder.debug("Invalid SOF byte: \(data[0], privacy: .public)")
            return nil
        }

        let cmd = data[1]
        let lengthLow = UInt16(data[2])
        _ = data[3]
        
        // Frame payload length
        let payloadLength = Int(lengthLow)

        // Minimum frame size = 4-byte header + payload
        let headerSize = 4
        guard data.count >= headerSize + payloadLength else {
            AppLogger.decoder.debug("Frame truncated: expected \(payloadLength) payload bytes, got \(data.count - headerSize)")
            return nil
        }

        let payloadData = data.subdata(in: headerSize..<(headerSize + payloadLength))

        switch cmd {
        case 0x01: // Live Telemetry Sample
            return decodeLiveTelemetryPayload(payloadData)

        case 0x02, 0x20: // Battery / Strap Status
            return decodeBatteryStatusPayload(payloadData)

        case 0x30: // Historical sync block
            return decodeHistoricalSyncPayload(payloadData)

        default:
            return .rawData(cmd: cmd, payload: payloadData)
        }
    }

    private func decodeLiveTelemetryPayload(_ payload: Data) -> DecodedPacketPayload? {
        guard payload.count >= 16 else { return nil }

        let hr = Int(payload[4])
        let rawRR = UInt16(payload[5]) | (UInt16(payload[6]) << 8)
        let rrMs: Double? = (rawRR > 0 && rawRR < 2500) ? Double(rawRR) : nil

        let rawAx = Int16(bitPattern: UInt16(payload[7]) | (UInt16(payload[8]) << 8))
        let rawAy = Int16(bitPattern: UInt16(payload[9]) | (UInt16(payload[10]) << 8))
        let rawAz = Int16(bitPattern: UInt16(payload[11]) | (UInt16(payload[12]) << 8))

        let ax = Double(rawAx) / 8192.0
        let ay = Double(rawAy) / 8192.0
        let az = Double(rawAz) / 8192.0

        let rawTemp = Int16(bitPattern: UInt16(payload[13]) | (UInt16(payload[14]) << 8))
        let tempC: Double? = (rawTemp > 2000 && rawTemp < 4500) ? Double(rawTemp) / 100.0 : nil

        let spo2Raw = payload[15]
        let spo2: Double? = (spo2Raw >= 70 && spo2Raw <= 100) ? Double(spo2Raw) : nil

        var onBody = true
        var isCharging = false
        if payload.count > 16 {
            let flags = payload[16]
            onBody = (flags & 0x01) != 0
            isCharging = (flags & 0x02) != 0
        }

        let sample = BiometricSample(
            timestamp: Date(),
            heartRate: hr,
            // The proprietary 0x01 payload carries exactly one interval, at `payload[5..6]`. It is
            // passed as a one-element series rather than as the scalar so that every producer writes
            // the canonical field, and `rrIntervalMs` stays what it is declared to be: derived.
            rrIntervalsMs: rrMs.map { [$0] },
            accelerometerX: ax,
            accelerometerY: ay,
            accelerometerZ: az,
            skinTemperatureCelsius: tempC,
            spO2Percentage: spo2,
            isOnBody: onBody,
            isCharging: isCharging
        )

        return .liveBiometric(sample)
    }

    private func decodeBatteryStatusPayload(_ payload: Data) -> DecodedPacketPayload? {
        guard !payload.isEmpty else { return nil }
        let battery = Int(payload[0])
        let isCharging = payload.count > 1 ? (payload[1] != 0) : false
        let onBody = payload.count > 2 ? (payload[2] != 0) : true

        return .batteryStatus(
            batteryPercent: max(0, min(100, battery)),
            isCharging: isCharging,
            isOnBody: onBody
        )
    }

    private func decodeHistoricalSyncPayload(_ payload: Data) -> DecodedPacketPayload? {
        var samples: [BiometricSample] = []
        let recordSize = 16
        var offset = 0

        while offset + recordSize <= payload.count {
            let chunk = payload.subdata(in: offset..<(offset + recordSize))
            if case .liveBiometric(let sample) = decodeLiveTelemetryPayload(chunk) {
                samples.append(sample)
            }
            offset += recordSize
        }

        return .historicalBatch(samples)
    }
}
