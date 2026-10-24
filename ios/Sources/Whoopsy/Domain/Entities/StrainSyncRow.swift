import Foundation

/// One day of `strains` in the shape the sync moves — a record, not an entity.
///
/// **This is `RecoverySyncRow`'s sibling, and it is the flat resource's shape rather than the
/// aggregate's.** A strain is one row keyed on its day, so there are no children to ride inside it and
/// no ordering to preserve: the type is a flat list of fields, and `StrainSyncStore`'s read hands out
/// one per day in ascending order. `WorkoutSyncRow`'s whole second half — the aggregate, the two child
/// arrays and the `String`/`UUID` boundary — has no counterpart here.
///
/// **The property names are the record's own.** They are taken from `StrainRecord` verbatim, so
/// row ↔ record is a field-for-field copy and the one place a *wire* name is written down is
/// `StrainWireMapper`. That is the three-namespace rule this family of types exists for, and here the
/// two namespaces that differ are the wire's and the record's:
///
/// | Record / row (this type) | The wire | D1 |
/// | :--- | :--- | :--- |
/// | `strainScore` | `strainScore` | `strain_score` |
/// | `kilojoules` | `kilojoules` | `kilojoules` |
/// | `averageHeartRate` | `averageHeartRate` | `average_heart_rate` |
/// | `maxHeartRate` | `maxHeartRate` | `max_heart_rate` |
/// | `hasMeasurement` | `hasMeasurement` | `has_measurement` |
/// | `source` | `source` | `source` |
///
/// It is a smaller table than the recoveries one — no `hrvMetric`, no `spo2Percentage`, no units
/// suffix — but the rule is the same and it is not a style choice: the sync moves *records*, and a
/// type that renamed a field to match the wire would put the conversion in two places instead of one.
/// The `strains` table's own columns are **camelCase in local SQLite** (`StrainRecord` declares no
/// `CodingKeys`) and snake_case in D1, which is the same split one resource over, and this type sits
/// on the local side of it.
///
/// **`hasMeasurement` rides the wire and is never inferred.** It is what separates a measured day from
/// the placeholder shape an older build could leave behind, and the server stores it as a required
/// column — so an unmeasured row is a legitimate thing to sync, not a row to drop. A `kilojoules` of
/// `0` beside `hasMeasurement == true` is a real reading of no work done and must survive the trip
/// unchanged; the flag is the only thing that tells the two apart.
///
/// **`source` is the one nullable field, and it is deliberately not defaulted on the wire round trip.**
/// NULL is the honest value for a row written before the column existed — see the `source` gotcha —
/// and `StrainWireMapper.isSendable` is what refuses an *empty* one rather than storing a string
/// nobody supplied.
public struct StrainSyncRow: Equatable, Sendable {

    /// The day, snapped to `startOfDay`. This table is keyed on it: a day holds one strain.
    public let date: Date

    /// WHOOP's 0–21 strain scale.
    public let strainScore: Double

    /// Work done over the day, in kilojoules. `0` is a legitimate measured value.
    public let kilojoules: Double

    /// The day's average heart rate.
    public let averageHeartRate: Int

    /// The day's peak heart rate.
    public let maxHeartRate: Int

    /// Whether the day was measured at all, as opposed to a placeholder.
    ///
    /// Required and never inferred. The server's schema requires it too, which is what makes an
    /// unmeasured row a thing the sync carries rather than a thing it skips.
    public let hasMeasurement: Bool

    /// Where the row came from — `whoop_export` for an imported day, `device` for one this app scored.
    public let source: String?

    /// The formula that produced `strainScore`, as `StrainAlgorithm.rawValue`.
    ///
    /// **The app's own statement about the row, carried on the wire because the Worker cannot know
    /// it.** The server stores what it is given and never invents a version; a row from a client older
    /// than `v35` arrives without one and is stored with a NULL.
    public let algorithm: String?

    public init(
        date: Date,
        strainScore: Double,
        kilojoules: Double,
        averageHeartRate: Int,
        maxHeartRate: Int,
        hasMeasurement: Bool,
        source: String? = nil,
        algorithm: String? = nil
    ) {
        self.date = date
        self.strainScore = strainScore
        self.kilojoules = kilojoules
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.hasMeasurement = hasMeasurement
        self.source = source
        self.algorithm = algorithm
    }

    /// The row a day would be stored as, with its provenance supplied by the caller.
    ///
    /// `kilojoules` is `StrainScore.activeCalories` converted kcal → kJ, which is the same
    /// `× 4.184` `GRDBStrainRepository` applies when it stores the entity — the entity carries the
    /// calorie figure a screen reads and the record/wire carry the kilojoule figure the sync moves.
    public init(_ strain: StrainScore, source: String?) {
        self.init(
            date: strain.date,
            strainScore: strain.score,
            kilojoules: strain.activeCalories * 4.184,
            averageHeartRate: strain.averageHeartRate,
            maxHeartRate: strain.maxHeartRate,
            hasMeasurement: strain.hasMeasurement,
            source: source,
            algorithm: strain.algorithm?.rawValue
        )
    }

    /// The entity a screen would draw, rebuilt from the stored fields.
    ///
    /// `rawAccumulatedLoad`, `zones`, `motionLoad` and `scoredThrough` have no wire fields and never
    /// did, so they come back at their defaults — the same shape `GRDBStrainRepository.makeScore`
    /// produces when it reads a record. **`source` and `algorithm` do ride the wire and are passed
    /// through**, because dropping them here is what would turn a cloud-read imported day into one the
    /// refresh would happily overwrite.
    public var score: StrainScore {
        StrainScore(
            date: date,
            score: strainScore,
            hasMeasurement: hasMeasurement,
            activeCalories: kilojoules / 4.184,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            source: source,
            algorithm: algorithm.flatMap(StrainAlgorithm.init(rawValue:))
        )
    }
}
