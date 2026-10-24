import Foundation
import Whoopsy

// MARK: - 16. The counter ledger's one persisted document

/// The `UserDefaults` store `TrackStepsUseCase` resumes from — round trip, absence and clear.
///
/// **Its own `UserDefaults` suite rather than `.standard`**, because a test that wrote to the
/// developer's defaults would both pollute the machine and pass or fail on what was left there. The
/// suite is removed at the end for the same reason.
enum StepCounterStatePersistenceTests {

    static func run() async throws {
        let suiteName = "org.whoopsy.tests.step-counter-state"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTest(false, "The test suite's UserDefaults could not be created")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsStepCounterStateStore(defaults: defaults)
        assertTest(
            store.load() == nil,
            "An install that has never seen a counter has no state — absence is `nil` rather than a "
                + "zeroed ledger, which would claim a day with no steps and no coverage")

        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let saved = StepCounterState(
            day: day,
            counterSteps: 8_234,
            counterMeasuredSeconds: 3_600,
            tailSteps: 214,
            tailMeasuredSeconds: 45,
            lastCounter: 12_345,
            lastSeconds: 1_700_003_600,
            lastSoftware: false,
            hasSeenClass: true)
        store.save(saved)

        let loaded = store.load()
        assertTest(
            loaded == saved,
            "The document round-trips field for field — the two totals, the continuation's three "
                + "values and whether a class has been seen. A field lost here is a delta the next "
                + "launch cannot compute or a day whose split between counter and detector is gone "
                + "(\(String(describing: loaded)))")
        assertTest(
            loaded?.day == day,
            "…and the day is stored with it, so a state for one day cannot be applied to another")

        store.clear()
        assertTest(
            store.load() == nil,
            "`clear()` removes the document rather than writing a zero, so the next launch starts a "
                + "ledger instead of resuming an empty one")
    }
}
