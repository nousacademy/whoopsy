import Foundation

/// What a WHOOP-export import actually did.
///
/// The counts are the point, exactly as they are for `HealthImportSummary`. An export can be partly
/// empty (a cycle that had not closed yet has no strain), and days the app already recorded from the
/// strap are skipped rather than overwritten — so "wrote nothing" has several very different causes
/// and the person who pressed the button needs to be told which one happened.
public struct WhoopImportSummary: Sendable, Equatable {
    /// Rows the export contained.
    public let rowsInExport: Int
    /// Rows carrying no wake onset and no strain — the export's blank filler rows.
    public let rowsEmpty: Int

    /// Rows written, per table. These are **not** day counts: a day can contribute to more than one
    /// table, and a day can contribute to none, so they must never be added together or subtracted
    /// from one another. `daysWritten` is the figure the message reports.
    public let recoveriesWritten: Int
    public let sleepsWritten: Int
    public let strainsWritten: Int

    /// Distinct days that received at least one row. A set count, not derivable from the three
    /// above — which is why the importer passes it in rather than the summary computing it.
    public let daysWritten: Int

    /// Days skipped because a measurement was already stored locally **before this import ran**.
    ///
    /// Strictly pre-existing history. A day that this same walk claimed and a later export row then
    /// collided with is counted in `duplicateExportRows` instead — see there for why the distinction
    /// is load-bearing.
    public let daysAlreadyRecorded: Int

    /// Export rows that lost their day to an earlier row of the same import.
    ///
    /// The export's fragmented cycles: 933 `Day Strain` values land on 931 days because two fragments
    /// share a day with a closed cycle. Reporting those as "already recorded" told a fresh install it
    /// had history it did not have, so they are counted apart from `daysAlreadyRecorded`. Deliberately
    /// not surfaced in `message`: it is a property of the export's shape, not of the import, and the
    /// person who pressed the button can do nothing with it.
    public let duplicateExportRows: Int
    /// Days with neither a recovery reading nor a strain figure, and so nothing to write.
    public let daysWithoutData: Int

    /// Days carrying a strain but **no** recovery score — the export's partly-recorded cycles.
    ///
    /// A set difference, not `strainsWritten - recoveriesWritten`. Those two agree only when no day
    /// falls the other way, and days do: a strain-only cycle and a scored night are both single-table
    /// days, so the subtraction reports a number that is wrong in both directions at once.
    public let strainOnlyDays: Int

    /// The span actually written, formatted for display. Empty strings when nothing was written.
    public let firstDay: String
    public let lastDay: String

    public init(
        rowsInExport: Int,
        rowsEmpty: Int,
        recoveriesWritten: Int,
        sleepsWritten: Int,
        strainsWritten: Int,
        daysAlreadyRecorded: Int,
        daysWithoutData: Int,
        duplicateExportRows: Int = 0,
        daysWritten: Int = 0,
        strainOnlyDays: Int = 0,
        firstDay: String = "",
        lastDay: String = ""
    ) {
        self.rowsInExport = rowsInExport
        self.rowsEmpty = rowsEmpty
        self.recoveriesWritten = recoveriesWritten
        self.sleepsWritten = sleepsWritten
        self.strainsWritten = strainsWritten
        self.daysAlreadyRecorded = daysAlreadyRecorded
        self.daysWithoutData = daysWithoutData
        self.duplicateExportRows = duplicateExportRows
        self.daysWritten = daysWritten
        self.strainOnlyDays = strainOnlyDays
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    public static let empty = WhoopImportSummary(
        rowsInExport: 0, rowsEmpty: 0, recoveriesWritten: 0, sleepsWritten: 0, strainsWritten: 0,
        daysAlreadyRecorded: 0, daysWithoutData: 0)

    /// Written for the person reading it. The date range matters more here than the totals: an
    /// import that wrote 910 rows in the wrong place and one that wrote them correctly both say
    /// "910", and only the span tells them apart.
    public var message: String {
        guard daysWritten > 0 else {
            if daysAlreadyRecorded > 0 {
                return "Nothing to import — all \(daysAlreadyRecorded) days in this export are "
                    + "already recorded locally."
            }
            if rowsInExport > 0 {
                return "No importable data found in the export (\(rowsInExport) rows read, "
                    + "\(rowsEmpty) of them empty)."
            }
            return "The WHOOP export file could not be read."
        }

        var text = "Imported \(daysWritten) days of history"
        if !firstDay.isEmpty, !lastDay.isEmpty { text += " (\(firstDay) → \(lastDay))" }
        text += "."
        // "further" only reads as further when some day was not strain-only. When every written day
        // was, the same sentence would claim twice as many days as were imported.
        if strainOnlyDays > 0, strainOnlyDays == daysWritten {
            text += " Each carried a strain but no recovery reading."
        } else if strainOnlyDays > 0 {
            text += " \(strainOnlyDays) further days had strain only."
        }
        if daysAlreadyRecorded > 0 { text += " \(daysAlreadyRecorded) already recorded locally." }
        if daysWithoutData > 0 { text += " \(daysWithoutData) had no reading." }
        return text
    }
}
