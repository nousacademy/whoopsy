import Foundation
import SwiftUI
import Whoopsy

// MARK: - 11. WHOOP export import

/// The export is read for real, and written into an in-memory database — no device, no bundle, and
/// nothing left on disk. This is the only place the day-keying, the unit conversions and the
/// precedence rule are exercised together against the actual 935-row file.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum WhoopExportImportTests {
    static func run() async throws {
        // Two calendars, because two different jobs need one.
        //
        // `utcCalendar` builds absolute instants from the wall-clock times in the file — that is what
        // makes the timezone assertion below meaningful. `dayCalendar` is `Calendar.current`, and it is
        // what the importer must be given: `LocalDatabaseManager.save*` snaps every write with the
        // `Date.startOfDay` extension, which is `Calendar.current` and is not injectable. Handing the
        // importer a calendar in another zone does not shift the day keys, it splits them — the importer
        // computes `startOfDay` in one zone, the database re-snaps in another, and a UTC midnight lands on
        // the previous day. Production passes `.current`, so the two agree; the test must too.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayCalendar = Calendar.current

        func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            return utcCalendar.date(from: components)!
        }

        func displayDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: date)
        }

        let csvURL = whoopExportURL()
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            assertTest(false, "The bundled export is missing at \(csvURL.path)")
            return
        }

        // ── The file's own contract, asserted before anything is written ─────────────────────────────
        // These counts stand on their own because a parser that silently dropped a row would still
        // satisfy every write assertion below. `CSVImporter` was exactly that failure: it returned `[]`
        // and threw nothing, because `ISO8601DateFormatter` yields nil for `2026-08-22 00:17:13`.
        let rows: [WhoopExportRow]
        do {
            rows = try WhoopExportParser.parseCycles(at: csvURL)
            assertTest(rows.count == 935, "Parsed all 935 rows from the export (got \(rows.count))")
            assertTest(
                rows.filter { $0.wakeOnset != nil }.count == 910,
                "910 rows carry a wake onset (got \(rows.filter { $0.wakeOnset != nil }.count))")
            assertTest(
                rows.filter(\.isEmpty).count == 1,
                "Exactly one row is empty (got \(rows.filter(\.isEmpty).count))")

            // The zone column is part of the value, not a display detail. 2024-01-14 01:39:10 at
            // UTC-05:00 is 06:39:10 UTC, and a parser that ignored the column would place it five hours
            // early — which the day key alone would not catch, since the date survives a five-hour shift.
            guard let known = rows.first(where: { $0.cycleStart == utc(2024, 1, 14, 6, 39, 10) }) else {
                assertTest(false, "The 2024-01-14 row was parsed with the export's own UTC offset")
                return
            }
            assertTest(true, "The 2024-01-14 row was parsed with the export's own UTC offset")
            assertTest(known.wakeOnset == utc(2024, 1, 14, 14, 4, 15), "Its wake onset is 14:04:15 UTC")
            assertTest(known.hrvMs == 50.0, "Its HRV parses to 50 ms (got \(known.hrvMs ?? -1))")
            assertTest(known.restingHeartRate == 57, "Its resting heart rate parses to 57 bpm")
            assertTest(known.bloodOxygenPercent == 98.33, "Its SpO2 parses to 98.33 (no ×100)")
            assertTest(known.lightMinutes == 179, "Its light sleep parses to 179 minutes")
            assertTest(known.sleepNeedMinutes == 602, "Its sleep need parses to 602 minutes")
        } catch {
            assertTest(false, "Parsing the real export threw: \(error)")
            return
        }

        // ── The day keys, recomputed independently of the importer ───────────────────────────────────
        //
        // Derived from the parsed rows rather than written down as literals. The device zone decides
        // `startOfDay`, and the two strain-only cycles that begin at 23:30 sit right on a date boundary —
        // in the export's own zone they collide with the closed cycle that already claims the day, one
        // zone east they do not. The importer's rule is asserted by recomputing the key set here, so the
        // assertion holds wherever this runs and still fails if the rule changes.
        let expectedRecoveryDays = Set(
            rows
                .filter { $0.wakeOnset != nil && ($0.hrvMs ?? 0) > 0 && $0.restingHeartRate != nil }
                .map { dayCalendar.startOfDay(for: $0.wakeOnset!) })
        let expectedSleepDays = Set(
            rows
                .filter { $0.sleepOnset != nil && $0.wakeOnset != nil && $0.wakeOnset! > $0.sleepOnset! }
                .map { dayCalendar.startOfDay(for: $0.wakeOnset!) })
        let expectedStrainDays = Set(
            rows
                .filter { $0.dayStrain != nil }
                .map { dayCalendar.startOfDay(for: $0.wakeOnset ?? $0.cycleStart) })

        assertTest(expectedRecoveryDays.count == 910, "910 rows have both an HRV and a resting heart rate")
        assertTest(expectedSleepDays.count == 910, "910 rows describe a night")
        assertTest(
            expectedStrainDays.count == 933 || expectedStrainDays.count == 931,
            "933 Day Strain values land on \(expectedStrainDays.count) distinct days "
                + "(931 where a fragment collides with its closed cycle)")

        // Every non-empty row contributes at least one row of its own — a row with a wake onset always
        // has a night in it, and a strain-only cycle always has its Day Strain — so the first entry for a
        // day always writes, and every *later* entry for that same day finds it taken. Those later rows
        // are `duplicateExportRows`, which is what this figure is: the export's own collisions, not
        // pre-existing local history.
        let entryCount = rows.filter { !$0.isEmpty }.count
        let entryDays = Set(
            rows
                .filter { !$0.isEmpty }
                .map { dayCalendar.startOfDay(for: $0.wakeOnset ?? $0.cycleStart) })
        let expectedAlreadyRecorded = entryCount - entryDays.count

        // ── The import ───────────────────────────────────────────────────────────────────────────────
        let db = LocalDatabaseManager(inMemory: true)
        let recoveryRepository = GRDBRecoveryRepository(db: db)
        let sleepRepository = GRDBSleepRepository(db: db)
        let strainRepository = GRDBStrainRepository(db: db)
        let napRepository = GRDBNapRepository(db: db)
        let importer = WhoopExportImporter(
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            napRepository: napRepository,
            workoutRepository: GRDBWorkoutRepository(db: db),
            userProfileRepository: GRDBUserProfileRepository(db: db),
            calendar: dayCalendar)

        do {
            let summary = try await importer.importExport(at: csvURL)

            assertTest(
                summary.recoveriesWritten == expectedRecoveryDays.count,
                "Wrote one recovery per measured day (\(summary.recoveriesWritten))")
            assertTest(
                summary.sleepsWritten == expectedSleepDays.count,
                "Wrote one sleep session per night (\(summary.sleepsWritten))")
            assertTest(
                summary.strainsWritten == expectedStrainDays.count,
                "Wrote one strain day per distinct Day Strain date (\(summary.strainsWritten))")
            // Nothing was recorded before this import ran, so nothing may be reported as pre-existing.
            // The `expectedAlreadyRecorded` collisions are the export's own duplicate rows and are counted
            // separately — reporting them here is what made a fresh install claim history it never had.
            assertTest(
                summary.daysAlreadyRecorded == 0,
                "A fresh database reports nothing already recorded (got \(summary.daysAlreadyRecorded))")
            assertTest(
                summary.duplicateExportRows == expectedAlreadyRecorded,
                "\(expectedAlreadyRecorded) export rows shared a day with an earlier row "
                    + "(got \(summary.duplicateExportRows))")
            assertTest(summary.daysWithoutData == 0, "Every non-empty row yielded something to write")

            // `daysWritten` and `strainOnlyDays` are day counts, so they come from sets, not from the
            // per-table row counts above — a day can appear in two tables or in one, and the row totals
            // cannot tell those apart. On a fresh database every non-empty row writes something (the
            // proof is the `expectedAlreadyRecorded` comment), so every entry day is a written day.
            assertTest(
                summary.daysWritten == entryDays.count,
                "The summary reports \(entryDays.count) distinct days written (got \(summary.daysWritten))")

            let expectedStrainOnly = expectedStrainDays.subtracting(expectedRecoveryDays)
            assertTest(
                summary.strainOnlyDays == expectedStrainOnly.count,
                "\(expectedStrainOnly.count) days carry a strain and no recovery (got \(summary.strainOnlyDays))")

            // The reason this field is not `strainsWritten - recoveriesWritten`. That subtraction is only
            // right when no day falls the other way, and days do: a night scored with no Day Strain is as
            // ordinary as a strain-only cycle. Asserted only when such a day exists, so the check records
            // the trap rather than failing on an export where the two figures happen to coincide.
            let recoveryDaysWithoutStrain = expectedRecoveryDays.subtracting(expectedStrainDays)
            let strainSurplus = summary.strainsWritten - summary.recoveriesWritten
            if !recoveryDaysWithoutStrain.isEmpty {
                assertTest(
                    summary.strainOnlyDays > strainSurplus,
                    "The set difference (\(summary.strainOnlyDays)) exceeds strains − recoveries "
                        + "(\(strainSurplus)) because "
                        + "\(recoveryDaysWithoutStrain.count) scored day(s) carry no strain")
            }

            // ── Day keys ─────────────────────────────────────────────────────────────────────────────
            // Read back through the same keyed lookups the app uses. A raw-timestamp write would leave a
            // row that is present in the table and unreachable by any of them.
            let recoveries = try await recoveryRepository.getRecoveryHistory(days: 4000)
            assertTest(recoveries.count == expectedRecoveryDays.count, "Reading history returns every recovery")
            assertTest(
                recoveries.allSatisfy { $0.date == dayCalendar.startOfDay(for: $0.date) },
                "Every recovery day key is a startOfDay")
            assertTest(
                Set(recoveries.map(\.date)) == expectedRecoveryDays,
                "The stored recovery days are exactly the days the export measured")
            assertTest(
                recoveries.allSatisfy { $0.hrvMetric == .rmssd && $0.hrvValueMs > 0 && $0.hasMeasurement },
                "Every imported recovery is a measured RMSSD row")

            let sleeps = try await sleepRepository.getSleepHistory(days: 4000)
            assertTest(sleeps.count == expectedSleepDays.count, "Reading history returns every sleep session")
            assertTest(
                Set(sleeps.map(\.date)) == expectedSleepDays, "The stored sleep days are exactly the nights")

            let strains = try await strainRepository.getStrainHistory(days: 4000)
            assertTest(strains.count == expectedStrainDays.count, "Reading history returns every strain day")
            assertTest(
                Set(strains.map(\.date)) == expectedStrainDays,
                "The stored strain days are exactly the days the export scored")
            assertTest(
                strains.allSatisfy { $0.date == dayCalendar.startOfDay(for: $0.date) },
                "Every strain day key is a startOfDay")

            // The summary's span must describe everything written, across all three tables — the earliest
            // day of all is 2023-07-22, a strain-only cycle with no recovery and no night, so checking it
            // against the recoveries alone would report a span four hours short of the truth. Compared
            // against the stored rows rather than a literal, since the span is what the user is shown as
            // evidence the import landed in the right place.
            let storedDays = Set(recoveries.map(\.date))
                .union(sleeps.map(\.date))
                .union(strains.map(\.date))
                .sorted()
            assertTest(
                summary.firstDay == displayDate(storedDays.first!) && summary.lastDay == displayDate(storedDays.last!),
                "The reported span (\(summary.firstDay) → \(summary.lastDay)) matches the rows written")
            assertTest(
                summary.message.contains(summary.firstDay) && summary.message.contains(summary.lastDay),
                "The message shown to the user carries the span")

            // ── Scoring ──────────────────────────────────────────────────────────────────────────────
            // The distribution is the assertion, not the individual values. `BaselineStatisticsMath`
            // anchors at 50 and moves by `z × 24` and `z × −18` against a ±4 z clamp, so two standard
            // deviations in HRV alone spans ±48 points — a day at 1 or 99 is the formula working, not
            // failing. What would be a failure is a history with no spread at all (every day at 50, i.e.
            // a baseline that never moved) or a run pinned entirely to one end.
            let distinctScores = Set(recoveries.map(\.score))
            assertTest(distinctScores.count > 20, "Scores span a real range (\(distinctScores.count) distinct values)")
            assertTest(recoveries.contains { $0.score > 1 }, "Not every day is pinned to the floor")
            assertTest(recoveries.contains { $0.score < 99 }, "Not every day is pinned to the ceiling")
            let saturated = recoveries.filter { $0.score == 1 || $0.score == 99 }.count
            assertTest(
                saturated < recoveries.count / 2,
                "Most days land inside the clamp (\(saturated) of \(recoveries.count) saturate)")

            // ── One day, field by field ──────────────────────────────────────────────────────────────
            // 2026-08-19, chosen because WHOOP's own `Sleep performance %` column says 30 for it while
            // asleep-over-need is 284/572 = 50%. The gap is what makes the assertion sharp: a stored 50
            // proves the app derived the figure, and a stored 30 would prove it copied the export's.
            let knownDay = dayCalendar.startOfDay(for: utc(2026, 8, 19, 12, 23, 23))

            let knownRecovery = try await recoveryRepository.getLocalRecovery(for: knownDay)
            assertTest(knownRecovery?.hrvValueMs == 31.0, "That day's HRV round-trips as 31 ms")
            assertTest(knownRecovery?.restingHeartRate == 66, "That day's resting heart rate round-trips as 66 bpm")
            assertTest(knownRecovery?.spO2Percentage == 96.5, "That day's SpO2 round-trips as 96.5")

            let knownSleep = try await sleepRepository.getSleepSession(for: knownDay)
            assertTest(knownSleep?.targetSleepNeedSeconds == 572 * 60, "Sleep need became seconds (572 min)")
            assertTest(knownSleep?.deepSleepSeconds == 152 * 60, "Deep sleep became seconds (152 min)")
            // The unit error that would otherwise look like a night rather than a bug: minutes stored as
            // seconds reads as 105 seconds of light sleep, and nothing else on the screen contradicts it.
            assertTest(knownSleep?.lightSleepSeconds == 105 * 60, "Light sleep became seconds (105 min)")
            assertTest((knownSleep?.lightSleepSeconds ?? 0) > 3600, "Light sleep is in seconds, not minutes")
            assertTest(
                knownSleep?.sleepPerformancePercentage == 50,
                "Sleep performance is derived from asleep-over-need, not copied from the export "
                    + "(got \(knownSleep?.sleepPerformancePercentage ?? -1), export says 30)")
            assertTest(knownSleep?.respiratoryRate == 16.5, "Respiratory rate round-trips as 16.5 rpm")
            assertTest(
                knownSleep?.sleepDebtSeconds == 77 * 60,
                "Sleep debt became seconds (77 min), not minutes — a raw 77 would render as a 1-minute "
                    + "debt on a row that reads in minutes (got \(knownSleep?.sleepDebtSeconds ?? -1))")
            assertTest(knownSleep?.disturbanceCount == nil, "No disturbance count is invented")
            assertTest(knownSleep?.sleepStages.isEmpty == true, "No stage timeline is invented")

            let knownStrain = try await strainRepository.getStrain(for: knownDay)
            assertTest(knownStrain?.score == 5.4, "That day's strain round-trips as 5.4")
            assertTest(knownStrain?.averageHeartRate == 72, "Average heart rate round-trips as 72 bpm")
            assertTest(knownStrain?.maxHeartRate == 156, "Peak heart rate round-trips as 156 bpm")
            assertTest(
                abs((knownStrain?.activeCalories ?? 0) - 1973) < 0.01,
                "Energy survives the kilojoule conversion (got \(knownStrain?.activeCalories ?? -1) kcal)")
            assertTest(
                knownStrain?.zones.isEmpty == true,
                "No heart-rate zones are invented — the export carries a total, not a distribution")

            // ── Naps, which are a second file rather than a second table ─────────────────────────────
            //
            // `sleeps.csv`'s eight nap rows are its entire unique contribution: its other 910 rows are
            // this file's 910 nights, set-for-set. So the whole of this path is exercised here against
            // the real file rather than a fixture, and the two properties that matter are asserted
            // separately — that a nap lands on the day it was *taken*, and that it is stored as a nap
            // (a window and a duration) and never as a night carrying a performance.
            let napsURL = whoopNapsURL()
            var napsWritten = 0
            if !FileManager.default.fileExists(atPath: napsURL.path) {
                assertTest(false, "The bundled sleep file is missing at \(napsURL.path)")
            } else {
                let napRows = try WhoopExportParser.parseNaps(at: napsURL)
                assertTest(!napRows.isEmpty, "The sleep file carries nap rows (\(napRows.count))")
                assertTest(napRows.allSatisfy { $0.isNap == true }, "…and every row it returns is one")

                // Pointed at the cycle file, the nap parser must refuse rather than find nothing. This is
                // the assertion that fails if `Nap` stops being a required column: without it the parser
                // reads the whole cycle file, filters to zero rows, and reports a successful import of
                // nothing — the failure shape `WhoopExportError` exists to prevent.
                do {
                    _ = try WhoopExportParser.parseNaps(at: csvURL)
                    assertTest(false, "Pointing the nap parser at the cycle file throws")
                } catch let error as WhoopExportError {
                    if case .missingColumns(let names) = error {
                        assertTest(
                            names == ["Nap"],
                            "…naming the one column the cycle file lacks, by its own header spelling "
                                + "(got \(names))")
                    } else {
                        assertTest(false, "The nap parser refused the cycle file with \(error)")
                    }
                }

                napsWritten = try await importer.importNaps(at: napsURL)
                assertTest(
                    napsWritten == napRows.count,
                    "Every parsed nap is written (\(napsWritten) of \(napRows.count))")

                // Read back through the same keyed lookup the sleep screen uses. The day key is the nap's
                // own onset, stated as a property rather than a count so it holds in any time zone.
                var readBackNaps: [SleepNap] = []
                for day in Set(napRows.compactMap { $0.sleepOnset.map(dayCalendar.startOfDay(for:)) }) {
                    readBackNaps += try await napRepository.getNaps(on: day)
                }
                assertTest(
                    readBackNaps.count == napsWritten,
                    "Every written nap is reachable by the day it was taken "
                        + "(\(readBackNaps.count) of \(napsWritten))")
                assertTest(
                    readBackNaps.allSatisfy { $0.date == dayCalendar.startOfDay(for: $0.startTime) },
                    "Every nap's day key is its own onset, not its wake")
                assertTest(
                    readBackNaps.allSatisfy { $0.id == String(Int($0.startTime.timeIntervalSince1970)) },
                    "…and its identity is that same instant, so a re-import updates the row it wrote")

                // The measured fact behind `SleepNap`'s whole reason for existing: every nap is shorter
                // than every need on the same rows. WHOOP's own `Sleep performance %` for these eight is
                // 6–43 because its denominator is a *night's* need, so reading it as a performance would
                // file a deliberate 33-minute nap as a 6% night. Both figures are the file's rather than
                // hardcoded, so the assertion says the same thing on any export.
                let napAsleep = napRows.compactMap(\.asleepMinutes)
                let napNeeds = napRows.compactMap(\.sleepNeedMinutes)
                assertTest(
                    napAsleep.count == napRows.count && napNeeds.count == napRows.count,
                    "Every nap row carries both an asleep duration and a need")
                if let longestNap = napAsleep.max(), let shortestNeed = napNeeds.min() {
                    assertTest(
                        longestNap < shortestNeed,
                        "The longest nap (\(Int(longestNap)) min) is shorter than the shortest need "
                            + "(\(Int(shortestNeed)) min), which is why a nap's own performance is not "
                            + "a performance")
                }

                // A nap's window is not the night table's rule, and the difference is a whole day. Driven
                // through a synthetic *file* rather than the export, because which of the export's eight
                // cross midnight depends on the device time zone — this does not. It carries the whole
                // slice: parse, key, write, read back, which is what makes it a test of the path rather
                // than of one function.
                // The zone is written as the *device's* offset, not as UTC. The export's timestamps are
                // local wall-clock plus the zone they were recorded in, and the day key is then snapped
                // with `Calendar.current` — so a fixture pinned to UTC asserts this property only on a
                // machine that happens to run in UTC. Written as the device's own offset, 23:48 → 02:36
                // crosses local midnight wherever the suite runs, which is what makes it a test of the
                // rule rather than of the time zone.
                let deviceOffset = TimeZone.current.secondsFromGMT()
                let sign = deviceOffset < 0 ? "-" : "+"
                let magnitude = abs(deviceOffset)
                let deviceZoneLabel = String(
                    format: "UTC%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)

                let syntheticURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("whoopsy-nap-fixture.csv")
                try ("Cycle start time,Cycle timezone,Wake onset,Sleep onset,Nap,"
                    + "Asleep duration (min),Sleep need (min)\n"
                    + "2024-08-26 23:48:00,\(deviceZoneLabel),2024-08-27 02:36:00,"
                    + "2024-08-26 23:48:00,true,149,585\n")
                    .write(to: syntheticURL, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: syntheticURL) }

                let crossingDB = LocalDatabaseManager(inMemory: true)
                let crossingRepository = GRDBNapRepository(db: crossingDB)
                let crossingWritten = try await WhoopExportImporter(
                    recoveryRepository: GRDBRecoveryRepository(db: crossingDB),
                    sleepRepository: GRDBSleepRepository(db: crossingDB),
                    strainRepository: GRDBStrainRepository(db: crossingDB),
                    napRepository: crossingRepository,
                    workoutRepository: GRDBWorkoutRepository(db: crossingDB),
                    userProfileRepository: GRDBUserProfileRepository(db: crossingDB),
                    calendar: dayCalendar
                ).importNaps(at: syntheticURL)

                let crossingNaps = try await crossingRepository.getNaps(
                    on: crossingNapsStart(syntheticURL: syntheticURL, calendar: dayCalendar))
                assertTest(crossingWritten == 1, "A nap file with one nap writes one row (got \(crossingWritten))")
                if let crossing = crossingNaps.first {
                    assertTest(
                        crossing.date == dayCalendar.startOfDay(for: crossing.startTime),
                        "A nap that ends the next morning is filed under the evening it began")
                    assertTest(
                        crossing.date != dayCalendar.startOfDay(for: crossing.endTime),
                        "…which is a different day from its wake, so the night table's rule would have "
                            + "moved it a day forward")
                    assertTest(
                        crossing.asleepSeconds == 149 * 60,
                        "…and its duration is the asleep figure, not the length of its window "
                            + "(got \(crossing.asleepSeconds) s)")
                } else {
                    assertTest(false, "The crossing-midnight nap is readable on the evening it began")
                }
            }

            // ── Re-running changes nothing ───────────────────────────────────────────────────────────
            // The assertion that catches a missing `startOfDay` snap: the first run's rows are found by
            // every keyed lookup, so a second run has to see them as already recorded.
            let second = try await importer.importExport(at: csvURL)
            assertTest(second.recoveriesWritten == 0, "A second import writes no recovery")
            assertTest(second.sleepsWritten == 0, "A second import writes no sleep session")
            assertTest(second.strainsWritten == 0, "A second import writes no strain")
            // A run that writes nothing must still report zero days written, or a re-import would claim
            // to have imported history it only recognised.
            assertTest(second.daysWritten == 0, "A second import reports no days written")
            // Now everything really is pre-existing, so the whole export is counted there — and nothing
            // is a duplicate, because this run claimed no day to collide with.
            assertTest(
                second.daysAlreadyRecorded == entryCount,
                "Every one of the \(entryCount) entries is now already recorded (got \(second.daysAlreadyRecorded))")
            assertTest(second.duplicateExportRows == 0, "A second import has no duplicate rows to report")
            assertTest(
                second.message.contains("Nothing to import"),
                "A second import says so rather than reporting an import (got \"\(second.message)\")")
            let afterSecond = try await recoveryRepository.getRecoveryHistory(days: 4000)
            assertTest(afterSecond.count == recoveries.count, "A second import adds no recovery row")

            // Naps are idempotent by a different mechanism than the day-keyed tables — an id derived from
            // the nap's own start instant rather than a snapped day — and it is worth its own assertion,
            // because a fresh `UUID()` here would write eight more rows on every press of the button.
            let secondNaps = try await importer.importNaps(at: whoopNapsURL())
            var napsAfterSecond: [SleepNap] = []
            for day in Set(try WhoopExportParser.parseNaps(at: whoopNapsURL())
                .compactMap { $0.sleepOnset.map(dayCalendar.startOfDay(for:)) }) {
                napsAfterSecond += try await napRepository.getNaps(on: day)
            }
            assertTest(
                secondNaps == napsWritten,
                "A second nap import writes \(napsWritten) rows again, every one onto a row that "
                    + "already existed (got \(secondNaps))")
            assertTest(
                napsAfterSecond.count == napsWritten,
                "…and adds none: the table still holds \(napsWritten) naps (got \(napsAfterSecond.count))")
            assertTest(
                Set(afterSecond.map(\.date)) == expectedRecoveryDays,
                "A second import leaves the day keys exactly as they were")
        } catch {
            assertTest(false, "The WHOOP export import threw: \(error)")
        }
    }

    /// The day key the synthetic nap fixture lands on, derived from the file rather than retyped — the
    /// same shape §11 uses for the export's own day keys, so the assertion holds in any time zone.
    ///
    /// `static` because its only caller is `run()`, which is itself `static` — the split left no instance
    /// for an instance method to hang off, and `whoopNapsURL()` above it is a free function because the
    /// resource paths have no section to belong to.
    static func crossingNapsStart(syntheticURL: URL, calendar: Calendar) -> Date {
        let rows = (try? WhoopExportParser.parseNaps(at: syntheticURL)) ?? []
        return calendar.startOfDay(for: rows.first?.sleepOnset ?? Date())
    }
}
