import Foundation

/// Brings a WHOOP data export into the local database.
///
/// This is the app's third input, after the strap and HealthKit, and it exists for exactly one
/// reason: a new install has three years of the user's history available as a file and no way to
/// show it. It is not a sync — it runs when the user asks, it writes days that are not already
/// recorded, and it never touches a day the app measured itself.
///
/// **What the export is.** WHOOP's `physiological_cycles.csv` holds *computed, cycle-level* output:
/// one row per day with an overnight HRV, a resting heart rate, SpO2, skin temperature, a respiratory
/// rate, sleep stage durations, and WHOOP's own recovery and strain scores. It holds no time series
/// at all. That asymmetry drives the whole design below — the Recovery inputs are imported and
/// re-scored locally, while Strain can only be taken as WHOOP's finished number, because the
/// integrator it would need has nothing to integrate.
///
/// **The day key is the wake onset.** `CalculateRecoveryUseCase` writes `date.startOfDay` and reads
/// the sleep session *for that same date*, so a recovery row for day D is built from the night that
/// ended on D's morning. Keying on the cycle start instead would collapse 935 rows onto 753 days and
/// silently drop a fifth of the history.
public struct WhoopExportImporter: WhoopExportImporting, Sendable {

    /// Written to the `source` column of every row this importer creates. Nothing reads it yet; it
    /// is what will make these rows identifiable if they ever need re-running or backing out.
    public static let sourceLabel = "whoop_export"

    private let recoveryRepository: any RecoveryRepository
    private let sleepRepository: any SleepRepository
    private let strainRepository: any StrainRepository
    private let napRepository: any NapRepository
    private let userProfileRepository: any UserProfileRepository
    private let calendar: Calendar

    public init(
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        napRepository: any NapRepository,
        userProfileRepository: any UserProfileRepository,
        calendar: Calendar = .current
    ) {
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
        self.napRepository = napRepository
        self.userProfileRepository = userProfileRepository
        self.calendar = calendar
    }

    /// The bundled export, or nil when it is not present in this build.
    ///
    /// `Bundle.module` **traps** rather than returning nil when the resource bundle itself is
    /// missing, so this must never be called at launch: a build without the bundle should fail when
    /// the user asks for an import, not on the way in. The optional is for the narrower case where
    /// the bundle resolved but this particular file is absent.
    public static func bundledExportURL() -> URL? {
        Bundle.module.url(forResource: "physiological_cycles", withExtension: "csv")
    }

    /// The bundled `sleeps.csv`, whose only unique contribution is its eight nap records.
    ///
    /// Same `Bundle.module` rule as the cycle file: it traps rather than returning nil when the
    /// resource bundle is missing, so this must stay inside the user-initiated action.
    public static func bundledNapsURL() -> URL? {
        Bundle.module.url(forResource: "sleeps", withExtension: "csv")
    }

    /// Imports the export that shipped with the app.
    ///
    /// This is where `Bundle.module` is touched, and it is deliberately only reachable from a
    /// user-initiated action — see `bundledExportURL()`.
    ///
    /// **Two files, one button.** The naps are imported first and folded into the summary, so the
    /// person who pressed the button gets one report rather than two. The cycle file is the one they
    /// asked for and the one whose absence is an error; a build without `sleeps.csv` imports no naps
    /// and reports `0` for them — see `importBundledNaps()`.
    public func importBundledExport() async throws -> WhoopImportSummary {
        guard let url = Self.bundledExportURL() else { throw WhoopExportError.notBundled }
        let napsWritten = try await importBundledNaps()
        return try await importExport(at: url).recordingNapsWritten(napsWritten)
    }

    public func importExport(at url: URL) async throws -> WhoopImportSummary {
        let rows = try WhoopExportParser.parseCycles(at: url)
        let profile = try await userProfileRepository.getUserProfile()
        return try await importRows(rows, profile: profile)
    }

    // MARK: - Naps

