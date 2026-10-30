import Foundation
import Whoopsy

/// The day purge at the database's own level: what a range removes, and what it deliberately leaves.
///
/// **The assertion that matters most is the one about the inputs.** A purge that removed `recoveries`
/// and left the samples would look complete on every screen and be undone by the next foreground, when
/// `RefreshRecoveryUseCase` re-folds the night and writes the row back. So the samples, the motion and
/// the night are seeded beside the scores and asserted gone beside them.
///
/// The other half is the scope the owner set: a purge removes **measurements**, and an activity or a
/// note dated inside the range is not one.
enum DayPurgePersistenceTests {
    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)
        let calendar = Calendar.current
        func day(_ daysAgo: Int) -> Date {
            calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        }

        // Five consecutive days, each with the four scored rows, a night's samples, a motion window
        // and a step day — plus a session and a note on the day in the middle, which must survive.
        for offset in 0..<5 {
            let date = day(offset)
            try await db.saveRecovery(RecoveryRecord(
                date: date,
                recoveryScore: 60,
                restingHeartRate: 52,
                hrvValueMs: 50,
                hrvMetric: .rmssd))
            try await db.saveSleep(SleepRecord(
                date: date,
                startTime: date,
                endTime: date.addingTimeInterval(8 * 3600),
                sleepPerformance: 80,
                totalSleepNeeded: 8,
                lightSleep: 3,
                deepSleep: 1,
                remSleep: 1.5,
                awakeTime: 0.5))
            try await db.saveStrain(StrainRecord(
                date: date,
                strainScore: 8.0,
                kilojoules: 2_000,
                averageHeartRate: 70,
                maxHeartRate: 150,
                hasMeasurement: true,
                motionLoad: nil,
                scoredThrough: nil,
                algorithm: nil))
            try await db.saveStepCount(
                StepCountRecord(date: date, stepCount: 4_000, measuredSeconds: 3_600))
            try await db.saveMotionEpoch(MotionEpochRecord(
                start: date,
                date: date,
                end: date.addingTimeInterval(30),
                meanMagnitudeG: 1.2,
                maxMagnitudeG: 2.0,
                sampleCount: 30))
            try await db.saveSamples((0..<3).map {
                BiometricSampleRecord(
                    timestamp: date.addingTimeInterval(Double($0) * 60),
                    heartRate: 50 + $0)
            })
        }
        let middle = day(2)
        try await db.saveWorkout(
            WorkoutRecord(
                id: UUID().uuidString,
                date: middle,
                startedAt: middle,
                endedAt: middle.addingTimeInterval(1_800),
                strain: 6.1,
                averageHeartRate: nil,
                maxHeartRate: nil,
                source: "manual",
                activityName: "Football",
                rpe: nil),
            route: [],
            splits: [])
        try await db.saveReceptiveInactivity(ReceptiveInactivityRecord(
            id: "note-\(Int(middle.timeIntervalSince1970))",
            date: middle,
            name: "Sauna",
            note: nil,
            startedAt: nil))

        let before = try await db.getRecoveryHistory(days: 10, endingOn: day(0))
        assertTest(before.count == 5, "Five days seeded, five read back (got \(before.count))")

        // ── The purge itself ───────────────────────────────────────────────────────────────────────
        let tally = try await db.purgeMeasuredDays(from: day(3), to: day(1))

        assertTest(tally.recoveries == 3 && tally.sleeps == 3 && tally.strains == 3,
                   "Three days of scores went — recovery \(tally.recoveries), sleep \(tally.sleeps), "
                       + "strain \(tally.strains)")
        assertTest(tally.stepCounts == 3 && tally.motionEpochs == 3,
                   "…as did the step days and the motion windows: \(tally.stepCounts) and "
                       + "\(tally.motionEpochs)")
        assertTest(tally.samples == 9,
                   "…and every sample of those nights (got \(tally.samples)), which is the half that "
                       + "stops the scorers re-deriving the day")
        assertTest(tally.naps == 0, "…no naps were seeded, so none were reported")

        let after = try await db.getRecoveryHistory(days: 10, endingOn: day(0))
        assertTest(Set(after.map(\.date)) == [day(0), day(4)],
                   "The days outside the range are untouched — a purge that took a neighbour would "
                       + "show up here as a shorter history than expected")

        // ── What it deliberately does not touch ────────────────────────────────────────────────────
        let sessions = try await db.getWorkouts(on: middle)
        assertTest(sessions.count == 1,
                   "The activity recorded on a purged day survives: this removes measurements, not "
                       + "sessions the owner recorded (got \(sessions.count))")
        let notes = try await db.getReceptiveInactivities(on: middle)
        assertTest(notes.count == 1,
                   "…and so does a note dated inside the range (got \(notes.count))")

        // ── Replay and the empty range ─────────────────────────────────────────────────────────────
        let again = try await db.purgeMeasuredDays(from: day(3), to: day(1))
        assertTest(again.isEmpty,
                   "A replayed purge finds nothing and says so rather than failing")

        let reversed = try await db.purgeMeasuredDays(from: day(0), to: day(4))
        assertTest(reversed.isEmpty,
                   "A reversed range removes nothing at all, rather than everything it happens to match")

        // ── The bounds, asserted from outside ──────────────────────────────────────────────────────
        // The day before the range keeps all three of its samples, and the day after keeps its scores.
        // Both are the other side of a bound the purge has to get exactly right.
        let survivor = day(4)
        let late = try await db.getSamples(
            from: survivor.startOfDay, to: survivor.startOfNextDay)
        assertTest(late.count == 3,
                   "The day before the range keeps all three of its samples (got \(late.count))")

        let newest = try await db.getRecoveryHistory(days: 0, endingOn: day(0))
        assertTest(newest.count == 1,
                   "…and the newest day, which the range never reached, keeps its row")
    }
}
