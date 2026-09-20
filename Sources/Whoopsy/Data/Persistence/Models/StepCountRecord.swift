import Foundation
import GRDB

/// The `stepCounts` row.
///
/// **No `CodingKeys`, so the property names are the column names** — `StrainRecord`'s convention, not
/// `RecoveryRecord`'s. That means `stepCount` and `measuredSeconds` are camelCase columns, and the
/// `v13` migration has to declare them exactly so. Getting this backwards is the failure `CLAUDE.md`
/// records against `v7`: a migration writing `has_measurement` against a record that declares
/// `hasMeasurement` produced `no such column` at launch, and a failing migration `fatalError`s.
///
/// `date` is the primary key. A day holds one step count, so this is the `strains` shape rather than
/// the `workouts` shape — there is no second row per day to preserve.
public struct StepCountRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "stepCounts"

    public var date: Date
    public var stepCount: Int

    /// Seconds of sample time the count came from. See `StepCount.measuredSeconds` — a `0` here is
    /// what makes the row unmeasured, and it is the column the absence rule reads.
    public var measuredSeconds: Double

    public init(date: Date, stepCount: Int, measuredSeconds: Double) {
        self.date = date
        self.stepCount = stepCount
        self.measuredSeconds = measuredSeconds
    }
}
