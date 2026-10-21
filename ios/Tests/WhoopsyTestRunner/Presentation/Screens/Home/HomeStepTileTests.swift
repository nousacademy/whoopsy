import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The STEPS tile while the screen is open

/// A file of §14's body, called by `HomeSourceTests.run()` after `HomeMetricSourceTests`.
///
/// §16 owns the store and the writer's hand-off. This owns the **reader's half**: Home is opened before
/// the strap has produced a motion batch, holds the dash it read at launch, and must take the first
/// total written while it is up rather than waiting for a day change or a relaunch.
///
/// That defect has a shape worth naming, because it is not the "saved row is not a drawn one" gotcha
/// verbatim. There a pushed screen wrote a row and the screen behind it never re-read; here nothing is
/// pushed and nothing is saved by a user action — a background writer ticks every second of motion,
/// and the screen that shows its output was opened first. The tile drew `—` for the whole session while
/// the database held a count, so the screen read as *steps are never recorded*. Both halves are
/// asserted below, plus the one thing a screenshot cannot see: a write for a different day is dropped
/// rather than folded in.
enum HomeStepTileTests {
    static func run() async throws {
        let calendar = Calendar.current
        let db = LocalDatabaseManager(inMemory: true)
        let stepRepository = GRDBStepRepository(db: db)
        let telemetry = ScriptedTelemetryRepository()
        let trackSteps = TrackStepsUseCase(bleRepository: telemetry, stepRepository: stepRepository)
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let home = await MainActor.run {
            HomeViewModel(
                recoveryRepository: GRDBRecoveryRepository(db: db),
                sleepRepository: GRDBSleepRepository(db: db),
                strainRepository: GRDBStrainRepository(db: db),
                workoutRepository: GRDBWorkoutRepository(db: db),
                receptiveInactivityRepository: GRDBReceptiveInactivityRepository(db: db),
                userProfileRepository: GRDBUserProfileRepository(db: db),
                stepRepository: stepRepository,
                analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                manage: ManageBLEConnectionUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                streamUseCase: StreamBiometricsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    biometricRepository: GRDBBiometricRepository(db: db)),
                trackSteps: trackSteps)
        }

        // The ordinary case: Home loads before the strap has moved, so the day has no row and the tile
        // draws a dash. That is not the bug — drawing `0` here would be.
        await home.load(for: today)
        let atOpen = await MainActor.run { home.steps }
        assertTest(
            atOpen == nil,
            "Home opens on a day with no stored row as `—`, not as a fabricated `0` "
                + "(\(String(describing: atOpen)))")

        // The subscription the view's `.task` starts, and the writer `MainContainerView` starts once for
        // the process. Neither is started by `load(for:)`, which is what keeps a day tap from stacking a
        // second reader on the motion stream.
        await MainActor.run { home.observeSteps() }
        let writer = Task { await trackSteps.start() }
        defer { writer.cancel() }
        assertTest(
            await waitUntil { telemetry.motionSubscriberCount == 1 },
            "The day's writer is attached to the strap's motion stream")

        telemetry.yieldMotion(motionBatch(startingAt: today.addingTimeInterval(9 * 3600), bumps: 12))

        let followedTheWrite = await waitUntil { await MainActor.run { home.steps == 12 } }
        let live = await MainActor.run { home.steps }
        assertTest(
            followedTheWrite,
            "The tile takes the first total written while the screen is open, with no second "
                + "`load(for:)` and no day change — the count the database now holds is the one on "
                + "screen (\(String(describing: live)))")
        let stored = try await stepRepository.getStepCount(for: today)
        assertTest(
            stored?.stepCount == 12 && live == stored?.measuredStepCount,
            "…and it is the stored row's own figure rather than a separate tally — the two cannot "
                + "disagree, because there is one computation and the stream carries its result")

        // A batch stamped yesterday. It is a real measurement and it is stored, so the contrast is
        // between a write that happened and a tile that must not move.
        telemetry.yieldMotion(motionBatch(startingAt: yesterday.addingTimeInterval(10 * 3600), bumps: 9))
        let yesterdayStored = await waitUntil {
            ((try? await stepRepository.getStepCount(for: yesterday)) ?? nil)?.stepCount == 9
        }
        assertTest(
            yesterdayStored,
            "A batch stamped yesterday is stored against yesterday — the writer's accumulator is keyed "
                + "by the batch's own instant, not by what the screen happens to be showing")
        // The pause is the *absence* probe, and it is the one place in this block that waits on nothing:
        // a wrong fold happens on the same main actor this read runs on, so giving it a beat is the only
        // way to see a value that must not appear. The assertion above already proved the delivery path
        // is live on this queue.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterOtherDay = await MainActor.run { home.steps }
        assertTest(
            afterOtherDay == 12,
            "…and today's tile does not move: a total from another day is dropped rather than folded "
                + "in, because the screen draws one day and yesterday's figure is not a stale version "
                + "of today's (\(String(describing: afterOtherDay)))")
    }
}
