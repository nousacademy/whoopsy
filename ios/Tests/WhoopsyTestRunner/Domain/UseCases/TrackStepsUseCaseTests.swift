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
        let useCase = TrackStepsUseCase(bleRepository: telemetry, stepRepository: stepRepository, stateStore: InMemoryStepCounterStateStore())
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
            "The writer attaches to the strap's motion stream — the detector's input, and one of the "
                + "count's two")

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

        // ---- The strap's counter and the live detector over one day ----
        //
        // The counter arrives in a drain and covers a window the detector may already have counted.
        // These four assertions are the arbitration in miniature: the counter replaces the detector's
        // total rather than adding to it, live motion after coverage still counts, a still-classed
        // record adds no steps, and a counter record overtaking the live tail drops steps the counter
        // is about to count again.

        assertTest(
            await waitUntil { telemetry.stepCounterSubscriberCount == 1 },
            "The writer attaches to the counter stream as well — a second consumer of a *different* "
                + "stream, which is what makes the drain's R18 records reach the day at all")

        let firstCounter = day.addingTimeInterval(10 * 3600)
        telemetry.yieldStepCounter(stepCounterSample(at: firstCounter, counter: 1_000))
        telemetry.yieldStepCounter(stepCounterSample(at: firstCounter.addingTimeInterval(1), counter: 1_002))
        telemetry.yieldStepCounter(stepCounterSample(at: firstCounter.addingTimeInterval(2), counter: 1_004))

        let replaced = await waitUntil {
            ((try? await stepRepository.getStepCount(for: day)) ?? nil)?.stepCount == 4
        }
        let afterCounter = try await stepRepository.getStepCount(for: day)
        assertTest(
            replaced && afterCounter?.stepCount == 4,
            "Three counter records contribute four ticks and the day's row becomes four — **not** "
                + "sixteen. The counter covers the window the detector counted at 09:00, so its total "
                + "replaces that row rather than adding to it, which is the double count this ledger "
                + "exists to prevent (\(String(describing: afterCounter?.stepCount)))")

        telemetry.yieldMotion(motionBatch(startingAt: day.addingTimeInterval(10 * 3600 + 300), bumps: 3))
        let tailAdded = await waitUntil {
            ((try? await stepRepository.getStepCount(for: day)) ?? nil)?.stepCount == 7
        }
        assertTest(
            tailAdded,
            "A live batch after the counter's coverage adds its three steps on top of the counter's "
                + "four — live walking after a drain still moves the tile")

        telemetry.yieldStepCounter(stepCounterSample(
            at: day.addingTimeInterval(10 * 3600 + 360), counter: 1_008, activityClass: 0))
        let tailDropped = await waitUntil {
            ((try? await stepRepository.getStepCount(for: day)) ?? nil)?.stepCount == 4
        }
        assertTest(
            tailDropped,
            "A counter record overtaking the live tail drops its three steps and adds none of its own "
                + "— the record is still-classed, so it is coverage with no steps, and the counter is "
                + "about to count the tail again")

        telemetry.yieldStepCounter(stepCounterSample(
            at: day.addingTimeInterval(10 * 3600 + 420), counter: 1_010, activityClass: 1))
        let walkedAgain = await waitUntil {
            ((try? await stepRepository.getStepCount(for: day)) ?? nil)?.stepCount == 6
        }
        assertTest(
            walkedAgain,
            "…and the next walk-classed record adds its two ticks, so the day resumes counting from "
                + "the counter rather than staying frozen at the drop")

        // ── Two pedometers, one walk ────────────────────────────────────────────────────────────────
        //
        // The counter covers banked history and the peak detector covers live motion. During a drain
        // the counter is *behind* the live edge — a drain delivers old records — so a tail that accepts
        // every live batch counts the same steps twice. Measured 2026-10-30 on the owner's 5.0: 2,362
        // counter ticks beside an 8,060-step tail, and 86,413 s of coverage in a day 60,480 s old.
        let covered = day.addingTimeInterval(10 * 3600)
        assertTest(
            TrackStepsUseCase.counterOwns(batchStart: covered, coveredThrough: covered),
            "A live batch starting exactly at the counter's newest instant is the counter's — its "
                + "record is stamped at that second, so the boundary belongs to history")
        assertTest(
            TrackStepsUseCase.counterOwns(
                batchStart: covered.addingTimeInterval(-60), coveredThrough: covered),
            "…and one starting inside the covered window is refused as well, which is the case the "
                + "drain produces: live motion behind the counter's cursor")
        assertTest(
            !TrackStepsUseCase.counterOwns(
                batchStart: covered.addingTimeInterval(1), coveredThrough: covered),
            "…while one after the counter's coverage is the tail's, which is the only window the "
                + "detector is allowed to count")
        assertTest(
            !TrackStepsUseCase.counterOwns(batchStart: covered, coveredThrough: nil),
            "A day the counter has never covered is entirely the detector's")

    }
}

/// Collects one subscriber's rows, so the block above can wait on both without awaiting a `for await`
/// loop that a regression would leave hanging.
private actor StepStreamRecorder {
    private var rows: [StepCount] = []

    func add(_ row: StepCount) { rows.append(row) }


    func snapshot() -> [StepCount] { rows }
}
