import Foundation
import Whoopsy

// MARK: - 16. The day-keyed step store

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum StepCountPersistenceTests {
    static func run() async throws {
        // MARK: The v13 round trip

        let stepDB = LocalDatabaseManager(inMemory: true)
        let stepRepository = GRDBStepRepository(db: stepDB)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        func dayOffset(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: day) ?? day
        }

        do {
            // Written at a raw 09:37, which is the shape a live write has: `saveStepCount` snaps it.
            try await stepRepository.saveStepCount(
                StepCount(date: day.addingTimeInterval(9 * 3600 + 37 * 60), stepCount: 5049,
                          measuredSeconds: 3600))
            try await stepRepository.saveStepCount(
                StepCount(date: dayOffset(1), stepCount: 6100, measuredSeconds: 1200))
            try await stepRepository.saveStepCount(
                StepCount(date: dayOffset(2), stepCount: 5200, measuredSeconds: 1800))

            let stored = try await stepRepository.getStepCount(for: day)
            assertTest(
                stored?.stepCount == 5049 && stored?.measuredSeconds == 3600,
                "The round trip carries both columns through unchanged: 5049 steps over 3600 measured "
                    + "seconds comes back as itself")
            assertTest(stored?.date == day, "…and under the day's `startOfDay`, not the instant written")
            assertTest(stored?.hasMeasurement == true, "…and reads back as a measurement")
            assertTest(
                try await stepRepository.getStepCount(for: dayOffset(-1)) == nil,
                "A row written at 09:37 is not found on the day before it")
            assertTest(
                try await stepRepository.getStepCount(for: dayOffset(3)) == nil,
                "…nor on the day after — the day-snap rule every other day-keyed table in this app is "
                    + "guarded by, and steps are day-keyed too")

            let history = try await stepRepository.getStepCountHistory(days: 3, endingOn: dayOffset(2))
            assertTest(
                history.map(\.stepCount) == [5049, 6100, 5200],
                "The window's rows come back oldest first — the order `RecoveryScoring.baselineWindow` "
                    + "requires, since it takes the trailing thirty of them")
            assertTest(
                history.map(\.date) == [day, dayOffset(1), dayOffset(2)],
                "…and inclusive at both ends: three days back from the third day reaches the first, so "
                    + "the span is four days' worth of slots read as three days of window")
            let bounded = try await stepRepository.getStepCountHistory(days: 3, endingOn: day)
            assertTest(
                bounded.map(\.stepCount) == [5049],
                "A window ending on the first day carries only it — the upper bound is real, so a read "
                    + "anchored on an old day does not run on to the present")

            assertTest(
                try await stepRepository.getStepCount(for: dayOffset(6)) == nil,
                "A day with no row is `nil` — there is no reserved zero, so 'not measured' and 'measured "
                    + "zero' are different answers rather than the same one")
            try await stepRepository.saveStepCount(
                StepCount(date: dayOffset(7), stepCount: 0, measuredSeconds: 0))
            let unmeasured = try await stepRepository.getStepCount(for: dayOffset(7))
            assertTest(
                unmeasured != nil && unmeasured?.hasMeasurement == false,
                "A row holding no measured span reads back unmeasured, which is reader tolerance for a "
                    + "row no writer produces rather than a state anything depends on")
            try await stepRepository.saveStepCount(
                StepCount(date: dayOffset(8), stepCount: 0, measuredSeconds: 600))
            let measuredZero = try await stepRepository.getStepCount(for: dayOffset(8))
            assertTest(
                measuredZero?.stepCount == 0 && measuredZero?.hasMeasurement == true,
                "…while a measured day of no walking is a real `0`: the two rows above hold the same "
                    + "count and are different answers, which is the whole reason `measuredSeconds` is the "
                    + "column the gate reads and the count is not")
        } catch {
            assertTest(false, "The step store threw: \(error)")
        }
    }
}
