import Foundation

/// One night of `sleeps` in the shape the sync moves — a record, not an entity.
///
/// **`StrainSyncRow`'s sibling, with one field the two flat resources beside it have no counterpart
/// for.** A night is one row keyed on its day, so there are no children and no ordering to preserve;
/// what it does carry is `sleepStages`, which is a `[SleepStageSegment]?` here and an **opaque JSON
/// string** on the wire. That conversion is the only structural thing this resource adds, and it lives
/// in `SleepWireMapper` rather than here for the reason every other conversion does: a row takes the
/// *record's* own property names, so a type that spelled the timeline as a `String` would put the same
/// mapping in two places.
///
/// **The property names are `SleepRecord`'s own**, verbatim — which matters more on this resource than
/// on `recoveries`, because `sleeps` is the table whose columns are snake_case (`start_time`,
/// `sleep_performance`, `total_sleep_needed`) while the record's properties are camelCase. The row sits
/// on the record's side of that seam, so row ↔ record is a field-for-field copy and
/// `SleepWireMapper` is the one place a wire name is written down.
///
/// **The four nullables are four different absences and none of them is a zero.** `respiratoryRate` is
/// derived from the R-R series and does not exist for every night; `disturbanceCount` exists only for a
/// night the actigraphy classifier could read; `sleepConsistency` needs four priors and is also absent
/// on any row written before `v9`; `sleepDebt` is WHOOP's own accumulation and is absent on every strap
/// night. A `0` in any of the four is a claim — a night nobody stirred, a night in perfect credit — so
/// they ride the wire as `null` and are refused as `""` only for `source`, which is the one of the five
/// that is a string.
public struct SleepSyncRow: Equatable, Sendable {

    /// The night's **wake** day, snapped to `startOfDay`. This table is keyed on it.
    ///
    /// A nap's day is its onset and a night's is its wake — `naps` follows `workouts` rather than
    /// `sleeps` for exactly this reason, and it is why the wire's own `Sleep` schema says in as many
    /// words that the day is not derived from `startTime`.
    public let date: Date

    /// When the night began and ended. Both are instants, and the wire spells them canonically.
    public let startTime: Date
    public let endTime: Date

    /// Sleep performance as a whole-scale percentage — **this app's own figure**, not WHOOP's column.
    public let sleepPerformance: Double

    /// The night's requirement, in **seconds**.
    public let totalSleepNeeded: Double

    /// The three stages whose sum is the asleep total `sleepPerformance` divides, plus wakefulness
    /// within the night's own span. All four are seconds, and a `0` in any is a measurement.
    public let lightSleep: Double
    public let deepSleep: Double
    public let remSleep: Double
    public let awakeTime: Double

    /// Breaths per minute, or `nil` on a night the R-R series cannot support.
    public let respiratoryRate: Double?

    /// How many times the night was disturbed, or `nil` when nothing scored it.
    public let disturbanceCount: Int?

    /// WHOOP's own Sleep Consistency for the night, as a whole percent, or `nil` when not scored.
    public let sleepConsistency: Int?

    /// The accumulated deficit, in seconds, or `nil`.
    public let sleepDebt: Double?

    /// The night's stage timeline, or `nil` when it was never staged.
    ///
    /// The two absences the doc comment above records hold here as well: a night the strap classified
    /// has one, every imported night is `nil` and always will be — the export reports stage *totals* —
    /// and so is any row written before `v12`. It is deliberately **not** an empty array, which
    /// `GRDBSleepRepository.saveSleepSession` stores as `nil` for that reason: nothing staged and never
    /// staged are one thing and only one of them should have a representation.
    public let sleepStages: [SleepStageSegment]?

    /// Where the row came from — `whoop_export` for an imported night, `nil` for one this app scored.
    ///
    /// **It carries more weight on this resource than on any other**, because it is the only marker
    /// separating two producers of `sleepPerformance`, `sleepConsistency`, `sleepDebt` and
    /// `respiratoryRate`: a strap night's need is computed and an imported night's is WHOOP's own, and
    /// nothing else on the row tells them apart.
    public let source: String?

    public init(
        date: Date,
        startTime: Date,
        endTime: Date,
        sleepPerformance: Double,
        totalSleepNeeded: Double,
        lightSleep: Double,
        deepSleep: Double,
        remSleep: Double,
        awakeTime: Double,
        respiratoryRate: Double? = nil,
        disturbanceCount: Int? = nil,
        sleepConsistency: Int? = nil,
        sleepDebt: Double? = nil,
        sleepStages: [SleepStageSegment]? = nil,
        source: String? = nil
    ) {
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.sleepPerformance = sleepPerformance
        self.totalSleepNeeded = totalSleepNeeded
        self.lightSleep = lightSleep
        self.deepSleep = deepSleep
        self.remSleep = remSleep
        self.awakeTime = awakeTime
        self.respiratoryRate = respiratoryRate
        self.disturbanceCount = disturbanceCount
        self.sleepConsistency = sleepConsistency
        self.sleepDebt = sleepDebt
        self.sleepStages = sleepStages
        self.source = source
    }
}
