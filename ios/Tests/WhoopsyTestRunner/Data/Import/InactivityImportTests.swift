import Foundation
import Whoopsy

// MARK: - 21. The receptive inactivity import

/// §21's body, split into the two files whose subjects it covers and called from here in order.
///
/// **What the section is shaped by, in the order the files meet it.**
///
/// A record in `dreams.json` carries no id of its own, so the import **derives** one from the record's
/// own day, type and text — and every assertion about storage rests on that. GRDB's `save` is
/// INSERT-or-UPDATE *by primary key*, so a fresh `UUID()` per record would append 60 more rows on every
/// press of the button while reading back a perfectly plausible journal, and nothing but the row count
/// would say so. The id is a UUIDv5 (RFC 4122 §4.3) computed in Swift and reproducible in Python, which
/// is what lets the parser file pin two of them as **literals whose expected values do not come from
/// the code under test**.
///
/// The prose is both the identity input *and* a stored value — the owner's reversal, `text will be added
/// to another screen, receptive inactivity detail page` — so the `v22` column is nullable, the sheet can
/// edit it, and a changed entry moves its own id.
///
/// Three consequences follow and each is asserted rather than left to be discovered. **A re-import
/// reverts a hand-edit**, silently, because there is no day-skip on this path and the same file derives
/// the same id — so the file's text is written back over the user's. **A changed notes file produces a
/// visible duplicate**, because the edited wording moves the id and the old row survives beside the new
/// one carrying different text. And **`nil` is the column's word for "nothing was given"**, which is
/// every meditation and every row written before `v22`, while `""` is a value somebody supplied that the
/// importer never produces and the draft's `setNote(_:)` trims away.
///
/// Everything here is one person's own notes read off disk and written to SQLite. **None of it is
/// evidence about a strap** — no part of this path touches BLE, `biometric_samples` holds 0 rows in
/// every database on this machine, and every record in the file was typed by a human.
enum InactivityImportTests {
    static func run() async throws {
        try await InactivityParserTests.run()

        // **One database, built here and threaded into both blocks that need it.** §6.2: the import
        // writes through this repository, and the card block at the end drives Home over the rows that
        // write produced — so a second `LocalDatabaseManager(inMemory: true)` built below would give the
        // card an empty database and every assertion in it would fail for a reason that has nothing to
        // do with the card. The database is the shared object here rather than the repository, because
        // `GRDBReceptiveInactivityRepository` is a stateless wrapper over it and the view-model block
        // needs the database itself to build Home's seven other readers.
        let db = LocalDatabaseManager(inMemory: true)
        let repository = GRDBReceptiveInactivityRepository(db: db)

        try await InactivityImporterTests.run(db: db, repository: repository)
    }
}
