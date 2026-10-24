import Foundation
import Whoopsy

/// The schema and the catalogue that make a stored score explainable.
enum StrainProvenancePersistenceTests {
    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)

        // ---- The columns ----
        //
        // **camelCase, because `StrainRecord` declares no `CodingKeys`** — its property names are its
        // column names. `motion_load` would be `no such column` at launch, and a failing migration
        // `fatalError`s the app.
        let columns = try await db.columnNames(in: "strains")
        for expected in ["motionLoad", "scoredThrough", "algorithm"] {
            assertTest(
                columns.contains(expected),
                "`strains` carries `\(expected)` — v35's column, spelled as the record's property")
        }
        assertTest(
            !columns.contains("motion_load") && !columns.contains("scored_through"),
            "…and not the snake-case spellings, which no record would ever read")

        let workoutColumns = try await db.columnNames(in: "workouts")
        assertTest(
            workoutColumns.contains("rpe"), "`v36` adds the session rating to `workouts`, got "
                + "\(workoutColumns)")

        // ---- The catalogue ----
        let catalogue = try await db.strainAlgorithmCatalogue()
        assertTest(catalogue.count == 3, "The catalogue seeds three versions, got \(catalogue.count)")

        let versions = catalogue.map(\.version)
        for expected in ["hr-zone-v1", "hr-motion-v2", "whoop-export"] {
            assertTest(versions.contains(expected), "…including `\(expected)`")
        }
        assertTest(
            catalogue.allSatisfy { !$0.formula.isEmpty && !$0.parameters.isEmpty },
            "Every catalogue row states a formula and its parameters — a name with no definition is "
                + "a label, not a record")
        assertTest(
            StrainAlgorithm.allCases.allSatisfy { versions.contains($0.rawValue) },
            "Every `StrainAlgorithm` case is documented in the table, so none is a name with no formula")
        assertTest(
            catalogue.last?.version == StrainAlgorithm.current.rawValue,
            "The newest catalogued version is the one the writer stamps — got "
                + "\(catalogue.last?.version ?? "none") vs \(StrainAlgorithm.current.rawValue)")

        // ---- A row's provenance survives the store ----
        let day = StrainTests.day
        let strains = GRDBStrainRepository(db: db)
        try await strains.saveStrain(
            StrainScore(
                date: day, score: 8.4, hasMeasurement: true,
                motionLoad: 321.5, source: StrainScore.deviceSource,
                algorithm: .hrMotionV2, scoredThrough: day.addingTimeInterval(3600)),
            source: StrainScore.deviceSource)

        let read = try await strains.getLocalStrain(for: day)
        assertTest(read?.algorithm == .hrMotionV2, "The algorithm round-trips through SQLite")
        assertTest(read?.motionLoad == 321.5, "…and so does the motion component")
        assertTest(
            read?.scoredThrough == day.addingTimeInterval(3600),
            "…and the watermark, to the second")

        // ---- The sync's two rules on this table ----
        let syncDay = day.addingTimeInterval(86_400).startOfDay
        try await db.saveSyncStrainRows([
            StrainSyncRow(
                date: syncDay, strainScore: 6.1, kilojoules: 900,
                averageHeartRate: 61, maxHeartRate: 140, hasMeasurement: true,
                source: nil, algorithm: StrainAlgorithm.hrMotionV2.rawValue)
        ])
        let synced = try await strains.getLocalStrain(for: syncDay)
        assertTest(synced?.algorithm == .hrMotionV2, "A synced row's algorithm is stored")
        assertTest(
            synced?.motionLoad == nil && synced?.scoredThrough == nil,
            "…and the local-only fields are NULL rather than a watermark from another device")

        // A client older than the field sends nothing; that must not erase what this phone knows.
        try await db.saveSyncStrainRows([
            StrainSyncRow(
                date: syncDay, strainScore: 6.3, kilojoules: 910,
                averageHeartRate: 62, maxHeartRate: 141, hasMeasurement: true,
                source: nil, algorithm: nil)
        ])
        let afterOldClient = try await strains.getLocalStrain(for: syncDay)
        assertTest(
            afterOldClient?.score == 6.3 && afterOldClient?.algorithm == .hrMotionV2,
            "A synced row with no algorithm updates the score and keeps the stored version")

        // ---- A rating is user data, and a sync must not erase it ----
        let workoutID = UUID()
        let start = day.addingTimeInterval(9 * 3600)
        try await db.saveWorkout(
            WorkoutRecord(
                id: workoutID.uuidString, date: start, startedAt: start,
                endedAt: start.addingTimeInterval(1_800),
                strain: 3.2, averageHeartRate: 120, maxHeartRate: 155,
                rpe: 6),
            route: [], splits: [])
        assertTest(
            try await db.getLatestWorkout()?.rpe == 6,
            "A stored rating reads back on its row")

        // The sync's write path carries no rating — see `WorkoutRecord+SyncRow`.
        try await db.saveSyncWorkoutRows([
            WorkoutSyncRow(
                id: workoutID, date: start, startedAt: start,
                endedAt: start.addingTimeInterval(1_800),
                strain: 3.4, averageHeartRate: 121, maxHeartRate: 156)
        ])
        let afterSync = try await db.getLatestWorkout()
        assertTest(
            afterSync?.strain == 3.4,
            "A synced session updates the measured fields, got \(afterSync?.strain ?? -1)")
        assertTest(
            afterSync?.rpe == 6,
            "…and keeps the rating the user entered, got \(afterSync?.rpe.map(String.init) ?? "nil")")

        // ---- The importer's label is the one a repair decision reads ----
        assertTest(
            WhoopExportImporter.sourceLabel == StrainScore.importSource,
            "The importer's `source` label and the value `StrainScore.isDeviceScored` tests are one "
                + "string, and this is the assertion that keeps them one")
    }
}
