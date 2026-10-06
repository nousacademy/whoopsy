import Foundation

/// One day of `stepCounts` in the shape the sync moves — a record, not an entity.
///
/// **The shortest row in this family, and the shortness is a fact about the table.** `stepCounts` has
/// three columns and no `source`, so there is no provenance to carry and nothing nullable to spell as
/// `null` rather than as an absent key. It is `StrainSyncRow` with two fields missing: a day holds one
/// count, keyed on its date, and there are no children and no second ordering key.
///
/// **The property names are `StepCountRecord`'s own.** That record declares no `CodingKeys`, so its
/// property names *are* its column names — `stepCount` and `measuredSeconds` are camelCase in SQLite
/// and camelCase on the wire, which makes this the one resource whose three namespaces collapse to two.
///
/// **`measuredSeconds` is the whole of the absence rule and it is not decoration.** `StepCount`'s
/// `hasMeasurement` is `measuredSeconds > 0`, applied on both sides of the write, so a row carrying
/// `0` here is a day the app counted nothing on — and `StepCountWireMapper.isSendable` refuses exactly
/// that row rather than sending a `0` the server would store as a measurement of no steps. The column
/// exists so the absence is visible; this type carries it so the sync can act on it.
public struct StepCountSyncRow: Equatable, Sendable {

    /// The day, snapped to `startOfDay`. This table is keyed on it: a day holds one count.
    public let date: Date

    /// Steps recorded that day. `0` beside a positive `measuredSeconds` is a real measurement of a day
    /// spent sitting down, and it is a different fact from a day nothing measured.
    public let stepCount: Int

    /// Seconds of sample time the count came from. `0` is what makes the row unmeasured.
    public let measuredSeconds: Double

    public init(date: Date, stepCount: Int, measuredSeconds: Double) {
        self.date = date
        self.stepCount = stepCount
        self.measuredSeconds = measuredSeconds
    }
}
