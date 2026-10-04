import Foundation
import Whoopsy

// MARK: - 6. End-to-End Clean Architecture & Local Data Sovereignty

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum DIContainerTests {
    static func run() async throws {
        let container = DIContainer(useMockBLE: true)

        // Calculate Recovery UseCase. As with Sleep below, this runs against the shared dev database and
        // a mock strap that recorded nothing, so both outcomes are checked only for what must hold of
        // them: a day with a reading scores in range, and a day without one reports no reading rather
        // than a row of zeros. The "answers nil *and* writes nothing" rule is asserted in §10, where the
        // database is in memory and the sample source is empty.
        let recovery = try await container.calculateRecoveryUseCase.execute()
        if let recovery {
            assertTest(recovery.score >= 0 && recovery.score <= 100, "Recovery UseCase returned valid score: \(recovery.score)%")
            assertTest(recovery.hasMeasurement, "A returned recovery carries a measurement, not a reserved zero")
        } else {
            assertTest(true, "Recovery UseCase reported no measurement rather than inventing a row")
        }

        // Calculate Strain UseCase
        let strain = try await container.calculateStrainUseCase.execute()
        if let strain {
            assertTest(strain.score >= 0.0 && strain.score <= 21.0, "Strain UseCase returned valid score: \(strain.score)")
            assertTest(strain.hasMeasurement, "A returned strain carries a measurement, not a reserved zero")
        } else {
            assertTest(true, "Strain UseCase reported no measurement rather than inventing a row")
        }

        // Analyze Sleep UseCase. This runs against the shared dev database, which is not under the
        // suite's control — whether a night exists for today depends on what this machine has recorded,
        // and a database written by an older build can hold rows no current code would produce. So both
        // outcomes are checked only for what must hold of them. The "answers nil *and* writes nothing"
        // rule is asserted in §10, where the database is in memory and the sample source is empty.
        let sleep = try await container.analyzeSleepUseCase.execute()
        if let sleep {
            assertTest(sleep.sleepPerformancePercentage >= 0 && sleep.sleepPerformancePercentage <= 100, "Sleep UseCase returned valid performance: \(sleep.sleepPerformancePercentage)%")
        } else {
            assertTest(true, "Sleep UseCase reported no session: no classifiable samples for today")
        }

        // Export Data UseCase (Data Sovereignty)
        let exportResult = try await container.exportLocalDataUseCase.execute()
        assertTest(!exportResult.jsonString.isEmpty, "JSON local backup generated successfully")
        assertTest(exportResult.csvHeartRates.contains("Timestamp,HeartRateBPM"), "CSV heart rate telemetry exported properly")

        // **The export is the whole store, and these are the assertions that say so.** It used to be a
        // 30-day window whose JSON carried four *counts* — `sampleCount`, `recoveriesCount` and so on —
        // so nothing on this database could distinguish a complete export from one that had silently
        // dropped a table. What it is now is every row of every table the migrations created, under the
        // table's own column names, with the app's settings beside it.
        //
        // **The table set is asserted against `existingTableNames()`, which is the same `sqlite_master`
        // query the export walks.** That is the strongest form available here: it is not a pinned list
        // that a `v21` would make stale, it is the live schema, so a migration that adds a table cannot
        // land unexported — the one failure an export has that no screen and no build can see, since
        // nobody opens the file during a build.
        let exportedTables = Set(exportResult.tableRowCounts.keys)
        let liveTables = Set(try await LocalDatabaseManager.shared.existingTableNames())
        assertTest(
            exportedTables == liveTables && !liveTables.isEmpty,
            "The export covers every table the database has (\(exportedTables.count) of \(liveTables.count)"
                + "): a table present in one set and absent from the other is an export quietly missing "
                + "part of the user's record, which is what a hand-written per-table read produces the "
                + "day someone adds a migration")
        assertTest(
            exportResult.totalRows == exportResult.tableRowCounts.values.reduce(0, +),
            "…and the row total is the sum of the per-table counts, so the figure the screen's sentence "
                + "prints cannot disagree with the tables it is counting")

        // Parsed rather than string-matched, because the claim is about the document's shape: a file
        // that had shipped `rowCounts` alone — which is what the old four-count JSON was — would
        // satisfy every "non-empty string" test above it.
        let exportJSON = try JSONSerialization.jsonObject(with: Data(exportResult.jsonString.utf8))
            as? [String: Any]
        let exportTables = exportJSON?["tables"] as? [String: [[String: Any]]]
        assertTest(exportTables != nil, "The export's JSON carries rows and not only counts")
        assertTest(
            (exportTables.map { Set($0.keys) } ?? []) == exportedTables,
            "…and the JSON's `tables` and the result's `rowCounts` name the same tables, so the summary "
                + "beside the file and the file itself cannot come apart")
        assertTest(
            exportJSON?["app"] as? String == ExportLocalDataUseCase.appName,
            "…and it names the app that wrote it, so a file found on disk is identifiable without its "
                + "filename")

        // **A row's keys are the table's own column names**, read off the table rather than off a
        // record's `CodingKeys` — and on this schema those disagree, `recoveries` being snake_case
        // (`hrv_value_ms`) and `strains` camelCase (`strainScore`). An export going through the records
        // would have to pick one convention and be wrong about half the database, and `grdb_migrations`
        // would be absent from it altogether, having no record type at all.
        var rowKeysMatchColumns = true
        for (table, rows) in exportTables ?? [:] {
            let columns = Set(try await LocalDatabaseManager.shared.columnNames(in: table))
            for row in rows where Set(row.keys) != columns { rowKeysMatchColumns = false }
        }
        assertTest(
            rowKeysMatchColumns,
            "Every exported row carries its table's own columns, which is what makes the file legible "
                + "without this app: the keys are read off the table, so they cannot disagree with the "
                + "schema the way a record's `CodingKeys` can — `recoveries` is snake_case and `strains` "
                + "is camelCase, and a reader of the file needs the name the database actually uses")

        // The second store. `AppPreferences` is `UserDefaults`-backed and is a row in no table, so an
        // export reading only the database would leave the unit choice and the three toggles out — which
        // is the half of the user's instruction that says *"local or a database"*.
        let exportSettings = exportJSON?["settings"] as? [String: Any]
        assertTest(
            exportSettings?["analyticsEnabled"] != nil
                && exportSettings?["healthKitSyncEnabled"] != nil
                && exportSettings?["liveHeartRateBroadcastEnabled"] != nil
                && exportSettings?.keys.contains("usesMetricUnits") == true,
            "The export carries the app's settings beside its tables. They live in `UserDefaults` and "
                + "in no table, so this is the one part of the record a database read cannot reach — and "
                + "`usesMetricUnits` is asserted by **key presence** rather than by value, because its "
                + "`nil` means *nobody has chosen* and is written as JSON `null` rather than dropped: a "
                + "missing key would say the setting does not exist")
    }
}
