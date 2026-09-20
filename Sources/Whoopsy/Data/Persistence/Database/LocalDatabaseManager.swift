import Foundation
import GRDB

public actor LocalDatabaseManager {
    public static let shared = LocalDatabaseManager()

    private let dbQueue: DatabaseQueue

    public init(inMemory: Bool = false) {
        do {
            let fileManager = FileManager.default
            let dbPath: String
            if inMemory {
                dbPath = ":memory:"
            } else {
                let appSupport = try fileManager.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                    create: true)
                dbPath = appSupport.appendingPathComponent("whoopsy.sqlite").path
            }

            var config = Configuration()
            config.readonly = false
            config.qos = .utility

            self.dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
            try Self.runMigrations(on: dbQueue)
        } catch {
            fatalError("Failed to initialize GRDB database: \(error)")
        }
    }

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "recoveries", ifNotExists: true) { t in
                t.primaryKey("date", .datetime)
                t.column("recovery_score", .integer).notNull()
                t.column("resting_heart_rate", .integer).notNull()
                t.column("hrv_rmssd", .double).notNull()
                t.column("skin_temperature", .double)
                t.column("spo2_percentage", .double)
                t.column("respiratory_rate", .double)
            }

            try db.create(table: "sleeps", ifNotExists: true) { t in
                t.primaryKey("date", .datetime)
                t.column("start_time", .datetime).notNull()
                t.column("end_time", .datetime).notNull()
                t.column("sleep_performance", .double).notNull()
                t.column("total_sleep_needed", .double).notNull()
                t.column("light_sleep", .double).notNull()
                t.column("deep_sleep", .double).notNull()
                t.column("rem_sleep", .double).notNull()
                t.column("awake_time", .double).notNull()
            }
        }

        // `v1` is frozen: GRDB records applied migration *identifiers* and does not checksum
        // bodies, so any database that already recorded `v1` would never re-run an edited body.
        // Schema changes go in a new migration, never into the one above.
        migrator.registerMigration("v2_add_missing_tables") { db in
            // `strains`, `user_profiles` and `biometric_samples` had no migration at all, so every
            // query against them threw `SQLite error 1: no such table`.
            if try !db.tableExists("strains") {
                try db.create(table: "strains") { t in
                    t.primaryKey("date", .datetime)
                    t.column("strainScore", .double).notNull()
                    t.column("kilojoules", .double).notNull()
                    t.column("averageHeartRate", .integer).notNull()
                    t.column("maxHeartRate", .integer).notNull()
                }
            }

            if try !db.tableExists("user_profiles") {
                try db.create(table: "user_profiles") { t in
                    t.primaryKey("id", .text)
                    t.column("maxHeartRate", .integer).notNull()
                    t.column("restingHeartRate", .integer).notNull()
                }
            }

            if try !db.tableExists("biometric_samples") {
                try db.create(table: "biometric_samples") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("timestamp", .datetime).notNull()
                    t.column("heartRate", .integer).notNull()
                    t.column("rrIntervalMs", .double)
                    t.column("accelX", .double)
                    t.column("accelY", .double)
                    t.column("accelZ", .double)
                    t.column("skinTemp", .double)
                    t.column("spo2Percentage", .double)
                    t.column("isOnBody", .boolean)
                    t.column("isCharging", .boolean)
                    t.column("rawSequenceNumber", .integer)
                }
            }

            // A device that ran an intermediate build may already hold a partial table. Add any
            // column this schema expects but the table lacks, rather than failing the migration.
            try Self.addMissingColumns(
                to: "biometric_samples",
                columns: [
                    ("rrIntervalMs", .double), ("accelX", .double), ("accelY", .double),
                    ("accelZ", .double), ("spo2Percentage", .double), ("isOnBody", .boolean),
                    ("isCharging", .boolean), ("rawSequenceNumber", .integer),
                ],
                in: db)

            try Self.addMissingColumns(
                to: "strains",
                columns: [
                    ("strainScore", .double), ("kilojoules", .double),
                    ("averageHeartRate", .integer), ("maxHeartRate", .integer),
                ],
                in: db)

            try Self.addMissingColumns(
                to: "user_profiles",
                columns: [("maxHeartRate", .integer), ("restingHeartRate", .integer)],
                in: db)

            try db.create(
                index: "biometric_samples_on_timestamp", on: "biometric_samples",
                columns: ["timestamp"], ifNotExists: true)
        }

        // `hrv_rmssd` held one metric under a name that asserted which. HealthKit only exposes SDNN,
        // so the column becomes metric-agnostic and the metric is stored beside it.
        migrator.registerMigration("v3_recovery_hrv_metric") { db in
            guard try db.tableExists("recoveries") else { return }
            // Tracked as mutations of this set: after the rename below, `hrv_value_ms` exists, and
            // re-deriving from the pre-rename snapshot would try to add it a second time.
            var columns = Set(try db.columns(in: "recoveries").map(\.name))

            if columns.contains("hrv_rmssd") && !columns.contains("hrv_value_ms") {
                try db.alter(table: "recoveries") { t in
                    t.rename(column: "hrv_rmssd", to: "hrv_value_ms")
                }
                columns.remove("hrv_rmssd")
                columns.insert("hrv_value_ms")
            }
            if !columns.contains("hrv_value_ms") {
                try db.alter(table: "recoveries") { t in
                    t.add(column: "hrv_value_ms", .double).notNull().defaults(to: 0.0)
                }
                columns.insert("hrv_value_ms")
            }
            // Every pre-existing row is RMSSD: the strap was the only source. The default backfills
            // them correctly without a separate UPDATE, and keeps the column NOT NULL so no future
            // writer can omit the metric and leave a value whose meaning is unknown.
            if !columns.contains("hrv_metric") {
                try db.alter(table: "recoveries") { t in
                    t.add(column: "hrv_metric", .text).notNull().defaults(to: HRVMetric.rmssd.rawValue)
                }
                columns.insert("hrv_metric")
            }
        }

        // `sleeps` had no column for either of these, so `GRDBSleepRepository` handed every session
        // it read back a `respiratoryRate` of `14.0` and a `disturbanceCount` of `0` — numbers the
        // strap had never produced, in the fields a reader would take for measurements. Nullable and
        // undefaulted on purpose: existing rows hold no reading, and NULL is how a row says so.
        migrator.registerMigration("v4_sleep_measured_fields") { db in
            try Self.addMissingColumns(
                to: "sleeps",
                columns: [("respiratory_rate", .double), ("disturbance_count", .integer)],
                in: db)
        }

        // Provenance, for the bulk WHOOP-export import. Nullable and undefaulted: NULL is the honest
        // value for every row written before this column existed, and it stays the value for rows the
        // strap or the HealthKit importer writes now — they are the app's own measurements and have
        // no need to name a source. Nothing reads this column today. It exists so that a bulk import
        // of nine hundred historical rows can be identified, re-run, or backed out later, which is
        // not possible once the rows are indistinguishable from local measurements.
        migrator.registerMigration("v5_add_source_provenance") { db in
            for table in ["recoveries", "sleeps", "strains"] {
                try Self.addMissingColumns(to: table, columns: [("source", .text)], in: db)
            }
        }

        // Recorded workouts had no table at all: `LocalWorkoutRepository` held them in an in-memory
        // array, so every workout the user recorded was gone at the next launch. Three tables,
        // because a workout is one aggregate — the session, its GPS route, and its splits.
        //
        // `workouts` is keyed on `id`, not on `date`: a day can hold several workouts, so the day key
        // that `recoveries`/`sleeps`/`strains` are primary-keyed on would collide here. `date` is a
        // plain indexed lookup column, and the route/split tables cascade with the workout so a
        // deleted session cannot leave orphans behind.
        migrator.registerMigration("v6_recorded_workouts") { db in
            try db.create(table: "workouts", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("date", .datetime).notNull().indexed()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime).notNull()
                t.column("strain", .double).notNull()
                t.column("average_heart_rate", .integer).notNull()
                t.column("max_heart_rate", .integer).notNull()
                t.column("source", .text)
            }

            try db.create(table: "workout_route_points", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("workout_id", .text).notNull()
                    .references("workouts", onDelete: .cascade).indexed()
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("heart_rate", .integer).notNull()
            }

            try db.create(table: "workout_splits", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("workout_id", .text).notNull()
                    .references("workouts", onDelete: .cascade).indexed()
                t.column("elapsed", .double).notNull()
                t.column("strain", .double).notNull()
            }
        }

        // `strains` could not say whether a stored `0.0` was a measured rest day or the placeholder
        // `CalculateStrainUseCase` wrote for a day with no samples, so every reader of a strain
        // value was one screenshot away from drawing a day the strap sat on the charger as a real
        // zero. This is the counterpart of `recoveries`' marker, and `RecoveryRecord` needed no
        // column for its own because HRV already carried the signal — strain has no such field.
        //
        // The column is camelCase because `strains` is: unlike `RecoveryRecord`, `StrainRecord` has no
        // `CodingKeys`, so a property's name *is* its column. A snake_case name here would add a
        // column no read or write ever touches, and every save would throw on the missing one.
        //
        // NOT NULL with a default, so `addMissingColumns` cannot be used; the shape is `v3`'s.
        //
        // The default is `1` because most rows that already exist are measurements, and the UPDATE
        // below corrects the ones that are not. **A zero score is not the test**, and reaching for it
        // would be wrong twice over: the export's own `Day Strain` holds exactly `0.0` on two of its
        // 933 rows (2024-06-05 and 2024-12-31), and the app's measured branch can land on `0.0` too,
        // when a worn day's samples never reach zone 1 and nothing accumulates. Both are readings.
        //
        // What identifies a placeholder is the **empty branch's whole signature**, not its score:
        // `CalculateStrainUseCase` wrote `score: 0.0` there while passing no heart rates, so the
        // entity's defaults left `averageHeartRate` at `0` — and `source` at NULL, because the
        // app is its own source. The measured branch computes `hrSum / samples.count` over a
        // non-empty sample set, so it can never write `averageHeartRate = 0`. All three conditions
        // together are the only shape that path has ever produced.
        //
        // That branch no longer stores anything at all — a day with no samples returns `nil` — but
        // the rows this backfill classified are still on disk, and this migration has already run on
        // every database that holds them, so neither the UPDATE nor its reasoning is dead.
        migrator.registerMigration("v7_strain_measurement_marker") { db in
            guard try db.tableExists("strains") else { return }
            let columns = Set(try db.columns(in: "strains").map(\.name))
            if !columns.contains("hasMeasurement") {
                try db.alter(table: "strains") { t in
                    t.add(column: "hasMeasurement", .boolean).notNull().defaults(to: true)
                }
                try db.execute(
                    sql: """
                        UPDATE strains SET hasMeasurement = 0
                        WHERE strainScore = 0 AND averageHeartRate = 0 AND source IS NULL
                        """)
            }
        }

        // `v8` adds the full per-notification R-R series.
        //
        // The strap sends several beat-to-beat intervals per Heart Rate notification (0x2A37) and the
        // BLE layer kept only the first, storing it in `rrIntervalMs`. That discarded most of the raw
        // material a respiratory-rate estimate needs: Respiratory Sinus Arrhythmia is read off the
        // beat-to-beat tachogram, so the series has to be contiguous and in beat order, and a
        // thinning of one interval per notification cannot supply that.
        //
        // **The column name is `rrIntervalsMs`, camelCase**, because `BiometricSampleRecord` declares
        // no `CodingKeys`, so its property names *are* its column names. Getting this wrong is not a
        // silent failure — `v7`'s `has_measurement` mistake produced `SQLite error 1: no such column`
        // and, because a failing migration `fatalError`s, took the whole app down at launch.
        //
        // `.text` because GRDB JSON-encodes a `[Double]` property of a `Codable` record to a String.
        //
        // No `UPDATE`, no `.notNull()`, no default, and no backfill from `rrIntervalMs`. The helper
        // produces a nullable undefaulted column, which is the honest shape here: `NULL` is the value
        // for a row written before the column existed, and it is *also* the value for a notification
        // that carried no intervals. A synthesised `[882.0]` backfill would claim that the one
        // surviving interval was the whole notification, which is precisely the loss this migration
        // exists to stop repeating.
        migrator.registerMigration("v8_rr_interval_series") { db in
            try Self.addMissingColumns(
                to: "biometric_samples", columns: [("rrIntervalsMs", .text)], in: db)
        }

        // `v9` adds WHOOP's own Sleep Consistency to a night.
        //
        // The export has carried this column all along — `physiological_cycles.csv` column 26, 892
        // non-empty values — and nothing parsed it, so the quantity was not merely unshown but
        // unreadable. The sleep-performance screen needs it, and it belongs on the row for the same
        // reason `Sleep need (min)` does: an imported night carries WHOOP's own number and a strap
        // night carries one this app computed, exactly as `total_sleep_needed` already works.
        //
        // Nullable and undefaulted, which is what the helper produces and the honest shape here. NULL
        // is the value for every row written before the column existed, and it stays the value for a
        // night the app has no four priors to compute one for. It is deliberately **not** backfilled
        // from `SleepConsistencyMath`: that would write a computed number into a column an imported
        // row uses for a measured one, and the two would then be indistinguishable.
        migrator.registerMigration("v9_sleep_consistency") { db in
            try Self.addMissingColumns(to: "sleeps", columns: [("sleep_consistency", .integer)], in: db)
        }

        // `v10` adds WHOOP's accumulated Sleep Debt to a night.
        //
        // The export has carried `Sleep debt (min)` all along — 910 non-empty values, 0 to 127 — and
        // nothing parsed it, so the app held a night's need and its performance but not the deficit
        // between them. It belongs on the row for the same reason `sleep_consistency` does: it is a
        // figure about *this* night, and the sleep screen is where a night's figures are read.
        //
        // **Seconds, like every other duration in this table**, though the export writes minutes. A
        // column here that was in minutes while `light_sleep` beside it is in seconds is the kind of
        // inconsistency that reads as a bug at every call site; the conversion is exact and happens
        // once, in the importer.
        //
        // Nullable and undefaulted, which is what the helper produces and the honest shape: NULL is
        // the value for every row written before this column existed, and it stays NULL for a strap
        // night, which has no source for a debt — the deficit is WHOOP's own accumulation across
        // nights, not something one night's stages can produce. It is deliberately **not** computed
        // here: a fitted deficit would be this app's number in a column an imported row uses for
        // WHOOP's, and the two would then be indistinguishable.
        migrator.registerMigration("v10_sleep_debt") { db in
            try Self.addMissingColumns(to: "sleeps", columns: [("sleep_debt", .double)], in: db)
        }

        // `v11` gives naps a table of their own.
        //
        // **They cannot live in `sleeps`, and the reason is the day key.** That table is primary-keyed
        // on `date` snapped to `startOfDay` because a night is one per day; measured against the
        // export, all eight of its nap records land on a day that already holds a night — four of them
        // by their own wake onset (2024-02-06, 2024-08-27), and the rest by the onset day — so filing
        // them there would either overwrite a night or be silently skipped by the INSERT-or-UPDATE on
        // the shared key. So this is `workouts`' shape, not `sleeps`': **`id`-keyed, with `date` an
        // ordinary indexed lookup column**, and a read that returns an array because a day can hold
        // more than one nap.
        //
        // The `id` is the nap's own start instant rather than a fresh `UUID` — the importer supplies
        // it, and `NapRecord.id` carries the reasoning. A random id per import would make the second
        // press of the import button write eight more rows.
        //
        // Only the window and the asleep duration are stored. The export's nap rows carry a full stage
        // split as well, and it is left alone deliberately: those columns are already covered on the
        // *night* rows, nothing draws a nap's stages, and four more columns no reader touches is the
        // shape `csv-field-coverage` exists to prevent. `sleep_performance` is absent for a stronger
        // reason — see `WhoopImportSummary.napsWritten`'s sibling note in `WhoopExportImporter`: a
        // nap's performance is its own asleep minutes over a whole night's need, which is why the
        // export's eight nap rows score 6% to 43%. That is not a performance and must not be stored
        // as one.
        migrator.registerMigration("v11_recorded_naps") { db in
            try db.create(table: "naps", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("date", .datetime).notNull().indexed()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime).notNull()
                t.column("asleep_seconds", .double).notNull()
                t.column("source", .text)
            }
        }

        // `v12` adds the night's stage timeline, which until now was computed and then thrown away.
        //
        // `AnalyzeSleepUseCase` has always built one `SleepStageSegment` per 30-second epoch and
        // handed the array to the `SleepSession` — but no record property and no column existed for
        // it, so `saveSleepSession` dropped it and the read path's `[]` default filled it back in.
        // A night the strap had staged perfectly came back from storage indistinguishable from one
        // that was never staged at all, and the sleep-efficiency card's timeline could therefore only
        // ever draw its "strap data not available" note. This is the column that makes a recording
        // outlive the moment it was made.
        //
        // `.text` rather than a table of its own, which follows `v8_rr_interval_series`: an `Array`
        // is not a `DatabaseValueConvertible`, so a `[SleepStageSegment]` can only be stored as its
        // JSON encoding, and `SleepRecord.sleepStages` is the property that carries it. A side table
        // would need a second repository, a protocol and a container entry to hold the same bytes.
        //
        // **Nullable and undefaulted, and NULL is the meaning rather than a gap.** A row written
        // before `v12` has no timeline and neither does any imported night — `WhoopExportImporter`
        // writes `sleepStages: []` because the export reports stage totals and no timeline, and an
        // empty array is stored as NULL for exactly that reason. It is deliberately **not** backfilled
        // from `AnalyzeSleepUseCase`: this database holds no raw samples for an imported night, so a
        // backfill could only invent one.
        migrator.registerMigration("v12_sleep_stage_segments") { db in
            try Self.addMissingColumns(
                to: "sleeps", columns: [("sleep_stages", .text)], in: db)
        }

        // `v13` is the first table in this app that stores a *derived* daily total rather than a
        // reading: steps are counted from 100 Hz motion that is never persisted, so the count cannot
        // be recomputed on read the way every other metric here can.
        //
        // That is the whole reason a table is needed. A day of motion at 100 Hz across three axes is
        // ~26M samples — far too much to keep, and far too much to re-walk — so `StepAccumulator`
        // consumes each batch as it arrives and stores only the running figure. Nothing can
        // reconstruct it afterwards, which is why this is a stored total and not a projection over
        // samples.
        //
        // The primary key is `date`, on the `strains` rule: a day holds one step count. It is snapped
        // on write by `saveStepCount`, because a row written at a raw timestamp is inserted rather
        // than updated and no keyed read can find it.
        //
        // **`measuredSeconds` is the column the absence rule reads, and it is not decoration.** The
        // count alone cannot separate "wore the strap, did not walk" (`0`) from "never measured"
        // (no row) — both are `0`. This column is what makes the first a measurement and the second
        // an absence, and `StepCount.hasMeasurement` derives the flag from it rather than storing a
        // second copy that a writer could set the other way. See `StepCount`.
        //
        // **No `source` column**, unlike `strains`. That table carries one because two producers
        // write it — the strap and the CSV import — and a reader has to tell them apart. Steps have
        // one producer: the strap. Its live and banked transports deliver the same measurement of the
        // same motion from the same sensor, a single day is routinely fed by both, and a single
        // value per row could therefore not be written honestly. The export carries no step counts at
        // all, so there is no second producer to distinguish.
        migrator.registerMigration("v13_step_counts") { db in
            try db.create(table: "stepCounts", ifNotExists: true) { t in
                t.primaryKey("date", .datetime)
                t.column("stepCount", .integer).notNull()
                t.column("measuredSeconds", .double).notNull()
            }
        }

        // WHOOP's own five heart-rate zone percentages for an imported workout, as the JSON-encoded
        // `[Double]?`-in-a-`.text`-column shape `v8` and `v12` already set — `Array` is not a
        // `DatabaseValueConvertible`, so it can only ever be a record property.
        //
        // **Nullable and undefaulted, which is the honest value rather than the convenient one.** The
        // 673 imported workouts all carry a block; every session this app recorded itself carries
        // none, and neither does any row written before this migration. NULL says exactly that, and
        // the strain page draws it as a dash — where a defaulted `[0, 0, 0, 0, 0]` would be a
        // measured workout that never reached zone 1, which the export also contains 45 of.
        migrator.registerMigration("v14_workout_hr_zones") { db in
            try Self.addMissingColumns(
                to: "workouts", columns: [("hr_zone_percents", .text)], in: db)
        }

        // `workouts.csv`'s `Activity name`, which the Home screen's activity row draws in place of one
        // label for every session.
        //
        // **Nullable and undefaulted**, on `source`'s reasoning rather than `hrZonePercents`': NULL is
        // the honest value for a fact nobody recorded at the time, and here that is every session this
        // app recorded itself plus all 673 imported rows written before this migration. There is no
        // default to pick, because there is no column in any other file to default from.
        //
        // The name is **not** an absence marker the way the zone block is — a name is not a
        // measurement, so `nil` reaches the screen as WHOOP's own word for an uncategorised activity
        // rather than as a dash. `WhoopExportRow.activityName` carries that reasoning.
        migrator.registerMigration("v15_workout_activity_name") { db in
            try Self.addMissingColumns(
                to: "workouts", columns: [("activity_name", .text)], in: db)
        }

        try migrator.migrate(queue)
    }

    /// Adds only the columns `table` is missing. `Database.alter` cannot check for itself, and a
    /// plain `add(column:)` on an existing column aborts the whole migration.
    private static func addMissingColumns(
        to table: String, columns: [(String, Database.ColumnType)], in db: Database
    ) throws {
        guard try db.tableExists(table) else { return }
        let existing = Set(try db.columns(in: table).map(\.name))
        for (name, type) in columns where !existing.contains(name) {
            try db.alter(table: table) { t in
                t.add(column: name, type)
            }
        }
    }

    /// Names of the tables the migrations actually created. Exposed for schema assertions, which
    /// is how a missing migration is caught before it surfaces as `no such table` at runtime.
    public func existingTableNames() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                    """)
        }
    }

    /// The column names `table` actually has, in declaration order.
    ///
    /// Exposed for the same reason `existingTableNames()` is: a migration that names a column the
    /// record does not declare — or a record that expects a column the migration never added — fails
    /// at runtime, and on this database that means `no such column` at launch. This is what lets a
    /// test assert the two agree before a strap ever connects.
    ///
    /// Returns `[]` for a table that does not exist rather than throwing, so a caller asserting on a
    /// missing table sees an empty list instead of an error it has to distinguish from a real one.
    public func columnNames(in table: String) throws -> [String] {
        try dbQueue.read { db in
            guard try db.tableExists(table) else { return [] }
            return try db.columns(in: table).map(\.name)
        }
    }

    public func getRecovery(for date: Date) throws -> RecoveryRecord? {
        try dbQueue.read { db in
            try RecoveryRecord.fetchOne(db, key: ["date": date.startOfDay])
        }
    }

    /// The three day-keyed tables (`recoveries`, `sleeps`, `strains`) are read back with
    /// `date.startOfDay` as the lookup key, so writes are snapped to the same instant here. Callers
    /// pass wall-clock dates; saving one raw makes GRDB's `save` append a row that no keyed read can
    /// ever find, which is silent data loss — the row exists, and is unreachable.
    public func saveRecovery(_ record: RecoveryRecord) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
        }
    }

    /// The day-key window a history read covers: `days` back from `endingOn`, including both ends.
    ///
    /// The upper bound is not decoration. These reads used to run from a cutoff to *now* with nothing
    /// above them, which is only the same thing while the caller is asking about today. A screen that
    /// asks about an arbitrary day — which is what the day-keyed screens now do — would otherwise get
    /// every row after that day too, and a chart of "the 14 days to Aug 22" would silently be a chart
    /// of the 14 days to Aug 22 *plus everything since*.
    private static func historyWindow(days: Int, endingOn: Date) -> (from: Date, to: Date) {
        let calendar = Calendar.current
        let from = calendar.date(byAdding: .day, value: -days, to: endingOn)?.startOfDay
            ?? endingOn.startOfDay
        return (from, endingOn.endOfDay)
    }

    /// History ending on `endingOn`, most recent last.
    ///
    /// `endingOn` defaults to now, so the "last N days" callers are unchanged — but it is a real
    /// parameter now rather than an assumption, because a screen showing an old day needs the window
    /// that ends on *that* day. See `historyWindow(days:endingOn:)` for why the bound matters.
    public func getRecoveryHistory(days: Int, endingOn: Date = Date()) throws -> [RecoveryRecord] {
        let window = Self.historyWindow(days: days, endingOn: endingOn)
        return try dbQueue.read { db in
            try RecoveryRecord
                .filter(Column("date") >= window.from)
                .filter(Column("date") <= window.to)
                .order(Column("date").asc)
                .fetchAll(db)
        }
    }

    /// See `saveRecovery` for why the date is snapped.
    public func saveSleep(_ record: SleepRecord) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
        }
    }

    public func getSleep(for date: Date) throws -> SleepRecord? {
        try dbQueue.read { db in
            try SleepRecord.fetchOne(db, key: ["date": date.startOfDay])
        }
    }

    /// See `getRecoveryHistory(days:endingOn:)`.
    public func getSleepHistory(days: Int, endingOn: Date = Date()) throws -> [SleepRecord] {
        let window = Self.historyWindow(days: days, endingOn: endingOn)
        return try dbQueue.read { db in
            try SleepRecord
                .filter(Column("date") >= window.from)
                .filter(Column("date") <= window.to)
                .order(Column("date").asc)
                .fetchAll(db)
        }
    }

    /// See `saveRecovery` for why the date is snapped — and note that a nap's snap is onto the day it
    /// **started**, which is a different question from the night table's wake-onset key and the
    /// reason the two live in separate tables.
    public func saveNap(_ record: NapRecord) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
        }
    }

    /// The naps taken on `date`'s day, earliest first. More than one in a day is possible, which is
    /// why this returns an array where `getSleep(for:)` returns a single row.
    public func getNaps(on date: Date) throws -> [NapRecord] {
        try dbQueue.read { db in
            try NapRecord
                .filter(Column("date") == date.startOfDay)
                .order(Column("started_at").asc)
                .fetchAll(db)
        }
    }

    /// See `saveRecovery` for why the date is snapped.
    public func saveStrain(_ record: StrainRecord) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
        }
    }

    public func getStrain(for date: Date) throws -> StrainRecord? {
        try dbQueue.read { db in
            try StrainRecord.fetchOne(db, key: ["date": date.startOfDay])
        }
    }

    /// See `getRecoveryHistory(days:endingOn:)`.
    public func getStrainHistory(days: Int, endingOn: Date = Date()) throws -> [StrainRecord] {
        let window = Self.historyWindow(days: days, endingOn: endingOn)
        return try dbQueue.read { db in
            try StrainRecord
                .filter(Column("date") >= window.from)
                .filter(Column("date") <= window.to)
                .order(Column("date").asc)
                .fetchAll(db)
        }
    }

    /// See `saveRecovery` for why the date is snapped.
    ///
    /// The snap is load-bearing here for a second reason beyond the keyed read: `TrackStepsUseCase`
    /// flushes the running count repeatedly through one day, and each flush is a *replacement* of the
    /// day's row rather than an addition to it. An unsnapped write would append a row per flush and
    /// leave the day's total split across rows no reader can add back up.
    public func saveStepCount(_ record: StepCountRecord) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
        }
    }

    /// The day's count, or `nil` when that day was never measured — see `StepRepository`.
    public func getStepCount(for date: Date) throws -> StepCountRecord? {
        try dbQueue.read { db in
            try StepCountRecord.fetchOne(db, key: ["date": date.startOfDay])
        }
    }

    /// See `getRecoveryHistory(days:endingOn:)`.
    public func getStepCountHistory(days: Int, endingOn: Date = Date()) throws -> [StepCountRecord] {
        let window = Self.historyWindow(days: days, endingOn: endingOn)
        return try dbQueue.read { db in
            try StepCountRecord
                .filter(Column("date") >= window.from)
                .filter(Column("date") <= window.to)
                .order(Column("date").asc)
                .fetchAll(db)
        }
    }

    public func saveProfile(_ record: UserProfileRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func getProfile() throws -> UserProfileRecord? {
        try dbQueue.read { db in
            try UserProfileRecord.fetchOne(db, key: "primary")
        }
    }

    public func saveSamples(_ records: [BiometricSampleRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    /// The samples in a window, oldest first.
    ///
    /// `id` is the secondary key because `timestamp` alone leaves ties undefined, and ties are
    /// ordinary here: a notification carrying several intervals stores one row, but `historicalBatch`
    /// yields a batch of samples stamped from the same decode, and `saveSamples` writes them in one
    /// transaction. An undefined order among rows sharing an instant means two reads of the same
    /// unchanged data can disagree — and the consumers of this are order-sensitive by construction.
    ///
    /// `id` is `INTEGER PRIMARY KEY` (autoincrement), and the rows are inserted in array order inside
    /// a single write, so ascending `id` is exactly arrival order. This can only change a result that
    /// was already arbitrary.
    public func getSamples(from startDate: Date, to endDate: Date) throws -> [BiometricSampleRecord] {
        try dbQueue.read { db in
            try BiometricSampleRecord
                .filter(Column("timestamp") >= startDate && Column("timestamp") <= endDate)
                .order(Column("timestamp").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    /// The newest sample, by the same ordering as ``getSamples(from:to:)`` so the two agree about
    /// which row is "latest" when several share the newest timestamp.
    public func getLatestSample() throws -> BiometricSampleRecord? {
        try dbQueue.read { db in
            try BiometricSampleRecord
                .order(Column("timestamp").desc, Column("id").desc)
                .fetchOne(db)
        }
    }

    public func clearAllSamples() throws {
        try dbQueue.write { db in
            _ = try BiometricSampleRecord.deleteAll(db)
        }
    }

    /// A workout is written with its route and its splits as one unit — a stored session with no map
    /// would be a session the summary screen cannot fully draw. Children are rewritten rather than
    /// appended, so saving the same `id` twice replaces it instead of stacking a second route.
    ///
    /// `date` is snapped for the reason `saveRecovery` gives: `getWorkouts(on:)` matches on
    /// `startOfDay`, so an unsnapped row would exist and be unreachable.
    public func saveWorkout(
        _ record: WorkoutRecord,
        route: [WorkoutRoutePointRecord],
        splits: [WorkoutSplitRecord]
    ) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
            _ = try WorkoutRoutePointRecord
                .filter(Column("workout_id") == snapped.id).deleteAll(db)
            _ = try WorkoutSplitRecord
                .filter(Column("workout_id") == snapped.id).deleteAll(db)
            for point in route { try point.save(db) }
            for split in splits { try split.save(db) }
        }
    }

    /// The workouts recorded on `date`'s day, earliest first. Several per day is normal, which is
    /// why this returns an array where `getStrain(for:)` returns one row.
    public func getWorkouts(on date: Date) throws -> [WorkoutRecord] {
        try dbQueue.read { db in
            try WorkoutRecord
                .filter(Column("date") == date.startOfDay)
                .order(Column("started_at").asc)
                .fetchAll(db)
        }
    }

    public func getRoutePoints(for workoutId: String) throws -> [WorkoutRoutePointRecord] {
        try dbQueue.read { db in
            try WorkoutRoutePointRecord
                .filter(Column("workout_id") == workoutId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    public func getSplits(for workoutId: String) throws -> [WorkoutSplitRecord] {
        try dbQueue.read { db in
            try WorkoutSplitRecord
                .filter(Column("workout_id") == workoutId)
                .order(Column("elapsed").asc)
                .fetchAll(db)
        }
    }

    /// The most recently *started* workout, or nil when none was ever recorded.
    ///
    /// Ordered on `started_at` rather than `date`: those are the same instant snapped, so ordering on
    /// the snapped column would put a late-evening session and an early-morning one on the same day in
    /// an arbitrary order.
    public func getLatestWorkout() throws -> WorkoutRecord? {
        try dbQueue.read { db in
            try WorkoutRecord.order(Column("started_at").desc).fetchOne(db)
        }
    }

    /// Every workout whose **day** falls in the window, earliest first.
    ///
    /// Shaped like `getRecoveryHistory(days:endingOn:)` and its siblings rather than taking a from/to
    /// pair, so the two ends come from the one `historyWindow(days:endingOn:)` — a window anchored on a
    /// day in the past would otherwise run on to the present and pull the whole imported history in
    /// behind the thirty days a baseline is taken over.
    ///
    /// It filters on `date` — the snapped day key — and not on `started_at`, which is what makes the
    /// result a set of *days* rather than of instants: a session started at 23:50 belongs to the day
    /// `getWorkouts(on:)` would find it on, and a range test on the raw instant would disagree with
    /// that lookup by one day at each boundary.
    public func getWorkoutHistory(days: Int, endingOn: Date = Date()) throws -> [WorkoutRecord] {
        let window = Self.historyWindow(days: days, endingOn: endingOn)
        return try dbQueue.read { db in
            try WorkoutRecord
                .filter(Column("date") >= window.from)
                .filter(Column("date") <= window.to)
                .order(Column("started_at").asc)
                .fetchAll(db)
        }
    }
}