    /// The naps out of the bundled `sleeps.csv`, or `0` when this build does not carry that file.
    ///
    /// **A missing side file is not an error**, which is the opposite of the cycle file's rule. The
    /// naps are eight rows of a 918-row file the app was not shipping at all until now; failing the
    /// whole import over their absence would trade a working history for a missing curiosity.
    @discardableResult
    func importBundledNaps() async throws -> Int {
        guard let url = Self.bundledNapsURL() else { return 0 }
        return try await importNaps(at: url)
    }

    /// The naps in `sleeps.csv`. The non-nap rows are filtered by `parseNaps` — see there for why
    /// importing them here would be a second writer for days the cycle import already owns.
    @discardableResult
    public func importNaps(at url: URL) async throws -> Int {
        try await importNapRows(WhoopExportParser.parseNaps(at: url))
    }

    /// Rows written, which on this export is 8. Idempotent by construction: `NapRecord`'s primary key
    /// is the nap's own start instant, so a second run updates the same eight rows.
    @discardableResult
    func importNapRows(_ rows: [WhoopExportRow]) async throws -> Int {
        var written = 0
        for row in rows {
            guard let nap = Self.makeNap(from: row, calendar: calendar) else { continue }
            try await napRepository.saveNap(nap, source: Self.sourceLabel)
            written += 1
        }
        return written
    }

