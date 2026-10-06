import Foundation

/// What a receptive inactivity import actually did.
///
/// `FastingImportSummary`'s shape, and it keeps that type's rule: the counts are the point, because
/// "wrote nothing" has several very different causes and the person who pressed the button needs to be
/// told which one happened.
///
/// **It leads with inactivities and states days as its own clause**, which it must: the bundled
/// `dreams.json` holds **62 records over 57 distinct days**, so a sentence naming one figure and
/// meaning the other is wrong by five. The two are separate numbers and are printed as separate
/// things — the same reason the fasting summary prints its own pair apart, and the two files happen to
/// differ by a similar margin for a similar reason: **a day can hold more than one dream.** Five days
/// in this file do.
///
/// There is deliberately **no "the file was missing" branch** in `message`, on
/// `FastingImportSummary`'s recorded reason. `importBundledInactivities()` throws
/// `InactivityImportError.notBundled` for that case, and the button renders
/// `error.localizedDescription` — so a summary is only ever built for a file that was found, and a
/// branch here would be a sentence nothing could reach.
public struct InactivityImportSummary: Sendable, Equatable {

    /// Records the file's `receptive_inactivities` array held.
    public let rowsInFile: Int

    /// Rows written to `receptive_inactivities`. **Not a day count** — a day can hold several entries,
    /// and this file's 62 records land on 57 days. Equal to `rowsInFile` on the bundled file, and the
    /// two part company only when a record is refused.
    public let inactivitiesWritten: Int

    /// Distinct days that received at least one entry, by `startOfDay` in the device's own zone.
    ///
    /// A set count rather than a division, and the importer passes it in because the summary cannot
    /// compute it. It is also the one figure here that a device time zone can move without the file
    /// changing at all: the parser snaps each record's date through `Calendar.current`, so the count
    /// is recomputed from the parsed rows by the suite rather than pinned as a literal.
    public let daysWritten: Int

    /// Records dropped because they could not be read.
    ///
    /// **Structurally zero on this path, and the difference from `FastingImportSummary.rowsUnreadable`
    /// is worth stating rather than leaving as a field nobody can move.** The fasting import can refuse
    /// a row *after* parsing it, because a `FastID` that will not round-trip through `UUID(uuidString:)`
    /// is a well-formed record whose id is unusable — the parser cannot know, so the importer drops it
    /// and counts it here. Nothing equivalent exists on this path: `dreams.json` carries no id at all,
    /// the id is derived, and every record that reaches the importer has already survived the parser's
    /// own refusals, which **throw** rather than skip. So this is a real count of a refusal that never
    /// happens rather than a placeholder, and `message`'s clause for it stays because a future producer
    /// read through this same importer could have a reason the bundled file does not.
    public let rowsUnreadable: Int

    /// The span actually written, formatted for display. Empty strings when nothing was written.
    public let firstDay: String
    public let lastDay: String

    public init(
        rowsInFile: Int,
        inactivitiesWritten: Int,
        daysWritten: Int,
        rowsUnreadable: Int,
        firstDay: String = "",
        lastDay: String = ""
    ) {
        self.rowsInFile = rowsInFile
        self.inactivitiesWritten = inactivitiesWritten
        self.daysWritten = daysWritten
        self.rowsUnreadable = rowsUnreadable
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    /// Written for the person reading it, and it names **inactivities** first because that is what was
    /// imported. The day count follows as its own clause rather than as a restatement, since the two
    /// figures differ by five on this file.
    ///
    /// The span is `firstDay → lastDay` through `Date.formattedImportDay()`, the one definition of that
    /// grammar shared with the other two import reports — so this sentence and the WHOOP export's read
    /// alike without either holding its own `DateFormatter`.
    public var message: String {
        guard inactivitiesWritten > 0 else {
            if rowsInFile == 0 {
                return "No receptive inactivities found — the file holds no entries."
            }
            return "No receptive inactivities could be imported from \(rowsInFile) records."
        }

        var text = "Imported \(inactivitiesWritten) receptive inactivities over \(daysWritten) days"
        if !firstDay.isEmpty, !lastDay.isEmpty { text += " (\(firstDay) → \(lastDay))" }
        text += "."
        if rowsUnreadable > 0 { text += " \(rowsUnreadable) records were unreadable." }
        return text
    }
}
