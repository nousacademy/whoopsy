import Foundation
import GRDB

public final class GRDBBiometricRepository: BiometricRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    public func saveSamples(_ samples: [BiometricSample]) async throws {
        let records = samples.map { sample in
            BiometricSampleRecord(
                timestamp: sample.timestamp,
                heartRate: sample.heartRate,
                rrIntervalsMs: sample.rrIntervalsMs,
                rrIntervalMs: sample.rrIntervalMs,
                accelX: sample.accelerometerX,
                accelY: sample.accelerometerY,
                accelZ: sample.accelerometerZ,
                skinTemp: sample.skinTemperatureCelsius,
                spo2Percentage: sample.spO2Percentage,
                isOnBody: sample.isOnBody,
                isCharging: sample.isCharging,
                rawSequenceNumber: sample.rawSequenceNumber
            )
        }
        try await db.saveSamples(records)
    }

    public func getSamples(from startDate: Date, to endDate: Date) async throws -> [BiometricSample] {
        let records = try await db.getSamples(from: startDate, to: endDate)
        return records.map(Self.makeSample)
    }

    public func getLatestSample() async throws -> BiometricSample? {
        guard let record = try await db.getLatestSample() else { return nil }
        return Self.makeSample(from: record)
    }

    /// Absent channels stay absent. Substituting a plausible default here (a 36.5 °C skin
    /// temperature, a `0` R-R interval, a `0` g accelerometer) puts invented data into the recovery
    /// and sleep math with no way downstream to tell it apart from a real reading — and the accel
    /// zero is the worst of the three, because it asserts the strap was motionless rather than
    /// merely being wrong about a value nothing reads.
    private static func makeSample(from record: BiometricSampleRecord) -> BiometricSample {
        BiometricSample(
            timestamp: record.timestamp,
            heartRate: record.heartRate,
            // `rrSeries` collapses the two columns into one answer, with the pre-`v8` scalar as the
            // fallback and an empty series as `nil` — the same absence the BLE layer already
            // collapses, so a row that captured nothing cannot read back as a row that captured an
            // empty list.
            rrIntervalsMs: record.rrSeries.isEmpty ? nil : record.rrSeries,
            accelerometerX: record.accelX,
            accelerometerY: record.accelY,
            accelerometerZ: record.accelZ,
            skinTemperatureCelsius: record.skinTemp,
            spO2Percentage: record.spo2Percentage,
            isOnBody: record.isOnBody ?? true,
            isCharging: record.isCharging ?? false,
            rawSequenceNumber: record.rawSequenceNumber
        )
    }

    public func clearAllBiometricData() async throws {
        try await db.clearAllSamples()
    }
}