    /// The whole import, over rows that are already parsed — the seam the tests drive directly, so
    /// they exercise the day-keying and the scoring walk without going near a bundle.
    func importRows(_ rows: [WhoopExportRow], profile: UserProfile) async throws -> WhoopImportSummary {
        let emptyRows = rows.filter(\.isEmpty).count

        // One entry per day, in chronological order. Order matters twice over: the scoring walk needs
        // each day's baseline to be the days before it, and "first writer wins" for a day that the
        // export and a strain-only cycle both claim is only deterministic if the walk is.
        //
        // The tiebreak is load-bearing. `sorted(by:)` is not a stable sort, so with `day` alone the
        // two strain-only cycles that share a day with a closed cycle (2024-02-11, 2024-03-20) would
        // win or lose the day's strain at random. A row carrying a wake onset *is* that day's cycle;
        // a strain-only cycle is a fragment that never closed, and for those two it starts at 23:30
        // and 23:48 — near enough to midnight that the day it belongs to is genuinely unknown. So
        // the closed cycle takes the day and the fragment defers to it.
        let days: [DayEntry] = rows
            .filter { !$0.isEmpty }
            .map { DayEntry(day: calendar.startOfDay(for: $0.wakeOnset ?? $0.cycleStart), row: $0) }
            .sorted { left, right in
                guard left.day == right.day else { return left.day < right.day }
                return left.row.wakeOnset != nil && right.row.wakeOnset == nil
            }

        // Row counts per table, plus the two day-level counts that cannot be derived from them.
        // `daysWritten` and `strainOnlyDays` are accumulated per day as the walk goes, because a day
        // that holds a recovery and no strain is as ordinary as the reverse and neither figure
        // survives being expressed as a difference between table totals.
        var recoveriesWritten = 0
        var sleepsWritten = 0
        var strainsWritten = 0
        var daysWritten = 0
        var strainOnlyDays = 0
        var alreadyRecorded = 0
        var duplicateExportRows = 0
        var withoutData = 0
        /// Days this walk itself has already written. Needed to tell "this day was already in the
        /// database" from "an earlier row of this same export claimed this day" — both look like a
        /// skipped row, and only the first one is pre-existing history.
        var claimedThisWalk: Set<Date> = []
        var firstDay: Date?
        var lastDay: Date?

        // The baseline is built in memory rather than read from the database. `getRecoveryHistory`
        // windows on `Date()` — "the last 30 days from now" — which is the wrong question for a walk
        // over 2023, and it would score every imported day against an empty window.
        var scoredSeries: [RecoveryMetric] = []

        for entry in days {
            let row = entry.row
            let day = entry.day
            var wroteForThisDay = false
            var skippedForExistingRow = false
            // Whether the day ends with a recovery, however it got one. A day whose recovery was
            // already on disk is not a strain-only day, and testing what *this* walk wrote would
            // misreport exactly that case.
            var dayHasRecovery = false
            var wroteStrainForThisDay = false

            // MARK: Sleep
            //
            // Built before Recovery because the recovery score's sleep term is this session's
            // performance, and `SleepSession` derives that from asleep-over-need. Using WHOOP's own
            // `Sleep performance %` column instead would give the app a second opinion about a
            // number it already has one rule for.
            let session = Self.makeSession(from: row, day: day)
            if let session {
                if try await sleepRepository.getSleepSession(for: day) == nil {
                    try await sleepRepository.saveSleepSession(session, source: Self.sourceLabel)
                    sleepsWritten += 1
                    wroteForThisDay = true
                } else {
                    skippedForExistingRow = true
                }
            }

            // MARK: Recovery
            //
            // Only rows that carry a wake onset are nights, and only a real HRV reading can be
            // scored: `hrvValueMs > 0` is what `RecoveryMetric.hasMeasurement` tests, so writing a
            // day from a missing reading would put a fabricated 0 ms into the baseline. The export's
            // `Recovery score %` column is deliberately not used — see the type's doc comment.
            if row.wakeOnset != nil, let hrv = row.hrvMs, hrv > 0, let restingHeartRate = row.restingHeartRate {
                if let existing = try await recoveryRepository.getLocalRecovery(for: day),
                    existing.hasMeasurement
                {
                    skippedForExistingRow = true
                    // Still a day the baseline is entitled to count. Leaving it out would score the
                    // days after it against a window with a hole in it purely because a row was
                    // already on disk.
                    scoredSeries.append(existing)
                    dayHasRecovery = true
                } else {
                    let sleepPerformance = session.map { Double($0.sleepPerformancePercentage) / 100.0 }
                        ?? BaselineStatisticsMath.sleepPerformancePivot

                    // Input built as its own value: inlined into the call, the mix of `nil`-coalescing,
                    // `map` and optional arguments upstream defeats the type checker.
                    let input = RecoveryScoring.Input(
                        history: RecoveryScoring.baselineWindow(before: day, in: scoredSeries),
                        todayHrvValueMs: hrv,
                        // The export does not name its HRV metric. WHOOP publishes overnight HRV as
                        // rMSSD, and the observed distribution (52.5 ± 10.5 ms, range 15–99) sits in
                        // the RMSSD band and reaches values SDNN rarely does — so this is the one
                        // place that inference is made, and the never-mix rule means it decides which
                        // baseline these days join.
                        todayHrvMetric: .rmssd,
                        todayRestingHeartRate: restingHeartRate,
                        sleepPerformance: sleepPerformance,
                        fallbackRestingHeartRateBaseline: profile.baselineRhr)

                    let scoring = RecoveryScoring.score(input)

                    let recovery = RecoveryMetric(
                        date: day,
                        score: scoring.score,
                        hrvValueMs: hrv,
                        hrvMetric: .rmssd,
                        restingHeartRate: restingHeartRate,
                        skinTemperatureCelsius: row.skinTempCelsius,
                        spO2Percentage: row.bloodOxygenPercent,
                        respiratoryRate: row.respiratoryRate,
                        hrvBaselineDeltaMs: scoring.hrvBaselineDeltaMs,
                        rhrBaselineDeltaBpm: scoring.rhrBaselineDeltaBpm)

                    try await recoveryRepository.saveRecovery(recovery, source: Self.sourceLabel)
                    scoredSeries.append(recovery)
                    recoveriesWritten += 1
                    wroteForThisDay = true
                    dayHasRecovery = true
                }
            }

            // MARK: Strain
            //
            // Verbatim, and there is no alternative: WHOOP's integrator consumes a heart-rate series
            // and the export has none, so recomputing would mean feeding a different algorithm. The
            // zone breakdown is absent too, which is why the Strain screen has to render the absence.
            if let strainScore = row.dayStrain {
                // The **measurement**, not the row — matching the recovery half above. A placeholder
                // left on disk by an older build (`score: 0.0`, flag cleared) is a day this app never
                // measured, so WHOOP's own figure for it must still land. Testing row existence
                // instead skipped the day outright and counted it into `daysAlreadyRecorded`, which
                // also contradicted this type's own contract that it never touches a day the app
                // measured itself — a placeholder day was not measured.
                let existingStrain = try await strainRepository.getStrain(for: day)
                if existingStrain?.hasMeasurement != true {
                    let strain = StrainScore(
                        date: day,
                        score: strainScore,
                        // A `Day Strain` value exists, so this day was measured — WHOOP's own figure
                        // for it. The column is non-empty on 933 of the export's 935 rows and holds
                        // exactly `0.0` on two of them (2024-06-05, 2024-12-31), both genuinely
                        // measured — so **a zero score is not the test** and never was. The flag is
                        // what a reader trusts, not the value.
                        //
                        // The `?? 0` companions below are unreachable on this export (Energy burned,
                        // Average HR and Max HR are non-empty on the same 933 rows), but they are why
                        // `v7_strain_measurement_marker`'s backfill tests `source IS NULL` as well as
                        // the two zero fields: every row written here carries `whoop_export`, so a
                        // fabricated `averageHeartRate: 0` could never be mistaken for a placeholder.
                        hasMeasurement: true,
                        activeCalories: row.energyKcal ?? 0,
                        averageHeartRate: row.averageHeartRate ?? 0,
                        maxHeartRate: row.maxHeartRate ?? 0)
                    try await strainRepository.saveStrain(strain, source: Self.sourceLabel)
                    strainsWritten += 1
                    wroteForThisDay = true
                    wroteStrainForThisDay = true
                } else {
                    skippedForExistingRow = true
                }
            }

            if wroteForThisDay {
                daysWritten += 1
                claimedThisWalk.insert(day)
                // The export's fragmented cycles: a cycle that never closed carries a strain and no
                // recovery inputs, so the day is real but half-populated. Counted here, where both
                // facts are in hand, rather than inferred later from the table totals.
                if wroteStrainForThisDay, !dayHasRecovery { strainOnlyDays += 1 }
                firstDay = firstDay ?? day
                lastDay = day
            } else if skippedForExistingRow {
                // Two different situations reach this branch and only one of them is history. A day
                // that already held rows when the walk began is genuinely already recorded; a day an
                // *earlier row of this same import* claimed is a duplicate row in the export. Counting
                // both as "already recorded" made a fresh install report pre-existing history it did
                // not have.
                if claimedThisWalk.contains(day) {
                    duplicateExportRows += 1
                } else {
                    alreadyRecorded += 1
                }
            } else {
                withoutData += 1
            }
        }

        return WhoopImportSummary(
            rowsInExport: rows.count,
            rowsEmpty: emptyRows,
            recoveriesWritten: recoveriesWritten,
            sleepsWritten: sleepsWritten,
            strainsWritten: strainsWritten,
            daysAlreadyRecorded: alreadyRecorded,
            daysWithoutData: withoutData,
            duplicateExportRows: duplicateExportRows,
            daysWritten: daysWritten,
            strainOnlyDays: strainOnlyDays,
            firstDay: firstDay.map(Self.displayDate) ?? "",
            lastDay: lastDay.map(Self.displayDate) ?? "")
    }

