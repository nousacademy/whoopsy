import Foundation
import Whoopsy

// MARK: - 22.4 The phone's own door into `recoveries`, and the two conventions every block inherits

/// **The block that pins the conventions the rest of §22 is built on**: that a sync range is half-open
/// `[from, to)`, and that a day is snapped on the way in.
///
/// It drives `LocalDatabaseManager` directly rather than through `RecoveryRepository`, because that is
/// the door the sync actually uses. `RecoverySyncStore` is a *second* way into a table the repository
/// already reads, and the reason is on the protocol rather than on this test: `RecoveryRepository`
/// speaks `RecoveryMetric`, which has no `source` and no home for the three baseline columns, so a sync
/// built on it would drop provenance from every imported row and report success while doing it.
///
/// **Half-open is the assertion that carries the block.** `endOfDay` is `23:59:59` — the last *instant*
/// of a day, right for the inclusive window `getRecoveryHistory` draws for a screen and wrong for a
/// chunk boundary, which has to abut the next chunk without overlapping it. The two differ by exactly
/// one second, so a range built from the wrong one puts a row written at midnight outside both halves of
/// a split: invisible on a read of one chunk and written twice on a chunked upload.
enum LocalDatabaseManagerSyncTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped. Built by adding to today rather than subtracting
        /// from a literal, so the assertions hold on whatever day the suite runs — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        /// A row on a named day, with every value derived from what it is given so two rows never
        /// compare equal by accident.
        let row: (Date, Int) -> RecoverySyncRow = { date, score in
            RecoverySyncRow(date: date, recoveryScore: score, restingHeartRate: 55,
                            hrvValueMs: Double(score) + 0.5, hrvMetric: .rmssd, source: "whoop_export")
        }

        /// The same row for a day named by offset, scoring within the band the server accepts.
        let rowOn: (Int) -> RecoverySyncRow = { offset in row(day(offset), 40 + abs(offset) % 60) }

        /// The two hundred days a chunk of a real upload would carry: the corpus is 910 rows, and one
        /// chunk of the two hundred rows the engine sends per request is what a reviewer should be able
        /// to picture.
        let offsets = (0 ..< 200).map { -600 + $0 }
        let rows = offsets.map(rowOn)

        // MARK: A batch goes in whole and comes back whole, oldest first

        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncRows(rows)

            let readBack = try await db.syncRows(from: day(-600), to: day(-400))
            assertTest(readBack.count == 200, "A batch of two hundred days comes back as two hundred rows")
            assertTest(readBack == rows, "…field for field, which is the record round trip by value")

            // Ascending is load-bearing rather than a convenience: the upload chunks this array and
            // advances the boundary to each chunk's own last row, so a shuffled read would move the
            // boundary across days it had not sent.
            assertTest(readBack.map(\.date) == readBack.map(\.date).sorted(),
                       "…in ascending day order, which is what the upload's boundary advance depends on")
            assertTest(readBack.first?.date == day(-600) && readBack.last?.date == day(-401),
                       "…from the range's first day to the day before its upper bound")

            // The bounds are snapped by the reader, not by its callers — `HomeDashboardView` hands a raw
            // instant on first load, and a window that trusted it would drop or gain a day at each end.
            let midMorning = try await db.syncRows(from: day(-600) + 5 * 3600, to: day(-400) + 7 * 3600)
            assertTest(midMorning.count == 200, "A range whose bounds carry a clock time is snapped to their days")
            assertTest(midMorning == readBack, "…and reads exactly the rows the snapped range does")
        }

        // MARK: The upper bound is exclusive, at both edges

        // The five ranges around the batch are the whole of the convention, and the two-day one is the
        // assertion that fails if anyone writes `<=` — it would name three days where the convention
        // names two.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncRows(rows)

            let empty = try await db.syncRows(from: day(-600), to: day(-600))
            assertTest(empty.isEmpty, "An empty range names no days rather than the one it lands on")

            let firstOnly = try await db.syncRows(from: day(-600), to: day(-599))
            assertTest(firstOnly.count == 1 && firstOnly.first?.date == day(-600),
                       "A one-day range is `[from, from + 1)`, and its single day is the lower bound")

            let lastOnly = try await db.syncRows(from: day(-401), to: day(-400))
            assertTest(lastOnly.count == 1 && lastOnly.first?.date == day(-401),
                       "…and the same at the batch's far end")

            let pastTheEnd = try await db.syncRows(from: day(-400), to: day(-399))
            assertTest(pastTheEnd.isEmpty, "The day after the upper bound is outside the range")

            let lastTwo = try await db.syncRows(from: day(-402), to: day(-400))
            assertTest(lastTwo.count == 2, "A two-day range names two days, not three — the upper bound is exclusive")
            assertTest(lastTwo.map(\.date) == [day(-402), day(-401)],
                       "…and they are the two the range covers")
        }

        // MARK: A day carrying a clock time is filed on its own day

        // The snap the sync shares with every other writer here, and the one it needs most: these rows
        // arrive from a wire format whose day is a bare `YYYY-MM-DD`, and GRDB's `save` is
        // INSERT-or-UPDATE *by primary key* — so a record written at a raw instant would be INSERTed
        // rather than UPDATEd, exist, and be unreachable by every keyed read in the app.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let afternoon = day(-900) + 12 * 3600 + 34 * 60

            try await db.saveSyncRows([row(afternoon, 63)])
            let stored = try await db.syncRows(from: day(-900), to: day(-899))
            assertTest(stored.count == 1, "A row written mid-afternoon is filed on its own day")
            assertTest(stored.first?.date == day(-900), "…at that day's midnight, not at the instant it carried")

            // Read through the app's own door as well, because the sync's write being visible to a
            // screen's read is the whole point of the two sharing a choke point.
            let repository = GRDBRecoveryRepository(db: db)
            let metric = try await repository.getRecovery(for: day(-900))
            assertTest(metric?.score == 63, "…and the repository that draws the day finds it, unchanged")
        }

        // MARK: Re-saving a day updates it rather than appending a second row

        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncRows([row(day(-950), 30)])
            try await db.saveSyncRows([row(day(-950), 80)])

            let stored = try await db.syncRows(from: day(-950), to: day(-949))
            assertTest(stored.count == 1, "A second write to one day leaves one row, not two")
            assertTest(stored.first?.recoveryScore == 80, "…and the day carries the newer figure")
        }

        // An empty batch is not a write. The guard is in `saveSyncRows` rather than at its call sites,
        // because the upload can reach it with a chunk that filtered to nothing.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncRows(rows)
            try await db.saveSyncRows([])
            let stored = try await db.syncRows(from: day(-600), to: day(-400))
            assertTest(stored.count == 200, "An empty batch changes nothing")
        }

        // MARK: There is no delete, and its absence is the decision this whole feature is built on

        // **A block used to stand here** asserting `deleteSyncRows(from:to:)`: `An empty range deletes
        // nothing`, `A half-open range deletes exactly the hundred days it names`, `…and the second half
        // takes the rest`, and `A row outside the ranges survives both deletes`. It is gone with the
        // method, and the absence is the user's own ruling rather than a simplification: *"if a DB is
        // selected, it doesnt purge anything, it just switches where data will be stored to."* A
        // destination is a switch and a sync is a write-through, so nothing in this app removes a row
        // from either store — which is also why the whole provenance model (`uploadedCutoff`,
        // `cloudHolds`, `pendingWork`) went with it: all of that machinery existed to answer *what has to
        // be fetched back after a delete*.
        //
        // **Nothing here can assert an absence**, so what pins it is elsewhere and in two places: the
        // port is the evidence that the *client* cannot delete (`CloudSync` has no delete method, and
        // `SpyCloudSync`'s `Call` enum has no case for one), and §22's contract sweep is where the
        // *server* half is read — the Worker mounts no `DELETE` route for any of its eight resources.
        // A block asserting "no such method exists" would not compile against a method that did, so
        // there is nothing to write here; the comment is the record.

        // MARK: The columns, by name — the three namespaces' first two

        // `RecoveryRecord.CodingKeys` is internal to the module and cannot be read from here, so the
        // schema is pinned through the door that exists for it. The whole set rather than a `contains`
        // sweep: a tenth column is a column no record declares, and its values would be read by nothing.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let columns = try await db.columnNames(in: "recoveries")
            assertTest(Set(columns) == [
                "date", "recovery_score", "resting_heart_rate", "hrv_value_ms", "hrv_metric",
                "skin_temperature", "spo2_percentage", "respiratory_rate", "source"
            ], "The table's columns are the record's own nine, spelled in snake case")

            // The two the wire spells a third way are named here, because a `skinTemp` column would
            // mean the record's mapping and the table had drifted and every read would throw at launch.
            assertTest(columns.contains("skin_temperature") && !columns.contains("skinTemp"),
                       "Skin temperature's column is snake case and not the record property's name")
            assertTest(columns.contains("spo2_percentage") && !columns.contains("spo2"),
                       "…and so is SpO2's")

            assertTest(try await db.columnNames(in: "no_such_table").isEmpty,
                       "A table that does not exist has no columns rather than throwing")
        }

        // MARK: The nine fields, across the three namespaces

        // A row carrying **every** field with a value no other field shares, so a mapping that swapped
        // two of them cannot cancel itself out. The assertion is made twice on purpose: by `==` on the
        // row, which is the record's own round trip, and then field by field through the *repository*,
        // whose `RecoveryMetric` spells two of the nine differently — a swap inside the record's
        // mapping would survive the first and fail the second.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let source = RecoverySyncRow(
                date: day(-800),
                recoveryScore: 71,
                restingHeartRate: 52,
                hrvValueMs: 68.4,
                hrvMetric: .sdnn,
                skinTemp: 34.25,
                spo2: 96.5,
                respiratoryRate: 13.75,
                source: "whoop_export")

            try await db.saveSyncRows([source])
            let back = try await db.syncRows(from: day(-800), to: day(-799))
            assertTest(back == [source], "All nine fields survive a write and a read, provenance included")

            let repository = GRDBRecoveryRepository(db: db)
            let metric = try await repository.getRecovery(for: day(-800))
            assertTest(metric?.score == 71, "…and the score crosses to the entity unchanged")
            assertTest(metric?.restingHeartRate == 52, "…and the resting rate")
            assertTest(metric?.hrvValueMs == 68.4, "…and the HRV value")
            assertTest(metric?.hrvMetric == .sdnn, "…and which quantity that value is")
            assertTest(metric?.skinTemperatureCelsius == 34.25,
                       "…and skin temperature reads back as the entity's own fourth name for it")
            assertTest(metric?.spO2Percentage == 96.5, "…and SpO2 as its fifth")
            assertTest(metric?.respiratoryRate == 13.75, "…and the respiratory rate")

            // The absence rule, on the field most likely to be given a plausible default: an unmeasured
            // value is `nil` on both sides rather than `0`, which is a real reading on this column.
            try await db.saveSyncRows([RecoverySyncRow(
                date: day(-801), recoveryScore: 40, restingHeartRate: 55,
                hrvValueMs: 41, hrvMetric: .rmssd, source: nil)])
            let bare = try await repository.getRecovery(for: day(-801))
            assertTest(bare?.skinTemperatureCelsius == nil, "A field nobody measured stays absent rather than zero")
            assertTest(bare?.spO2Percentage == nil, "…on every one of the optional columns")
            assertTest(bare?.respiratoryRate == nil, "…including the respiratory rate")

            let bareRow = try await db.syncRows(from: day(-801), to: day(-800))
            assertTest(bareRow.first?.source == nil, "…and a nil provenance is stored as nil, not as a label")
        }
    }
}
