import Foundation
import Whoopsy

// MARK: - 15. The nights a drain classifies

/// The block that closes the gap between "the records arrived" and "Home can draw them".
///
/// **What it pins is the range arithmetic, not the analyzer.** `RefreshNightsUseCase` decides *which*
/// days a drained range obliges the app to classify; the night itself is `AnalyzeSleepUseCase`'s work
/// and §15's other files already cover it. So the assertions here are the newest-first ordering, the
/// three-day cap, the nil-range no-op, and the empty-database case where an owed day has no night to
/// find — the one that must leave no row rather than a placeholder.
enum RefreshNightsUseCaseTests {
    static func run() async throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))

        assertTest(
            RefreshNightsUseCase.maximumNightsPerDrain == 3,
            "A drain classifies at most **three** of its newest days: the night a phone is holding, "
                + "the one before it, and one spare — a first sync can cover a fortnight and the "
                + "sleep page is what classifies those, on open")

        assertTest(
            RefreshNightsUseCase.days(from: nil, to: nil, now: day, calendar: calendar) == [day],
            "**A drain that delivered nothing still asks for today.** That is the case this rule was "
                + "corrected for: once the cursor has passed the night, every later drain answers with "
                + "zero records — and today's records are exactly what is sitting unclassified in "
                + "storage. A nil range meaning 'no days' left the ring a dash on 2026-10-26")

        assertTest(
            RefreshNightsUseCase.days(from: day, to: day, now: day, calendar: calendar) == [day],
            "A range inside one day asks for that day once, not twice")

        let fiveDaysAgo = calendar.date(byAdding: .day, value: -4, to: day) ?? day
        let capped = RefreshNightsUseCase.days(
            from: fiveDaysAgo, to: day, now: day, calendar: calendar)
        assertTest(
            capped == (0..<3).map { calendar.date(byAdding: .day, value: -$0, to: day) ?? day },
            "…while a five-day range yields the **newest three, newest first**: the cap is a "
                + "foreground-cost bound on the days a person is likely to look at, not a claim that "
                + "the older nights do not exist "
                + "(\(capped.map { $0.description }))")

        let oldRange = RefreshNightsUseCase.days(
            from: calendar.date(byAdding: .day, value: -9, to: day) ?? day,
            to: calendar.date(byAdding: .day, value: -7, to: day) ?? day,
            now: day,
            calendar: calendar)
        assertTest(
            oldRange.first == day
                && oldRange.contains(calendar.date(byAdding: .day, value: -7, to: day) ?? day)
                && oldRange.count == RefreshNightsUseCase.maximumNightsPerDrain,
            "…and a range that lies wholly in the past still holds **today**, at the cap's "
                + "expense: a backlog is not a reason to leave tonight's ring empty "
                + "(\(oldRange.map { $0.description }))")

        // An empty database, a real range: the analyzer finds no night, so nothing is written and no
        // row is invented. That is the absence rule at the seam this file adds.
        let db = LocalDatabaseManager(inMemory: true)
        let sleeps = GRDBSleepRepository(db: db)
        let biometrics = OvernightBiometricStore(samples: [])
        let analyze = AnalyzeSleepUseCase(
            biometricRepository: biometrics,
            sleepRepository: sleeps,
            strainRepository: GRDBStrainRepository(db: db),
            userProfileRepository: GRDBUserProfileRepository(db: db),
            motionRepository: GRDBMotionEpochRepository(db: db))
        let nights = RefreshNightsUseCase(analyze: analyze, repository: sleeps)

        let noRange = await nights.refresh(from: nil, to: nil, now: day)
        assertTest(
            noRange == 0,
            "…and a nil range writes nothing at all, so a drain with no records costs no analysis")

        let emptyRange = await nights.refresh(from: day, to: day, now: day)
        let stored = try await sleeps.getSleepSession(for: day)
        assertTest(
            emptyRange == 0 && stored == nil,
            "A day with no samples and no motion classifies to **no night and no row**, not a "
                + "reserved-zero one — the same absence rule the sleep page applies, reached here "
                + "from the drain's side")
    }
}
