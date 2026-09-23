import Foundation
import GRDB

public final class GRDBStrainRepository: StrainRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// A day the strap did not record has no strain — `nil`, not a substituted score.
    public func getStrain(for date: Date) async throws -> StrainScore? {
        try await db.getStrain(for: date).map(Self.makeScore)
    }

    public func saveStrain(_ strain: StrainScore, source: String?) async throws {
        let record = StrainRecord(
            date: strain.date,
            strainScore: strain.score,
            // The column is joules and the entity is kilocalories, so the conversion belongs here
            // rather than in either side's units. Writing `0.0` — which is what this did — silently
            // discarded the value, so every reader saw a day that burned nothing.
            kilojoules: strain.activeCalories * Self.kilojoulesPerKilocalorie,
            averageHeartRate: strain.averageHeartRate,
            maxHeartRate: strain.maxHeartRate,
            hasMeasurement: strain.hasMeasurement,
            source: source
        )
        try await db.saveStrain(record)
    }

    public func getStrainHistory(days: Int, endingOn: Date) async throws -> [StrainScore] {
        try await db.getStrainHistory(days: days, endingOn: endingOn).map(Self.makeScore)
    }

    /// `rawAccumulatedLoad` and `zones` have no columns and never did, so they come back at their
    /// defaults. That is honest for the load figure, but it means a `StrainScore` read from disk
    /// knows nothing about heart-rate zones — see `StrainDashboardView`, which must say so rather
    /// than render a stand-in.
    private static func makeScore(from record: StrainRecord) -> StrainScore {
        StrainScore(
            date: record.date,
            score: record.strainScore,
            // Read, not re-derived. `record.strainScore > 0` is the tempting shortcut and it is
            // wrong: a measured rest day is a real `0.0`, and the column is the only record of
            // which kind of zero this row holds.
            hasMeasurement: record.hasMeasurement,
            activeCalories: record.kilojoules / kilojoulesPerKilocalorie,
            averageHeartRate: record.averageHeartRate,
            maxHeartRate: record.maxHeartRate
        )
    }

    /// Thermochemical conversion, kcal → kJ. It is the standard constant and **not** something
    /// `StrainAccumulatorMath.estimateCalories` supplies: that function returns kilocalories and names
    /// no conversion (it used to claim one in a comment that was untrue of its own body). The
    /// conversion lives here because this is the boundary where the entity's unit and the column's
    /// unit differ.
    private static let kilojoulesPerKilocalorie = 4.184
}