    // MARK: - Mapping

    /// One export row placed on its day. A named type rather than a tuple: the sort closure over an
    /// anonymous `(day:row:)` pair is what pushed the type checker past its limit here.
    struct DayEntry {
        let day: Date
        let row: WhoopExportRow
    }

    /// A night from the export, or nil when the row holds no sleep at all.
    ///
    /// `disturbanceCount` is nil because the export has no such figure — it reports total awake
    /// minutes, which is a different measurement, and labelling one as the other is the fabrication
    /// the `sleeps` schema was changed to prevent. `sleepStages` is empty for the same reason: the
    /// export gives stage totals, not a timeline, so there is no hypnogram to draw.
    static func makeSession(from row: WhoopExportRow, day: Date) -> SleepSession? {
        guard let start = row.sleepOnset, let end = row.wakeOnset, end > start else { return nil }

        /// The export writes every duration in minutes. Seconds is what the entity expects, and a
        /// missed conversion reads as a four-hundred-second night rather than as an error.
        func seconds(_ minutes: Double?) -> TimeInterval { (minutes ?? 0) * 60 }

        return SleepSession(
            date: day,
            startTime: start,
            endTime: end,
            targetSleepNeedSeconds: seconds(row.sleepNeedMinutes),
            lightSleepSeconds: seconds(row.lightMinutes),
            deepSleepSeconds: seconds(row.deepMinutes),
            remSleepSeconds: seconds(row.remMinutes),
            awakeSeconds: seconds(row.awakeMinutes),
            disturbanceCount: nil,
            respiratoryRate: row.respiratoryRate,
            // WHOOP's own, verbatim, exactly as `respiratoryRate` above and `sleepNeedMinutes` in the
            // target are. This is the one quantity on the sleep screen where an imported night and a
            // strap night carry numbers from different sources, and `GRDBSleepRepository` stores them
            // in the same column without a marker: what distinguishes them is that a strap night's is
            // computed on read from this column being empty, never written into it.
            sleepConsistency: row.sleepConsistencyPercent,
            // WHOOP's accumulated deficit, verbatim, in the seconds every duration in this entity is
            // in. A strap night's is a different quantity — this app's own `SleepDebtMath` running
            // deficit — and `hasWhoopSleepNeed` below is what keeps the two from being read as one:
            // WHOOP's is an additive term of the need beside it, and this app's is not.
            //
            // **`map`, never `?? 0`.** A missing `Sleep debt (min)` cell would become `0` seconds,
            // and the screen prints that as `0 min` — a night in perfect credit, which is the
            // strongest possible claim about a deficit and one this app would be inventing. Every
            // duration above uses `?? 0` because a row with no stage durations genuinely has none;
            // this one is optional *on the entity*, so the absence has somewhere to go.
            sleepDebtSeconds: row.sleepDebtMinutes.map { $0 * 60 },
            // The need above is WHOOP's own column, stored verbatim, and that is the fact a reader
            // of the row cannot recover from the numbers: this need is a total that already contains
            // the debt term, where a strap night's is a total that does not. It is also written to
            // `sleeps.source` at the save site below, which is where the read path gets it back.
            hasWhoopSleepNeed: true,
            sleepStages: [])
    }

