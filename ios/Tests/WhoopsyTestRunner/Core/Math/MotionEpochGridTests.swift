import Foundation
import Whoopsy

/// The 30-second grid both motion writers and readers share.
enum MotionEpochGridTests {
    static func run() async throws {
        // 1_790_000_001 is 21 seconds past a grid boundary, so the floor is a real floor rather than
        // an identity. The two constants are derived here by hand rather than by calling the type:
        // 30 × 59,666,666 = 1,789,999,980.
        let instant = Date(timeIntervalSince1970: 1_790_000_001)
        let expectedBoundary = Date(timeIntervalSince1970: 1_789_999_980)

        assertTest(
            MotionEpochGrid.start(for: instant) == expectedBoundary,
            "An instant 21 s past a boundary floors to that boundary")
        assertTest(
            MotionEpochGrid.index(for: instant) == 59_666_666,
            "…and its integer window index is the same floor, got \(MotionEpochGrid.index(for: instant))")
        assertTest(
            MotionEpochGrid.date(forIndex: 59_666_666) == expectedBoundary,
            "…and the index converts back to the boundary, so the two halves are inverses")
        assertTest(
            MotionEpochGrid.epochSeconds == 30,
            "The window is 30 seconds — the length the sleep classifier consumes")

        let onBoundary = expectedBoundary
        assertTest(
            MotionEpochGrid.start(for: onBoundary) == onBoundary,
            "An instant already on a boundary is its own window start")
        assertTest(
            MotionEpochGrid.index(for: onBoundary.addingTimeInterval(29.999))
                == MotionEpochGrid.index(for: onBoundary),
            "The last millisecond of a window is still in that window")

        // **The round trip is the reason this type exists.** A `Date` comes back from SQLite at
        // millisecond precision and compares unequal to the one written; the integer index does not.
        // A window stored at a non-grid instant — which only a hand-built row can be, and a legacy or
        // probe row is — must land in the same bucket before and after.
        let db = LocalDatabaseManager(inMemory: true)
        let repository = GRDBMotionEpochRepository(db: db)
        let written = MotionEpoch(
            start: Date(timeIntervalSince1970: 1_790_000_001.2345),
            end: Date(timeIntervalSince1970: 1_790_000_031.2345),
            meanMagnitudeG: 1.06,
            maxMagnitudeG: 1.21,
            sampleCount: 1_234)
        try await repository.saveMotionEpoch(written)
        let read = try await repository.getMotionEpochs(
            from: written.start.startOfDay, to: written.start.startOfNextDay)

        guard let stored = read.first else {
            assertTest(false, "A stored motion window is readable, got none")
            return
        }
        assertTest(
            MotionEpochGrid.index(for: stored.start) == MotionEpochGrid.index(for: written.start),
            "A window's bucket index survives the database round trip")
        assertTest(
            stored.start != written.start,
            "…and the instants themselves really do differ, which is what makes the index the identity")
    }
}
