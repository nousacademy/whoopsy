import Foundation

/// Brings a file of received states into the local database as `receptive_inactivities` rows.
///
/// This is the app's fifth input, after the strap, HealthKit, the WHOOP export and Zero's fasts — and it
/// is the first to write a table no other producer touches. The four above it all land in `workouts`,
/// `recoveries`, `sleeps` or `strains`, each carrying a figure some sensor or some other app measured;
/// a receptive inactivity carries none, which is why it has its own table and why this importer has no
/// `source` label to write: there is no column for one and no question it would answer.
///
/// **Its rows are named by the file's own vocabulary and not by this app's.** `dreams.json` writes
/// `"type": "dream"`; `InactivityParser` hands that word through untouched and
/// `ReceptiveInactivityCatalog.name(for:)` maps it to the app's own spelling, `Dream`, at the one place
/// the mapping belongs. A second producer of `"type": "meditation"` therefore needs no change here —
/// and the reason to keep it that way is that the alternative, teaching the importer one file's word,
/// is a coupling nothing on screen would reveal.
///
/// **It carries no day skip, on `ZeroFastingImporter`'s argument.** The other four imports refuse a day
/// that already holds a row; this one must not, because each entry's primary key is derived from its own
/// content and is therefore disjoint from every other producer's. A write here can only ever touch a row
/// this importer put there, so a skip would drop entries to protect nothing. The cost of *that* is the
/// one thing a reader has to be told, and it is on the button rather than here: a re-import recomputes
/// the same ids from the unchanged file and writes the file's text back over any edit. See
/// `InactivityImportAction`'s caption.
public struct InactivityImporter: InactivityImporting, Sendable {

    private let receptiveRepository: any ReceptiveInactivityRepository

    public init(receptiveRepository: any ReceptiveInactivityRepository) {
        self.receptiveRepository = receptiveRepository
    }

    /// The bundled resource's name, without its extension.
    ///
    /// **Named for the file, while every type around it is named for the row.** The file is
    /// `dreams.json` and the row it produces is a receptive inactivity — so the resource keeps the
    /// producer's word and the parser, the importer, the summary and the screen take the row's. It is
    /// the same split `ZeroFastingImporter` already carries, where the resource is `"fasts"` and the
    /// button says `biodata.json`: a name inside a bundle and a name on a button answer to different
    /// readers, and a constant apiece is what keeps one from dragging the other.
    ///
    /// **It is a constant rather than a literal inside `bundledInactivitiesURL()`** so the pairing of a
    /// button to a file is one value §21 can assert, on `WhoopExportFile.rawValue`'s rule.
    public static let bundledResourceName = "dreams"

    /// The bundled `dreams.json`.
    ///
    /// **No `subdirectory:`** — `Package.swift` processes an explicit file path, which flattens the file
    /// into the bundle's root, so `Data/Resources/Custom/` is an organisation rather than part of the
    /// resource path. That is the same reason the three CSVs and `fasts.json` are looked up with none.
    ///
    /// `Bundle.module` **traps** rather than returning nil when the resource bundle itself is missing, so
    /// this must never be called at launch: a build without the bundle should fail when the user asks
    /// for an import. The optional covers the narrower case where the bundle resolved but this file is
    /// absent, which ``importBundledInactivities()`` throws for.
    public static func bundledInactivitiesURL() -> URL? {
        Bundle.module.url(forResource: bundledResourceName, withExtension: "json")
    }

    /// Imports the receptive inactivities that shipped with the app.
    ///
    /// **A missing file is an error here, not a `0`** — the rule all four imports above follow. This file
    /// *is* the import, so a button reporting "imported nothing" over a build that does not carry it
    /// would be the silent-success failure `InactivityImportError` exists to refuse.
    public func importBundledInactivities() async throws -> InactivityImportSummary {
        guard let url = Self.bundledInactivitiesURL() else {
            throw InactivityImportError.notBundled
        }
        return try await importInactivities(at: url)
    }

