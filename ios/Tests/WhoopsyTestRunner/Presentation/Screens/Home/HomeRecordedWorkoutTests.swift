import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. Recorded workouts and naps, the two id-keyed tables

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeRecordedWorkoutTests {
    static func run() async throws {
        // ---- v6: recorded workouts now survive the launch that recorded them ----

        let db = LocalDatabaseManager(inMemory: true)
        let tables = (try? await db.existingTableNames()) ?? []
        for expected in ["workouts", "workout_route_points", "workout_splits"] {
            assertTest(tables.contains(expected), "v6 migration created table '\(expected)'")
        }

        let repository = GRDBWorkoutRepository(db: db)
        let calendar = Calendar.current

        // 17:33 on a day two days back, so the day-snap is tested against a day that is not today and the
        // assertion does not move with the clock.
        let sessionDay = calendar.date(byAdding: .day, value: -2, to: Date())!.startOfDay
        let startedAt = calendar.date(byAdding: .minute, value: 17 * 60 + 33, to: sessionDay)!
        let endedAt = calendar.date(byAdding: .minute, value: 14, to: startedAt)!

        let workout = WorkoutSession(
            startedAt: startedAt,
            endedAt: endedAt,
            strain: 3.0,
            averageHeartRate: 128,
            maxHeartRate: 164,
            route: [
                WorkoutRoutePoint(latitude: 40.7411, longitude: -73.9897, timestamp: startedAt, heartRate: 120),
                WorkoutRoutePoint(latitude: 40.7420, longitude: -73.9880, timestamp: endedAt, heartRate: 164),
            ],
            splits: [
                WorkoutSplit(elapsed: 300, strain: 1.1),
                WorkoutSplit(elapsed: 600, strain: 2.4),
            ],
            activityName: "Yoga")

        do {
            try await repository.save(workout)

            let onTheDay = try await repository.getWorkouts(for: sessionDay)
            assertTest(onTheDay.count == 1, "A saved workout is read back on its own day (\(onTheDay.count) found)")

            if let read = onTheDay.first {
                assertTest(read.id == workout.id, "…with the same identity")
                assertTest(read.route.count == 2, "…and its route points (\(read.route.count) of 2)")
                assertTest(read.splits.count == 2, "…and its splits (\(read.splits.count) of 2)")
                assertTest(
                    read.route.map(\.id) == workout.route.map(\.id),
                    "…and the route points keep their own identities, so a point is addressable")
                // The field that fails if it is added to the record but not to `WorkoutRecord.CodingKeys`:
                // that record declares them, so an unlisted property is written under its own name and the
                // column does not exist — and the write is the loud half, not the read.
                assertTest(
                    read.activityName == "Yoga",
                    "…and the `v15` activity name it was saved with (got "
                        + "\(read.activityName.map { "'\($0)'" } ?? "nil"))")
            }

            // The primary-key rule from CLAUDE.md: `date` is snapped to `startOfDay`, so a read keyed on a
            // neighbouring day must not find it. Without the snap — or with a read that fails to snap —
            // this is the assertion that fails, and it is exactly how the day-keyed writers broke before.
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: sessionDay)!
            let dayAfter = calendar.date(byAdding: .day, value: 1, to: sessionDay)!
            assertTest(
                (try await repository.getWorkouts(for: dayBefore)).isEmpty,
                "A workout saved at a raw 17:33 is not found on the day before (the day key is snapped)")
            assertTest(
                (try await repository.getWorkouts(for: dayAfter)).isEmpty,
                "…nor on the day after")

            // Several sessions in one day is the normal case and is why this table is keyed on `id`
            // rather than on `date` the way `recoveries`/`sleeps`/`strains` are.
            let second = WorkoutSession(
                startedAt: calendar.date(byAdding: .hour, value: 2, to: startedAt)!,
                endedAt: calendar.date(byAdding: .minute, value: 30, to: startedAt)!,
                strain: 1.2, averageHeartRate: 102, maxHeartRate: 121, route: [], splits: [])
            try await repository.save(second)
            let both = try await repository.getWorkouts(for: sessionDay)
            assertTest(both.count == 2, "Two sessions on one day are both read back (\(both.count) found)")
            assertTest(
                both.map(\.startedAt) == both.map(\.startedAt).sorted(),
                "…earliest first")
            // A session with no name stays `nil` rather than defaulting to a word: `nil` is what a
            // live-recorded workout really has, and the screen draws it as WHOOP's own term for an
            // uncategorised activity rather than as the dash an unmeasured figure gets — a name is not a
            // measurement, so the absence vocabulary here is the label's, not the value column's.
            assertTest(
                both.first(where: { $0.id == second.id })?.activityName == nil,
                "…and a session saved without a name reads back `nil` rather than defaulting to a word")

            let latest = try await repository.latest()
            assertTest(latest?.id == second.id, "`latest()` returns the most recent session by start time")

            // Re-saving the same id replaces rather than duplicates — `save` is INSERT-or-UPDATE by
            // primary key, and a route that were only appended would double on every re-save.
            try await repository.save(workout)
            let afterResave = try await repository.getWorkouts(for: sessionDay)
            assertTest(afterResave.count == 2, "Re-saving a session does not duplicate it")
            assertTest(
                afterResave.first(where: { $0.id == workout.id })?.route.count == 2,
                "…and does not duplicate its route points either")
        } catch {
            assertTest(false, "The workout persistence round trip threw: \(error)")
        }

        // ---- A day with nothing recorded reads as nothing, not as zeros ----

        do {
            let emptyDay = calendar.date(byAdding: .day, value: -400, to: Date())!.startOfDay
            let nothing = try await repository.getWorkouts(for: emptyDay)
            assertTest(nothing.isEmpty, "A day with no recorded workouts returns an empty array, not a row")
        } catch {
            assertTest(false, "The empty-day workout read threw: \(error)")
        }

        // ---- v11: naps are the second id-keyed table, and the same rules hold ----
        //
        // `naps` follows `workouts` rather than `sleeps` for the reason that table does: a day holds one
        // night but several naps, so a `date` primary key would make the second nap overwrite the first.
        // The day-snap still applies, and it is asserted on the same 17:33 shape so the two tables are
        // visibly under one rule.
        do {
            let napRepository = GRDBNapRepository(db: db)

            // 17:33 and 21:10 two days back, so nothing moves with the clock.
            let napDay = calendar.date(byAdding: .day, value: -2, to: Date())!.startOfDay
            let firstStart = calendar.date(byAdding: .minute, value: 17 * 60 + 33, to: napDay)!
            let secondStart = calendar.date(byAdding: .minute, value: 21 * 60 + 10, to: napDay)!

            // The `date` here is deliberately the **raw** start instant, not `start.startOfDay`. The
            // repository is what snaps it, centrally, the way it does for every other day-keyed writer —
            // and a fixture that snapped its own date first would make the assertion below pass whether
            // or not that snap existed. Confirmed by mutation: dropping the snap from `saveNap` left this
            // block green until this line was fixed.
            func nap(startingAt start: Date, minutes: Double) -> SleepNap {
                SleepNap(
                    id: String(Int(start.timeIntervalSince1970)),
                    date: start,
                    startTime: start,
                    endTime: start.addingTimeInterval(minutes * 60),
                    asleepSeconds: minutes * 60)
            }

            // Written latest-first, so a repository that returned insertion order rather than sorting
            // would fail the ordering assertion below rather than passing it by luck.
            try await napRepository.saveNap(nap(startingAt: secondStart, minutes: 25), source: "test")
            try await napRepository.saveNap(nap(startingAt: firstStart, minutes: 40), source: "test")

            let onTheDay = try await napRepository.getNaps(on: napDay)
            assertTest(onTheDay.count == 2, "Two naps on one day are both read back (\(onTheDay.count) found)")
            assertTest(
                onTheDay.allSatisfy { $0.date == napDay },
                "…and each was stored under the day key the read uses, not the raw instant it was written at")
            assertTest(
                onTheDay.map(\.startTime) == onTheDay.map(\.startTime).sorted(),
                "…earliest first, whatever order they were written in")

            // The same primary-key rule as `workouts`. A read keyed on a neighbouring day must not find
            // them, and a write at a raw 17:33 must still be reachable through the day key.
            assertTest(
                (try await napRepository.getNaps(on: calendar.date(byAdding: .day, value: -1, to: napDay)!))
                    .isEmpty,
                "A nap saved at a raw 17:33 is not found on the day before (the day key is snapped)")
            assertTest(
                (try await napRepository.getNaps(on: calendar.date(byAdding: .day, value: 1, to: napDay)!))
                    .isEmpty,
                "…nor on the day after")

            // Empty is an ordinary answer, not a missing one: it means the user did not nap. The sleep
            // screen draws no nap row at all for it, which is a different rendering from the `—` a row
            // with a value nobody measured would get.
            let noNapDay = calendar.date(byAdding: .day, value: -400, to: Date())!.startOfDay
            assertTest(
                (try await napRepository.getNaps(on: noNapDay)).isEmpty,
                "A day with no naps returns an empty array rather than a row")

            // Re-saving the same identity replaces rather than duplicates — `save` is INSERT-or-UPDATE by
            // primary key, and this is the whole of what makes the import idempotent.
            try await napRepository.saveNap(nap(startingAt: firstStart, minutes: 55), source: "test")
            let afterResave = try await napRepository.getNaps(on: napDay)
            assertTest(afterResave.count == 2, "Re-saving a nap does not duplicate it")
            assertTest(
                afterResave.first?.asleepSeconds == 55 * 60,
                "…it updates the row it wrote (got \(afterResave.first?.asleepSeconds ?? -1) s)")
        } catch {
            assertTest(false, "The nap persistence round trip threw: \(error)")
        }
    }
}
