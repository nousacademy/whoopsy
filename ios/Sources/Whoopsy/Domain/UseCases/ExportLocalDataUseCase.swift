import Foundation

/// What the `Whoopsy` export hands back, and the sentence the `LOGS` pane prints for it.
///
/// **The counts are on the result rather than left inside the JSON**, for `WhoopImportSummary`'s reason:
/// the screen's sentence has to be a value the runner can assert, and a figure a view digs out of a JSON
/// string is a figure nothing can check. The string itself is still carried, because it is what the
/// share sheet hands on.
public struct LocalExportResult: Sendable {

    /// The whole record, pretty-printed. See `ExportLocalDataUseCase.execute()` for the shape.
    public let jsonString: String

    /// The heart-rate series as CSV — the one table also offered in a form a spreadsheet opens.
    public let csvHeartRates: String

    /// Rows per table, the same map the JSON carries. Empty only for a store with no tables at all,
    /// which no migration set in this app can produce.
    public let tableRowCounts: [String: Int]

    /// Every row in the store, across every table.
    public let totalRows: Int

    public let timestamp: Date

    public init(
        jsonString: String,
        csvHeartRates: String,
        tableRowCounts: [String: Int] = [:],
        totalRows: Int = 0,
        timestamp: Date = Date()
    ) {
        self.jsonString = jsonString
        self.csvHeartRates = csvHeartRates
        self.tableRowCounts = tableRowCounts
        self.totalRows = totalRows
        self.timestamp = timestamp
    }

    /// What the `LOGS` pane prints once the export is ready.
    ///
    /// **It counts rows and tables and not days**, which is the difference from every other sentence on
    /// that pane: the three imports above it describe history they added, and this one describes a
    /// record it handed over — so the honest summary is how much of it there was, not how far back it
    /// went. **The zero case is a real answer rather than a failure**, because a fresh install genuinely
    /// holds nothing, and reporting it as an error would send a user looking for a problem that is not
    /// there. **The settings sentence is not decoration**: the unit choice and the three toggles live in
    /// `UserDefaults` and not in the database, so naming them is what tells the reader the file holds
    /// more than the tables listed beside it.
    public var message: String {
        guard totalRows > 0 else {
            return "Exported an empty record — no rows are stored yet. Settings are included."
        }

        let tables = tableRowCounts.count
        return "Exported \(totalRows) rows from \(tables) "
            + (tables == 1 ? "table" : "tables")
            + ". Settings are included."
    }
}

