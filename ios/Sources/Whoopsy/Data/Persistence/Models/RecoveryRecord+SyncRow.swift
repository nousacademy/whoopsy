import Foundation

/// The two conversions between a stored row and the shape a sync moves.
///
/// **This is where the three namespaces meet, and it is the only place they do.** A recovery reading
/// goes by three names on its way from SQLite to the wire — `skin_temperature` / `skinTemp` /
/// `skinTemperature` — and every one of those is a place a mapping can be written wrong in a way
/// nothing catches, because both sides of a wrong mapping are the same `Double?` and every screen built
/// on either one would look right. `RecoverySyncRow` takes the *record's* property names for exactly
/// this reason: it makes the conversions below a field-for-field copy with no naming decision in them,
/// so the one place a name changes is `RecoveryWireMapper` and there is one file to check.
///
/// **Hand-written and not reflective.** A `Mirror`-based or `KeyedDecodingContainer`-based copy would
/// be fewer lines and would silently stop covering a field the day someone adds one to
/// `RecoveryRecord` — it would still compile, still round-trip everything it knew about, and drop the
/// new column on every synced row. Written out, a tenth property is a compile error here. That is the
/// same bargain `RecoveryRecord.CodingKeys` makes by being declared rather than derived.
///
/// `source` is the field this file exists for: it is a column, it is on the wire, and `RecoveryMetric`
/// has no property for it — so a sync built on the entity would lose the provenance of all 910 imported
/// rows with a green build and no log line.
extension RecoveryRecord {

    /// The row a sync sends for this record.
    var syncRow: RecoverySyncRow {
        RecoverySyncRow(
            date: date,
            recoveryScore: recoveryScore,
            restingHeartRate: restingHeartRate,
            hrvValueMs: hrvValueMs,
            hrvMetric: hrvMetric,
            skinTemp: skinTemp,
            spo2: spo2,
            respiratoryRate: respiratoryRate,
            source: source
        )
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// Nothing is defaulted and nothing is filled in: a row that arrives without a skin temperature
    /// stores a NULL, which is this schema's word for *nobody measured one* and is a different answer
    /// from `0`. The `date` is left as the mapper handed it over — already `startOfDay` in the device's
    /// own zone — and `LocalDatabaseManager.saveSyncRows` snaps it again on the way in, because that is
    /// where every other writer in this app snaps it and a row written at a raw instant is inserted
    /// rather than updated, which no keyed read can find again.
    init(_ row: RecoverySyncRow) {
        self.init(
            date: row.date,
            recoveryScore: row.recoveryScore,
            restingHeartRate: row.restingHeartRate,
            hrvValueMs: row.hrvValueMs,
            hrvMetric: row.hrvMetric,
            skinTemp: row.skinTemp,
            spo2: row.spo2,
            respiratoryRate: row.respiratoryRate,
            source: row.source
        )
    }
}
