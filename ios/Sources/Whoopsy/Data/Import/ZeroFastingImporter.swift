import Foundation

/// Brings a Zero fasting tracker's history into the local database as `workouts` rows.
///
/// This is the app's fourth input, after the strap, HealthKit and the WHOOP export, and the smallest:
/// one JSON array of finished fasts, read once when the user asks. It exists because a fasting window
/// is something the user did and this app had no way to show it — `WhoopActivityCatalog.fastingName`
/// was added for this producer and sat with nothing behind it until now.
///
/// **It is the first producer of a session with no measurement behind it, and that is the whole of why
/// the schema moved.** A fast has no strain, no heart rate and no zone block: nothing measured it. The
/// three figures were non-optional on `WorkoutSession` and NOT NULL in `workouts` until `v18` relaxed
/// them, because until this file there was no producer that needed to say so — and a `0` written in
/// their place would be a fabricated reading of exactly the kind every absence rule in this app
/// forbids. See `ActivityFigure` for the two dashes the screens draw for it.
///
/// **It carries no day skip, unlike its three siblings, and that is deliberate.** The fast's primary
/// key is Zero's own `FastID` — disjoint from the export's id, which packs two instants into a UUID,
/// and from a live session's, which is a fresh `UUID()`. A write here can therefore only ever touch a
/// fast row, so skipping a day that already held something would lose fasts and protect nothing.
/// Measured over the bundled files: 16 of the export's 673 workout rows land on the 10 days that are
/// also fast start days, and the pair is therefore order-independent — `WhoopExportImporter` carries
/// the matching half of this rule in `recordedWorkoutDays()`, which filters fasts out of the day set
/// it skips against.
public struct ZeroFastingImporter: FastingImporting, Sendable {

    /// Written to the `source` column of every row this importer creates, beside
    /// `WhoopExportImporter.sourceLabel`.
    ///
    /// **It is read, not merely recorded.** `WhoopExportImporter.recordedWorkoutDays()` excludes rows
    /// carrying it from the set of days the export refuses to write to, which is what keeps the two
    /// imports from erasing each other's days. A second reader is `WorkoutSession.source`'s own doc.
    public static let sourceLabel = "zero_fasting"

    private let workoutRepository: any WorkoutRepository

    public init(workoutRepository: any WorkoutRepository) {
        self.workoutRepository = workoutRepository
    }

    /// The bundled resource's name, without its extension. **`"fasts"` and not `"biodata"`**, and this
    /// constant is where that decision is written down.
    ///
    /// It is a named constant rather than a literal inside `bundledFastsURL()` so the pairing of a
    /// button to a file is one value the suite can assert, on `WhoopExportFile.rawValue`'s rule — there
    /// the raw value *is* the filename, and here the name is the resource.
    ///
    /// **There are two names for this one file, and they are not a mistake to reconcile.** What ships
    /// inside the build is `fasts.json`: `biodata.json`'s `fast_data` array projected down to the single
    /// key this importer reads, which is why the two hold the same fasts. The name **the screen says** is
    /// `FastingImportAction.fileName`, `"biodata.json"` — the file Zero hands a user who exports their own
    /// data, and therefore the name a reader recognises on a button caption. The user's instruction
    /// separates them exactly: *"so my modified version was fasts.json, in UI refer to it as
    /// "biodata.json" as thats what zero gives when exporting"* — the resource is theirs and the caption
    /// names the producer's file.
    ///
    /// The split is not cosmetic. Shipping the export itself would bundle a real person's whole record —
    /// 599 KB across nineteen top-level keys, 92% of which this app does not read — and the
    /// `ZeroFasting/` directory is gitignored for exactly that reason. `ZeroFastingParser.parseFasts`
    /// would refuse the raw file anyway. Moving this string is therefore the edit that has to be
    /// deliberate rather than incidental, and §20 pins it so a caption change cannot drag the resource
    /// along with it.
    public static let bundledResourceName = "fasts"

    /// The bundled `fasts.json`.
    ///
    /// `Bundle.module` **traps** rather than returning nil when the resource bundle itself is missing,
    /// so this must never be called at launch — a build without the bundle should fail when the user
    /// asks for an import, not on the way in. The optional is for the narrower case where the bundle
    /// resolved but this particular file is absent, which `importBundledFasts()` throws for.
    ///
    /// **`fasts.json` and not the producer's `biodata.json`**: that file is 599 KB across nineteen
    /// keys and 92% of it is data this app does not read, so the bundled projection holds
    /// `{"fast_data": […]}` and every byte of it is read. The generation recipe is in `README.md`.
    public static func bundledFastsURL() -> URL? {
        Bundle.module.url(forResource: bundledResourceName, withExtension: "json")
    }