    public func importInactivities(at url: URL) async throws -> InactivityImportSummary {
        try await importInactivityRows(InactivityParser.parseInactivities(at: url))
    }

    /// Rows written, which on the bundled file is **62 entries over 57 days**.
    ///
    /// Idempotent by primary key rather than by a day check: `receptive_inactivities` is keyed on `id`
    /// and GRDB's `save` is INSERT-or-UPDATE, so a second press rewrites the same 62 rows. That is the
    /// whole reason `InactivityParser` derives each id from the record — the mistake `ReceptiveInactivity
    /// .init`'s `id: UUID = UUID()` default would otherwise walk straight into, appending 62 rows per
    /// press while reading back perfectly well.
    ///
    /// **The days are counted from the file's own dates rather than from the written rows**, and here
    /// that is not a shortcut but the same number arrived at twice: the parser snaps each date through
    /// `startOfDay`, and `ReceptiveInactivity.init` snaps the day it is handed. The two agree because
    /// they are the same call on the same instant — which is also why there is no second `startOfDay`
    /// below the way `ZeroFastingImporter` has one, where a fast's day has to be derived from an instant
    /// the file states raw.
    ///
    /// **`rowsUnreadable` is a literal `0` and not an accumulator.** The fasting import can refuse a row
    /// after parsing it, because a `FastID` that will not round-trip through `UUID(uuidString:)` is a
    /// well-formed record whose id is unusable — the parser cannot know, so the importer drops it. No
    /// such refusal exists on this path: the id is derived, it is a `UUID` by the time a row exists, and
    /// every record that reaches this loop has already survived the parser's own checks, which **throw**
    /// rather than skip. An accumulator that nothing can increment would be a claim that a skip is
    /// possible here, which is the opposite of what this importer does with a bad record.
    @discardableResult
    public func importInactivityRows(_ rows: [InactivityRow]) async throws -> InactivityImportSummary {
        var days: Set<Date> = []
        var firstDay: Date?
        var lastDay: Date?

        for row in rows {
            try await receptiveRepository.save(Self.makeInactivity(from: row))

            days.insert(row.date)
            firstDay = min(firstDay ?? row.date, row.date)
            lastDay = max(lastDay ?? row.date, row.date)
        }

        return InactivityImportSummary(
            rowsInFile: rows.count,
            inactivitiesWritten: rows.count,
            daysWritten: days.count,
            rowsUnreadable: 0,
            firstDay: firstDay.map { $0.formattedImportDay() } ?? "",
            lastDay: lastDay.map { $0.formattedImportDay() } ?? "")
    }

    /// One parsed record as a row, with **the parser's id passed explicitly**.
    ///
    /// That single argument is the whole of what makes this import idempotent, and it is worth being
    /// blunt about why it looks redundant: `ReceptiveInactivity`'s initialiser accepts the id as a
    /// defaulted parameter, so omitting it here would compile, run, write sixty rows on the first press
    /// and sixty *more* on every press after — while every read of every day came back looking correct,
    /// because the duplicates would be identical in every other field. The suite asserts the second
    /// import writes nothing, which is the assertion that fails the moment this line loses the argument.
    ///
    /// **`startedAt: nil` is the file's own answer and not an omission.** `dreams.json` states a day and
    /// no time, which is the user's settled choice — `Import with none` — so every imported entry is
    /// untimed until someone sets one by hand. The Home row draws nothing in its clock slot for it,
    /// which is the honest drawing of "no time given", and not the dash a measured row would carry.
    ///
    /// The name is the catalogue's spelling rather than the file's: `"dream"` becomes `"Dream"`, so the
    /// sheet's picker shows its own row as the selected one when the user opens the entry, and
    /// `ActivityGlyph` needs no second key beside the `"dream"` it already holds.
    static func makeInactivity(from row: InactivityRow) -> ReceptiveInactivity {
        ReceptiveInactivity(
            id: row.id,
            date: row.date,
            name: ReceptiveInactivityCatalog.name(for: row.type),
            note: row.note,
            startedAt: nil)
    }
}
