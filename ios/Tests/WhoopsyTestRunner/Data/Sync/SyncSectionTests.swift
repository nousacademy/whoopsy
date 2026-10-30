import Foundation
import Whoopsy

// MARK: - 22. The sync: the span, the wire, the seven stores and the run

/// The suite's section for the database sync — one install's seven resources moving between this phone's
/// SQLite file and the Worker behind it.
///
/// **What this section is evidence for, and what it is not.** Every block below runs against an
/// in-memory `LocalDatabaseManager`, a spy `CloudSync` and a fixture settings store. **No block here
/// opens a socket.** There is no test double for the Worker and none is possible: `CloudSync` is the
/// seam, so what is asserted is this app's half of the contract — the day snap, the two-names rule, the
/// absence rule applied to a `null` on the wire, the chunking, and the walk's arithmetic. A passing run
/// is therefore **not** evidence that the deployed Worker answers the way the mapper expects; that is
/// `backend/tests/`'s half, against a real Worker in `workerd` with a local D1.
///
/// **It is one section and not seven, because the seven resources are one feature.** `CloudSync` is one
/// port, `SyncSettings` is one type, and the walk, the chunking and the skip count are written once and
/// read by all seven. Splitting them would put seven copies of that argument in seven banners and let
/// them drift, and it would put `SyncSettingsTests` — which is about the *shape*, not about a resource —
/// in none of the halves or in all of them.
///
/// **The order below is the order of a run, not the order the files were written.** A span is drawn
/// (22.1), a row is spelled on the wire (22.2), the store the phone reads through answers or degrades
/// (22.3), the database underneath it takes the row (22.4), the run walks all seven (22.5), and then the
/// two claims the run cannot make about itself are swept over the source and the contract (22.6, 22.7).
/// Each block assumes the one above it: a wire mapper asserted before the settings it reads a span from
/// would be asserting against a default nobody chose.
///
/// **Nothing here is `@MainActor`**, on `TestSection`'s own rule: an isolated body removes real hops and
/// changes what is observable rather than merely how fast. The engine is a `Sendable` struct over actor
/// and spy dependencies, so no block below needs the main actor to reach it.
enum SyncSectionTests {
    static func run() async throws {
        // 22.1 — the destination, the span, its snap and its day count, and the once-a-day window
        // that decides when any of it may leave the phone. No database.
        SyncScheduleTests.run()
        try await SyncSettingsTests.run()

        // 22.2 — a row on the wire, for all seven resources: the day key and the instant in both
        // directions, the two-names rule, and the nullable-not-optional rule that decides whether a
        // body's absent fields are omitted or sent as `null`. No database either; this is the one place
        // a wire name is written down.
        try await RecoveryWireMapperTests.run()
        try await WorkoutWireMapperTests.run()
        try await SleepWireMapperTests.run()
        try await StepCountWireMapperTests.run()
        try await ReceptiveInactivityWireMapperTests.run()
        try await UserProfileWireMapperTests.run()

        // 22.3 — the decorator: which store answers a day, and what a screen is told when the cloud
        // could not.
        try await CloudRecoveryRepositoryTests.run()
        try await CloudSyncRepositoriesTests.run()

        // 22.4 — the phone's own door into the two resources. A real `LocalDatabaseManager(inMemory:)`,
        // which is the only place the SQLite column names and the day snap are asserted.
        try await LocalDatabaseManagerSyncTests.run()
        try await LocalDatabaseManagerWorkoutSyncTests.run()

        // 22.5 — the run itself: one engine over all seven resources, driven against a real in-memory
        // database and a spy cloud, so the ceiling, the skip count and the chunk boundary are asserted
        // on the walk rather than on a description of it.
        try await SyncEngineTests.run()

        // 22.6 — the one read path that reaches the API, and the three states in which it must not.
        try await RestoreFromCloudUseCaseTests.run()

        // …and the control that invokes it. Two names, and one of them has to warn: unlike `SYNC` the
        // restore writes over days this phone already holds, so the caption says so rather than
        // leaving it to be discovered.
        assertTest(
            SyncStorageViewModel.restoreTitle == "RESTORE",
            "The pane's second control is named for what it does, beside `SYNC`")
        assertTest(
            SyncStorageViewModel.restoreCaption.contains("replaced"),
            "…and its caption states that a restore replaces days the phone already holds, which is "
                + "the one thing a reader must know before pressing it "
                + "(\(SyncStorageViewModel.restoreCaption))")

        // 22.7 — the pane's list read off the contract rather than typed beside it, so a resource the
        // Worker mounts and the app forgot cannot pass. Two files of text and one enum; no database.
        try await SyncedResourceTests.run()

        // 22.8 — **exactly one delete door, and it is the day purge**, swept over the port, the seven
        // store protocols and the committed contract. The guarantee changed shape on 2026-10-29 and it
        // did not weaken: one method on the port is a removal, it takes a range, and the contract
        // mounts four `delete` operations on the four measured day-keyed resources and nothing else.
        try await CloudSyncTests.run()

        // …and the purge's own rules: which side it visits first, and the refusal that deletes
        // nothing when the database cannot be reached.
        try await PurgeDaysUseCaseTests.run()
    }
}
