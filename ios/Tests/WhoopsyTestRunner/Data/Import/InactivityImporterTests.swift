import Foundation
import Whoopsy

// MARK: - 21. The import, against an in-memory database

/// The storage half of §21. `InactivityImportTests.run()` calls it after the parser file, with the one
/// database both blocks share.
///
/// **What this is evidence for, and what it is not.** Everything below is arithmetic, storage and one
/// screen's read path. `biometric_samples` holds 0 rows in every database on this machine, no strap has
/// ever been connected, and nothing on this path touches BLE at all — the rows here were typed by a
/// person and their only transformation is a date snap and a UUIDv5. **None of it is evidence about a
/// strap.**
///
/// **Why the database arrives as a parameter rather than being built here.** §6.2's rule, and it bites
/// on this path in a way it does not on most: the import below writes through `repository`, and the
/// block at the end drives `HomeViewModel` — which needs a `LocalDatabaseManager` to build its other
/// seven repositories — over the very rows that write produced. Building a second
/// `LocalDatabaseManager(inMemory: true)` for the card block would give it an empty database, and every
/// assertion in it would fail for a reason that has nothing to do with the card. Blocks below that want
/// a database of their *own* build one inline, which is `ZeroFastingImporterTests`' own shape.
enum InactivityImporterTests {
    static func run(db: LocalDatabaseManager, repository: GRDBReceptiveInactivityRepository) async throws {

        // MARK: - B. The import, against an in-memory database

        let rows = (try? InactivityParser.parseInactivities(at: inactivitiesURL())) ?? []
        let calendar = Calendar.current
        let importer = InactivityImporter(receptiveRepository: repository)

        let summary = try await importer.importInactivities(at: inactivitiesURL())

        // The three counts are asserted separately rather than as a tuple, because they answer three
        // different questions and a summary that swapped two of them is a real bug that one equality
        // against a constructed `InactivityImportSummary` would report as a single mismatch.
        assertTest(
            summary.rowsInFile == rows.count,
            "The summary counts the file's own records, so a re-generated journal reports the number of "
                + "lines it actually has (\(summary.rowsInFile) against \(rows.count) parsed)")
        assertTest(
            summary.inactivitiesWritten == 62,
            "…and all **62** of them reached `receptive_inactivities`. This is the assertion that fails "
                + "if anyone reaches for `ReceptiveInactivity(date:name:startedAt:)` without passing the "
                + "derived id — not because the write fails, but because it would write 62 rows on every "
                + "press and read back perfectly well while doing it (\(summary.inactivitiesWritten))")
        assertTest(
            summary.rowsUnreadable == 0,
            "…and nothing was refused. This count is structurally zero on this path rather than "
                + "unexercised: the parser **throws** on a record it cannot read, so a record that "
                + "reaches the importer has already survived every refusal — which is why the parser "
                + "block above asserts the throwing rather than this asserting the dropping "
                + "(\(summary.rowsUnreadable))")

        // **The day count is recomputed, never pinned.** `startOfDay` is `Calendar.current`, and this
        // file's dates are pure days that a device time zone could in principle merge; §20 shipped the
        // hardcoded `136` once and it was a UTC number. The figure is 57 on this machine, and the
        // assertion is that the importer's own count agrees with a set built from the parsed rows —
        // which is the property, and the one that holds in every zone.
        let expectedDays = Set(rows.map(\.date))
        assertTest(
            summary.daysWritten == expectedDays.count,
            "The day count is the number of **distinct days** the records land on, recomputed here from "
                + "the parsed rows rather than pinned as a literal, so the assertion holds in whatever "
                + "zone the suite runs in (\(summary.daysWritten) written against \(expectedDays.count) "
                + "distinct in the parsed rows)")
        assertTest(
            summary.daysWritten < summary.inactivitiesWritten,
            "…and it is strictly below the row count, which is the whole reason the summary names the two "
                + "as separate clauses: five days in this journal carry two dreams each, and a sentence "
                + "printing one figure for both would be wrong by five (\(summary.daysWritten) days over "
                + "\(summary.inactivitiesWritten) rows)")

        assertTest(
            summary.message.contains("62 receptive inactivities") && summary.message.contains("57 days"),
            "The sentence a reader is shown leads with the rows and states the days as its own clause — "
                + "the same split the two counts above are asserted separately for "
                + "(\(summary.message))")
        assertTest(
            summary.message.contains("23 Jul 2023") && summary.message.contains("5 Oct 2026"),
            "…and it names the span it wrote, at both ends, through the shared `formattedImportDay()` "
                + "grammar. The last day is **5 Oct 2026** and not the 7 Aug the plan sketched: that "
                + "range was written from memory and the file's own tail is later than it "
                + "(\(summary.message))")

        // ---- All 62, read back on their own days ----

        // **The read that proves the id is a real UUID string.** `GRDBReceptiveInactivityRepository`
        // `makeActivities` guards `UUID(uuidString: record.id)` and drops the row when it fails, so a
        // string id writes 62 rows, reads back **none**, and reports a successful import of nothing.
        // Reading through the repository rather than through `db.getReceptiveInactivities(on:)` is the
        // point: the record-level read would return all 62 either way, and this is the one that fails.
        var readBack: [ReceptiveInactivity] = []
        for day in expectedDays.sorted() {
            readBack.append(contentsOf: try await repository.getReceptiveInactivities(for: day))
        }
        assertTest(
            readBack.count == 62,
            "All **62** rows come back through `GRDBReceptiveInactivityRepository` on their own days. "
                + "The 57 days are walked rather than one query run, because the repository has one "
                + "day-keyed read and no windowed sibling — a receptive inactivity has no end, so there "
                + "is nothing for a `covering:` read to overlap (\(readBack.count) read back)")
        assertTest(
            Set(readBack.map(\.id)).count == readBack.count,
            "…with no id collapsing two of them, which is the same property the parser asserted over the "
                + "file now asserted over what storage gave back — the two can only disagree if the "
                + "record's `id` column is written or read with something other than the derived string "
                + "(\(Set(readBack.map(\.id)).count) distinct)")

        // **Every row's note is its own record's prose.** Matched through the id rather than by index,
        // so a `save` that filed one record's text onto another's row is caught rather than passing on
        // a day where both happen to be similar.
        let proseByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.note) })
        let wrongProse = readBack.filter { proseByID[$0.id] != $0.note }
        assertTest(
            wrongProse.isEmpty,
            "Every one of the 62 rows carries **its own record's prose** and not a neighbour's — the "
                + "assertion that fails if `save(_:)` stops passing `note:` through, or passes it to the "
                + "wrong slot, which no count can see (\(wrongProse.count) rows disagree)")

        let notesMissing = readBack.filter { ($0.note ?? "").isEmpty }
        assertTest(
            notesMissing.isEmpty,
            "…and none of them came back without it. The column is nullable and a meditation will "
                + "legitimately hold NULL, so an import that dropped the text would read back a day of "
                + "correctly-named, correctly-dated rows with nothing in them and report success "
                + "(\(notesMissing.count) empty)")

        // The two fields the import does *not* supply, asserted so that "untimed" is written down as a
        // fact about this path rather than inferred from a screen that draws no clock.
        let timed = readBack.filter { $0.startedAt != nil }
        assertTest(
            timed.isEmpty,
            "Every row is **untimed** — `dreams.json` carries a date and no clock, so the importer "
                + "passes `startedAt: nil` and the Home row draws nothing in the clock's slot. That "
                + "empty slot is the honest drawing of \"no time given\"; the alternative, a midnight, "
                + "would be a time the user never chose (\(timed.count) timed)")
        let named = Set(readBack.map(\.name))
        assertTest(
            named == ["Dream"],
            "…and every one is named **`Dream`**, the catalogue's own spelling rather than the file's "
                + "lowercase `type` — so the row the import writes and the row the picker writes are the "
                + "same word on the screen and in the same glyph's table (\(named.sorted()))")

        // ---- The second press ----

        // **The assertion §4 exists for.** GRDB's `save` is INSERT-or-UPDATE *by primary key*, so this
        // holds only while the id is derived from the record's own content: with a fresh `UUID()` the
        // second press appends 62 more rows, every one of them reading back as a `Dream` on the right
        // day, and this is the only thing in the suite that would notice.
        let second = try await importer.importInactivities(at: inactivitiesURL())
        assertTest(
            second.inactivitiesWritten == 62,
            "The second press reports the same 62 rows, because it rewrites the same primary keys rather "
                + "than writing a second journal (\(second.inactivitiesWritten))")

        var afterSecond: [ReceptiveInactivity] = []
        for day in expectedDays.sorted() {
            afterSecond.append(contentsOf: try await repository.getReceptiveInactivities(for: day))
        }
        assertTest(
            afterSecond.count == 62,
            "…and the database still holds **62** rows and not 124. This is the assertion the whole "
                + "derived-id design is for, and the failure it catches is silent: an appending importer "
                + "reports a successful import, draws a correct-looking card, and quietly doubles the "
                + "journal on every press (\(afterSecond.count) after the second import)")

        // ---- The note's absence rules, which are what a nullable column buys ----

        // **A round trip preserves the prose verbatim.** Whitespace, punctuation and length included —
        // a column declared with a length or trimmed on the way through would still read back *a*
        // string, and the day would lose a sentence's worth of the entry with nothing reporting it.
        let proseDay = calendar.date(from: DateComponents(year: 2023, month: 7, day: 23))!.startOfDay
        let proseRows = try await repository.getReceptiveInactivities(for: proseDay)
        assertTest(
            proseRows.count == 2 && proseRows.allSatisfy { $0.note == proseByID[$0.id] && $0.note != nil },
            "A row read back carries its text **byte for byte** — no trimming on the way in or out. The "
                + "prose is the identity input as well as the stored value, so a column that normalised "
                + "it would change what the next import derives an id from ("
                + "\(proseRows.filter { $0.note == proseByID[$0.id] }.count) of \(proseRows.count) match)")

        // **`nil` reads back `nil`, and never `""`.** The two mean different things on this table: NULL
        // is "no text was given", which is every meditation and every row written before `v22`, while
        // `""` is a value somebody supplied. A mapper using `record.note ?? ""` would erase the
        // distinction on the read side and nothing would report it.
        let nilNoteDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!.startOfDay
        let nilNoteID = UUID()
        try await repository.save(
            ReceptiveInactivity(
                id: nilNoteID,
                date: nilNoteDay,
                name: "Meditation",
                note: nil,
                startedAt: nil))
        let nilNoteBack = try await repository.getReceptiveInactivities(for: nilNoteDay)
            .first { $0.id == nilNoteID }
        assertTest(
            nilNoteBack?.note == nil,
            "A row saved with **no text** reads back `nil` and not the empty string — NULL is this "
                + "column's word for \"nothing was given\", and `?? \"\"` on either side of the mapper "
                + "would turn every untimed meditation into a row that claims to hold text "
                + "(\(nilNoteBack?.note.map { "\"\($0)\"" } ?? "nil"))")

        // The other side of that pair, and the reason it is written down: `""` **is** reachable, just
        // not from this importer. A row written by hand through the record — which is what a future
        // backfill or a second producer would be — stores the empty string and reads it straight back,
        // so the storage layer is not laundering it and the draft's trim-to-nil is doing real work.
        // Asserted on the *record* read rather than the entity, because the entity's optional would
        // report both an absent note and an empty one as `nil` if the mapper coalesced them.
        let blankNoteDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 16))!.startOfDay
        let blankNoteID = UUID()
        try await db.saveReceptiveInactivity(
            ReceptiveInactivityRecord(
                id: blankNoteID.uuidString,
                date: blankNoteDay,
                name: "Meditation",
                note: "",
                startedAt: nil))
        let blankRecord = try await db.getReceptiveInactivities(on: blankNoteDay)
            .first { $0.id == blankNoteID.uuidString }
        assertTest(
            blankRecord?.note == "",
            "…while a row written by hand with an **empty string** stores and returns `\"\"` — a case "
                + "this importer never produces, asserted so the distinction is written down rather than "
                + "left to be rediscovered. It is why `ReceptiveInactivityDraft.setNote(_:)` trims a "
                + "blank field to `nil`: without that, the sheet would be the app's one producer of the "
                + "value the column does not mean (\(blankRecord?.note.map { "\"\($0)\"" } ?? "nil"))")

        // ---- The card, through the view model that draws it ----

        // §14's one-table-two-readers rule, on one of the file's five real two-dream nights. The
        // repository read above proves the storage; this proves the read path Home actually runs, and
        // it is deliberately `HomeViewModel.load(for:)` rather than the repository again — a view model
        // that filtered, de-duplicated or took only the newest row would pass every assertion above and
        // draw one row on a day holding two.
        //
        // Built over the **same** `db` the import wrote into, which is why that database is a parameter.
        let viewModel = await MainActor.run {
            HomeViewModel(
                recoveryRepository: GRDBRecoveryRepository(db: db),
                sleepRepository: GRDBSleepRepository(db: db),
                strainRepository: GRDBStrainRepository(db: db),
                workoutRepository: GRDBWorkoutRepository(db: db),
                receptiveInactivityRepository: repository,
                userProfileRepository: GRDBUserProfileRepository(db: db),
                stepRepository: GRDBStepRepository(db: db),
                analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                manage: ManageBLEConnectionUseCase(bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                streamUseCase: StreamBiometricsUseCase(
                    bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                    biometricRepository: GRDBBiometricRepository(db: db)))
        }
        await viewModel.load(for: proseDay)
        let card = await MainActor.run { viewModel.receptiveInactivities }

        assertTest(
            card.count == 2,
            "Home's `RECEPTIVE INACTIVITIES` card draws **two** rows on 23 Jul 2023 — the file's own "
                + "two-dream night, reaching the screen through the view model rather than through the "
                + "repository. A day holding one entry anywhere in the file would make this pass for the "
                + "wrong reason, which is why the parser block pins this day's count separately "
                + "(\(card.count) rows)")
        assertTest(
            card.allSatisfy { $0.name == "Dream" && $0.note != nil },
            "…both named `Dream` and both carrying their text, so the two rows on the card are the two "
                + "entries rather than one entry drawn twice — the pair a de-duplicating read would "
                + "collapse into a single row that still looks entirely plausible "
                + "(\(card.map { $0.note?.prefix(24) ?? "nil" }))")
        assertTest(
            card.allSatisfy { $0.startedAt == nil },
            "…and neither draws a clock, which is what the tile will look like on every imported day: "
                + "the row's time slot is an `if let` with no `else`, so an untimed entry renders "
                + "**nothing** there — not a dash, nothing "
                + "(\(card.filter { $0.startedAt != nil }.count) of \(card.count) carry an instant)")

        // A day the file does not cover draws an empty card rather than a stale one. Cheap, and it is
        // the assertion that fails if `load(for:)` ever stops clearing the array before it reads.
        //
        // The day chosen is the one **before the journal opens**, which is uncovered by construction:
        // the parser block pins the file's order as non-decreasing and its first day as 23 Jul 2023, so
        // nothing can precede it. Picking the day *after* the first one, as this block first did, is a
        // guess about the file rather than a property of it — and it was wrong: 24 Jul carries an entry.
        let uncoveredDay = calendar.date(byAdding: .day, value: -1, to: proseDay)!
        assertTest(
            !expectedDays.contains(uncoveredDay),
            "…and the day the assertion below loads is genuinely outside the file, checked rather than "
                + "assumed — an uncovered day that turned out to hold an entry would fail the assertion "
                + "under it for a reason that has nothing to do with the card "
                + "(\(uncoveredDay.formatted(date: .numeric, time: .omitted)))")
        await viewModel.load(for: uncoveredDay)
        let uncovered = await MainActor.run { viewModel.receptiveInactivities }
        assertTest(
            uncovered.isEmpty,
            "…while a day the file does not cover draws **no rows at all**, which is the card's own "
                + "empty state and the sentence beside it — a read that left the previous day's array in "
                + "place would draw yesterday's dreams under today's date "
                + "(\(uncovered.count) on an uncovered day)")
    }
}
