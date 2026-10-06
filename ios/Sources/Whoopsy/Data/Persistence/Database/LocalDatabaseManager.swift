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

        // The body weight the calorie estimate needs, supplied by the user on the profile page.
        //
        // `user_profiles` has stored exactly two fields since `v2` — a maximal and a resting heart
        // rate — while `UserProfile` carries ten, so every other field was an initialiser default that
        // no row could override. For eight of them that was invisible, because nothing read them.
        // `weightKg` was the exception: `CalculateStrainUseCase` fed its `75.0` default into
        // `StrainAccumulatorMath.estimateCalories`, so every calorie figure this app has ever computed
        // rested on a body the user never described.
        //
        // **Nullable and undefaulted**, on `source`'s reasoning: NULL is the honest value for a fact
        // nobody supplied, and it is what makes the absence reachable. A default here would be a
        // number this app invented and then divided by — the fabrication the whole no-data discipline
        // exists to prevent — so an unset weight must produce *no* calorie figure rather than a
        // plausible one. `UserProfile.weightKg` is optional for the same reason, and
        // `estimateCalories` returns `nil` rather than a value when it is absent.
        //
        // The heart rates stay non-optional and keep their column defaults. They are the inputs the
        // Karvonen zones cannot be built without, so an absent one is not an absence the screen can
        // draw — it is a zone table that cannot be computed at all.
        migrator.registerMigration("v16_profile_weight") { db in
            try Self.addMissingColumns(
                to: "user_profiles", columns: [("weightKg", .double)], in: db)
        }

        // ## v17 — the steps one session walked
        //
        // `stepCounts` has held a day's total since `v13`, and this is the same measurement scoped to a
        // single session: the slice of the day's motion that fell inside the session's own span. The
        // activity detail page prints it beside the activity's own history.
        //
        // **Nullable and undefaulted, and here the absence is the ordinary case rather than the edge.**
        // No bundled CSV carries a per-workout step count, so all 673 imported sessions read NULL — and
        // so does every row written before this migration. NULL is what the page draws as a dash, and it
        // is *not* the same answer as a session of no walking, which stores a real `0`. A default of
        // `0` would collapse the two and put a confident no-steps figure on every imported session the
        // app has ever shown.
        //
        // It is the session's own column rather than a second table because a workout row is already
        // keyed on its own `id` and a day can hold several sessions, which is the shape `v6` chose for
        // exactly this reason.
        migrator.registerMigration("v17_workout_steps") { db in
            try Self.addMissingColumns(to: "workouts", columns: [("steps", .integer)], in: db)
        }

        // ## v18 — a session nothing measured says so
        //
        // `v6` declared `strain`, `average_heart_rate` and `max_heart_rate` NOT NULL, which was right
        // while the only producer was a strap: every recorded session had all three. The Zero fasting
        // import is the first producer with no sensor behind it — a fasting window has no strain and no
        // heart rate — and a NOT NULL column leaves it no way to say so. Writing `0` would be worse
        // than saying nothing: it reads as *measured, and no strain at all*, which is the fabricated
        // reading the absence rule forbids everywhere else in this app. So the three become nullable,
        // on `steps`' own reasoning one migration up, and `nil` is what the activity page draws as a
        // dash.
        //
        // **In place, and not as a table rebuild.** `workout_route_points` and `workout_splits` are
        // bound to `workouts` by `ON DELETE CASCADE`, and GRDB runs a migration with foreign keys
        // deferred — so dropping `workouts` would *not* fire the cascade and every route point and
        // split in the database would be silently orphaned. A rebuild that hand-restated the column
        // list would also be a second copy of `v6`'s schema, free to drift from it. Altering the three
        // columns in place touches no other row and no other table.
        //
        // **The `UPDATE` is not optional.** A bare `ADD` of a nullable column leaves every existing row
        // NULL, which would quietly convert every measured workout on disk into "nothing was measured"
        // — the exact opposite of this migration's intent. The four statements per column are
        // add-then-copy-then-swap because SQLite cannot relax NOT NULL in place, and the staging column
        // is named for what it holds rather than being a `_new` suffix so a half-applied migration is
        // legible in `pragma_table_info`.
        //
        // **The last two statements move the data to the *old* name, and the direction is the whole of
        // the trick.** The staging column is what survives: it is dropped from and renamed *back onto*
        // `name`, so the table ends with one column called `strain` holding every value the NOT NULL one
        // held. Written the other way round — `rename(column: name, to: staging)`, which reads just as
        // plausibly and was this migration's first draft — the rename targets a column the line above
        // just dropped and SQLite aborts the whole migration with
        // `no such column: "strain"`. GRDB runs a migration in one transaction, so that failure rolls
        // back to a schema with no `strain_unmeasured` in it and no `v18` row in `grdb_migrations` —
        // which is what makes the bug both loud (`fatalError` at launch) and harmless (nothing applied).
        //
        // The cost is that the three columns move to the end of the table. Nothing reads `workouts` by
        // declaration order — `WorkoutRecord` maps by `CodingKeys` name — so this is invisible, and no
        // test asserts the order.
        //
        // Requires SQLite ≥ 3.35 for `DROP COLUMN` (3.25 for `RENAME COLUMN`), which iOS 17 clears by
        // a wide margin. The three columns are plain — no index, no `UNIQUE`, no generated column, and
        // no view or trigger names them — which is what `DROP COLUMN` requires.
        migrator.registerMigration("v18_workout_measurement_absence") { db in
            for (name, type) in [
                ("strain", Database.ColumnType.double),
                ("average_heart_rate", .integer),
                ("max_heart_rate", .integer),
            ] {
                let staging = "\(name)_unmeasured"
                try db.alter(table: "workouts") { t in t.add(column: staging, type) }
                try db.execute(sql: "UPDATE workouts SET \(staging) = \(name)")
                try db.alter(table: "workouts") { t in t.drop(column: name) }
                // Staging onto the old name, never the other way round — see the note above.
                try db.alter(table: "workouts") { t in t.rename(column: staging, to: name) }
            }
        }

        // ## v19 — a session remembers the offline map it downloaded
        //
        // `USE OFFLINE MAP` on the live session screen asks Mapbox for a tile region around the user,
        // while they still have signal, so that the route card on this session's detail page can be
        // drawn from disk afterwards. Mapbox owns the tiles — it has its own `TileStore` on disk — so
        // there is no new table here and nothing to store but the *name* of the region.
        //
        // **One nullable column, and the reason it exists at all is that a session has no id while it
        // is recording.** `LiveSessionUseCase.end()` builds its `WorkoutSession` without passing an
        // `id`, so the `UUID` is minted by `WorkoutSession.init` at that moment — which means the
        // region cannot simply be named after the session it belongs to. The id is minted when the
        // toggle goes on, held on the use case for the length of the session, and carried onto the row
        // here at `end()`. See `LiveSessionUseCase.offlineRegionID`.
        //
        // The two alternatives are both worse and both look simpler. Moving identity minting into
        // `start()` would give the session an id early enough, but §18 asserts the lifecycle in detail
        // and this is not a small change to it. Deriving the region name from `startedAt` would tie the
        // tiles to a fact `ActivityEditSheet` rewrites — trim a session's start and the region is
        // orphaned under a name nothing will ever ask for again.
        //
        // NULL is the honest value for every row written before this column existed and for every
        // session recorded with the switch off, which is most of them. It is not an absence marker the
        // way `strain` is: the reader is `RouteMapRenderer.resolve`, and its gate is the tile region
        // being `.ready`, not this column being non-null.
        migrator.registerMigration("v19_workout_offline_region") { db in
            try Self.addMissingColumns(
                to: "workouts", columns: [("offline_region_id", .text)], in: db)
        }

        // ## v20 — the four body facts the profile page collects
        //
        // `FIRST NAME`, `BIRTHDAY`, `GENDER` and `HEIGHT` are the profile page's other four rows, and
        // none of them had a column: `UserProfile` carried `name`, `birthDate` and `heightCm` as
        // initialiser defaults that no row could override, and had no notion of gender at all. This is
        // `v16`'s change applied to the rest of the body, for `v16`'s reason.
        //
        // **The three that existed were worse than absent — they were invented, and one of them moved.**
        // `name` defaulted to `"Athlete"`, a name this app typed on the user's behalf; `heightCm`
        // defaulted to `178.0`, the exact analogue of the `75.0` weight `v16` deleted; and `birthDate`
        // defaulted to *28 years before `Date()`*, which is not merely a value nobody supplied but an
        // **unstable** one — it is relative to now, so a defaulted column would be a different instant
        // at every launch and `age` would walk forward with the wall clock. NULL is the honest value for
        // all three: in each case nobody supplied the fact.
        //
        // **`gender` has no default to argue with** because the table has never had a vocabulary for
        // it. It is a `.text` column holding `UserProfile.Gender`'s raw value, and an unrecognised
        // string reads back as `nil` rather than being guessed into a neighbouring case — the rule
        // `UserDefaultsStrapModelRepository` already follows for a strap generation this build cannot
        // describe.
        //
        // **All four are nullable, so `addMissingColumns` is the right tool and `v18`'s staging dance is
        // not needed.** That sequence exists only to *remove* a `NOT NULL` constraint, which SQLite
        // cannot relax in place; there is no constraint here to remove.
        //
        // `.datetime` for `birthDate` rather than `.text`, matching how `recoveries.date` and its
        // siblings are declared. `UserProfileRecord` declares no `CodingKeys`, so these property names
        // *are* the column names — camelCase, like `maxHeartRate` and `weightKg` beside them.
        migrator.registerMigration("v20_profile_body_fields") { db in
            try Self.addMissingColumns(
                to: "user_profiles",
                columns: [
                    ("name", .text), ("birthDate", .datetime), ("gender", .text), ("heightCm", .double),
                ],
                in: db)
        }

        // `v21` adds the receptive inactivities — the states recorded on Home's second card.
        //
        // **A new table rather than rows in `workouts`, and the reason is that table's two instants.**
        // `started_at` and `ended_at` have been `NOT NULL` since `v6`, and the whole of what
        // `WorkoutSession` offers hangs off them: `covers(_:)` asks which days a session was underway
        // on, `durationSeconds` is their difference, `elapsedSeconds(byEndOf:)` is the cumulative form
        // of it, and `zoneSeconds(_:)` scales WHOOP's zone share by it. A receptive inactivity has **no
        // end time** — the user's rule is *"just start time is needed no need for end time"* — so
        // storing one in `workouts` would mean relaxing that pair, which is what the half-open overlap
        // read behind Home's ACTIVITIES card is built on. An untimed row would have no instants for
        // `getWorkouts(covering:)` to compare, and the 86-hour fast that draws on all five of its days
        // would stop drawing on any.
        //
        // **`naps` (`v11`) is the shape this follows, not `sleeps`.** A day can hold several receptive
        // activities, so the table is keyed on `id` with `date` an ordinary indexed lookup column —
        // a `date` primary key would make the second meditation of a day overwrite the first. The day
        // key is still snapped centrally by `saveReceptiveInactivity`, on `saveNap`'s precedent, so a row
        // written at a raw 17:33 is found on its day and not on a neighbouring one.
        //
        // **`started_at` is nullable and the two `NOT NULL` instants above are why this table exists
        // instead of a relaxed `workouts`.** NULL means no time was given, which the user's rule makes
        // an ordinary answer rather than a gap. It is a *time of day on `date`'s day* and never a
        // second day key: `ReceptiveInactivityDraft.applying(to:)` rebuilds the picked hour and minute
        // onto the day the form is for, so `date == startOfDay(startedAt)` holds whenever a time is
        // given. That is also why `saveReceptiveInactivity` does **not** derive `date` from `startedAt`
        // the way `saveNap` does — an untimed entry has no derivation to make.
        //
        // Nothing is stored that measures anything: no strain, no heart rate, no zone block, no step
        // count and no route. A receptive inactivity is the state where conscious exertion drops to
        // zero, so a figure describing exertion is not merely unmeasured on one, it is the wrong
        // question — and a defaulted number on a stored row is the fabrication every absence rule in
        // this app forbids.
        migrator.registerMigration("v21_receptive_inactivities") { db in
            try db.create(table: "receptive_inactivities", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("date", .datetime).notNull().indexed()
                t.column("name", .text).notNull()
                // NULL = no time given.
                t.column("started_at", .datetime)
            }
        }

        // The text a receptive inactivity was recorded with — a dream's own prose, an imported
        // entry's note, or a meditation's own words.
        //
        // **NULL is the honest value for an entry with no text**, which is why the column is
        // nullable and undefaulted rather than `NOT NULL DEFAULT ''`. A meditation is complete
        // without one, and an empty string would be a value nobody supplied — the fabrication
        // every absence rule in this app forbids. `ReceptiveInactivityDraft.setNote(_:)` is what
        // keeps the two from blurring on the write side: it trims and stores `nil` for a blank
        // value, so `""` never reaches this column.
        //
        // **It is the second kind of column this table holds, and that is why it is worth a note
        // of its own.** `name` and `started_at` are what the *user* supplied; this one arrives
        // from an import as well, which makes it the identity input for an imported row —
        // `InactivityParser.identifier(date:type:note:)` hashes the prose along with the day and
        // the type, because a record with no producer id has to derive its identity from its own
        // content. Two roles for one value, deliberately: an entry's identity *is* its text on
        // its day.
        //
        // `addMissingColumns` and not a bare `add(column:)`: this table already exists on every
        // database that ran `v21`, and that helper's skip-if-present guard is what makes a
        // half-applied migration a no-op rather than an abort. It adds **nullable, undefaulted**
        // columns only, which is exactly this one — unlike `v18`, which needed the staging dance
        // to relax a `NOT NULL` in place.
        migrator.registerMigration("v22_receptive_inactivity_note") { db in
            try Self.addMissingColumns(
                to: ReceptiveInactivityRecord.databaseTableName,
                columns: [("note", .text)],
                in: db)
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
    ///
    /// **It is also the list the export walks**, which is why the query is a `static` taking a `db`
    /// rather than written into this method: `exportAllRows()` needs the same answer inside its own
    /// read block, and two copies of a `sqlite_master` query are two definitions of "which tables does
    /// this app have" that a filter like `NOT LIKE 'sqlite_%'` is free to drift between.
    public func existingTableNames() throws -> [String] {
        try dbQueue.read { db in try Self.tableNames(in: db) }
    }

    private static func tableNames(in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
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

    /// Every row of every table, for the `Whoopsy` export on the profile page's `LOGS` pane.
    ///
    /// **It walks `sqlite_master` rather than a list of tables written out here**, which is the whole
    /// of what makes the export complete rather than complete-looking: a `v21` that adds a table is
    /// exported the moment it exists, with no edit to this file or to the use case above it, and the
    /// only way a table can be missing from an export is for it to be missing from the database.
    /// The alternative — a read per entity through each `GRDB*Repository` — is a second definition of
    /// the schema living in an exporter, and it fails by *silently omitting* whatever it was not told
    /// about, which no screen and no build can see.
    ///
    /// **The columns are read off each row rather than off a record's `CodingKeys`**, so a column that
    /// exists in the table but on no record — or one whose record names it differently — is still
    /// exported, under the name the database actually uses. See `LocalDataRow` for why the two names
    /// differ on this schema.
    ///
    /// **`SELECT *` and no `WHERE`**, deliberately: there is no day window, no `LIMIT` and no ordering
    /// the caller can ask for. This is the record, not a screen — see `LocalDataSnapshot`.
    ///
    /// Table names are interpolated into the SQL because SQLite has no bind parameter for an
    /// identifier. They come from `sqlite_master` and not from a caller, and are quoted besides; the
    /// values in every row are read normally and never interpolated.
    public func exportAllRows() throws -> LocalDataSnapshot {
        try dbQueue.read { db in
            var tables: [String: [LocalDataRow]] = [:]

            for table in try Self.tableNames(in: db) {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"")
                tables[table] = rows.map { row in
                    // `Row`'s own element *is* the `(column, value)` pair — it is a
                    // `RandomAccessCollection` over its columns — so this walks the row rather than
                    // zipping it against `columnNames`, which would pair each column name with the
                    // pair holding it.
                    var values: [String: LocalDataValue] = [:]
                    for (column, value) in row {
                        values[column] = LocalDataValue(value)
                    }
                    return LocalDataRow(values: values)
                }
            }

            return LocalDataSnapshot(tables: tables)
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

    /// Every recovery row filed in `[from, to)`, ascending — the sync's own read.
    ///
    /// **Half-open, and that is deliberately not `getRecoveryHistory`'s window.** A screen asks for *the
    /// days up to and including this one*, so its window closes on `endOfDay`; a sync chunks an
    /// arithmetic range and needs the chunks to abut without overlapping, because a shared instant
    /// between two chunks is a day written twice. `endOfDay` is the last *instant* of a day rather than
    /// the first of the next, so a row written at midnight would fall outside both halves of a split
    /// built from it — see the `startOfNextDay` gotcha.
    ///
    /// Ascending is load-bearing rather than a convenience: the upload chunks this array and advances
    /// the boundary to each chunk's last row, so a shuffled read would move the boundary across days it
    /// had not sent.
    public func syncRows(from: Date, to: Date) throws -> [RecoverySyncRow] {
        try dbQueue.read { db in
            try RecoveryRecord
                .filter(Column("date") >= from.startOfDay)
                .filter(Column("date") < to.startOfDay)
                .order(Column("date").asc)
                .fetchAll(db)
                .map(\.syncRow)
        }
    }

    /// Insert or replace every row given, in **one** transaction.
    ///
    /// One transaction rather than a loop of `saveRecovery` calls, and the reason is the sync's rather
    /// than the database's: a chunk that failed halfway would leave a range the sync cannot describe —
    /// partly written, with nothing on disk recording which rows landed.
    ///
    /// The date is snapped here for `saveRecovery`'s reason, and it matters more in a download than in
    /// any other write: these rows arrive from a wire format whose day is a bare `YYYY-MM-DD`, and a
    /// record written at a raw instant is INSERTed rather than UPDATEd by GRDB's `save` — so it would
    /// exist, and no keyed read could ever find it.
    public func saveSyncRows(_ rows: [RecoverySyncRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                var record = RecoveryRecord(row)
                record.date = row.date.startOfDay
                try record.save(db)
            }
        }
    }

    /// Every night filed on a day in `[from, to)`, ascending — the sleeps half of the sync's read.
    ///
    /// **The same window arithmetic as `syncRows(from:to:)` and the same reason for it**, quoted rather
    /// than restated: half-open, because a sync chunks an arithmetic range and needs the chunks to abut
    /// without overlapping, and a shared instant between two of them is a night written twice.
    ///
    /// **The key is the wake day and this method must not recompute it.** `SleepRecord.date` is the
    /// morning the night ended; `startTime` is the evening before, so a read that filtered on
    /// `startOfDay(startTime)` would miss every night it was asked about once the window's lower bound
    /// fell between the two.
    public func syncSleepRows(from: Date, to: Date) throws -> [SleepSyncRow] {
        try dbQueue.read { db in
            try SleepRecord
                .filter(Column("date") >= from.startOfDay)
                .filter(Column("date") < to.startOfDay)
                .order(Column("date").asc)
                .fetchAll(db)
                .map(\.syncRow)
        }
    }

    /// Insert or replace every night given, in **one** transaction.
    ///
    /// One transaction rather than a loop, on `saveSyncRows`'s argument. The date is snapped here for
    /// `saveSleep`'s reason: a night arriving from the wire carries a day key that has already been
    /// parsed back into a `Date` by the mapper, and the snap is what puts it on the same instant every
    /// other writer in this app writes.
    public func saveSyncSleepRows(_ rows: [SleepSyncRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                var record = SleepRecord(row)
                record.date = row.date.startOfDay
                try record.save(db)
            }
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

    /// See `saveRecovery` for why the date is snapped — and note that this one snaps onto the day the
    /// **caller** supplied rather than onto anything derived from `startedAt`.
    ///
    /// `saveNap` above derives a nap's day from its onset, and that derivation must not be copied
    /// here: a receptive inactivity's `date` is mandatory while its `started_at` is nullable, so an
    /// untimed entry would have nothing to derive from. The day comes from the screen the user was
    /// looking at, which is the whole point — filing yesterday's meditation onto yesterday is what
    /// `ReceptiveInactivityDraft.applying(to:)` exists to make true, and the picker's hour and minute
    /// are rebuilt onto that day rather than carrying a day of their own.
    public func saveReceptiveInactivity(_ record: ReceptiveInactivityRecord) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try dbQueue.write { db in
            try snapped.save(db)
        }
    }

    /// The receptive inactivities filed on `date`'s day, earliest first with the untimed ones last.
    ///
    /// **The order is `started_at` ascending, nulls last, ties broken by `name`** — and each clause is
    /// doing something. `ascNullsLast` rather than a plain `asc` because SQLite sorts NULL *first* in
    /// an ascending order, which would put every untimed entry above the day's timed ones and leave
    /// the timed half of the list reading as an afterthought. The name tie-break is what makes the
    /// untimed group a stable list rather than an arbitrary one: two entries with no time have no
    /// other field that orders them, and a row order that changes between two reads of an unchanged
    /// day is a list that appears to shuffle.
    ///
    /// This is the only read this table has. A receptive inactivity has no end, so there is no
    /// `covering:` sibling — see `ReceptiveInactivityRepository` for why adding one would be a
    /// double-counting hazard rather than a harmless duplicate.
    public func getReceptiveInactivities(on date: Date) throws -> [ReceptiveInactivityRecord] {
        try dbQueue.read { db in
            try ReceptiveInactivityRecord
                .filter(Column("date") == date.startOfDay)
                .order(Column("started_at").ascNullsLast, Column("name").asc)
                .fetchAll(db)
        }
    }

    /// Removes one entry, reporting the store's affected-row count so a caller can tell a real delete
    /// from a silent no-op — the contract `deleteWorkout(id:)` carries and for the same reason.
    ///
    /// Unlike that method there is no child table to clear: nothing is filed under a receptive
    /// activity, because there is nothing on one to file.
    @discardableResult
    public func deleteReceptiveInactivity(id: String) throws -> Int {
        try dbQueue.write { db in
            try ReceptiveInactivityRecord
                .filter(Column("id") == id).deleteAll(db)
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

    // MARK: - The sync's door into `strains`

    /// Every strain row filed in `[from, to)`, ascending — the sync's own read.
    ///
    /// **Half-open, on `syncRows(from:to:)`'s recoveries argument rather than a second one**: a screen
    /// asks for *the days up to and including this one*, so its window closes on `endOfDay`, while a
    /// sync chunks an arithmetic range and needs the chunks to abut without overlapping, because a
    /// shared instant between two of them is a day written twice.
    ///
    /// **The day alone is the order, and there is no second key.** `syncWorkoutRows` needs
    /// `started_at` and `id` behind its `date` because a day can hold several sessions; this table is
    /// keyed on the day, so a day holds one row and `date` is already a total order. Ascending is
    /// load-bearing rather than a convenience, for the recoveries' reason: the upload chunks this array
    /// and advances the boundary to each chunk's last row, so a shuffled read would move the boundary
    /// across days it had not sent.
    public func syncStrainRows(from: Date, to: Date) throws -> [StrainSyncRow] {
        try dbQueue.read { db in
            try StrainRecord
                .filter(Column("date") >= from.startOfDay)
                .filter(Column("date") < to.startOfDay)
                .order(Column("date").asc)
                .fetchAll(db)
                .map(\.syncRow)
        }
    }

    /// Insert or replace every row given, in **one** transaction.
    ///
    /// One transaction rather than a loop of `saveStrain` calls, and the reason is the sync's rather
    /// than the database's: a chunk that failed halfway would leave a range the sync cannot describe —
    /// partly written, with nothing on disk recording which rows landed.
    ///
    /// The date is snapped here for `saveStrain`'s reason, and it matters more in a download than in any
    /// other write: these rows arrive from a wire format whose day is a bare `YYYY-MM-DD`, and a record
    /// written at a raw instant is INSERTed rather than UPDATEd by GRDB's `save` — so it would exist,
    /// and no keyed read could ever find it.
    ///
    /// **A plain upsert and not a replacement**, which is the one structural difference from
    /// `saveSyncWorkoutRows`: there is nothing filed under a strain, so there is no child to clear and
    /// no order to restore. The `hasMeasurement` flag and the `source` string ride through unchanged,
    /// because they are the whole reason the sync speaks the record rather than `StrainScore`.
    public func saveSyncStrainRows(_ rows: [StrainSyncRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                var record = StrainRecord(row)
                record.date = row.date.startOfDay
                try record.save(db)
            }
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
    ///
    public func saveWorkout(
        _ record: WorkoutRecord,
        route: [WorkoutRoutePointRecord],
        splits: [WorkoutSplitRecord]
    ) throws {
        try dbQueue.write { db in
            try Self.writeWorkout(record, route: route, splits: splits, in: db)
        }
    }

    /// The body of `saveWorkout`, taking the database so a caller can put several of them in one
    /// transaction.
    ///
    /// **Extracted for `saveSyncRows`, and the extraction is the point rather than tidying.** A sync
    /// chunk must land whole or not at all — a parent written and a route that did not is a session
    /// whose path comes from an older write, and nothing on disk records that — so the chunk needs one
    /// `dbQueue.write` around a loop of these. Reaching for `saveWorkout` from inside that loop would
    /// open a transaction per session, and duplicating the four statements into the sync would be a
    /// second definition of what saving a session means, free to drift from this one on the next
    /// change to either.
    private static func writeWorkout(
        _ record: WorkoutRecord,
        route: [WorkoutRoutePointRecord],
        splits: [WorkoutSplitRecord],
        in db: Database
    ) throws {
        var snapped = record
        snapped.date = record.date.startOfDay
        try snapped.save(db)
        _ = try WorkoutRoutePointRecord
            .filter(Column("workout_id") == snapped.id).deleteAll(db)
        _ = try WorkoutSplitRecord
            .filter(Column("workout_id") == snapped.id).deleteAll(db)
        for point in route { try point.save(db) }
        for split in splits { try split.save(db) }
    }

    /// Removes a session and everything filed under it, and reports **how many session rows** went.
    ///
    /// The inverse of `saveWorkout` and written to mirror it: the children are deleted **explicitly**,
    /// in the same order and by the same filter `saveWorkout` rewrites them with, rather than left to
    /// the schema's `onDelete: .cascade`. The cascade would probably work — but nothing in this type
    /// relies on it (`Configuration` does not set `foreignKeysEnabled`, though it defaults true), and
    /// the repo's own precedent is not to. A route point or a split that outlives its session is
    /// invisible to every reader in this app: `makeSessions` fetches children *per session*, so an
    /// orphan is never read, never drawn, and never noticed — it is only ever found as a row count.
    ///
    /// **The returned count is the whole point.** It is the only signal that separates "removed" from
    /// "matched nothing", and `GRDBWorkoutRepository.delete` turns it into its `Bool`. Counting the
    /// children here instead would let an orphaned route point make a failed session delete look
    /// successful.
    ///
    /// Deleting an id that is not stored is not an error: it deletes nothing and returns `0`.
    public func deleteWorkout(id: String) throws -> Int {
        try dbQueue.write { db in
            _ = try WorkoutRoutePointRecord
                .filter(Column("workout_id") == id).deleteAll(db)
            _ = try WorkoutSplitRecord
                .filter(Column("workout_id") == id).deleteAll(db)
            return try WorkoutRecord
                .filter(Column("id") == id).deleteAll(db)
        }
    }

    // MARK: - The sync's door into `workouts`

    /// Every session filed on a day in `[from, to)`, ascending, each with its route and its splits.
    ///
    /// **Half-open, and that is deliberately not `getWorkoutHistory`'s window**, for
    /// `syncRows(from:to:)`'s recoveries reason: a screen asks for *the days up to and including this
    /// one*, so its window closes on `endOfDay`; a sync chunks an arithmetic range and needs the chunks
    /// to abut without overlapping, because a shared instant between two of them is a day written
    /// twice.
    ///
    /// **The order is `date`, `started_at`, `id`, and all three are load-bearing.** `date` is what the
    /// range is built on. `started_at` is the order the card and the export already read a day's
    /// sessions in. `id` breaks the remaining tie so the walk is deterministic — a day holding two
    /// sessions that started on the same second is ordinary, and an undefined order among them would
    /// let two reads of one unchanged database disagree about which one a chunk boundary fell after.
    ///
    /// The children are fetched **inside this one read**, per session and in the manager's own sorted
    /// order — `timestamp` for the route, `elapsed` for the splits. That order is not a preference: the
    /// child tables have no `seq` column, so it is the only record of the sequence, and the wire binds
    /// its own `seq` from this array's index. Re-sorting here would be a second ordering rule.
    public func syncWorkoutRows(from: Date, to: Date) throws -> [WorkoutSyncRow] {
        try dbQueue.read { db in
            let records = try WorkoutRecord
                .filter(Column("date") >= from.startOfDay)
                .filter(Column("date") < to.startOfDay)
                .order(Column("date").asc, Column("started_at").asc, Column("id").asc)
                .fetchAll(db)

            return try records.compactMap { record in
                let route = try WorkoutRoutePointRecord
                    .filter(Column("workout_id") == record.id)
                    .order(Column("timestamp").asc)
                    .fetchAll(db)
                let splits = try WorkoutSplitRecord
                    .filter(Column("workout_id") == record.id)
                    .order(Column("elapsed").asc)
                    .fetchAll(db)
                // `nil` for a session whose stored id will not parse, which drops it from the read
                // rather than minting an identity for it — `WorkoutSyncStore`'s doc comment carries why
                // the parent is dropped and the children below are not.
                return record.syncRow(route: route, splits: splits)
            }
        }
    }

    /// Insert or replace every session given, **with its children**, in **one** transaction.
    ///
    /// One transaction rather than a loop of `saveWorkout` calls, and the reason is the sync's rather
    /// than the database's: a chunk that failed halfway would leave a set of days nothing can describe
    /// — some written and some not — and the next run would rewrite the whole chunk by replacement
    /// without a way to tell which half had landed. `writeWorkout` is what makes that affordable — the whole
    /// chunk goes through one definition of saving a session, rather than through a second copy of the
    /// four statements that a later change to either could leave behind.
    ///
    /// The day snap happens inside `writeWorkout`, for `saveWorkout`'s reason, and it matters more here
    /// than in any other write: these rows arrive from a wire format whose day is a bare `YYYY-MM-DD`,
    /// and a record written at a raw instant is INSERTed rather than UPDATEd by GRDB's `save` — so it
    /// would exist and no keyed read could find it.
    public func saveSyncWorkoutRows(_ rows: [WorkoutSyncRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                let record = WorkoutRecord(row)
                try Self.writeWorkout(
                    record,
                    // The back-pointer comes from the parent's own id, which is the only honest source
                    // for it — the entity has no such field, because the wire has no such field.
                    route: row.route.map { WorkoutRoutePointRecord($0, workoutId: record.id) },
                    splits: row.splits.map { WorkoutSplitRecord($0, workoutId: record.id) },
                    in: db
                )
            }
        }
    }

    // MARK: - The sync's doors into the remaining four tables

    /// Every step-count row filed in `[from, to)`, ascending — the sync's own read.
    ///
    /// **Half-open, on `syncRows(from:to:)`'s recoveries argument rather than a second one**: a screen
    /// asks for *the days up to and including this one*, so its window closes on `endOfDay`, while a
    /// sync chunks an arithmetic range and needs the chunks to abut without overlapping, because a
    /// shared instant between two of them is a day written twice.
    ///
    /// **A day with `measuredSeconds == 0` is returned like any other row**, and that is deliberate
    /// rather than an oversight: on this table the absence is a *column*, not a missing row — see
    /// `StepCountSyncStore` — so filtering here would answer a question the caller did not ask and would
    /// hide a day that exists. Whether such a row is worth sending is `StepCountWireMapper.isSendable`'s
    /// decision, one layer up, where it can name itself in a log.
    public func syncStepCountRows(from: Date, to: Date) throws -> [StepCountSyncRow] {
        try dbQueue.read { db in
            try StepCountRecord
                .filter(Column("date") >= from.startOfDay)
                .filter(Column("date") < to.startOfDay)
                .order(Column("date").asc)
                .fetchAll(db)
                .map(\.syncRow)
        }
    }

    /// Insert or replace every step-count row given, in **one** transaction.
    ///
    /// The date is snapped here for `saveStepCount`'s reason, and it matters more in a download than in
    /// any other write: these rows arrive from a wire format whose day is a bare `YYYY-MM-DD`, and a
    /// record written at a raw instant is INSERTed rather than UPDATEd by GRDB's `save` — so it would
    /// exist, and no keyed read could ever find it.
    public func saveSyncStepCountRows(_ rows: [StepCountSyncRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                var record = StepCountRecord(row)
                record.date = row.date.startOfDay
                try record.save(db)
            }
        }
    }

    /// Every entry filed on a day in `[from, to)`, ascending — the sync's own read.
    ///
    /// **Keyed on the day in the window and on the id in the row, which is this table's whole oddity.**
    /// A day can hold several entries, so `date` alone is not a total order — but unlike `workouts`
    /// there is no second key to add, because nothing about an entry's identity or its upload depends on
    /// which of its day's entries comes first. `ORDER BY date ASC` is therefore the whole of the order
    /// this method promises.
    ///
    /// Half-open, on `syncRows(from:to:)`'s argument.
    public func syncReceptiveInactivityRows(from: Date, to: Date) throws -> [ReceptiveInactivitySyncRow] {
        try dbQueue.read { db in
            try ReceptiveInactivityRecord
                .filter(Column("date") >= from.startOfDay)
                .filter(Column("date") < to.startOfDay)
                .order(Column("date").asc)
                .fetchAll(db)
                .map(\.syncRow)
        }
    }

    /// Insert or replace every entry given, in **one** transaction.
    ///
    /// The date is snapped here for `saveReceptiveInactivity`'s reason. **The id is not touched**: it is
    /// the row's primary key and, on this table, the mechanism that makes re-importing the bundled file
    /// rewrite its rows instead of appending a second copy of every one — so an implementation here that
    /// minted an id for a row arriving without one would quietly double the table.
    public func saveSyncReceptiveInactivityRows(_ rows: [ReceptiveInactivitySyncRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                var record = ReceptiveInactivityRecord(row)
                record.date = row.date.startOfDay
                try record.save(db)
            }
        }
    }

    /// The one stored profile, or `nil` when this database holds none.
    ///
    /// **No day and no range**, because the table is a singleton keyed `"primary"` — so this is
    /// `getProfile()` read through the sync's own shape, and it deliberately goes through the same key
    /// literal for the same reason: a second spelling of the key would be a second opinion about which
    /// row is the profile.
    ///
    /// Nothing is substituted for an absent row. The app's cold-start 190/60 pair is applied by the
    /// client that draws the form, never by a stored row — a row this method invented would be
    /// indistinguishable from one the user typed, and the calorie estimate divides by one of these
    /// fields.
    public func syncProfileRow() throws -> UserProfileSyncRow? {
        try dbQueue.read { db in
            try UserProfileRecord.fetchOne(db, key: "primary")?.syncRow
        }
    }

    /// Insert or replace the profile, in **one** transaction.
    ///
    /// It goes through `saveProfile` rather than repeating its two lines, and that is the point: a
    /// profile write is INSERT-or-UPDATE over the *whole* row, so a second implementation that saved a
    /// subset would silently NULL the rest and surface as a form that comes back empty on the second
    /// launch.
    public func saveSyncProfileRow(_ row: UserProfileSyncRow) throws {
        try saveProfile(UserProfileRecord(row))
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

    /// The workouts **underway at any point during** `day`, earliest first — the other question.
    ///
    /// ## Two questions, two names, and they must not be merged
    ///
    /// ``getWorkouts(on:)`` above asks *which day is this row filed on* — it matches the snapped `date`
    /// column, so a session appears on exactly one day, the day it started. This asks *which sessions
    /// were underway on this day*, so an 86-hour fast appears on all five of its days. Home's
    /// `ACTIVITIES` card is the only caller: a fast that ran over a day is a thing that happened on that
    /// day and a user paging back through the week should see it.
    ///
    /// **Widening `getWorkouts(on:)` instead would be wrong, and the reason is a double count rather
    /// than a wrong day key.** `WorkoutSession.zoneSeconds(_:)` scales WHOOP's published share by the
    /// session's *whole* `durationSeconds`, so the export's three cross-midnight rows would contribute
    /// their entire zone block to both the day they started on and the day they ended on — the same
    /// measured time added to two days' `HEART RATE ZONES` rows. The mis-keying is the corollary:
    /// `WorkoutZoneTime.aggregate` keys a whole day's array off `workouts.first?.startedAt.startOfDay`,
    /// and on a day a fast merely covers the fast sorts first, so the day's zone time would be filed
    /// under the fast's start day on a screen that shows the day.
    ///
    /// ``getWorkoutHistory(days:endingOn:)`` stays as it is for a third reason: it filters on `date` and
    /// deliberately **not** on `started_at`, *"because a range test on the raw instant would disagree
    /// with that lookup by one day at each boundary"*. That is a true statement about that read and the
    /// opposite of what this one does on purpose — this read *is* the range test, and disagreeing with
    /// the day-key lookup by design is the whole of what it is for. `WhoopExportImporter`'s day skip
    /// depends on the day-key reading: a covering read there would make every day a fast passes through
    /// look already recorded and silently drop the export's rows for it.
    ///
    /// ## The predicate
    ///
    /// `date <= day && ended_at > day`, which is the half-open overlap written as two chained filters so
    /// this file keeps its no-`OR` house style. `date` is always `startOfDay(startedAt)` — `saveWorkout`
    /// snaps it — so this is `startedAt < startOfNextDay(day) && endedAt > startOfDay(day)`
    /// (``WorkoutSession/covers(_:)``) for every row except a zero-length session sitting exactly on
    /// midnight, which that form covers and this one does not and which `ActivityEditDraft`'s 60-second
    /// `minimumDuration` makes unreachable.
    ///
    /// **Nothing here avoids a table scan.** `started_at` and `ended_at` are unindexed and no formulation
    /// bounds `started_at` from below, so the `date` index only halves it. At ~840 rows on a read that
    /// runs once per chevron tap that is fine, and it is noted here rather than indexed.
    public func getWorkouts(covering day: Date) throws -> [WorkoutRecord] {
        try dbQueue.read { db in
            try WorkoutRecord
                .filter(Column("date") <= day.startOfDay)
                .filter(Column("ended_at") > day.startOfDay)
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

/// The export's whole read, declared against the Domain protocol it satisfies.
///
/// **The conformance is spelled here rather than on the actor's own declaration**, so the sentence
/// `LocalDatabaseSnapshotting`'s doc comment makes — that this is not one of the app's repositories and
/// has no subject — is visible at the point the app takes it on. `exportAllRows()` itself stays inside
/// the actor body beside `existingTableNames()` and `columnNames(in:)`, which are the two other reads
/// that ask about the schema rather than about a day.
extension LocalDatabaseManager: LocalDatabaseSnapshotting {}

/// The sync's own door into `recoveries`, taken on at the same choke point and for the same reason.
///
/// **It is a second way into a table `RecoveryRepository` already reads, and the two answer different
/// questions.** `RecoveryRepository` speaks `RecoveryMetric`, which has no `source` and carries three
/// baseline deltas that have no column; a sync built on it would drop provenance on all 910 imported
/// rows and would have nothing to write into three of the columns on the way back, silently and with a
/// green build. So the sync gets a door that speaks the stored shape, and the conformance is declared
/// here — beside the snapshotting one and away from the actor's own declaration — so that the same
/// sentence is visible at the point the app takes it on: neither of these is one of the app's
/// repositories and neither has a subject.
extension LocalDatabaseManager: RecoverySyncStore {}

/// The sync's own door into `workouts`, taken on at the same choke point and for the same reason —
/// with one difference the flat resource has no equivalent for.
///
/// **`WorkoutRepository` is a worse fit for this resource than `RecoveryRepository` is for the one
/// beside it, and that is not a matter of degree.** `makeSessions` drops any stored row whose id will
/// not parse as a `UUID` and mints a **fresh** `UUID` for every route point and split it keeps, so a
/// sync built on the entity would upload a session under an identity the database has never held and
/// would rewrite a path with different child ids on every pass. The stored shape is the only one that
/// round trips, which is what this door speaks.
///
/// The conformance is declared here, beside the snapshotting and recoveries ones and away from the
/// actor's own declaration, so the same sentence is visible at the point the app takes it on: none of
/// these three is one of the app's repositories and none has a subject.
extension LocalDatabaseManager: WorkoutSyncStore {}

/// The sync's own door into `strains`, taken on at the same choke point and for the same reason.
///
/// **`StrainRepository` is a worse fit for this resource than `RecoveryRepository` is for the one two
/// above it, and the reason is a field it does not have.** `StrainRepository` speaks `StrainScore`,
/// whose `zones` array is computed from `biometric_samples` and has no column, so a sync built on the
/// entity would carry a field the database cannot store on the way up and would have nothing to
/// reconstruct on the way back. The stored shape is the one that round trips, which is what this door
/// speaks — and unlike the workouts half there is no id policy to state, because a strain's identity
/// *is* its day and that is a `Date` on both sides.
///
/// **The two method names carry the resource because they have to**, which is `StrainSyncStore`'s own
/// point rather than a naming preference: `syncRows(from:to:)` differs from the recoveries one in
/// nothing at all — a signature is a name plus its argument labels, and the row type appears in neither
/// — so declaring it a second time is `invalid redeclaration`.
///
/// The conformance is declared here, beside the snapshotting, recoveries and workouts ones and away
/// from the actor's own declaration, so the same sentence is visible at the point the app takes it on:
/// none of these is one of the app's repositories and none has a subject.
extension LocalDatabaseManager: StrainSyncStore {}

/// The sync's own door into `sleeps`, taken on at the same choke point and for the same reason.
///
/// **`SleepRepository` is a worse fit than `RecoveryRepository` is, for the same kind of reason and one
/// more.** The entity is `SleepSession`, whose `id` is a `UUID` the record does not have and whose
/// `sleepStages` is a parsed `[SleepStageSegment]` where the column holds opaque JSON text — so a sync
/// built on it could neither round trip an identity nor hand the wire the bytes the schema asks for.
/// The stored shape is the one that round trips, which is what this door speaks.
///
/// **The day this door reads is the night's wake day**, and that is the one rule worth repeating at the
/// point the conformance is taken on: nothing here derives a key from `startTime`.
extension LocalDatabaseManager: SleepSyncStore {}

/// The sync's own door into `stepCounts`, taken on at the same choke point and for the same reason —
/// and this is the member of the family whose entity would have been *closest* to usable, which makes
/// saying why it is not worth the line.
///
/// `StepCount` carries `hasMeasurement` as a computed property over `measuredSeconds`, so a sync built
/// on the entity would look right and would be one field short on the way out: the absence rule this
/// table expresses as a *column* would arrive at the wire as an absence of a row, and a day the strap
/// never counted would be stored on the far side as a day of zero steps. The stored shape carries the
/// column, which is what this door speaks.
extension LocalDatabaseManager: StepCountSyncStore {}

/// The sync's own door into `receptive_inactivities`, taken on at the same choke point and for the same
/// reason.
///
/// **The entity's id is a `UUID` and the stored id is a `String`, which is the whole reason this needs a
/// door of its own.** A `ReceptiveInactivity` is identified by a `UUID` and `ReceptiveInactivityRecord`
/// by the text a `UUID` renders to — and that text is not a convenience here but a *derived* value:
/// `InactivityParser.identifier(date:type:note:)` computes a UUIDv5 from the entry's own facts, which is
/// what makes re-importing the bundled file rewrite its rows rather than append a second copy of every
/// one. A sync built on the entity would put a `UUID(uuidString:)` conversion in that path, where a
/// stored id that failed to parse would either drop the row silently or be replaced by a fresh
/// `UUID()` — and the second of those does not fail either, it appends. The stored shape has no such
/// seam, so it is the one this door speaks.
extension LocalDatabaseManager: ReceptiveInactivitySyncStore {}

/// The sync's own door into `user_profiles`, taken on at the same choke point and for the same reason —
/// and the one whose two questions are furthest apart.
///
/// **`UserProfileRepository` speaks an eleven-field entity while the table stores seven**, so a sync
/// built on it would carry four fields with no column and no way to say which of them the user actually
/// supplied. `UserProfileRecord` is exactly the stored row, so the stored shape is the one that round
/// trips — and this is also the one conformance here with **no range**: the table is a singleton, so its
/// read takes no `from`/`to` and its save takes no array.
extension LocalDatabaseManager: UserProfileSyncStore {}

/// The one conversion from what GRDB hands back to the `Sendable` value the export carries.
///
/// **It lives in `Data/` and cannot live beside the enum** because it is the only part of
/// `LocalDataValue` that knows GRDB exists: `LocalDataValue` is a Domain type and Domain imports only
/// `Foundation`, so an initialiser taking a `DatabaseValue` could not be declared on it. Keeping the
/// mapping here is the same split `GRDBRecoveryRepository` makes between a record's columns and the
/// entity a repository hands up, one layer down.
///
/// **`DatabaseValue.storage` is exhaustive over the five things a SQLite column can hold**, and there is
/// deliberately no `default` arm: five of the app's own columns are JSON text and none is a blob, so a
/// `default` that folded an unknown storage class into `.text` would export a value that is not the one
/// stored — silently, on the one artifact nobody opens during a build. A sixth case added by a future
/// GRDB is a compile error here instead.
extension LocalDataValue {
    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let number): self = .integer(number)
        case .double(let number): self = .real(number)
        case .string(let text): self = .text(text)
        case .blob(let data): self = .blob(base64: data.base64EncodedString())
        }
    }
}
