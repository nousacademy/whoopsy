import Foundation
import Whoopsy

// MARK: - 22.4b The phone's own door into `workouts`, which is an aggregate and not a row

/// **`LocalDatabaseManagerSyncTests`' sibling, and the three things it cannot say.** A recovery is one
/// row keyed on a day; a workout is a parent keyed on an id with two child tables hanging off it, so the
/// questions this block exists for are the ones the aggregate creates: whether a chunk's children move
/// with it, whether re-saving replaces them or stacks them, and what happens to a parent whose stored id
/// will not parse.
///
/// **It had a fourth question and that question is gone.** A range delete used to be the fourth — with
/// the aggregate-specific twist that a table-wide child delete would orphan every route point in the
/// database — and it went with the method, on the user's ruling that a destination *"doesnt purge
/// anything, it just switches where data will be stored to"*. The block below records what it asserted
/// and where each of its claims lives now.
///
/// **Two conventions are inherited from the block above rather than re-argued.** The range is half-open
/// `[from, to)` — the same boundary a chunked upload advances — and a day is snapped on the way in. Both
/// are asserted here anyway, because a table that is keyed differently could hold them differently and
/// this is the only block that can see it: `workouts` is the one table in this family whose primary key
/// is not its day.
///
/// **The children are read back through the repository, not counted.** `LocalDatabaseManager` exposes no
/// row count for any table, and an orphaned route point is invisible to every reader in this app —
/// `makeSessions` fetches children *per session*, so a fix whose session is gone is never read, never
/// drawn and never noticed. That is why the deleted delete block's survivor assertions were the ones
/// that carried it, and why the comment recording their removal is longer than the code around it.
enum LocalDatabaseManagerWorkoutSyncTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped — `LocalDatabaseManagerSyncTests`' helper, whose
        /// reason is §11's: an assertion anchored on `Date()` must move with the day the suite runs.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        /// A session on a named day, carrying a route and a split, so every assertion below is about the
        /// aggregate rather than about the parent alone.
        ///
        /// The route runs **oldest first**, which is not decoration: the child table has no `seq` column
        /// and `syncWorkoutRows` recovers the order by sorting on `timestamp`, so a fixture written
        /// newest-first would come back re-ordered and `readBack == rows` would fail on a correct
        /// implementation. The block below pins that re-ordering deliberately; this one must not trip on it.
        let session: (UUID, Date, Double) -> WorkoutSyncRow = { id, date, strain in
            let start = date.addingTimeInterval(6 * 3600)
            return WorkoutSyncRow(
                id: id,
                date: date,
                startedAt: start,
                endedAt: start.addingTimeInterval(3600),
                strain: strain,
                averageHeartRate: 121,
                maxHeartRate: 164,
                source: "whoop_export",
                activityName: "Basketball",
                hrZonePercents: [10, 20, 35, 25, 5],
                steps: 693,
                route: [
                    WorkoutRoutePoint(latitude: 51.5074, longitude: -0.1278,
                                      timestamp: start, heartRate: 121),
                    WorkoutRoutePoint(latitude: 51.5080, longitude: -0.1282,
                                      timestamp: start.addingTimeInterval(600), heartRate: 150),
                ],
                splits: [WorkoutSplit(elapsed: 1800, strain: strain)])
        }

        /// A session on a day named by offset, with a strain derived from the offset so two rows never
        /// compare equal by accident.
        let sessionOn: (Int) -> WorkoutSyncRow = { offset in
            session(UUID(), day(offset), 2.0 + Double(abs(offset) % 90) / 10)
        }

        /// The two hundred days one chunk of a real upload would carry — the engine's 200-session
        /// ceiling (`maximumBatchWorkouts`) is what a reviewer should be able to picture, and it is the
        /// cap the server publishes.
        let offsets = (0 ..< 200).map { -600 + $0 }
        let rows = offsets.map(sessionOn)

        // MARK: A chunk goes in whole and comes back whole, children and all

        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncWorkoutRows(rows)

            let readBack = try await db.syncWorkoutRows(from: day(-600), to: day(-400))
            assertTest(readBack.count == 200, "A chunk of two hundred sessions comes back as two hundred rows")
            assertTest(readBack == rows,
                       "…field for field and child for child, which is the aggregate's round trip by value")
            assertTest(readBack.reduce(0) { $0 + $1.route.count } == 400,
                       "…carrying all four hundred GPS fixes with them")
            assertTest(readBack.reduce(0) { $0 + $1.splits.count } == 200,
                       "…and all two hundred laps, because a chunk that moved parents alone would move neither")

            // Ascending is load-bearing rather than a convenience: the upload chunks this array and
            // advances the boundary to each chunk's own last row, so a shuffled read would move the
            // boundary across days it had not sent.
            assertTest(readBack.map(\.date) == readBack.map(\.date).sorted(),
                       "…in ascending day order, which is what the upload's boundary advance depends on")
            assertTest(readBack.first?.date == day(-600) && readBack.last?.date == day(-401),
                       "…from the range's first day to the day before its upper bound")

            // The bounds are snapped by the reader, not by its callers — the same contract the recovery
            // half has, asserted here because a second table could have been given a second reader.
            let midMorning = try await db.syncWorkoutRows(from: day(-600) + 5 * 3600,
                                                          to: day(-400) + 7 * 3600)
            assertTest(midMorning.count == 200, "A range whose bounds carry a clock time is snapped to their days")
            assertTest(midMorning == readBack, "…and reads exactly the sessions the snapped range does")
        }

        // MARK: A day holds several sessions, and the order among them is three keys deep

        // **The assertion that fails if anyone normalises this table onto a day key.** `recoveries`,
        // `sleeps` and `strains` hold one row per day and are primary-keyed on `date`; a second session
        // on one day would overwrite the first here, silently, with the day still drawing a plausible
        // card. The fixture puts **two sessions on one second** as well, which is the case the third
        // ordering key exists for: without it two reads of one unchanged database could disagree about
        // which session a chunk boundary fell after.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let early = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            let middle = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
            let late = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

            let noon = day(-700) + 12 * 3600
            let sessionAt: (UUID, Date) -> WorkoutSyncRow = { id, startedAt in
                WorkoutSyncRow(id: id, date: day(-700), startedAt: startedAt,
                               endedAt: startedAt.addingTimeInterval(1800),
                               strain: 4.1, averageHeartRate: 121, maxHeartRate: 164)
            }

            // Written out of order on purpose, so the read's order is the read's rather than the write's.
            try await db.saveSyncWorkoutRows([
                sessionAt(late, noon.addingTimeInterval(3600)),
                sessionAt(early, noon),
                sessionAt(middle, noon),
            ])

            let day700 = try await db.syncWorkoutRows(from: day(-700), to: day(-699))
            assertTest(day700.count == 3, "A day holding three sessions reads back three, because the key is the id")
            assertTest(day700.map(\.id) == [early, middle, late],
                       "…ordered by day, then by start, then by id — the third key breaking the same-second pair")
            assertTest(day700[0].id.uuidString < day700[1].id.uuidString,
                       "…and the pair that started on one second is broken by the id's own string")
            assertTest(day700.map(\.startedAt) == [noon, noon, noon.addingTimeInterval(3600)],
                       "…so the walk is deterministic over a day the app can really produce")
        }

        // MARK: The upper bound is exclusive, at both edges

        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncWorkoutRows(rows)

            let empty = try await db.syncWorkoutRows(from: day(-600), to: day(-600))
            assertTest(empty.isEmpty, "An empty range names no days rather than the one it lands on")

            let firstOnly = try await db.syncWorkoutRows(from: day(-600), to: day(-599))
            assertTest(firstOnly.count == 1 && firstOnly.first?.date == day(-600),
                       "A one-day range is `[from, from + 1)`, and its single session is the lower bound")

            let lastOnly = try await db.syncWorkoutRows(from: day(-401), to: day(-400))
            assertTest(lastOnly.count == 1 && lastOnly.first?.date == day(-401),
                       "…and the same at the chunk's far end")

            let pastTheEnd = try await db.syncWorkoutRows(from: day(-400), to: day(-399))
            assertTest(pastTheEnd.isEmpty, "The day after the upper bound is outside the range")

            let lastTwo = try await db.syncWorkoutRows(from: day(-402), to: day(-400))
            assertTest(lastTwo.count == 2, "A two-day range names two days, not three — the upper bound is exclusive")
            assertTest(lastTwo.map(\.date) == [day(-402), day(-401)],
                       "…and they are the two the range covers")
        }

        // MARK: The children's order is recovered by the read, because no column records it

        // **This is the whole of the aggregate's ordering rule, and it is one sentence:** the child
        // tables have no `seq` column, so the read sorts the route on `timestamp` and the splits on
        // `elapsed` — the wire then binds its own `seq` from that array's index. A chunk is therefore
        // written as it was read and never sorted by the mapper, because the store's answer is already
        // the order the server needs. Asserted on a fixture whose route is deliberately newest-first,
        // which an equal-width probe could not see.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let start = day(-650) + 6 * 3600
            let unordered = WorkoutSyncRow(
                id: UUID(), date: day(-650),
                startedAt: start, endedAt: start.addingTimeInterval(3600),
                strain: 4.1, averageHeartRate: 121, maxHeartRate: 164,
                route: [
                    WorkoutRoutePoint(latitude: 51.51, longitude: -0.13,
                                      timestamp: start.addingTimeInterval(1800), heartRate: 160),
                    WorkoutRoutePoint(latitude: 51.50, longitude: -0.12,
                                      timestamp: start.addingTimeInterval(600), heartRate: 130),
                    WorkoutRoutePoint(latitude: 51.5074, longitude: -0.1278,
                                      timestamp: start, heartRate: 121),
                ],
                splits: [
                    WorkoutSplit(elapsed: 3600, strain: 4.1),
                    WorkoutSplit(elapsed: 1200, strain: 1.4),
                ])

            try await db.saveSyncWorkoutRows([unordered])
            let ordered = try await db.syncWorkoutRows(from: day(-650), to: day(-649))

            assertTest(ordered.count == 1, "The session comes back")
            assertTest(ordered.first?.route.map(\.timestamp) == [
                start, start.addingTimeInterval(600), start.addingTimeInterval(1800)
            ], "…with its route in timestamp order rather than the order it was written in")
            assertTest(ordered.first?.splits.map(\.elapsed) == [1200, 3600],
                       "…and its splits in elapsed order, the same rule on the second child table")
            assertTest(ordered.first?.route.map(\.heartRate) == [121, 130, 160],
                       "…so the fixes are ordered by their own instants and nothing else")

            // Read through the app's own door as well, because the page that draws a route is the reader
            // this ordering exists for and it must see the same order the sync sends.
            let throughRepository = try await GRDBWorkoutRepository(db: db).getWorkouts(for: day(-650))
            assertTest(throughRepository.first?.route.map(\.timestamp) == ordered.first?.route.map(\.timestamp),
                       "…and the repository that draws the path hands back the same sequence")
        }

        // MARK: A session written at a raw instant is filed on its own day

        // The snap the sync shares with every other writer here, and the one it needs most: these rows
        // arrive from a wire format whose day is a bare `YYYY-MM-DD`, and GRDB's `save` is
        // INSERT-or-UPDATE *by primary key* — a record inserted at a raw instant would exist and be
        // unreachable by every keyed read in the app.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let afternoon = day(-900) + 12 * 3600 + 34 * 60
            let raw = WorkoutSyncRow(id: UUID(), date: afternoon,
                                     startedAt: afternoon, endedAt: afternoon.addingTimeInterval(2700),
                                     strain: 7.4, averageHeartRate: 131, maxHeartRate: 172)

            try await db.saveSyncWorkoutRows([raw])
            let stored = try await db.syncWorkoutRows(from: day(-900), to: day(-899))
            assertTest(stored.count == 1, "A session written mid-afternoon is filed on its own day")
            assertTest(stored.first?.date == day(-900), "…at that day's midnight, not at the instant it carried")
            assertTest(stored.first?.startedAt == afternoon,
                       "…while the session's own start instant is untouched, because that is a reading")

            // Both reads the app has over this table, because the sync's write being visible to a
            // screen's read is the whole point of the two sharing one definition of saving a session.
            let onItsDay = try await db.getWorkouts(on: day(-900))
            assertTest(onItsDay.count == 1 && onItsDay.first?.id == raw.id.uuidString,
                       "…and the manager's own day read finds it")

            let repository = GRDBWorkoutRepository(db: db)
            let sessions = try await repository.getWorkouts(for: day(-900))
            assertTest(sessions.first?.id == raw.id, "…and so does the repository the card is built from")
            assertTest(sessions.first?.strain == 7.4, "…carrying the session unchanged")
            assertTest(try await repository.getWorkouts(for: day(-901)).isEmpty,
                       "…on that day alone, and not on the day before it")
        }

        // MARK: Re-saving a session replaces its children rather than stacking a second set

        // `writeWorkout` clears both child tables by `workout_id` before writing the new ones, and the
        // assertion that sees it is a *shorter* route on the second write: a save that appended would
        // read back three fixes where two were written, and the page would draw a path with a spur into
        // it while every parent field looked right.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let id = UUID()
            let start = day(-950) + 7 * 3600
            let full = WorkoutSyncRow(
                id: id, date: day(-950), startedAt: start, endedAt: start.addingTimeInterval(3600),
                strain: 4.1, averageHeartRate: 121, maxHeartRate: 164,
                route: [
                    WorkoutRoutePoint(latitude: 51.50, longitude: -0.12, timestamp: start, heartRate: 121),
                    WorkoutRoutePoint(latitude: 51.51, longitude: -0.13,
                                      timestamp: start.addingTimeInterval(600), heartRate: 140),
                ],
                splits: [
                    WorkoutSplit(elapsed: 900, strain: 1.1),
                    WorkoutSplit(elapsed: 1800, strain: 2.2),
                ])

            try await db.saveSyncWorkoutRows([full])

            // The same session trimmed by the edit sheet: one fix and one lap, one field changed.
            let trimmed = WorkoutSyncRow(
                id: id, date: day(-950), startedAt: start, endedAt: start.addingTimeInterval(3600),
                strain: 5.9, averageHeartRate: 121, maxHeartRate: 164,
                route: [WorkoutRoutePoint(latitude: 51.50, longitude: -0.12, timestamp: start, heartRate: 121)],
                splits: [WorkoutSplit(elapsed: 900, strain: 1.1)])

            try await db.saveSyncWorkoutRows([trimmed])

            let stored = try await db.syncWorkoutRows(from: day(-950), to: day(-949))
            assertTest(stored.count == 1, "A second write to one session leaves one parent, not two")
            assertTest(stored.first?.strain == 5.9, "…and the session carries the newer figure")
            assertTest(stored.first?.route.count == 1,
                       "…with its route replaced rather than appended to — the write clears before it saves")
            assertTest(stored.first?.splits.count == 1, "…and its splits replaced the same way")
        }

        // A chunk that filtered to nothing is not a write. The guard is inside `saveSyncWorkoutRows`
        // rather than at its call sites, because the upload can reach it with a chunk that emptied.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            try await db.saveSyncWorkoutRows(rows)
            try await db.saveSyncWorkoutRows([])
            let stored = try await db.syncWorkoutRows(from: day(-600), to: day(-400))
            assertTest(stored.count == 200, "An empty chunk changes nothing")
        }

        // MARK: There is no range delete, and the aggregate is why its absence matters most here

        // **A block used to stand here** seeding three sessions across two days — each with two route
        // points and two splits — and asserting `deleteSyncWorkoutRows(from:to:)` against them: an empty
        // range deleting nothing, a half-open range taking every session filed on the day it names, a
        // session outside the range surviving *with its own two fixes and two laps*, and a second delete
        // of the same range taking nothing further. The survivor assertions were the point of the whole
        // block, because a `deleteAll` on each child table without the `workout_id` filter would have
        // removed every route point in the database on the first chunk deleted — leaving every remaining
        // session reading back with an empty path, invisible in a parent-level read and drawn as "no
        // route recorded" on a session that has one.
        //
        // The method is gone and the block with it, on the user's own ruling: *"if a DB is selected, it
        // doesnt purge anything, it just switches where data will be stored to."* A sync is a
        // write-through and a destination is a switch, so no run can delete a session or orphan a child.
        //
        // **What the aggregate still needs asserted, and where it is.** The three questions this block's
        // own doc comment names are not all about deletion. *Whether re-saving replaces the children or
        // stacks them* is `saveSyncWorkoutRows`' documented replacement, and *whether a chunk's children
        // move with it* is the read-back order assertion above — `The children ride inside the row, so a
        // read is one request` and `the wire mapper must preserve read order and must never sort` are
        // both pinned in the blocks that own them. Deleting was the third, and there is no third.

        // MARK: The columns, by name — the aggregate's three tables

        // `WorkoutRecord.CodingKeys` and its two siblings are internal to the module and cannot be read
        // from here, so the schema is pinned through the door that exists for it. The whole set rather
        // than a `contains` sweep, because a thirteenth column is a column no record declares and its
        // values would be read by nothing — and because `workouts` is the one table here whose columns
        // arrived across six migrations, so a set is the only shape that can see one go missing.
        do {
            let db = LocalDatabaseManager(inMemory: true)

            let columns = try await db.columnNames(in: "workouts")
            assertTest(Set(columns) == [
                "id", "date", "started_at", "ended_at", "strain", "average_heart_rate",
                "max_heart_rate", "source", "activity_name", "hr_zone_percents", "steps",
                "offline_region_id"
            ], "The parent's columns are the record's own twelve, spelled in snake case")

            // The names the record spells differently from its properties are named here, because a
            // camelCase column would mean the record's mapping and the table had drifted and every read
            // would throw at launch. `id`, `date`, `strain`, `source` and `steps` are the five that
            // agree with their property names and are deliberately not asserted twice.
            assertTest(columns.contains("started_at") && !columns.contains("startedAt"),
                       "A start instant's column is snake case and not the record property's name")
            assertTest(columns.contains("hr_zone_percents") && !columns.contains("hrZonePercents"),
                       "…and so is the zone block's")
            assertTest(columns.contains("offline_region_id") && !columns.contains("offlineRegionID"),
                       "…and the tile region's")

            // The two child tables, which is the half of the aggregate a parent-level assertion cannot
            // see. `workout_id` is the join and is the one column whose absence would orphan every child
            // silently — the read filters on it, so a renamed column throws rather than misleads, but a
            // *missing* one would be a table nothing can be filed under.
            let routeColumns = try await db.columnNames(in: "workout_route_points")
            assertTest(Set(routeColumns) == [
                "id", "workout_id", "latitude", "longitude", "timestamp", "heart_rate"
            ], "The route table's columns are the record's own six")
            assertTest(routeColumns.contains("workout_id") && !routeColumns.contains("workoutId"),
                       "…with the back-pointer in snake case")

            let splitColumns = try await db.columnNames(in: "workout_splits")
            assertTest(Set(splitColumns) == ["id", "workout_id", "elapsed", "strain"],
                       "The splits table's columns are the record's own four")

            // **Neither child table has a `seq` column, and that absence is the ordering rule.** It is
            // asserted here rather than left to be discovered: a `seq` added to either table would be a
            // second record of the sequence, free to disagree with the `timestamp`/`elapsed` sort the
            // read actually performs — and the wire binds its own `seq` from the array index.
            assertTest(!routeColumns.contains("seq") && !splitColumns.contains("seq"),
                       "…and neither child table records a sequence, which is why the read sorts to recover one")

            assertTest(try await db.columnNames(in: "no_such_table").isEmpty,
                       "A table that does not exist has no columns rather than throwing")
        }

        // MARK: A session whose stored id will not parse is dropped from the sync's read

        // **Three readers, three answers, one row — and the disagreement is the point.** `workouts` is
        // keyed on an id the app writes as a UUID string, but the column is a string and the two reads
        // that never parse it will hand the row back: `getWorkouts(on:)` returns records and the record
        // carries whatever text is in the column. The other two parse and drop it, and they are the ones
        // that matter — `GRDBWorkoutRepository.makeSessions` skips a row it cannot give an identity to,
        // and the sync drops it before a chunk is built, because the wire's `id` is a UUID the server
        // validates. Dropping is the honest answer: minting a fresh `UUID()` for the row would upload a
        // copy of a session the cloud already holds under another id, and rewriting the stored one would
        // rename a row on disk from a read path.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let start = day(-500) + 9 * 3600
            let validID = UUID()

            try await db.saveWorkout(
                WorkoutRecord(id: "sleep-nap-2026-08-21", date: day(-500), startedAt: start,
                              endedAt: start.addingTimeInterval(1800),
                              strain: 2.2, averageHeartRate: 118, maxHeartRate: 152),
                route: [WorkoutRoutePointRecord(id: UUID().uuidString, workoutId: "sleep-nap-2026-08-21",
                                                latitude: 51.5074, longitude: -0.1278,
                                                timestamp: start, heartRate: 118)],
                splits: [])

            try await db.saveWorkout(
                WorkoutRecord(id: validID.uuidString, date: day(-500),
                              startedAt: start.addingTimeInterval(3600),
                              endedAt: start.addingTimeInterval(5400),
                              strain: 3.3, averageHeartRate: 124, maxHeartRate: 165),
                route: [WorkoutRoutePointRecord(id: UUID().uuidString, workoutId: validID.uuidString,
                                                latitude: 51.508, longitude: -0.128,
                                                timestamp: start.addingTimeInterval(3600), heartRate: 124)],
                splits: [])

            let records = try await db.getWorkouts(on: day(-500))
            assertTest(records.count == 2,
                       "The manager's day read hands back both rows, because it reads the column and parses nothing")
            assertTest(records.contains { $0.id == "sleep-nap-2026-08-21" },
                       "…including the one whose id is not a UUID at all")

            let synced = try await db.syncWorkoutRows(from: day(-500), to: day(-499))
            assertTest(synced.count == 1,
                       "The sync's read drops it rather than minting an identity for it")
            assertTest(synced.first?.id == validID,
                       "…leaving the session whose id the wire can address")

            let sessions = try await GRDBWorkoutRepository(db: db).getWorkouts(for: day(-500))
            assertTest(sessions.count == 1 && sessions.first?.id == validID,
                       "…and the repository that draws the day agrees with the sync rather than with the manager")
        }
    }
}