    /// A nap from the export, or nil when the row cannot be placed in time or carries no duration.
    ///
    /// **The day key is the nap's own onset — the night table's rule, and the opposite of it.** A
    /// night is filed under the morning it ended on because that is the day it belongs to; a nap is
    /// filed under the day it was *taken* on, and four of the export's eight naps end after midnight
    /// (2024-02-06 02:34, 2024-08-27 02:36). Measured against the bundled export, all eight land on a
    /// day the cycle file already carries a night for — so this key puts every nap on a day the sleep
    /// screen can actually show, which keying on the wake onset does not.
    ///
    /// **A nap with no asleep duration is not a nap**, so `nil` rather than a zero: `?? 0` here would
    /// store a nap the user never took. The export populates this column on all eight rows.
    static func makeNap(from row: WhoopExportRow, calendar: Calendar) -> SleepNap? {
        guard let start = row.sleepOnset, let end = row.wakeOnset, end > start,
            let asleepMinutes = row.asleepMinutes
        else { return nil }

        return SleepNap(
            id: Self.napID(startingAt: start),
            date: calendar.startOfDay(for: start),
            startTime: start,
            endTime: end,
            asleepSeconds: asleepMinutes * 60)
    }

    /// A nap's stable identity: its own start instant, to the second.
    ///
    /// Deliberately not a `UUID` — see `NapRecord`'s doc comment. The import has to be idempotent, and
    /// a fresh id per run writes eight more rows every time the button is pressed.
    static func napID(startingAt start: Date) -> String {
        String(Int(start.timeIntervalSince1970))
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
