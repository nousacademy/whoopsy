import Foundation

/// The two conversions between a stored night and the shape a sync moves.
///
/// **This is the file the `sleep_stages` column makes different from its three siblings.**
/// `recoveries`, `strains` and `stepCounts` are flat rows of scalars, so their conversions are a
/// field-for-field copy with one day key in them. `sleeps` carries `sleepStages`, which is a
/// `[SleepStageSegment]?` on the record and an opaque JSON *string* on the wire — and the conversion
/// between those two shapes is deliberately **not** here. It lives in `SleepWireMapper`, for the rule
/// this whole family is built on: a row takes the record's own property names, so a row that held the
/// string would be a second place the timeline is spelled.
///
/// **Hand-written and not reflective**, on `StrainRecord+SyncRow`'s argument: a `Mirror`-based copy
/// would silently stop covering a field the day someone adds one to `SleepRecord` and would drop it on
/// every synced night with a green build. Written out, a sixteenth property is a compile error here.
///
/// **The four optional columns ride through unchanged**, which is what makes an imported night
/// distinguishable from a strap night on the far side: `respiratoryRate` alone present is the shape a
/// classified night has and an unreadable one does not, and `source` is the only marker between the two
/// producers of it. Nothing here defaults, fills in or drops one.
extension SleepRecord {

    /// The row a sync sends for this record.
    var syncRow: SleepSyncRow {
        SleepSyncRow(
            date: date,
            startTime: startTime,
            endTime: endTime,
            sleepPerformance: sleepPerformance,
            totalSleepNeeded: totalSleepNeeded,
            lightSleep: lightSleep,
            deepSleep: deepSleep,
            remSleep: remSleep,
            awakeTime: awakeTime,
            respiratoryRate: respiratoryRate,
            disturbanceCount: disturbanceCount,
            sleepConsistency: sleepConsistency,
            sleepDebt: sleepDebt,
            sleepStages: sleepStages,
            source: source
        )
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// Nothing is defaulted: a night that arrives with no `source` stores a NULL, which is this schema's
    /// word for *nobody recorded one* and a different answer from the empty string. The `date` is left
    /// as the mapper handed it over — already `startOfDay` in the device's own zone — and
    /// `LocalDatabaseManager.saveSyncSleepRows` snaps it again on the way in, because that is where
    /// every other writer in this app snaps it and a row written at a raw instant is inserted rather
    /// than updated, which no keyed read can find again.
    init(_ row: SleepSyncRow) {
        self.init(
            date: row.date,
            startTime: row.startTime,
            endTime: row.endTime,
            sleepPerformance: row.sleepPerformance,
            totalSleepNeeded: row.totalSleepNeeded,
            lightSleep: row.lightSleep,
            deepSleep: row.deepSleep,
            remSleep: row.remSleep,
            awakeTime: row.awakeTime,
            respiratoryRate: row.respiratoryRate,
            disturbanceCount: row.disturbanceCount,
            sleepConsistency: row.sleepConsistency,
            sleepDebt: row.sleepDebt,
            sleepStages: row.sleepStages,
            source: row.source
        )
    }
}
