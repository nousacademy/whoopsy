import Foundation
import Whoopsy

// MARK: - 13. Sleep Need — the export's own figures, and the guard that keeps them

/// A file of §13's body, cut at the section's own `── Title` boundary and moved verbatim.
/// `SleepNeedTests.run()` calls it, in the order the section ran it in.
///
/// **This file carries the export guard, and it is the only file in §13 that reads the export at
/// all.** Before the split the `guard FileManager.default.fileExists` at the top of this block was a
/// `return` from the section's *whole* body, so a missing CSV silently skipped the respiratory and
/// the debt blocks too — and neither of those reads the export: they are synthetic tachograms and an
/// in-memory database. Scoping the guard to the one file that depends on it is a coverage
/// improvement rather than a reorganisation, and the `assertions=` count is unmoved by it, because
/// the failing branch fires exactly one `assertTest(false, …)` either way.
enum SleepExportProvenanceTests {
    static func run() async throws {
        // ── History is untouched ─────────────────────────────────────────────────────────────────────
        //
        // The assertion that fails if anyone ever routes an imported night through the new formula. Every
        // imported night carries WHOOP's own `Sleep need (min)` — a whole number of minutes — and the
        // strain model cannot reproduce that: it starts at the baseline and only adds. So a single night
        // that needed *less* than 8 hours is proof the stored figure came from WHOOP rather than from
        // `SleepNeedMath`, which has no way to produce one.
        let csvURL = whoopExportURL()
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            assertTest(false, "The bundled export is missing at \(csvURL.path)")
            return
        }

        do {
            let exportDB = LocalDatabaseManager(inMemory: true)
            let exportSleepRepository = GRDBSleepRepository(db: exportDB)
            _ = try await WhoopExportImporter(
                recoveryRepository: GRDBRecoveryRepository(db: exportDB),
                sleepRepository: exportSleepRepository,
                strainRepository: GRDBStrainRepository(db: exportDB),
                napRepository: GRDBNapRepository(db: exportDB),
                workoutRepository: GRDBWorkoutRepository(db: exportDB),
                userProfileRepository: GRDBUserProfileRepository(db: exportDB),
                calendar: Calendar.current
            ).importExport(at: csvURL)

            let imported = try await exportSleepRepository.getSleepHistory(days: 4000)
            // Recomputing the exact day-key count is §11's job; every assertion here is over the set the
            // import actually produced, so a zone that merges two nights on one day key narrows this
            // without weakening any of them.
            assertTest(imported.count > 900, "The export still imports its history (\(imported.count) nights)")

            let needs = imported.map(\.targetSleepNeedSeconds)
            let notWholeMinutes = needs.filter { $0.truncatingRemainder(dividingBy: 60) != 0 }
            assertTest(
                notWholeMinutes.isEmpty,
                "Every imported night still carries WHOOP's own need, in whole minutes "
                    + "(\(notWholeMinutes.count) do not)")

            let belowBaseline = needs.filter { $0 < 8 * 3600 }
            assertTest(
                !belowBaseline.isEmpty,
                "…and \(belowBaseline.count) needed less than the 8-hour baseline — impossible under the "
                    + "strain model, whose floor is the baseline, so these values did not come from it")

            assertTest(
                (needs.min() ?? 0) >= 300 * 60 && (needs.max() ?? 0) <= 660 * 60,
                "The imported needs stay inside WHOOP's own band "
                    + "(\(Int((needs.min() ?? 0) / 60))–\(Int((needs.max() ?? 0) / 60)) min)")

            // ── Sleep Consistency is WHOOP's number, not ours ────────────────────────────────────────
            //
            // Same shape of guard as the need above, and it needs one for the same reason: the importer
            // stores the export's `Sleep consistency %` verbatim, while a *strap* night goes through
            // `SleepConsistencyMath` — and the two are the same `Int` on the same column, so nothing but
            // an assertion keeps one from being quietly routed through the other.
            //
            // The property that separates them is disagreement. The model reproduces WHOOP's figure
            // closely but not exactly (in sample, 79% of nights within ±3 points), so if the stored values
            // had been recomputed rather than read, the two would agree on *every* night. Counting the
            // nights they disagree on by more than the model's own error bar is the assertion that fails
            // under that rewrite — and it is a count of a property rather than of a fixed number of
            // nights, so a device time zone that merges two day keys narrows it without breaking it.
            let consistencies = imported.compactMap(\.sleepConsistency)
            assertTest(
                consistencies.count > 850,
                "The export still imports its own consistency values (\(consistencies.count) of "
                    + "\(imported.count) nights carry one)")
            let outOfBand = consistencies.filter { $0 < 0 || $0 > 100 }
            assertTest(
                outOfBand.isEmpty,
                "Every imported consistency value is inside WHOOP's own 0–100 scale "
                    + "(\(outOfBand.count) are not, e.g. \(outOfBand.prefix(3)))")

            let importedNights = imported.map {
                SleepConsistencyMath.Night(day: $0.date, onset: $0.startTime, wake: $0.endTime)
            }
            let scorable = imported.filter { session in
                importedNights.filter { $0.day < session.date }.count >= SleepConsistencyMath.priorNightCount
            }
            let disagreements = scorable.filter { session in
                guard let stored = session.sleepConsistency else { return false }
                let computed = SleepConsistencyMath.consistency(
                    for: SleepConsistencyMath.Night(
                        day: session.date, onset: session.startTime, wake: session.endTime),
                    history: importedNights)
                guard let computed else { return false }
                return abs(stored - computed) > 3
            }
            assertTest(
                disagreements.count > 50,
                "The stored consistency values are WHOOP's, not this app's recomputation — the model and "
                    + "the export disagree by more than 3 points on \(disagreements.count) of "
                    + "\(scorable.count) scorable nights, which a recomputed column could not do")
        } catch {
            assertTest(false, "The imported-history guard threw: \(error)")
        }
    }
}
