import Foundation

/// What a Zero fasting import actually did.
///
/// `WhoopImportSummary`'s shape for a much smaller file, and it keeps the same rule: the counts are the
/// point, because "wrote nothing" has several very different causes and the person who pressed the
/// button needs to be told which one happened. Here the causes are narrow — a fast already on disk, a
/// fast this build could not read — but they are still two, and a bare "0" says neither.
///
/// **It leads with fasts and states days as its own clause**, which `WhoopImportSummary` cannot do:
/// that summary's rows are days by construction, while **170 fasts fall on 136 distinct start days**,
/// so a sentence naming one figure and meaning the other is wrong by 34. The two are separate numbers
/// and are printed as separate things.
///
/// There is deliberately **no "the file was missing" branch** in `message`, unlike `WhoopImportSummary`'s
/// "could not be read" tail. `importBundledFasts()` throws `ZeroFastingError.notBundled` for that case,
/// and the button renders `error.localizedDescription` — so a summary is only ever built for a file
/// that was found, and a branch here would be a sentence nothing could reach.
public struct FastingImportSummary: Sendable, Equatable {

    /// Records the file's `fast_data` array held.
    public let rowsInFile: Int

    /// Rows written to `workouts`. **Not a day count** — a day can hold several fasts, and 170 of them
    /// land on 136 days. Equal to `rowsInFile` on the bundled file, and the two part company only when
    /// a record is refused.
    public let fastsWritten: Int

    /// Distinct days that received at least one fast, by `startOfDay` in the device's own zone.
    ///
    /// A set count rather than a division, and the importer passes it in because the summary cannot
    /// compute it: a fast spanning midnight contributes two calendar days to its own length and one to
    /// this number.
    public let daysWritten: Int

    /// Records dropped because their `FastID` would not round-trip through `UUID(uuidString:)`.
    ///
    /// The one refusal this import can make, and it is not about the data being wrong — it is about
    /// `GRDBWorkoutRepository.makeSessions`, which skips any stored row whose id is not a UUID. Writing
    /// one would leave a row on disk that no reader can ever see: the worse of the two failure modes,
    /// and silent. Zero on the bundled file, where all 170 parse.
    public let rowsUnreadable: Int

    /// The span actually written, formatted for display. Empty strings when nothing was written.
    public let firstDay: String
    public let lastDay: String

    public init(
        rowsInFile: Int,
        fastsWritten: Int,
        daysWritten: Int,
        rowsUnreadable: Int,
        firstDay: String = "",
        lastDay: String = ""
    ) {
        self.rowsInFile = rowsInFile
        self.fastsWritten = fastsWritten
        self.daysWritten = daysWritten
        self.rowsUnreadable = rowsUnreadable
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    /// The date grammar `WhoopImportSummary.firstDay` uses, so the two import reports read alike.
    public static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Written for the person reading it, and it names **fasts** first because that is what was
    /// imported. The day count follows as its own clause rather than as a restatement, since the two
    /// figures differ by 34 on this file.
    public var message: String {
        guard fastsWritten > 0 else {
            if rowsInFile == 0 {
                return "No fasting history found — the Zero export holds no finished fasts."
            }
            return "No fasting history could be imported from \(rowsInFile) records."
        }

        var text = "Imported \(fastsWritten) fasts over \(daysWritten) days"
        if !firstDay.isEmpty, !lastDay.isEmpty { text += " (\(firstDay) → \(lastDay))" }
        text += "."
        if rowsUnreadable > 0 { text += " \(rowsUnreadable) records were unreadable." }
        return text
    }
}
