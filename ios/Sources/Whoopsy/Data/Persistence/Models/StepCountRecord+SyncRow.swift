import Foundation

/// The two conversions between a stored step count and the shape a sync moves.
///
/// **The shortest of the four files of its kind, and this time there is nothing left over at all.**
/// `StrainRecord+SyncRow` is short because the table has no name seam; this one is shorter still,
/// because the table has three columns, no `CodingKeys`, no nullable field and no provenance. There is
/// no day-key decision here either — `LocalDatabaseManager` owns the snap on both sides — so the two
/// functions below are a pure copy in each direction, which is what the two-names rule leaves when the
/// record's names and the wire's happen to be the same word.
///
/// **Hand-written and not reflective**, on its siblings' argument: a `Mirror`-based copy would stop
/// covering a fourth column invisibly, and `measuredSeconds` is the column the absence rule reads — a
/// sync that dropped it on the way out would send every unmeasured day as a measured one and the server
/// would store it.
extension StepCountRecord {

    /// The row a sync sends for this record.
    var syncRow: StepCountSyncRow {
        StepCountSyncRow(date: date, stepCount: stepCount, measuredSeconds: measuredSeconds)
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// The date is left as the mapper handed it over and `LocalDatabaseManager.saveSyncStepCountRows`
    /// snaps it again on the way in, for the reason every other writer in this app snaps it there:
    /// GRDB's `save` is INSERT-or-UPDATE *by primary key*, so a row written at a raw instant is
    /// inserted rather than updated and no keyed read finds it again.
    init(_ row: StepCountSyncRow) {
        self.init(date: row.date, stepCount: row.stepCount, measuredSeconds: row.measuredSeconds)
    }
}