/// The `Whoopsy` export: everything this app stores, from both places it stores it.
///
/// **It reads the database through `LocalDatabaseSnapshotting` and not through the repositories**, and
/// that is the whole of what makes it complete rather than complete-looking. A read per entity would be
/// a second definition of the schema living in an exporter — one that no migration updates, so a table
/// added later would be silently omitted while the export went on reporting success. The snapshot walks
/// `sqlite_master` instead, so the set of tables in the file is the set of tables in the database by
/// construction. See `LocalDataSnapshot`.
///
/// **`UserDefaults` is the second store, and it is why this type reaches for a preferences repository at
/// all.** `AppPreferences` — the unit choice and the three toggles, including the anonymous-diagnostics
/// switch that is the entire contents of the Settings page — is not a row in any table, so an export
/// reading only the database would leave it out and the file would not be the user's whole record.
///
/// **Nothing here is windowed.** The 30-day bound and the four history reads this replaced are gone; the
/// export is the record, and the only read that is still a window is the CSV's, which is a convenience
/// rendering of one table the JSON already carries in full.
public final class ExportLocalDataUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let snapshotter: any LocalDatabaseSnapshotting
    private let preferencesRepository: any AppPreferencesRepository

    public init(
        biometricRepository: any BiometricRepository,
        snapshotter: any LocalDatabaseSnapshotting,
        preferencesRepository: any AppPreferencesRepository
    ) {
        self.biometricRepository = biometricRepository
        self.snapshotter = snapshotter
        self.preferencesRepository = preferencesRepository
    }

    /// The name this app calls itself in its own export, so a file is identifiable without its filename.
    public static let appName = "Whoopsy"

    public func execute() async throws -> LocalExportResult {
        let now = Date()
        let snapshot = try await snapshotter.exportAllRows()
        let preferences = await preferencesRepository.load()

        // The heart-rate series, in the one form a reader can open in a spreadsheet. It is the same
        // rows the JSON carries under `biometric_samples`, deliberately duplicated: those are there so
        // the file is complete, and these are here so the one series in this app that is a *time series*
        // can be charted by something that is not this app.
        //
        // **Unbounded from the epoch**, which is the difference from the 30-day window this had — a
        // window here would be the export deciding part of the user's history is not theirs. On every
        // database on this machine it reads 0 rows, since `biometric_samples` holds none; it is written
        // for the strap path, which is the only producer that table has.
        let samples = try await biometricRepository.getSamples(
            from: Date(timeIntervalSince1970: 0), to: now)

        let jsonString = try Self.json(
            snapshot: snapshot, preferences: preferences, now: now)
        let csv = Self.csv(samples: samples)

        return LocalExportResult(
            jsonString: jsonString,
            csvHeartRates: csv,
            tableRowCounts: snapshot.rowCounts,
            totalRows: snapshot.totalRows,
            timestamp: now
        )
    }

    // MARK: - The JSON

    /// The export's document: what wrote it, when, every table row by row, and the settings beside them.
    ///
    /// ```json
    /// {
    ///   "app": "Whoopsy",
    ///   "exportDate": "2026-10-02T19:04:11Z",
    ///   "totalRows": 12345,
    ///   "rowCounts": { "recoveries": 931, "sleeps": 918, "…": 0 },
    ///   "tables": { "recoveries": [ { "date": "…", "recovery_score": 55, "hrv_value_ms": 62.4 } ] },
    ///   "settings": { "usesMetricUnits": null, "analyticsEnabled": true, "…": false }
    /// }
    /// ```
    ///
    /// **The tables are keyed by their own names and the rows carry their own column names**, so the
    /// document is legible without this app and `grdb_migrations` is in it — the export states which
    /// schema version wrote it rather than leaving a reader to guess. **`rowCounts` repeats what
    /// `tables` already implies**, on purpose: it is what makes a file checkable at a glance and what
    /// §6 asserts coverage against, and a summary that could disagree with its own body is worth less
    /// than one computed from it — so it is computed from it.
    ///
    /// **The schema version cannot drift from the export**, because `grdb_migrations` is a table like
    /// any other and arrives through the same walk.
    ///
    /// Sorted keys and pretty printing: this is a file a person may open, and a stable key order is what
    /// makes two exports of one database diff cleanly.
    private static func json(
        snapshot: LocalDataSnapshot,
        preferences: AppPreferences,
        now: Date
    ) throws -> String {
        var tables: [String: Any] = [:]
        for (name, rows) in snapshot.tables {
            tables[name] = rows.map { row in
                row.values.mapValues(Self.jsonValue)
            }
        }

        let document: [String: Any] = [
            "app": appName,
            "exportDate": ISO8601DateFormatter().string(from: now),
            "totalRows": snapshot.totalRows,
            "rowCounts": snapshot.rowCounts,
            "tables": tables,
            "settings": [
                "usesMetricUnits": preferences.usesMetricUnits.map { $0 as Any } ?? NSNull(),
                "analyticsEnabled": preferences.analyticsEnabled,
                "healthKitSyncEnabled": preferences.healthKitSyncEnabled,
                "liveHeartRateBroadcastEnabled": preferences.liveHeartRateBroadcastEnabled,
            ],
        ]

        let data = try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// One stored value as something `JSONSerialization` accepts.
    ///
    /// **`.null` becomes `NSNull()`, never a zero, an empty string or a dropped key.** A `NULL` in this
    /// database means *nothing was measured there* — it is the app's whole absence vocabulary — so an
    /// export that folded it into a `0` would hand the user a file claiming measurements that were never
    /// taken. **The key stays in the row** for the same reason: `{"strain": null}` says the column exists
    /// and this session has no figure for it, where a missing key says the column does not exist.
    ///
    /// A `.blob` is base64 rather than raw bytes, because JSON has no byte string and
    /// `LocalDataValue.blob` already carries it that way. Nothing in this database takes that arm today.
    private static func jsonValue(_ value: LocalDataValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let number): return number
        case .real(let number): return number
        case .text(let text): return text
        case .blob(let base64): return base64
        }
    }

    // MARK: - The CSV

    /// The heart-rate series, one row per stored sample.
    ///
    /// The header is pinned by §6, and it is also the file's contract: five columns in this order, with
    /// an absent reading written as an empty cell rather than as a `0` — the same distinction the JSON
    /// makes with `null`, in the only vocabulary a CSV has for it.
    private static func csv(samples: [BiometricSample]) -> String {
        var csv = "Timestamp,HeartRateBPM,RRIntervalMs,SkinTempC,SpO2\n"
        let isoFormatter = ISO8601DateFormatter()
        for sample in samples {
            let rr = sample.rrIntervalMs.map { String(format: "%.1f", $0) } ?? ""
            let temp = sample.skinTemperatureCelsius.map { String(format: "%.2f", $0) } ?? ""
            let spo2 = sample.spO2Percentage.map { String(format: "%.1f", $0) } ?? ""
            csv += "\(isoFormatter.string(from: sample.timestamp)),\(sample.heartRate),"
                + "\(rr),\(temp),\(spo2)\n"
        }
        return csv
    }
}
