import Foundation

public final class GRDBRecoveryRepository: RecoveryRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// No data for a day is `nil`, not a substituted row. A caller that cannot tell a stored
    /// measurement from a synthesised one will render the synthesised one as physiology.
    public func getRecovery(for date: Date) async throws -> RecoveryMetric? {
        try await db.getRecovery(for: date).map(Self.makeMetric)
    }

    public func saveRecovery(_ recovery: RecoveryMetric, source: String?) async throws {
        let record = RecoveryRecord(
            date: recovery.date,
            recoveryScore: recovery.score,
            restingHeartRate: recovery.restingHeartRate,
            hrvValueMs: recovery.hrvValueMs,
            hrvMetric: recovery.hrvMetric,
            skinTemp: recovery.skinTemperatureCelsius,
            spo2: recovery.spO2Percentage,
            respiratoryRate: recovery.respiratoryRate,
            source: source
        )
        try await db.saveRecovery(record)
    }

    /// The same local read as `getRecovery(for:)`, and kept as a distinct name because the two
    /// answer different questions — see the protocol. It exists so a caller about to write can say
    /// which one it means.
    public func getLocalRecovery(for date: Date) async throws -> RecoveryMetric? {
        try await db.getRecovery(for: date).map(Self.makeMetric)
    }

    public func getRecoveryHistory(days: Int, endingOn: Date) async throws -> [RecoveryMetric] {
        try await db.getRecoveryHistory(days: days, endingOn: endingOn).map(Self.makeMetric)
    }

    /// A reading the strap did not report stays absent. Substituting `0.0` here would tell the
    /// Recovery screen that skin temperature was 0 °C rather than that it was unknown.
    private static func makeMetric(from record: RecoveryRecord) -> RecoveryMetric {
        RecoveryMetric(
            date: record.date,
            score: record.recoveryScore,
            hrvValueMs: record.hrvValueMs,
            hrvMetric: record.hrvMetric,
            restingHeartRate: record.restingHeartRate,
            skinTemperatureCelsius: record.skinTemp,
            spO2Percentage: record.spo2,
            respiratoryRate: record.respiratoryRate
        )
    }
}
