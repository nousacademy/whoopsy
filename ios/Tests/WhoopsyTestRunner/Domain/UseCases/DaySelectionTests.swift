import Foundation
import Whoopsy

// MARK: - 12. Choosing a day

/// A day the user picks must be **read**, and reading it must not disturb it.
///
/// The three metric screens were blank for imported history because each was wired to
/// `execute(for: Date())` — a recompute, never a read. The obvious repair (hand them a day picker and
/// keep the use case) is still the wrong one, though for a different reason than it was: an imported
/// day has no `biometric_samples` by construction, so `execute(for:)` on one comes back as no row at
/// all and would blank the day it was asked about. Before the calculate use cases stopped storing
/// placeholders it was worse — they saved `score: 0` over whatever was stored, so paging back would
/// have replaced all 910 imported recoveries and all 931 imported strains with their placeholder
/// shape.
///
/// So this section asserts both halves: the read finds the imported day, which is what makes it
/// visible at all, and then the real view models are driven over that day and every row must come
/// back identical. The second half is the regression guard — "the screen does not write" is a
/// property of the screen's *wiring*, and it is exactly what a later change could undo by handing
/// `load(for:)` a use case again.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum DaySelectionTests {
    static func run() async throws {
        let csvURL = whoopExportURL()
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            assertTest(false, "The bundled export is missing at \(csvURL.path)")
            return
        }

        // Its own in-memory database and its own import, so the section stands alone whatever §11 did.
        let db = LocalDatabaseManager(inMemory: true)
        let recoveryRepository = GRDBRecoveryRepository(db: db)
        let sleepRepository = GRDBSleepRepository(db: db)
        let strainRepository = GRDBStrainRepository(db: db)
        let napRepository = GRDBNapRepository(db: db)
        let profile = GRDBUserProfileRepository(db: db)

        do {
            _ = try await WhoopExportImporter(
                recoveryRepository: recoveryRepository,
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                napRepository: napRepository,
                workoutRepository: GRDBWorkoutRepository(db: db),
                userProfileRepository: profile,
                calendar: Calendar.current
            ).importExport(at: csvURL)

            // Each kind of row is read from its own last day rather than all from one. The export's
            // partial cycles make those days differ — a strain-only cycle has no recovery, and one scored
            // night has no strain — so picking a single day and demanding all three would assert something
            // about the export's shape rather than about the read.
            func lastDay(_ dates: [Date]) -> Date? { dates.max() }
            guard
                let lastRecoveryDay = lastDay(try await recoveryRepository.getRecoveryHistory(days: 4000).map(\.date)),
                let lastStrainDay = lastDay(try await strainRepository.getStrainHistory(days: 4000).map(\.date)),
                let lastSleepDay = lastDay(try await sleepRepository.getSleepHistory(days: 4000).map(\.date))
            else {
                assertTest(false, "The import wrote rows of each kind to read back")
                return
            }
            assertTest(true, "The import wrote rows of each kind to read back")

            // ── The read the screens now make ────────────────────────────────────────────────────────
            assertTest(
                try await recoveryRepository.getRecovery(for: lastRecoveryDay)?.hasMeasurement == true,
                "The chosen day reads back a real recovery, not a placeholder")
            assertTest(
                try await recoveryRepository.getRecovery(for: lastRecoveryDay)?.hrvMetric == .rmssd,
                "It carries the export's RMSSD classification")
            assertTest(
                try await sleepRepository.getSleepSession(for: lastSleepDay) != nil,
                "The chosen day reads back a sleep session")
            assertTest(
                try await strainRepository.getStrain(for: lastStrainDay) != nil,
                "The chosen day reads back a strain")

            // ── The window anchor, which is why the screen was blank ─────────────────────────────────
            //
            // `endingOn` is the fix. Asserted by moving the anchor rather than by comparing against
            // `Date()`, so the result does not depend on the day this suite happens to run.
            let windowEndingOnLastDay = try await recoveryRepository.getRecoveryHistory(
                days: 14, endingOn: lastRecoveryDay)
            assertTest(!windowEndingOnLastDay.isEmpty, "A 14-day window ending on the last imported day is populated")
            assertTest(
                windowEndingOnLastDay.contains { $0.date == lastRecoveryDay },
                "…and it includes the day the window ends on")

            let sixtyDaysLater = Calendar.current.date(byAdding: .day, value: 60, to: lastRecoveryDay)!
            assertTest(
                try await recoveryRepository.getRecoveryHistory(days: 14, endingOn: sixtyDaysLater).isEmpty,
                "The same window 60 days later is empty — the anchor is real, not ignored")

            // The upper bound is not decoration. Without it a window anchored on an old day would run on
            // to now, and a chart of that day's fortnight would silently be a chart of everything since.
            let wideWindow = try await recoveryRepository.getRecoveryHistory(days: 4000, endingOn: lastRecoveryDay)
            let past = wideWindow.filter { $0.date > lastRecoveryDay }
            assertTest(past.isEmpty, "No row after the window's end day is returned (got \(past.count) past the bound)")

            // ── Reading must not write ───────────────────────────────────────────────────────────────
            //
            // The live use cases, built on a strap that recorded nothing — which is the true shape of an
            // imported day, since the import writes no `biometric_samples`. If either use case were
            // reachable from `load(for:)`, a recompute over this day would come back as no row at all and
            // replace what the screen was showing.
            let strapThatRecordedNothing = EmptyBiometricStore()

            let recoveryBefore = try await db.getRecovery(for: lastRecoveryDay)
            let strainBefore = try await db.getStrain(for: lastStrainDay)
            let sleepBefore = try await sleepRepository.getSleepSession(for: lastSleepDay)

            let recoveryViewModel = await MainActor.run {
                RecoveryViewModel(
                    calculate: CalculateRecoveryUseCase(
                        biometricRepository: strapThatRecordedNothing,
                        recoveryRepository: recoveryRepository,
                        sleepRepository: sleepRepository,
                        userProfileRepository: profile),
                    repository: recoveryRepository,
                    sleepRepository: sleepRepository)
            }
            await recoveryViewModel.load(for: lastRecoveryDay)

            // The breakdown the screen draws. `RecoveryDetailView` prints four figures each against a
            // trailing baseline, so a read that returns the day but no window leaves every row a bare
            // number with nothing to compare against — a screen that looks like it works and explains
            // nothing. Asserted on an imported day because that is the hard case: the values are read
            // from the database rather than recomputed, and the baseline has to be rebuilt from the same
            // thirty days the importer scored against, out of a table holding nine hundred.
            let loadedBaselines = await MainActor.run { recoveryViewModel.baselines }
            assertTest(
                loadedBaselines?.displayed.hrvMs != nil,
                "A day read back carries an HRV baseline for the screen to print beneath it")
            assertTest(
                loadedBaselines?.displayed.restingHeartRate != nil,
                "…and a resting-heart-rate baseline")
            assertTest(
                loadedBaselines?.displayed.sleepPerformance != nil,
                "…and a sleep-performance baseline, which is the one drawn from the other table")
            assertTest(
                loadedBaselines?.displayed.respiratoryRate != nil,
                "…and a respiratory-rate baseline, which is the one the score does not read")

            // The week card at the foot of the same screen. A `nil` week and a week with no measurement in
            // it draw the same thing — no chart — so a wiring break here is invisible on screen, which is
            // why the assignment is asserted rather than left to the screenshot.
            let loadedWeek = await MainActor.run { recoveryViewModel.week }
            assertTest(
                loadedWeek != nil,
                "A day loaded through the view model builds the week card's window")
            assertTest(
                loadedWeek?.days.count == MetricWeek.dayCount,
                "…with exactly \(MetricWeek.dayCount) slots (got \(loadedWeek?.days.count ?? -1))")
            assertTest(
                loadedWeek?.endingOn == lastRecoveryDay.startOfDay,
                "…ending on the day that was loaded, not on today")
            assertTest(
                loadedWeek?.days.last?.recoveryScore == recoveryBefore?.recoveryScore,
                "…whose last slot carries the stored day's own score, so the bar and the ring describe one day")

            // A deliberate documentation of the narrowing, in the shape of the `batteryPercentage == 100`
            // assertion below: the page's week is built from the recovery history **alone**, so `strain` is
            // `nil` on every slot and that `nil` means *not asked for* rather than *not measured*. This
            // fails loudly if anyone points the week at a strain-plotted view, where every day of it would
            // read as unmeasured.
            assertTest(
                loadedWeek?.days.allSatisfy { $0.strain == nil } == true,
                "The Recovery page's week carries no strain on any slot — it is built from one history, and that `nil` is 'not asked for', not 'not measured'")

            let strainViewModel = await MainActor.run {
                StrainViewModel(
                    calculate: CalculateStrainUseCase(
                        biometricRepository: strapThatRecordedNothing,
                        strainRepository: strainRepository,
                        userProfileRepository: profile),
                    repository: strainRepository,
                    workoutRepository: GRDBWorkoutRepository(db: db),
                    stepRepository: GRDBStepRepository(db: db))
            }
            await strainViewModel.load(for: lastStrainDay)

            let sleepViewModel = await MainActor.run {
                SleepViewModel(
                    analyze: AnalyzeSleepUseCase(
                        biometricRepository: strapThatRecordedNothing,
                        sleepRepository: sleepRepository,
                        strainRepository: strainRepository,
                        userProfileRepository: profile),
                    repository: sleepRepository,
                    napRepository: napRepository,
                    biometricRepository: strapThatRecordedNothing,
                    analyzeSleepStress: AnalyzeSleepStressUseCase(
                        biometricRepository: strapThatRecordedNothing))
            }
            await sleepViewModel.load(for: lastSleepDay)

            // Not merely "the row still exists": every value a recompute would have replaced is checked,
            // plus `source`, which the placeholder path rebuilds as nil and which is the only thing that
            // records where these rows came from.
            let recoveryAfter = try await db.getRecovery(for: lastRecoveryDay)
            assertTest(
                recoveryAfter?.recoveryScore == recoveryBefore?.recoveryScore,
                "Loading the day left its recovery score alone "
                    + "(\(recoveryBefore?.recoveryScore ?? -1) → \(recoveryAfter?.recoveryScore ?? -1))")
            assertTest(
                recoveryAfter?.hrvValueMs == recoveryBefore?.hrvValueMs,
                "…and its HRV reading (\(recoveryBefore?.hrvValueMs ?? -1) → \(recoveryAfter?.hrvValueMs ?? -1))")
            assertTest(
                recoveryAfter?.source == WhoopExportImporter.sourceLabel,
                "…and its provenance (got \(recoveryAfter?.source ?? "nil"))")

            let strainAfter = try await db.getStrain(for: lastStrainDay)
            assertTest(
                strainAfter?.strainScore == strainBefore?.strainScore,
                "Loading the day left its strain alone "
                    + "(\(strainBefore?.strainScore ?? -1) → \(strainAfter?.strainScore ?? -1))")
            assertTest(
                strainAfter?.source == WhoopExportImporter.sourceLabel,
                "…and its provenance (got \(strainAfter?.source ?? "nil"))")

            // Compared field by field rather than with `==`. `SleepSession` carries a `let id: UUID` that
            // its initialiser defaults to a fresh `UUID()`, and the synthesised `Equatable` includes it —
            // so two separate reads of the same stored night are never equal, and `==` here would fail
            // whatever the database holds. The fields below are the ones a recompute would have replaced.
            let sleepAfter = try await sleepRepository.getSleepSession(for: lastSleepDay)
            assertTest(
                sleepAfter?.startTime == sleepBefore?.startTime
                    && sleepAfter?.endTime == sleepBefore?.endTime
                    && sleepAfter?.lightSleepSeconds == sleepBefore?.lightSleepSeconds
                    && sleepAfter?.deepSleepSeconds == sleepBefore?.deepSleepSeconds
                    && sleepAfter?.remSleepSeconds == sleepBefore?.remSleepSeconds
                    && sleepAfter?.awakeSeconds == sleepBefore?.awakeSeconds
                    && sleepAfter?.sleepPerformancePercentage == sleepBefore?.sleepPerformancePercentage,
                "Loading the day left its sleep session alone")

            // The view models must also be *showing* what was read — a guard that protects the row by
            // rendering nothing would pass every assertion above.
            await MainActor.run {
                assertTest(
                    recoveryViewModel.recovery?.score == recoveryBefore?.recoveryScore,
                    "The Recovery screen displays the stored score")
                assertTest(strainViewModel.strain?.score == strainBefore?.strainScore, "The Strain screen displays the stored score")
                assertTest(sleepViewModel.session != nil, "The Sleep screen displays the stored session")
            }
        } catch {
            assertTest(false, "The day-selection tests threw: \(error)")
        }
    }
}
