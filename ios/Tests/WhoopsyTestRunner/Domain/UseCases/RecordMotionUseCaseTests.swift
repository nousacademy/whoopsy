import Foundation
import Whoopsy

// MARK: - 16. The motion the sleep classifier reads

/// The recorder that gives sleep onset a signal other than heart rate.
///
/// The strap's R21 stream already reaches the app; before this it was consumed only for steps and
/// never stored, so the classifier had no motion at all on the live path. These assertions pin the
/// two properties the analyzer depends on: a window is **30 seconds of wall time**, and a second
/// batch in the same window **upserts** rather than creating a second row.
enum RecordMotionUseCaseTests {
    static func run() async throws {
        let db = LocalDatabaseManager(inMemory: true)
        let repository = GRDBMotionEpochRepository(db: db)
        let telemetry = ScriptedTelemetryRepository()
        let recorder = RecordMotionUseCase(
            bleRepository: telemetry,
            motionRepository: repository)

        let writer = Task { await recorder.start() }
        defer { writer.cancel() }

        assertTest(
            await waitUntil { telemetry.motionSubscriberCount == 1 },
            "The recorder attaches to the strap's motion stream — the same multicast stream the step "
                + "counter reads, which is why this is an addition and not a second subscription")

        // Three seconds into a 30-second boundary, so `epochStart` has to round down rather than use
        // the batch's own instant.
        let base = Date(timeIntervalSince1970: 1_790_000_003)
        let windowStart = RecordMotionUseCase.epochStart(for: base)
        let range = (from: windowStart.addingTimeInterval(-30), to: windowStart.addingTimeInterval(90))

        telemetry.yieldMotion(motionBatch(startingAt: base, bumps: 0))
        let arrived = await waitUntil {
            let stored = try? await repository.getMotionEpochs(from: range.from, to: range.to)
            return stored?.isEmpty == false
        }
        assertTest(arrived, "A batch is persisted as a motion epoch, not merely decoded")

        let first = try await repository.getMotionEpochs(from: range.from, to: range.to)
        assertTest(
            first.count == 1 && first.first?.start == windowStart,
            "…on the 30-second boundary containing the batch's start, which is the grid the sleep "
                + "classifier reads (got \(first.map(\.start)) from \(base))")
        let firstCount = first.first?.sampleCount ?? 0
        assertTest(
            abs((first.first?.meanMagnitudeG ?? 0) - 1.0) < 0.01,
            "…and a still batch's mean magnitude is its gravity shell ≈1.0 G, not 0 — a fabricated "
                + "free-fall reading would pass every stillness test")

        telemetry.yieldMotion(motionBatch(startingAt: base.addingTimeInterval(1), bumps: 0))
        let grew = await waitUntil {
            let stored = try? await repository.getMotionEpochs(from: range.from, to: range.to)
            return (stored?.first?.sampleCount ?? 0) > firstCount
        }
        let final = try await repository.getMotionEpochs(from: range.from, to: range.to)
        assertTest(
            grew && final.count == 1,
            "A second batch inside the same window **upserts** the epoch — the sample count grows and "
                + "the table still holds one row, which is what lets a 30-second window be written as "
                + "its batches arrive")
    }
}
