import Foundation
import Whoopsy

// MARK: - 21. The parser, over the real file, with no database behind it

/// A file of §21's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// beside its siblings. `InactivityImportTests.run()` calls it, in the order the section ran it in.
///
/// **What this is evidence for, and what it is not.** `dreams.json` is the owner's own notes with their
/// dates resolved by a generator kept outside this repository, so the row count, the days, the order and the
/// prose are facts about a file — and the ids are facts about this app, assertable only because the
/// same namespace and name string reproduce in Python. What none of it is evidence for is a strap: no
/// part of this path touches BLE, and every record here was typed by a person.
enum InactivityParserTests {
    static func run() async throws {

        // MARK: - A. The parser, over the real file, with no database behind it

        let rows = (try? InactivityParser.parseInactivities(at: inactivitiesURL())) ?? []
        assertTest(
            rows.count == 60,
            "The bundled `dreams.json` parses to its 60 records — one person's own dream journal, so a "
                + "re-generation that dropped a line or trimmed either end of the history would fail "
                + "here rather than importing a shorter journal and reporting success (got \(rows.count))")

        // **This is the resource half of a two-name split.** The resource is named for the *file* —
        // `dreams` — while the type, the section and the button are named for the *row* it produces,
        // `Inactivity*`. It is deliberately not asserted through `bundledInactivitiesURL()`, which
        // reaches for `Bundle.module` and **traps** in this runner (no resource bundle is linked); the
        // file the name resolves to is the one read above. §18 pins the caption's own name separately,
        // so a rename of the file cannot drag a caption along with it or the reverse.
        assertTest(
            InactivityImporter.bundledResourceName == "dreams",
            "The receptive inactivity import reads the bundled `dreams.json` and not some other "
                + "producer's file. The name is the half of the wiring a runner can see — the other half "
                + "is that `Package.swift` processes exactly this one path and that the lookups pass no "
                + "`subdirectory:`, `.process` on an explicit file flattening into the bundle's root")

        // The id is the row's storage key, and it is **derived** rather than minted: these records
        // carry no producer id, and GRDB's `save` is INSERT-or-UPDATE by primary key, so a fresh
        // `UUID()` per record would append 60 more rows on every press of the button. The properties
        // are asserted over every row rather than on one, because an id that is right on the first
        // record and wrong on the fifty-first reports identically.
        let ids = rows.map(\.id)
        assertTest(
            Set(ids).count == rows.count,
            "All 60 records carry distinct ids, which is what makes a re-import an update rather than "
                + "an append — two records deriving one id would collapse a day (\(Set(ids).count) "
                + "distinct over \(ids.count) rows)")

        // **The assertion that carries the file, and the only one here whose expected value does not
        // come from the code under test.** Both endpoints are pinned as literals computed independently
        // in Python:
        //
        //     ns = uuid.UUID("1B671A64-40D5-491E-99B0-DA7E7B3FB3E1")
        //     uuid.uuid5(ns, f'{date}|{type}|{note}')
        //
        // A round trip through `identifier(date:type:note:)` on both ends would be an encoder and a
        // decoder sharing a mistake — the rule this repo states for the CRC and BLE vectors — and it
        // could not see a namespace typo, a changed separator or a digest taken over the wrong bytes.
        // Pinning the two ends as the *file's own* first and last records means a re-generated journal
        // fails here, which is the honest place for it: the ids would move with the prose.
        let first = rows.first
        let last = rows.last
        assertTest(
            first?.id == UUID(uuidString: "7805a9df-1064-5201-9c99-378fd38d1ed6"),
            "The first record's id is the UUIDv5 that Python's `uuid.uuid5` derives from the same "
                + "namespace and the same `date|type|note` name string, pinned as a literal so the "
                + "namespace, the separator and the digest's input length are all covered by one value "
                + "(\(first?.id.uuidString ?? "nil"))")
        assertTest(
            last?.id == UUID(uuidString: "1346f436-bbba-5b5b-a40c-193086f688de"),
            "…and the last record's is pinned the same way, so the file's other end cannot move either "
                + "(\(last?.id.uuidString ?? "nil"))")

        // The vocabulary, which is the file's own word and not a value this parser chooses. It is
        // asserted rather than required: the row's *name* goes through
        // `ReceptiveInactivityCatalog.name(for:)`, so a future producer carrying `"meditation"` joins
        // this path rather than needing a second one — and this assertion is what would fail, loudly,
        // if someone made the parser hard-code `"dream"`.
        let types = Set(rows.map(\.type))
        assertTest(
            types == ["dream"],
            "Every record carries the file's own `type`, `\"dream\"` — read rather than required, so the "
                + "catalogue resolves it and a second producer's vocabulary would arrive as a second "
                + "value here rather than as a parse failure (\(types.sorted()))")

        // ---- The dates: non-decreasing, snapped, and pinned at both ends ----

        let dates = rows.map(\.date)
        assertTest(
            zip(dates, dates.dropFirst()).allSatisfy { $0 <= $1 },
            "The file is sorted and the parser preserves its order rather than re-sorting, so a day's "
                + "records arrive in the order the journal holds them — which is what makes the two-dream "
                + "days below read in the order they happened")

        // **The zone assertion, and the sharpest trap in the whole path.** A `DateFormatter` left on its
        // UTC default turns `"2023-07-23"` into `2023-07-23T00:00Z`, which `Calendar.current.startOfDay`
        // snaps back to **2023-07-22** in a negative-offset zone — every record a day early, silently,
        // on a screen that looks entirely plausible. The parser sets `timeZone = .current` and re-snaps;
        // this is the assertion that fails if either half is dropped, and it is why the pinned days
        // below are built through `Calendar.current` rather than typed as absolute instants.
        let calendar = Calendar.current
        let unsnapped = dates.filter { $0 != $0.startOfDay }
        assertTest(
            unsnapped.isEmpty,
            "Every parsed date is the **start of its own day** in the device's own zone, which is the "
                + "invariant the whole day-keyed read rests on — a record holding a midnight in another "
                + "zone files onto the day before it and no reader can tell (\(unsnapped.count) of "
                + "\(dates.count) unsnapped)")

        let firstDay = calendar.date(from: DateComponents(year: 2023, month: 7, day: 23))?.startOfDay
        let lastDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))?.startOfDay
        assertTest(
            dates.first == firstDay,
            "The journal opens on **23 Jul 2023**, pinned as a calendar day rather than as an instant "
                + "so the assertion holds in whatever zone the suite runs in (\(dates.first.map(String.init(describing:)) ?? "nil"))")
        assertTest(
            dates.last == lastDay,
            "…and closes on **9 Sep 2026**, the file's own last day — so a re-generation that trimmed "
                + "either end of the history fails here (\(dates.last.map(String.init(describing:)) ?? "nil"))")

        // The day count and the two-dream nights are facts about this file that the *storage* block
        // depends on: `2023-07-23` is one of the five days carrying two records, and it is the day
        // §21 drives `HomeViewModel.load(for:)` over. Asserted here, where the parse is, so the block
        // that relies on it is not resting on a fact nobody checked.
        let dayCount = Set(dates).count
        assertTest(
            dayCount == 55,
            "The 60 records fall on **55 distinct days** — five days carry two dreams each, which is "
                + "the property that makes a day's card a list rather than a single row (\(dayCount) days)")

        let onFirstDay = rows.filter { $0.date == firstDay }.count
        assertTest(
            onFirstDay == 2,
            "…and 23 Jul 2023 carries **two** of them, which is the number the in-memory block asserts "
                + "reaches Home's card — asserted here so that block is not resting on an unchecked "
                + "fact about the file (\(onFirstDay) on the first day)")

        // ---- The identity properties, on inputs this test chooses ----

        // Same inputs, same id — the whole of what makes a re-import idempotent. Stated as a property
        // rather than inferred from the two literals above, because those pin *this file's* values and
        // this pins the function's contract.
        let sampleDate = calendar.date(from: DateComponents(year: 2024, month: 3, day: 4))!.startOfDay
        let sampleNote = "dreamt of a long corridor"
        let once = InactivityParser.identifier(date: sampleDate, type: "dream", note: sampleNote)
        let twice = InactivityParser.identifier(date: sampleDate, type: "dream", note: sampleNote)
        assertTest(
            once == twice,
            "The same day, type and text derive the same id on every call, so pressing the import twice "
                + "rewrites the same rows rather than appending a second journal")

        // **A changed note moves the id, and that is the consequence §4 records rather than hides.** An
        // edited dream's old row survives beside the new one, and because the text is stored the pair is
        // *visible* on the day rather than indistinguishable — which is exactly why the caption beside
        // the button says a re-import reverts a hand-edit.
        let differentNote = InactivityParser.identifier(
            date: sampleDate, type: "dream", note: sampleNote + " with a door at the end")
        assertTest(
            differentNote != once,
            "…while a changed text derives a different id, which is what makes an edited journal entry "
                + "appear as a second row rather than overwriting the first")

        let differentDay = InactivityParser.identifier(
            date: calendar.date(from: DateComponents(year: 2024, month: 3, day: 5))!.startOfDay,
            type: "dream",
            note: sampleNote)
        assertTest(
            differentDay != once,
            "…and so does the same dream on another day, since the day is part of the name string")

        let differentType = InactivityParser.identifier(
            date: sampleDate, type: "meditation", note: sampleNote)
        assertTest(
            differentType != once,
            "…and so does the same text recorded as another kind of receptive inactivity, which is what "
                + "lets a second producer's vocabulary join this path without colliding with this one")

        // Every row's id is the one its own three fields derive — the property that ties the literals
        // above to the function rather than leaving them as two facts that happen to agree.
        let recomputed = rows.filter {
            InactivityParser.identifier(date: $0.date, type: $0.type, note: $0.note) != $0.id
        }
        assertTest(
            recomputed.isEmpty,
            "…and every one of the 60 rows carries the id its own day, type and text derive, so the "
                + "pinned literals are the function's own output and not a second implementation's "
                + "(\(recomputed.count) rows disagree)")

        // ---- The refusals, which a row count cannot see ----

        // A `guard … else { continue }` here would return a *shorter array* — or an empty one — and
        // every assertion above would fail with a row count rather than with the reason. That is the
        // defect `WhoopExportParser` shipped once and this repo's parsers are all shaped around.
        func errorThrown(by text: String) -> InactivityImportError? {
            do {
                _ = try InactivityParser.parseInactivities(text)
                return nil
            } catch let error as InactivityImportError {
                return error
            } catch {
                return nil
            }
        }

        func isMissingInactivities(_ text: String) -> Bool {
            guard let error = errorThrown(by: text) else { return false }
            if case .missingInactivities = error { return true }
            return false
        }

        assertTest(
            isMissingInactivities("{}"),
            "`{}` throws `.missingInactivities` rather than returning zero rows — the analogue of the "
                + "CSV parser's `missingColumns`, and the check that makes pointing this importer at any "
                + "other JSON fail loudly instead of reporting a successful import of nothing")
        assertTest(
            isMissingInactivities(#"{"receptive_inactivities": {}}"#),
            "…and so does a `receptive_inactivities` that is present but not an array of records, which "
                + "is the shape a producer changing the key's type would give it")
        assertTest(
            isMissingInactivities(#"{"receptive_inactivities": []}"#) == false,
            "…while the placeholder a fresh clone is given — the same key holding an empty array — "
                + "parses to zero rows and **not** to an error, because there is nothing wrong with a "
                + "journal that has no entries yet")

        guard let arrayError = errorThrown(by: "[1, 2, 3]") else {
            assertTest(false, "An array root throws rather than being read as a document")
            return
        }
        if case .malformedDocument = arrayError {} else {
            assertTest(
                false,
                "An array root throws **`.malformedDocument`** rather than `.missingInactivities`, "
                    + "because the document is not an object at all — the two refusals answer different "
                    + "questions and a parser that merged them would report a wrong file as a well-formed "
                    + "one missing its key (threw \(arrayError))")
        }
        assertTest(
            errorThrown(by: "not json at all") != nil,
            "…and a document that is not JSON at all throws rather than answering with an empty array")

        // **A record missing a field throws; it is never skipped.** This is the half a successful
        // import count cannot distinguish from a correct one: a record with no `note` dropped silently
        // reports the same green as one that was never in the file, and the journal is short by a night
        // with nothing anywhere saying so. The three fields are asserted one at a time, so a guard put
        // on the wrong key is visible rather than merely present.
        func refuses(_ document: String, field: String) -> Bool {
            guard let error = errorThrown(by: document) else { return false }
            if case .missingField(_, let failed) = error { return failed == field }
            return false
        }

        assertTest(
            refuses(#"{"receptive_inactivities":[{"type":"dream","note":"a door"}]}"#, field: "date"),
            "A record carrying no `date` throws with the field named, rather than being placed at the "
                + "reference date or dropped — an undated entry is the one thing this file must never "
                + "produce, since a receptive inactivity's whole storage key is its day")
        assertTest(
            refuses(
                #"{"receptive_inactivities":[{"date":"2023-07-23","note":"a door"}]}"#,
                field: "type"),
            "…and one carrying no `type` throws the same way, which is what stops a nameless record "
                + "reaching the catalogue and being resolved to an empty name")
        assertTest(
            refuses(
                #"{"receptive_inactivities":[{"date":"2023-07-23","type":"dream"}]}"#,
                field: "note"),
            "…and one carrying no `note` throws **rather than importing as a textless entry**, which is "
                + "the case this file cannot have: the prose is both the identity input and the stored "
                + "value, so a record without it has nothing to derive an id from and nothing to hold")
        assertTest(
            refuses(
                #"{"receptive_inactivities":[{"date":"2023-07-23","type":"dream","note":"   "}]}"#,
                field: "note"),
            "…and a note that is present but blank is refused identically, because `\"\"` is what a "
                + "truncated line arrives as and a whitespace-only value is not an entry — the same "
                + "reading `ReceptiveInactivityDraft.setNote(_:)` applies to the sheet's own field")

        // The date's refusal is separate from the field's absence, and it carries the offending value:
        // a parser that answered `.missingField(field: "date")` for `"2023-13-45"` would send a reader
        // looking for a missing key in a record that has one.
        guard let dateError = errorThrown(
            by: #"{"receptive_inactivities":[{"date":"2023-13-45","type":"dream","note":"a door"}]}"#)
        else {
            assertTest(false, "A record with an impossible date throws rather than being placed")
            return
        }
        if case .unparseableDate(_, let value) = dateError {
            assertTest(
                value == "2023-13-45",
                "…and an impossible date throws **`.unparseableDate`** carrying the value it could not "
                    + "read, so the message names the line to fix rather than a field to look for "
                    + "(\(value))")
        } else {
            assertTest(
                false,
                "An impossible date throws `.unparseableDate` rather than `.missingField` — the two send "
                    + "a reader to different places, and a date that is present but wrong is the second "
                    + "(threw \(dateError))")
        }
    }
}
