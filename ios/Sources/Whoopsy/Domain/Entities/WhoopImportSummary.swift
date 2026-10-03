import Foundation

/// What a WHOOP-export import actually did.
///
/// The counts are the point, exactly as they are for `HealthImportSummary`. An export can be partly
/// empty (a cycle that had not closed yet has no strain), and days the app already recorded from the
/// strap are skipped rather than overwritten — so "wrote nothing" has several very different causes
/// and the person who pressed the button needs to be told which one happened.
public struct WhoopImportSummary: Sendable, Equatable {

    /// Which of the three bundled files this import read.
    ///
    /// **The message is a function of this and nothing else**, because the three files are three
    /// different imports rather than three slices of one — a cycles import reports days, a naps import
    /// reports naps, and a workouts import reports rows and the days they landed on. Reading `message`
    /// as though it described a whole history was correct while one button imported all three; there
    /// are three buttons now and each summary describes its own file.
    ///
    /// Defaulted to `.cycles` so a caller building a summary by hand — the runner's `empty` among
    /// them — keeps the day-level reading without naming it.
    public let file: WhoopExportFile

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

    /// Nap rows written, out of the bundled `sleeps.csv`.
    ///
    /// A fourth table and a fourth count, kept apart from `sleepsWritten` because it comes from a
    /// different file and is not a night. On this export it is 8, against 910 nights — so it is the
    /// one figure here a reader might otherwise assume was a typo. It is read by the `.naps` arm of
    /// `message` and by nothing else.
    public let napsWritten: Int