    /// Imports the fasting history that shipped with the app.
    ///
    /// **A missing file is an error here, not a `0`** — and the WHOOP side files now follow the same
    /// rule rather than the opposite one. `WhoopExportImporter.importBundled(_:)` used to answer `0` for
    /// a missing `sleeps.csv` or `workouts.csv`, because those were extras folded into one button whose
    /// real subject was the cycle file. They are three buttons now, so each file *is* its own import
    /// exactly as this one is, and all four throw `.notBundled` for the same reason: a button that
    /// reports "imported nothing" over a build that does not carry its file would be the same
    /// silent-success failure `ZeroFastingError` exists to refuse.
    public func importBundledFasts() async throws -> FastingImportSummary {
        guard let url = Self.bundledFastsURL() else { throw ZeroFastingError.notBundled }
        return try await importFasts(at: url)
    }

    public func importFasts(at url: URL) async throws -> FastingImportSummary {
        try await importFastingRows(ZeroFastingParser.parseFasts(at: url))
    }

    /// Rows written, which on the bundled file is **170 fasts over 136 days**.
    ///
    /// Idempotent by primary key rather than by a day check: `workouts` is keyed on `id` and GRDB's
    /// `save` is INSERT-or-UPDATE, so a second press rewrites the same 170 rows. That is why the id is
    /// the `FastID` and not a fresh `UUID()` — the mistake `NapRecord`'s doc records against a
    /// per-run id, which writes eight more rows on every press of its button.
    ///
    /// **The two `startOfDay` calls are the database's own convention, not the file's.** A fast is
    /// filed under the day it *started* on, which is `LocalDatabaseManager.saveWorkout`'s snap — and
    /// the same call is made here to count the days the summary reports. It is `Calendar.current`
    /// because the write is: counting with a different calendar would report a day count the database
    /// does not hold. Measured, the 170 fasts fall on **136** distinct start days.
    @discardableResult
    public func importFastingRows(_ rows: [ZeroFastingRow]) async throws -> FastingImportSummary {
        var written = 0
        var unreadable = 0
        var days: Set<Date> = []
        var firstDay: Date?
        var lastDay: Date?

        for row in rows {
            guard let session = Self.makeSession(from: row) else {
                unreadable += 1
                continue
            }
            try await workoutRepository.save(session)
            written += 1

            let day = session.startedAt.startOfDay
            days.insert(day)
            firstDay = min(firstDay ?? day, day)
            lastDay = max(lastDay ?? day, day)
        }

        return FastingImportSummary(
            rowsInFile: rows.count,
            fastsWritten: written,
            daysWritten: days.count,
            rowsUnreadable: unreadable,
            firstDay: firstDay.map(FastingImportSummary.displayDate) ?? "",
            lastDay: lastDay.map(FastingImportSummary.displayDate) ?? "")
    }

    /// A fast as a session, or `nil` when its id will not round-trip.
    ///
    /// **The id is the only reason this can fail, and that is the point of it being optional.** The two
    /// instants are non-optional on `ZeroFastingRow` because the parser throws rather than skips, so by
    /// the time a row is here its window is known. What is not known is whether `FastID` is a UUID —
    /// and `GRDBWorkoutRepository.makeSessions` skips any stored row whose id is not one, which means a
    /// malformed id writes a row that no reader in this app can ever see. Refusing it here is the
    /// difference between a counted skip and a silent hole.
    ///
    /// **Every measured field is `nil`, and none of them is defaulted anywhere above.** That is the
    /// entire content of the `v18` change: this is the producer whose rows say *nothing measured this*,
    /// and the screens draw a dash for each. `hrZonePercents` and `steps` were already optional and are
    /// `nil` for the same reason. The route and the splits are empty because there is no route model
    /// behind a fast and no lap model at all.
    static func makeSession(from row: ZeroFastingRow) -> WorkoutSession? {
        guard let id = UUID(uuidString: row.fastID) else { return nil }

        return WorkoutSession(
            id: id,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            strain: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            route: [],
            splits: [],
            source: Self.sourceLabel,
            activityName: WhoopActivityCatalog.fastingName,
            hrZonePercents: nil,
            steps: nil)
    }
}
