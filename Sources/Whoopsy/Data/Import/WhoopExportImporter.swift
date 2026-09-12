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
    private let userProfileRepository: any UserProfileRepository
    private let calendar: Calendar

    public init(
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        userProfileRepository: any UserProfileRepository,
        calendar: Calendar = .current
    ) {
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
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

    /// Imports the export that shipped with the app.
    ///
    /// This is where `Bundle.module` is touched, and it is deliberately only reachable from a
    /// user-initiated action — see `bundledExportURL()`.
    public func importBundledExport() async throws -> WhoopImportSummary {
        guard let url = Self.bundledExportURL() else { throw WhoopExportError.notBundled }
        return try await importExport(at: url)
    }

    public func importExport(at url: URL) async throws -> WhoopImportSummary {
        let rows = try WhoopExportParser.parseCycles(at: url)
        let profile = try await userProfileRepository.getUserProfile()
        return try await importRows(rows, profile: profile)
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
            sleepStages: [])
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
