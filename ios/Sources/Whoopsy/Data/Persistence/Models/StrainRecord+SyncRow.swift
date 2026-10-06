import Foundation

/// The two conversions between a stored row and the shape a sync moves.
///
/// **This is the shortest of the three files of its kind, and the shortness is a fact about the table
/// rather than a shortcut.** `StrainRecord` declares no `CodingKeys`, so its property names *are* its
/// column names — there is no `skin_temperature` / `skinTemp` seam here, and no field whose wire name
/// differs from the name it is stored under. That leaves exactly one naming decision in the whole
/// resource, the day key, and it lives in `StrainWireMapper` where both conversions can see it.
///
/// **Hand-written and not reflective**, on `RecoveryRecord+SyncRow`'s argument: a `Mirror`-based copy
/// would be fewer lines and would silently stop covering a field the day someone adds one to
/// `StrainRecord` — it would still compile, still round-trip everything it knew about, and drop the new
/// column on every synced row. Written out, a seventh property is a compile error here.
///
/// **`hasMeasurement` and `source` are the two fields this file exists for, and for opposite reasons.**
/// The flag is the one thing that separates a measured day from a placeholder, and a sync built on
/// `StrainScore` would lose it on every row — the entity's own `hasMeasurement` is a required member
/// precisely so no construction site can forget it, and this is the second place that care is mirrored.
/// `source` is the provenance of every imported day, and `StrainScore` has no property for it either,
/// so a sync built on the entity would lose all 931 imported rows' provenance with a green build and no
/// log line.
extension StrainRecord {

    /// The row a sync sends for this record.
    var syncRow: StrainSyncRow {
        StrainSyncRow(
            date: date,
            strainScore: strainScore,
            kilojoules: kilojoules,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            hasMeasurement: hasMeasurement,
            source: source
        )
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// Nothing is defaulted and nothing is filled in: a row that arrives without a `source` stores a
    /// NULL, which is this schema's word for *nobody recorded one* and is a different answer from the
    /// empty string. The `date` is left as the mapper handed it over — already `startOfDay` in the
    /// device's own zone — and `LocalDatabaseManager.saveSyncStrainRows` snaps it again on the way in,
    /// because that is where every other writer in this app snaps it and a row written at a raw instant
    /// is inserted rather than updated, which no keyed read can find again.
    init(_ row: StrainSyncRow) {
        self.init(
            date: row.date,
            strainScore: row.strainScore,
            kilojoules: row.kilojoules,
            averageHeartRate: row.averageHeartRate,
            maxHeartRate: row.maxHeartRate,
            hasMeasurement: row.hasMeasurement,
            source: row.source
        )
    }
}