    /// Workout rows written, out of the bundled `workouts.csv`.
    ///
    /// A fifth table, and like `napsWritten` not a day count — a day can hold several workouts. On a
    /// **fresh install** it is 673 against 910 nights, and unlike the naps these are **not** a
    /// curiosity: they are the only producer of the strain page's two `HEART RATE ZONES` rows, so a zero
    /// on a first import is why those rows would be dashes on every day.
    ///
    /// **On a re-import it is 0**, because `importWorkoutRows` gained the day-already-recorded skip its
    /// three sibling tables always had — a second press writes nothing, which is the point of the skip,
    /// since a write there would revert an edit made on the activity detail page.
    ///
    /// **A zero here has one cause and no longer two.** `importBundledWorkouts()` used to answer `0`
    /// as well when this build carried no `workouts.csv` at all, so the same number meant either *this
    /// file's days are all recorded* or *there is no such file*, and a field distinguishing them was
    /// considered and rejected because the only reader is `message`. That ambiguity is gone rather than
    /// tolerated: `WhoopExportImporter.importBundled(_:)` **throws** `.notBundled` when the file is
    /// absent, so a summary is only ever built for a file that was found and this count means exactly
    /// one thing. The `.workouts` arm of `message` relies on that and says which of the two figures it
    /// is reporting.
    public let workoutsWritten: Int

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
        napsWritten: Int = 0,
        workoutsWritten: Int = 0,
        firstDay: String = "",
        lastDay: String = "",
        file: WhoopExportFile = .cycles
    ) {
        self.file = file
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
        self.napsWritten = napsWritten
        self.workoutsWritten = workoutsWritten
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    /// The summary for a naps import.
    ///
    /// Its own constructor rather than a general one taking a `file:`, so a caller cannot build a
    /// summary that claims to be about the naps while carrying a cycles import's counts. Only the two
    /// figures the naps arm of `message` reads are parameters; the rest keep their defaults, which is
    /// what makes the cycles fields structurally unreachable from here.
    ///
    /// **There is no `daysWritten`**, deliberately. A nap is keyed on its own start instant rather than
    /// on a day, so the count that matters is the naps, and any day figure would be a second way of
    /// saying eight.
    public static func naps(written: Int, rowsRead: Int) -> WhoopImportSummary {
        WhoopImportSummary(
            rowsInExport: rowsRead, rowsEmpty: 0,
            recoveriesWritten: 0, sleepsWritten: 0, strainsWritten: 0,
            daysAlreadyRecorded: 0, daysWithoutData: 0,
            napsWritten: written, file: .naps)
    }

    /// The summary for a workouts import.
    ///
    /// Three figures, because this walk reports three different things: rows written, the distinct days
    /// they landed on, and the days it refused. Rows and days are not interchangeable here — 673 rows
    /// land on 445 days — and `skippedDays` is what lets the `.workouts` arm distinguish *the file was
    /// empty* from *every day in it already holds a workout*, which is the question the old combined
    /// button could not answer.
    public static func workouts(
        written: Int,
        days: Int,
        skippedDays: Int,
        rowsRead: Int,
        firstDay: String = "",
        lastDay: String = ""
    ) -> WhoopImportSummary {
        WhoopImportSummary(
            rowsInExport: rowsRead, rowsEmpty: 0,
            recoveriesWritten: 0, sleepsWritten: 0, strainsWritten: 0,
            daysAlreadyRecorded: skippedDays, daysWithoutData: 0,
            daysWritten: days,
            workoutsWritten: written,
            firstDay: firstDay, lastDay: lastDay,
            file: .workouts)
    }

    public static let empty = WhoopImportSummary(
        rowsInExport: 0, rowsEmpty: 0, recoveriesWritten: 0, sleepsWritten: 0, strainsWritten: 0,
        daysAlreadyRecorded: 0, daysWithoutData: 0)

    /// Written for the person reading it. The date range matters more here than the totals: an
    /// import that wrote 910 rows in the wrong place and one that wrote them correctly both say
    /// "910", and only the span tells them apart.
    ///
    /// **Three arms, one per file, because there are three buttons.** Each summary describes the file
    /// its own button read, so a naps import doesn't speak about days and a workouts import doesn't
    /// speak about nights. The dispatch is on `file` rather than on which counts happen to be non-zero:
    /// a cycles import that wrote nothing and a naps import that wrote nothing are different sentences,
    /// and inferring which from the numbers would make a zero ambiguous again.
    public var message: String {
        switch file {
        case .cycles: return cyclesMessage
        case .naps: return napsMessage
        case .workouts: return workoutsMessage
        }
    }

    /// The day-level reading, unchanged from when one button imported all three files.
    private var cyclesMessage: String {
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
        // The "Plus N naps" and "Plus N workouts" clauses that stood here are gone with the button
        // that made them reachable. This walk no longer touches the two side files, so those counts
        // are 0 on every cycles summary and the clauses were dead sentences on a live screen.
        return text
    }

    /// The naps reading: eight rows, and a count is the whole of it.
    ///
    /// **There is no "nothing to import" branch, and that is the naps' own rule rather than an
    /// omission.** A nap's primary key is its start instant, so a second press *updates* the same
    /// eight rows rather than being skipped — `importNapRows` always reports eight, and the honest
    /// sentence is the same one. The `.workouts` arm below needs a skip branch because that walk
    /// refuses days; this one has nothing to refuse.
    private var napsMessage: String {
        guard napsWritten > 0 else {
            return rowsInExport > 0
                ? "No naps found in the sleep export (\(rowsInExport) rows read)."
                : "The WHOOP sleep export could not be read."
        }
        return "Imported \(napsWritten) naps."
    }

    /// The workouts reading: rows, the days they landed on, and the days this walk refused.
    ///
    /// **`workoutsWritten == 0` has two causes and they are now distinguishable**, which is the
    /// sentence the old combined summary could not write. `importBundled(_:)` throws rather than
    /// returning `0` when the file is absent, so a summary only exists for a file that was found —
    /// meaning a zero here is *always* the day skip, and the branch can say so. `rowsInExport > 0` is
    /// the guard for the one remaining empty case: a file that parsed to no rows at all.
    private var workoutsMessage: String {
        guard workoutsWritten > 0 else {
            if daysAlreadyRecorded > 0 {
                return "Nothing to import — all \(daysAlreadyRecorded) days in this file already "
                    + "hold a workout."
            }
            if rowsInExport > 0 {
                return "No importable workouts found in the export (\(rowsInExport) rows read)."
            }
            return "The WHOOP workouts file could not be read."
        }

        var text = "Imported \(workoutsWritten) workouts"
        // Rows and days are two different figures for the same file — 673 rows land on 445 days — so
        // stating both is what tells a reader the import understood that a day can hold several.
        if daysWritten > 0 { text += " across \(daysWritten) days" }
        if !firstDay.isEmpty, !lastDay.isEmpty { text += " (\(firstDay) → \(lastDay))" }
        text += "."
        if daysAlreadyRecorded > 0 {
            text += " \(daysAlreadyRecorded) further days already held a workout."
        }
        return text
    }
}
