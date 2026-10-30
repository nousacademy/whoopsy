import Foundation
import Whoopsy

// MARK: - 7. The database arm the app launches on

/// A file-backed `LocalDatabaseManager`, which is a **`DatabasePool`** and not the `DatabaseQueue`
/// every other block in this section opens.
///
/// **Why this exists.** The pool is the only writer a device build uses — the queue is the
/// in-memory test arm — so without a block that opens a file, the arm every launch takes would be
/// compiled and never executed. That is the shape of a migration that crashes the app at startup with
/// a green suite: `init(inMemory: true)` and `init(fileURL:)` run the same migrations, but only one of
/// them on a pool.
///
/// It asserts the three things the pool could get wrong that a queue cannot: that migrations run on it
/// at all, that a row written through it reads back under the day-key rule, and that two reads issued
/// at once — which is the point of the pool, and impossible on a queue without one waiting — both
/// answer.
enum LocalDatabasePoolTests {
    static func run() async throws {
        // Inside the repo's `tmp/`, never the machine's `/tmp` — the rule `tmp/README.md` states.
        let directory = packageRoot().appendingPathComponent("tmp/pool-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("whoopsy.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }

        let db = LocalDatabaseManager(fileURL: url)

        let tables = (try? await db.existingTableNames()) ?? []
        assertTest(
            tables.contains("recoveries") && tables.contains("biometric_samples"),
            "The migrator runs on a pool exactly as it does on a queue — a pool that skipped them "
                + "would crash the app at launch, and this is the only block that opens one "
                + "(\(tables.count) tables)")

        let day = Calendar.current.startOfDay(for: Date())
        try await db.saveRecovery(
            RecoveryRecord(date: day, recoveryScore: 64, restingHeartRate: 53, hrvValueMs: 61.2))

        async let firstRead = db.getRecovery(for: day)
        async let secondRead = db.getRecoveryHistory(days: 30)
        let row = try await firstRead
        let history = try await secondRead

        assertTest(
            row?.recoveryScore == 64 && history.count == 1,
            "A row written through the pool reads back through it, as a day and in a history — and "
                + "two reads issued together both answer, which is what the pool buys")

        assertTest(
            FileManager.default.fileExists(atPath: url.path),
            "…and it is a real file, so the in-memory branch was not silently taken")
    }
}
