import Foundation
import Whoopsy

enum SleepViewModelTests {
    static func run() async throws {
        // ── 9. The read, end to end ──────────────────────────────────────────────────────────────────
        //
        // The values above are the chart's substance; this is the same night arriving through the read the
        // card makes. It runs against an in-memory database rather than the export because the subject is
        // the **window**: the two samples below sit either side of midnight, and the night is filed under
        // the morning it ended on — so a read scoped to the day's own bounds would return the later one
        // and drop the earlier, drawing every night half-length.
        do {
            let hrDB = LocalDatabaseManager(inMemory: true)
            let hrSleepRepository = GRDBSleepRepository(db: hrDB)

            let day = Calendar.current.startOfDay(
                for: Calendar.current.date(byAdding: .day, value: -3, to: Date())!)
            let onset = day.addingTimeInterval(-3600)
            let wake = day.addingTimeInterval(6 * 3600)
            try await hrSleepRepository.saveSleepSession(
                SleepSession(
                    date: day,
                    startTime: onset,
                    endTime: wake,
                    lightSleepSeconds: 14400,
                    deepSleepSeconds: 5400,
                    remSleepSeconds: 5400,
                    awakeSeconds: 3600))

            let biometrics = OvernightBiometricStore(samples: [
                BiometricSample(timestamp: onset.addingTimeInterval(600), heartRate: 52),
                BiometricSample(timestamp: day.addingTimeInterval(3600), heartRate: 58),
            ])
            let readBack = await MainActor.run {
                SleepViewModel(
                    analyze: AnalyzeSleepUseCase(
                        biometricRepository: biometrics,
                        sleepRepository: hrSleepRepository,
                        strainRepository: GRDBStrainRepository(db: hrDB),
                        userProfileRepository: GRDBUserProfileRepository(db: hrDB)),
                    repository: hrSleepRepository,
                    napRepository: GRDBNapRepository(db: hrDB),
                    biometricRepository: biometrics,
                    analyzeSleepStress: AnalyzeSleepStressUseCase(biometricRepository: biometrics))
            }
            await readBack.load(for: day)

            let readSeries = await MainActor.run { readBack.hoursOfSleepSeries }
            assertTest(
                readSeries?.points.map(\.bpm) == [52, 58],
                "The view model reads the night's heart rate over the night's own bounds — the 11 PM "
                    + "reading precedes the midnight the night is filed under, and a day-scoped read "
                    + "would have dropped it (got "
                    + "\(readSeries.map { "\($0.points.count) points" } ?? "nil"))")
            assertTest(
                readSeries?.start == onset && readSeries?.end == wake,
                "…and the series' axis is those bounds, not the day's, so the two dashed markers stand at "
                    + "the night's ends")
        } catch {
            assertTest(false, "The heart-rate read block threw: \(error)")
        }

        // ── 10. The sleep page's week chart ──────────────────────────────────────────────────────────
        //
        // The `Weekly Trends` section below the sleep-stress card, and the one element on that page that
        // is not about the night: seven days of sleep performance ending on the night shown. It is
        // asserted against an in-memory database rather than the export because the case that matters is
        // the one the export cannot produce on demand — a day with **no night of its own** whose week
        // still has bars in it. A fresh install opens on exactly that day, so a chart hung off `session`
        // would be absent on the day it is most worth having.
        //
        // The chart itself is not re-asserted here; §14 owns `WeekBarSeries(sleepPerformanceWeek:)` and
        // its absences. What is new is the wiring: that the week is built at all on a nightless day, that
        // it ends on the day being shown, and that it and the three cards above it came off **one** read.
        do {
            let weekDB = LocalDatabaseManager(inMemory: true)
            // The nights are written through the real repository and read back through the counter, so
            // the query under assertion is the one the page actually issues.
            let weekNights = CountingSleepRepository(wrapping: GRDBSleepRepository(db: weekDB))

            let target = Calendar.current.startOfDay(
                for: Calendar.current.date(byAdding: .day, value: -2, to: Date())!)
            // Three nights inside the window and none of them on `target` itself, so the anchor column is
            // the one column on the chart with nothing in it — which is the day this block is about.
            for offset in 3...5 {
                let day = Calendar.current.date(byAdding: .day, value: -offset, to: target)!
                try await weekNights.saveSleepSession(
                    SleepSession(
                        date: day,
                        startTime: day,
                        endTime: day,
                        targetSleepNeedSeconds: 8 * 3600,
                        lightSleepSeconds: 0.75 * 8 * 3600))
            }

            let weekViewModel = await MainActor.run {
                SleepViewModel(
                    analyze: AnalyzeSleepUseCase(
                        biometricRepository: EmptyBiometricStore(),
                        sleepRepository: weekNights,
                        strainRepository: GRDBStrainRepository(db: weekDB),
                        userProfileRepository: GRDBUserProfileRepository(db: weekDB)),
                    repository: weekNights,
                    napRepository: GRDBNapRepository(db: weekDB),
                    biometricRepository: EmptyBiometricStore(),
                    analyzeSleepStress: AnalyzeSleepStressUseCase(
                        biometricRepository: EmptyBiometricStore()))
            }
            await weekViewModel.load(for: target)

            assertTest(
                await MainActor.run { weekViewModel.session } == nil,
                "The day the week chart is asserted on holds no night of its own")
            let week = await MainActor.run { weekViewModel.week }
            assertTest(
                week?.days.count == MetricWeek.dayCount,
                "…and its week is built anyway, from the nights before it, with all "
                    + "\(MetricWeek.dayCount) slots (got \(week?.days.count ?? -1))")
            assertTest(
                week?.endingOn == target,
                "…ending on the day being shown rather than on today, so the highlighted column is that day")
            assertTest(
                week?.days.map(\.sleepPerformance) == [nil, 75, 75, 75, nil, nil, nil],
                "…and each slot states its own night's performance, computed from the night's staged "
                    + "minutes over its need — oldest first, with the three measured nights in the middle "
                    + "and the anchor column absent (got "
                    + "\(week.map { "\($0.days.map(\.sleepPerformance))" } ?? "nil"))")
            assertTest(
                WeekBarSeries(sleepPerformanceWeek: week ?? MetricWeek(endingOn: target))?
                    .points.map(\.slot) == [1, 2, 3],
                "…which the bar series plots as three bars and not four: a column with no night draws no "
                    + "bar and no value label")
            assertTest(
                week?.days.allSatisfy { $0.strain == nil && $0.recoveryScore == nil } == true,
                "This page's week carries no strain and no recovery on any slot — it is built from the "
                    + "sleep history alone, and that `nil` is 'not asked for', not 'not measured'. A view "
                    + "handed this week and asked to plot strain would report every day of it as unmeasured")
            assertTest(
                await weekNights.historyReads == 1,
                "The window's three cards, the sleep-stress baseline and the week chart came off **one** "
                    + "read of the sleep history (got \(await weekNights.historyReads)) — a second read "
                    + "would be a second chance for the chart and the cards above it to describe different "
                    + "nights")
        } catch {
            assertTest(false, "The week-chart block threw: \(error)")
        }

        // ── 11. The real export ──────────────────────────────────────────────────────────────────────
        //
        // The same properties as above, but over 910 real nights rather than fixtures — which is what
        // catches a rounding rule that only works on the shapes someone thought to build. Properties and
        // not counts, so a device time zone that merges two day keys narrows this without breaking it.
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
            let withPeriod = imported.filter { $0.sleepPeriodSeconds > 0 }
            assertTest(
                withPeriod.count > 900,
                "The export still imports its nights with a sleep period (\(withPeriod.count))")

            func durations(_ session: SleepSession) -> [TimeInterval] {
                SleepStageRangeScoring.stages.map { session.seconds(of: $0) }
            }

            let notHundred = withPeriod.filter { session in
                guard let percents = SleepStageRangeScoring.wholePercents(
                    ofSeconds: durations(session)) else { return true }
                return percents.reduce(0, +) != 100
            }
            assertTest(
                notHundred.isEmpty,
                "Every imported night's four shares sum to exactly 100 "
                    + "(\(notHundred.count) of \(withPeriod.count) do not)")

            let farOff = withPeriod.filter { session in
                let values = durations(session)
                guard let percents = SleepStageRangeScoring.wholePercents(ofSeconds: values) else {
                    return true
                }
                let total = values.reduce(0, +)
                return zip(percents, values).contains { percent, seconds in
                    abs(Double(percent) - seconds / total * 100) > 1
                }
            }
            assertTest(
                farOff.isEmpty,
                "…and every one of those percents is within one of its exact share, which is the "
                    + "guarantee the rule actually makes (\(farOff.count) nights are outside it)")

            let mismatched = withPeriod.filter { session in
                SleepStageRangeScoring.summary(for: session, priorNights: [])?.durationSeconds
                    != session.sleepPeriodSeconds
            }
            assertTest(
                mismatched.isEmpty,
                "DURATION equals the night's own sleep period on every imported night — the identity the "
                    + "evaluation verified against the CSV, re-verified here rather than assumed "
                    + "(\(mismatched.count) disagree)")

            // The headline, over real history. Two claims, and the second is the one that matters: every
            // imported night carries a positive hours-of-sleep figure and it adds up with the awake row to
            // that night's own DURATION. That is what makes `HOURS OF SLEEP` a reading on every imported
            // night rather than a dash — the card's absence state belongs to the chart alone, and a
            // headline gated with the chart would blank a figure the export does store.
            let headlineMissing = withPeriod.filter { session in
                guard let s = SleepStageRangeScoring.summary(for: session, priorNights: []) else {
                    return true
                }
                return s.asleepSeconds <= 0
            }
            assertTest(
                headlineMissing.isEmpty,
                "Every imported night carries a positive hours-of-sleep headline — the card is never "
                    + "titled with a dash (\(headlineMissing.count) of \(withPeriod.count) are not)")
            let headlineMismatched = withPeriod.filter { session in
                guard let s = SleepStageRangeScoring.summary(for: session, priorNights: []) else {
                    return true
                }
                return s.asleepSeconds + s.awakeSeconds != s.durationSeconds
            }
            assertTest(
                headlineMismatched.isEmpty,
                "…and on each of them it adds up with the awake row to the same DURATION the typical-range "
                    + "card prints above the four rows (\(headlineMismatched.count) disagree)")

            // The bands over real history, on the export's newest night: four ordered bands, each inside
            // the 0–100 scale the bar is drawn on. What this cannot say is whether the bands are *good* —
            // a quartile is a definition, and the middle half is a choice this app made.
            if let newest = withPeriod.max(by: { $0.date < $1.date }) {
                let exportWindow = RecoveryScoring.baselineWindow(
                    before: newest.date, in: imported)
                let real = SleepStageRangeScoring.summary(for: newest, priorNights: exportWindow)
                let bands = real?.rows.compactMap(\.typical) ?? []
                assertTest(
                    bands.count == 4,
                    "The export's newest night has four bands over a window of "
                        + "\(exportWindow.count) nights")
                assertTest(
                    bands.allSatisfy { $0.lowPercent >= 0 && $0.highPercent <= 100 }
                        && bands.allSatisfy { $0.lowPercent <= $0.highPercent },
                    "…each ordered and inside the 0–100 scale its bar is drawn on, so no marker can be "
                        + "drawn off the end of a track")
                // The count the card reports is the window *after* the same filter the bands were built
                // over, so it is the number of nights that actually contributed — not the length of the
                // list handed in.
                let usable = exportWindow.filter { $0.sleepPeriodSeconds > 0 }
                assertTest(
                    real?.nightCount == usable.count,
                    "…and the count the card reports is the window those bands were taken over "
                        + "(\(usable.count) of \(exportWindow.count) nights are usable)")
            }

            // ── The need's split, over real history ─────────────────────────────────────────────────
            //
            // Every imported night carries WHOOP's own need, and this is the block that holds the need
            // card's box to it. The identity is re-verified against 910 real rows rather than assumed
            // from the fixture block above, because the fixture's numbers were chosen by hand and the
            // export's were not.
            let withDebt = withPeriod.filter { ($0.sleepDebtSeconds ?? 0) > 0 }
            assertTest(
                withDebt.count > 800,
                "The export still carries a stored sleep debt on most of its nights — the column the need "
                    + "card's box is the first and only consumer of (\(withDebt.count) of "
                    + "\(withPeriod.count))")

            // The provenance has to survive the round trip before anything below can mean what it says:
            // the split is gated on it, and a night the mapper marked as not-WHOOP's would lose its box
            // with no error anywhere.
            let notWhoopsNeed = withPeriod.filter { !$0.hasWhoopSleepNeed }
            assertTest(
                notWhoopsNeed.isEmpty,
                "…and every one of them reads back with WHOOP's own need — `sleeps.source` reaching the "
                    + "entity, which is the only thing separating the two producers "
                    + "(\(notWhoopsNeed.count) of \(withPeriod.count) do not)")

            let splitMismatched = withDebt.filter { session in
                guard let b = SleepNeedBreakdown.breakdown(
                    needSeconds: session.targetSleepNeedSeconds,
                    debtSeconds: session.sleepDebtSeconds,
                    hasWhoopNeed: session.hasWhoopSleepNeed) else { return true }
                return b.parts.count != 2
                    || b.parts.reduce(0) { $0 + $1.seconds } != b.needSeconds
                    || b.seconds(of: .minimumAndStrain) != session.targetSleepNeedSeconds
                        - (session.sleepDebtSeconds ?? 0)
            }
            assertTest(
                splitMismatched.isEmpty,
                "…and on every one of them the box's two figures sum to the need printed above it, with "
                    + "the base term exactly `need − debt` — the identity the card asserts on screen "
                    + "(\(splitMismatched.count) disagree)")

            // The guard that is unreachable, and the measurement that says so. `breakdown` refuses a debt
            // larger than its need, so a row that reached it would draw a part longer than the whole; the
            // base term's own range is what keeps the claim from going stale. A writer that started
            // storing the debt in the wrong unit — minutes where the column holds seconds, or a *deficit*
            // where it holds an accumulation — would land every night in this list.
            let baseSeconds = withDebt.compactMap { session -> TimeInterval? in
                guard let debt = session.sleepDebtSeconds else { return nil }
                return session.targetSleepNeedSeconds - debt
            }
            assertTest(
                baseSeconds.allSatisfy { $0 > 0 },
                "…and the base term is positive on every night, so no stored row reaches the "
                    + "`debt > need` guard — the smallest is "
                    + "\((baseSeconds.min() ?? 0).formattedCompactHoursMinutes())")
            assertTest(
                (baseSeconds.min() ?? 0) > 200 * 60 && (baseSeconds.max() ?? 0) < 600 * 60,
                "…and it spans the 228…523 min the design was evaluated against, which is the measurement "
                    + "that makes the guard a guard against a future writer rather than a case this file "
                    + "can reach (got \(Int((baseSeconds.min() ?? 0) / 60))…"
                    + "\(Int((baseSeconds.max() ?? 0) / 60)) min)")

            // ── The window's mean performance, over real windows ─────────────────────────────────────
            //
            // Cross-checked against a mean computed here from the same filtered window rather than
            // against the model that produced it. The agreement is a statement about the *window*: a
            // window that had not been filtered the same way — one that counted a stored night with no
            // sleep period, whose performance is a real-looking `0` — would disagree on any night whose
            // neighbourhood holds one. Only the newest twenty nights are checked, because a window is
            // taken per night and the whole file would be 910 of them.
            let recent = withPeriod.sorted { $0.date > $1.date }.prefix(20)
            let meanMismatched = recent.filter { session -> Bool in
                let window = RecoveryScoring.baselineWindow(before: session.date, in: imported)
                    .filter { $0.sleepPeriodSeconds > 0 }
                guard window.count >= RecoveryScoring.minimumBaselineDays else { return false }
                let hand = window.map { Double($0.sleepPerformancePercentage) }.reduce(0, +)
                    / Double(window.count)
                guard let modelled = SleepStageRangeScoring.summary(
                    for: session, priorNights: window)?.typicalPerformancePercent else { return true }
                return abs(hand - modelled) > 0.0001
            }
            assertTest(
                meanMismatched.isEmpty,
                "The mean the need card heads itself with is the mean of the window's own night figures, "
                    + "over the same filtered window the typical-range card bands — cross-checked on the "
                    + "export's 20 newest nights (\(meanMismatched.count) disagree)")
        } catch {
            assertTest(false, "The typical-range export block threw: \(error)")
        }

    }
}
