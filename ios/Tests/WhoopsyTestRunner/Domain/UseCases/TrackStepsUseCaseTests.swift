import Foundation
import Whoopsy

// MARK: - 16. The write a screen can see

/// A file of §16's body, called by `StepTests.run()` after `StepCountPersistenceTests`.
///
/// `StepCountPersistenceTests` owns the store; this owns the **hand-off** — the one thing that makes
/// the number reach a screen that is already open. `HomeViewModel` reads `stepCounts` once per day
/// selection and this writer flushes a new total every second of motion, so a tile opened before the
/// strap moved holds the dash it read at launch. That is the "a saved row is not a drawn one" gotcha in
/// its other shape: here the screen was open first, so no caller exists to hand it the row and the
/// writer has to publish.
///
/// The properties asserted below are the ones a screenshot cannot see:
///
/// - **A subscriber sees exactly what the store holds**, so the tile can never draw a figure the
///   database cannot answer back.
/// - **Two subscribers both see it.** This is a registry, not a single continuation: a second reader
///   must not orphan the first, and the failure if one does is a `for await` that simply stops
///   receiving — indistinguishable from a strap that went quiet.
/// - **The published row carries the snapped day**, not the batch's arrival instant, so a screen
///   comparing it against the day it is showing matches.
enum TrackStepsUseCaseTests {
    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)
        let stepRepository = GRDBStepRepository(db: db)
        let telemetry = ScriptedTelemetryRepository()
        let useCase = TrackStepsUseCase(bleRepository: telemetry, stepRepository: stepRepository)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())

        // Two readers attached before a single batch is yielded. An `AsyncStream` does not replay, so
        // a subscriber added after the write would see nothing and the assertion below would be
        // testing the fixture's timing rather than the registry.
        let first = StepStreamRecorder()
        let second = StepStreamRecorder()
        let firstTask = Task {
            for await row in useCase.stepUpdates { await first.add(row) }
        }
        let secondTask = Task {
            for await row in useCase.stepUpdates { await second.add(row) }
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        let writer = Task { await useCase.start() }
        defer { writer.cancel() }

        assertTest(
            await waitUntil { telemetry.motionSubscriberCount == 1 },
            "The writer attaches to the strap's motion stream, which is the only input the count has")

        // Two batches on one day, so the second total is cumulative — 12 then 24 — rather than a
        // replacement that happens to look the same.
        telemetry.yieldMotion(motionBatch(startingAt: day.addingTimeInterval(9 * 3600), bumps: 12))
        telemetry.yieldMotion(motionBatch(startingAt: day.addingTimeInterval(9 * 3600 + 60), bumps: 12))

        let bothSaw = await waitUntil {
            let firstRows = await first.snapshot().count
            let secondRows = await second.snapshot().count
            return firstRows == 2 && secondRows == 2
        }
        let firstCount = await first.snapshot().count
        let secondCount = await second.snapshot().count
        assertTest(
            bothSaw,
            "Two subscribers both receive both writes — the hub's registry keeps a second reader from "
                + "taking the batch away from the first, which is the multicast failure in its quiet form "
                + "(first \(firstCount), second \(secondCount))")

        let published = await first.snapshot()
        assertTest(
            published.map(\.stepCount) == [12, 24],
            "…and they arrive in write order with the running total, not a per-batch delta "
                + "(\(published.map(\.stepCount)))")
        assertTest(
            published.allSatisfy { $0.date == day },
            "…and each carries the day's `startOfDay`, so a screen drawing one day can match it. The "
                + "batch was stamped 09:00; a published row holding that instant would never equal the "
                + "`loadedDay` a screen compares against")

        let stored = try await stepRepository.getStepCount(for: day)
        assertTest(
            stored == published.last,
            "What the stream carries is exactly what the store holds — the hand-off is a copy of the "
                + "saved row rather than a second computation that could disagree with it "
                + "(published \(String(describing: published.last)), stored \(String(describing: stored)))")
    }
}

/// Collects one subscriber's rows, so the block above can wait on both without awaiting a `for await`
/// loop that a regression would leave hanging.
private actor StepStreamRecorder {
    private var rows: [StepCount] = []

    func add(_ row: StepCount) { rows.append(row) }

    func snapshot() -> [StepCount] { rows }
}
