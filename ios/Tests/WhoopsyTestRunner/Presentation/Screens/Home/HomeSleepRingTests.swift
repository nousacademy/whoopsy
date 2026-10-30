import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. What a reload may not do to the sleep ring

/// `HomeViewModel.load`'s one clear, and the reason it is now conditional.
///
/// **Measured 2026-10-27, from the user's report:** tapping the sleep ring and coming back left Home's
/// ring as a dash. `HomeDashboardView`'s `.task` re-runs when the screen is shown again, so returning
/// re-ran the whole load — and the load cleared `sleepScore` at its start, before a single read had
/// returned. On a real database a load is seconds, so the ring sat empty for the whole of it.
///
/// The fix is the sleep page's own correction, one screen over: a value already on screen is not
/// blanked for the length of a read. What has to stay true in both directions is asserted here — a
/// same-day reload keeps the figure whatever the reload does, and **a load for another day clears it**,
/// because that figure belongs to the day being left behind.
enum HomeSleepRingTests {

    /// A `SleepRepository` that fails one chosen `getSleepHistory` call and delegates everything else.
    ///
    /// The failure is what makes the rule observable without racing a load: once the reload throws, the
    /// only thing left holding the ring's figure is whether the load wiped it on the way in.
    actor FailingSleepRepository: SleepRepository {
        private let base: any SleepRepository
        private let failingCalls: Set<Int>
        private var historyCalls = 0

        init(base: any SleepRepository, failingCalls: Set<Int>) {
            self.base = base
            self.failingCalls = failingCalls
        }

        func getSleepSession(for date: Date) async throws -> SleepSession? {
            try await base.getSleepSession(for: date)
        }

        func saveSleepSession(_ session: SleepSession, source: String?) async throws {
            try await base.saveSleepSession(session, source: source)
        }

        func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession] {
            historyCalls += 1
            if failingCalls.contains(historyCalls) { throw CocoaError(.fileReadUnknown) }
            return try await base.getSleepHistory(days: days, endingOn: endingOn)
        }

        func deleteSleepSession(for date: Date) async throws {
            try await base.deleteSleepSession(for: date)
        }
    }

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let db = LocalDatabaseManager(inMemory: true)
        let nights = GRDBSleepRepository(db: db)

        // A night with three of the composite's four terms — need, period and restorative time — so
        // `SleepScoreScoring` can score it without any consistency history. What is being asserted is
        // the survival of the figure across a reload, not the figure itself.
        let night = SleepSession(
            date: today,
            startTime: today.addingTimeInterval(-9 * 3600),
            endTime: today.addingTimeInterval(-1 * 3600),
            targetSleepNeedSeconds: 8 * 3600,
            lightSleepSeconds: 4 * 3600,
            deepSleepSeconds: 1.5 * 3600,
            remSleepSeconds: 1.5 * 3600,
            awakeSeconds: 600,
            algorithm: .current,
            scoredThrough: today)
        try await nights.saveSleepSession(night)

        // Fails the second and third history reads — the same-day reload and then the day change.
        let flaky = FailingSleepRepository(base: nights, failingCalls: [2, 3])

        let viewModel = await MainActor.run {
            HomeViewModel(
                recoveryRepository: GRDBRecoveryRepository(db: db),
                sleepRepository: flaky,
                strainRepository: GRDBStrainRepository(db: db),
                workoutRepository: GRDBWorkoutRepository(db: db),
                receptiveInactivityRepository: GRDBReceptiveInactivityRepository(db: db),
                userProfileRepository: GRDBUserProfileRepository(db: db),
                stepRepository: GRDBStepRepository(db: db),
                analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                manage: ManageBLEConnectionUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                streamUseCase: StreamBiometricsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    biometricRepository: GRDBBiometricRepository(db: db)),
                trackSteps: TrackStepsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    stepRepository: GRDBStepRepository(db: db),
                    stateStore: InMemoryStepCounterStateStore()),
                refreshStrain: fixtureRefreshStrain(
                    strainRepository: GRDBStrainRepository(db: db),
                    biometricRepository: EmptyBiometricStore(),
                    userProfileRepository: GRDBUserProfileRepository(db: db)))
        }

        await viewModel.load(for: today)
        let firstScore = await MainActor.run { viewModel.sleepScore }

        assertTest(
            firstScore != nil,
            "A day with a scored night puts a figure on the sleep ring — the precondition, without "
                + "which the assertion below would pass for a ring that was never filled")

        // The reload the screen actually performs when the user comes back from the sleep page, and
        // it fails. Before the correction this left the ring blank: the clear ran first, and the
        // throw meant nothing ever replaced it.
        await viewModel.load(for: today)
        let afterFailedReload = await MainActor.run { viewModel.sleepScore }

        assertTest(
            afterFailedReload == firstScore,
            "A same-day reload that throws leaves the ring exactly as it was — the figure it is drawn "
                + "from is not cleared before the read that would replace it "
                + "(was \(String(describing: firstScore)), now \(String(describing: afterFailedReload)))")

        assertTest(
            await MainActor.run { viewModel.errorMessage } != nil,
            "…and the failure is still reported, because keeping the drawing is not hiding the error")

        // The day change, with the load failing as well — the worst case, and the one that used to
        // leave another day's night on screen with nothing ever replacing it.
        await viewModel.load(for: yesterday)
        let afterDayChange = await MainActor.run {
            (score: viewModel.sleepScore, night: viewModel.sleep, workouts: viewModel.workouts.count,
             steps: viewModel.steps)
        }

        assertTest(
            afterDayChange.score == nil && afterDayChange.night == nil,
            "…while a load for another day clears both the ring's figure **and the night itself**: "
                + "the previous day's sleep must not stay on screen behind a load that failed — which "
                + "is the reported bug, data from a day you have left still drawn under a day you have "
                + "just moved to (score \(String(describing: afterDayChange.score)), night "
                + "\(afterDayChange.night == nil ? "nil" : "present"))")

        assertTest(
            afterDayChange.workouts == 0 && afterDayChange.steps == nil,
            "…as do the activities and the step total, because every per-day value is cleared together "
                + "rather than only the one the ring reads (workouts \(afterDayChange.workouts))")
    }
}
