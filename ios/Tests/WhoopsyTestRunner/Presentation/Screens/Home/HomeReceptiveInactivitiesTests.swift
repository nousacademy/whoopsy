import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The receptive inactivities card

/// The second card on Home: the states where conscious exertion drops to zero.
///
/// **A file of §14's body**, cut at the section's own `// ---- Title ----` boundary and moved verbatim
/// beside its siblings. `HomeSourceTests.run()` calls it, in the order the section ran it in.
///
/// **What this block is evidence for, and what it is not.** It proves the storage, the day-snap, the
/// order, the draft's rebuild and the view model's merge. The runner has **no renderer**, so nothing
/// here is evidence that the card draws, that its empty state reads as words rather than a blank, or
/// that the sheet appears where it should — those are the reader's to check on a phone. What is
/// assertable is everything the drawing is made of.
///
/// Three of the claims are the ones a wrong implementation gets silently right:
///
/// - **an untimed entry reads back untimed.** `startedAt` is optional because the user's rule is
///   *"time is optional"*, and a mapper or a column that defaulted it would hand every reader a
///   midnight the user never picked — a fabricated reading, which is the class of defect this suite
///   exists to catch.
/// - **the SQL order and `isOrderedBefore` are one order.** `HomeViewModel` sorts its own list after a
///   save, so the two are both live: if they disagree, the card's order changes the moment an entry is
///   written and stays wrong until the day is reloaded.
/// - **a re-opened entry has nothing to save.** A `DatePicker` re-fires its setter with a fresh instant
///   built on *today*, so a draft compared raw would be permanently dirty and `SAVE` would be lit over
///   a sheet nobody touched.
enum HomeReceptiveInactivitiesTests {
    static func run() async throws {
        let calendar = Calendar.current

        // ---- v21: the round trip, in both directions, on its own day ----

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBReceptiveInactivityRepository(db: db)

            let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
            // Raw instants rather than `startOfDay + n` so the snap below is being tested against a
            // value that genuinely carries a clock time, which is what a caller off the sheet has.
            let timed = ReceptiveInactivity(
                date: day.addingTimeInterval(17 * 3600 + 33 * 60),
                name: "Dream",
                startedAt: day.addingTimeInterval(7 * 3600))
            let untimed = ReceptiveInactivity(date: day, name: "Body scan")

            try await repository.save(timed)
            try await repository.save(untimed)

            let readBack = try await repository.getReceptiveInactivities(for: day)
            assertTest(
                readBack.count == 2,
                "Both entries written for one day read back (\(readBack.count) returned)")

            // **The absence that carries this block.** `nil` is the user's own rule for a time they did
            // not give, and it is the value a defaulted column, a defaulted initialiser parameter or an
            // `?? startOfDay` in the mapper would each quietly replace with a midnight nobody chose.
            let storedUntimed = readBack.first { $0.name == "Body scan" }
            assertTest(
                storedUntimed?.startedAt == nil,
                "…and the untimed one reads back with **no** start instant rather than a fabricated "
                    + "midnight (got \(storedUntimed?.startedAt.map { "\($0)" } ?? "nil"))")

            let storedTimed = readBack.first { $0.name == "Dream" }
            assertTest(
                storedTimed?.startedAt == day.addingTimeInterval(7 * 3600),
                "…while the timed one keeps the instant it was given (got "
                    + "\(storedTimed?.startedAt.map { "\($0)" } ?? "nil"))")

            // The day-snap, asserted in both directions: found on its own day, and absent from the two
            // days either side of it. A single-direction assertion cannot tell a snapped write from a
            // row that is simply not being found at all.
            assertTest(
                storedTimed?.date == day.startOfDay,
                "A row saved at a raw 17:33 is filed on its own day rather than at that instant "
                    + "(\(storedTimed.map { "\($0.date)" } ?? "nil") against \(day.startOfDay))")
            assertTest(
                storedTimed?.date == storedTimed?.startedAt.map { $0.startOfDay },
                "…and the day it is filed on is the day of its own start instant, so the pair cannot "
                    + "come apart and file an 07:00 entry on the 14th")

            let dayBefore = calendar.date(byAdding: .day, value: -1, to: day)!
            let dayAfter = calendar.date(byAdding: .day, value: 1, to: day)!
            let beforeRows = try await repository.getReceptiveInactivities(for: dayBefore)
            let afterRows = try await repository.getReceptiveInactivities(for: dayAfter)
            assertTest(
                beforeRows.isEmpty && afterRows.isEmpty,
                "…and neither neighbouring day finds either row, so the day key is the only way in "
                    + "(\(beforeRows.count) before, \(afterRows.count) after)")

            // A day with nothing on it is an empty array and never a stand-in row: the card draws that
            // as its empty state, and a placeholder here would put a row on every day of the calendar.
            assertTest(
                try await repository.getReceptiveInactivities(
                    for: calendar.date(byAdding: .day, value: -30, to: day)!) == [],
                "A day nothing was recorded on returns no rows at all rather than a placeholder")

            // ---- The order the read uses is the order the model states ----

            // `LocalDatabaseManager.getReceptiveInactivities(on:)` orders `started_at ASC NULLS LAST,
            // name ASC` and `ReceptiveInactivity.isOrderedBefore` is that rule written as a comparison.
            // Both are live — `HomeViewModel.saveReceptiveInactivity` sorts its own list by the second
            // while a reload produces the first — so a disagreement is a card whose order changes when
            // an entry is written and changes back when the day is reopened.
            //
            // Two untimed rows and three timed ones, with a **tie** at 07:00 so the name clause is
            // exercised rather than merely present: a rule that dropped it would leave those two in
            // insertion order and agree with the sorted list by luck on this fixture's other rows.
            let orderDB = LocalDatabaseManager(inMemory: true)
            let orderRepository = GRDBReceptiveInactivityRepository(db: orderDB)
            let orderDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
            let fixture: [ReceptiveInactivity] = [
                ReceptiveInactivity(date: orderDay, name: "Dream"),                       // untimed
                ReceptiveInactivity(date: orderDay, name: "Body scan"),                   // untimed
                ReceptiveInactivity(date: orderDay, name: "Float",
                                  startedAt: orderDay.addingTimeInterval(21 * 3600 + 15 * 60)),
                ReceptiveInactivity(date: orderDay, name: "QiGong",
                                  startedAt: orderDay.addingTimeInterval(7 * 3600)),
                ReceptiveInactivity(date: orderDay, name: "Meditation",
                                  startedAt: orderDay.addingTimeInterval(7 * 3600)),
            ]
            for activity in fixture { try await orderRepository.save(activity) }

            let storeOrder = try await orderRepository.getReceptiveInactivities(for: orderDay).map(\.name)
            let statedOrder = fixture.sorted(by: ReceptiveInactivity.isOrderedBefore).map(\.name)
            assertTest(
                storeOrder == statedOrder,
                "The store's `started_at ASC NULLS LAST, name ASC` and `ReceptiveInactivity."
                    + "isOrderedBefore` produce one order over a day holding both kinds "
                    + "(\(storeOrder) against \(statedOrder))")
            assertTest(
                storeOrder == ["Meditation", "QiGong", "Float", "Body scan", "Dream"],
                "…and that order is the day's timed entries earliest-first — with the 07:00 tie broken "
                    + "by name — followed by the untimed ones, themselves ordered by name. `nil` sorts "
                    + "last because SQLite sorts NULL *first* ascending, which would put an entry that "
                    + "gave no time above one that did (\(storeOrder))")
        } catch {
            assertTest(false, "The receptive inactivity round trip threw: \(error)")
        }

        // ---- The draft: one rebuild, and a sheet that is not dirty on open ----

        do {
            let targetDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!

            // A `DatePicker` with `.hourAndMinute` hands back a whole instant carrying **today's**
            // year, month and day, whatever day the user is looking at — so the fixture is deliberately
            // an instant on another day entirely, which is the shape the trap arrives in.
            let pickedElsewhere = calendar.date(
                from: DateComponents(year: 2026, month: 10, day: 3, hour: 8, minute: 0))!
            let rebuilt = ReceptiveInactivityDraft.instant(of: pickedElsewhere, on: targetDay)

            assertTest(
                rebuilt == targetDay.startOfDay.addingTimeInterval(8 * 3600),
                "The picked hour and minute are rebuilt onto the target day's own midnight "
                    + "(\(rebuilt) against \(targetDay.startOfDay.addingTimeInterval(8 * 3600)))")
            assertTest(
                rebuilt.startOfDay == targetDay.startOfDay,
                "…which is the invariant the entity's doc states as `date == startOfDay(startedAt)`: an "
                    + "entry filed on the day the user was looking at carries a time *on that day*")
            assertTest(
                rebuilt != pickedElsewhere,
                "…and the raw instant the picker handed over does not survive — filing it directly would "
                    + "put a 2024 day's meditation on the day it was typed")

            // **The rebuild is elapsed seconds and not `date(bySettingHour:…)`, and that is the second
            // thing it buys.** `bySettingHour` returns `nil` for a wall time that does not exist, and
            // 02:30 is exactly that on a spring-forward day — so the alternative's failure mode is a
            // dropped time rather than a wrong one. Where this machine's zone has its transition is not
            // a fact to assert here, so what is pinned is the arithmetic: the offset is the picked hour
            // and minute as seconds, added to the target day's own midnight, with no calendar lookup in
            // between for a nonexistent hour to fail.
            let latePick = calendar.date(
                from: DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 45))!
            assertTest(
                ReceptiveInactivityDraft.instant(of: latePick, on: targetDay)
                    == targetDay.startOfDay.addingTimeInterval(23 * 3600 + 45 * 60),
                "…and the hour is taken off the picked instant as a clock reading rather than as a date "
                    + "component, so a late-evening pick lands late in the target day rather than being "
                    + "carried over into the next one")

            // A nameless draft is not an entry. This is the whole of the `SAVE` gate for the add mode:
            // `applying(to:)` answering `nil` is what keeps the button dark, with no second rule about
            // empty strings anywhere.
            var empty = ReceptiveInactivityDraft()
            assertTest(
                empty.applying(to: targetDay) == nil && !empty.hasChanges(on: targetDay),
                "An empty draft is not an entry and has nothing to save, so `SAVE` is dark on a sheet "
                    + "that was just opened")
            assertTest(!empty.isEditing, "…and it does not offer `Delete`, since there is no row behind it")

            empty.setName("Yoga nidra")
            let filed = empty.applying(to: targetDay)
            assertTest(
                filed?.name == "Yoga nidra" && filed?.date == targetDay.startOfDay
                    && filed?.startedAt == nil,
                "A named draft with no time becomes an entry on the target day carrying no clock, which "
                    + "is the user's *\"time is optional\"* in the value rather than in a guard")
            assertTest(
                empty.hasChanges(on: targetDay),
                "…and it now has something to save, so the one gate covers both modes: an add draft "
                    + "differs from `original`'s `nil` the moment it has a name")

            // ---- The assertion that keeps `SAVE` dark on an untouched edit ----

            // A `DatePicker` re-fires its setter with a freshly-built instant on a render the user did
            // not touch, and that instant carries today's date. Compared raw, the draft would differ
            // from its own row by a whole day and `SAVE` would be permanently live — `MetricChange`'s
            // formatted-pair rule, applied to a form. The setter below is deliberately handed an
            // instant on **another day** carrying the **same wall time**, which is precisely what the
            // picker does.
            let stored = ReceptiveInactivity(
                date: targetDay, name: "Dream", startedAt: targetDay.addingTimeInterval(8 * 3600))
            var editDraft = ReceptiveInactivityDraft(stored)
            assertTest(
                !editDraft.hasChanges(on: targetDay),
                "A draft opened over a row has nothing to save — it was seeded verbatim")
            assertTest(editDraft.isEditing, "…and it does offer `Delete`, because there is a row behind it")

            editDraft.setStart(calendar.date(
                from: DateComponents(year: 2026, month: 10, day: 3, hour: 8, minute: 0))!)
            assertTest(
                !editDraft.hasChanges(on: targetDay),
                "…and a `DatePicker` re-firing the same 8:00 AM on a day the user never touched leaves "
                    + "it clean, because both sides of the comparison are rebuilt onto the same day "
                    + "rather than compared as two instants a week apart")

            editDraft.setStart(calendar.date(
                from: DateComponents(year: 2026, month: 10, day: 3, hour: 9, minute: 0))!)
            assertTest(
                editDraft.hasChanges(on: targetDay),
                "…while moving the time to 9:00 AM is a real edit, so the clean read above is the "
                    + "rebuild's doing and not a comparison that never reports anything")

            var cleared = ReceptiveInactivityDraft(stored)
            cleared.setStart(nil)
            assertTest(
                cleared.hasChanges(on: targetDay) && cleared.applying(to: targetDay)?.startedAt == nil,
                "…and clearing the time altogether is an edit that files an untimed entry, so a time "
                    + "can be taken back rather than only moved")

            // A draft that is renamed keeps its row's identity, which is what makes the write an update
            // rather than a second entry beside the first.
            var renamed = ReceptiveInactivityDraft(stored)
            renamed.setName("Lucid dream")
            assertTest(
                renamed.applying(to: targetDay)?.id == stored.id,
                "An edit keeps the row's `id`, so `save` rewrites it in place — a fresh `UUID` would "
                    + "append a second entry beside the one being edited")
            assertTest(
                renamed.id == stored.id,
                "…and the draft's own identity is the row's, which is what `.sheet(item:)` keys on")

            // The name guard is `ActivityName.matches`, not `==`, on the picker's rule: a pick that
            // differs only in case or surrounding space must not mark the sheet dirty and light `SAVE`.
            var tolerant = ReceptiveInactivityDraft(stored)
            tolerant.setName("  dream ")
            assertTest(
                !tolerant.hasChanges(on: targetDay),
                "A re-pick differing only in case or spacing is not an edit, so the tick and the button "
                    + "agree about what the row already says")

            // ---- The text: written, trimmed, and compared ----

            // **The assertion that keeps `SAVE` live over an edit to the text alone.** `hasChanges(on:)`
            // carries a clause per field, and the text's is the one a form can lose without anyone
            // noticing: an edit draft over a stored row, written through `setNote(_:)` and nothing
            // else, must report a change — otherwise a user types a dream into the field, watches the
            // words appear, and finds `SAVE` still dark with nothing on screen explaining why. It is
            // the same class as the untouched-`DatePicker` assertion above and the opposite direction.
            var noteDraft = ReceptiveInactivityDraft(stored)
            noteDraft.setNote("  a long corridor with a door at the end  ")
            let noted = noteDraft.applying(to: targetDay)
            assertTest(
                noteDraft.hasChanges(on: targetDay),
                "Typing into the note alone is an edit — the third clause of `hasChanges(on:)` doing its "
                    + "work, and the assertion that fails if it is forgotten: the sheet would hold a "
                    + "filled-in field over a dead button")
            assertTest(
                noted?.name == "Dream" && noted?.note == "a long corridor with a door at the end",
                "…while `applying(to:)` carries the text **trimmed at both ends** and leaves the name "
                    + "alone, so the sheet's field and the stored value are one string rather than two "
                    + "differing by the padding a keyboard adds — the name is asserted beside it so this "
                    + "cannot pass over a draft that produced no entry at all "
                    + "(\(noted?.note.map { "\"\($0)\"" } ?? "nil"))")
            assertTest(
                noted?.id == stored.id,
                "…and the edit keeps the row's `id`, so the text is written onto the entry being edited "
                    + "rather than filed as a second one beside it — the pairing that makes a re-import "
                    + "revert this text rather than leave two rows carrying it")

            // **A blank field is *no* text, asserted as an indistinguishability rather than as a
            // value.** `stored` carries `nil`, so a `setNote(_:)` that stored `""` would report the row
            // as changed the moment the field was cleared and light `SAVE` over a form nobody had
            // touched — and the write behind that button would put an empty string on a column whose
            // whole vocabulary for *nothing was given* is NULL.
            var blankDraft = ReceptiveInactivityDraft(stored)
            blankDraft.setNote("   ")
            assertTest(
                !blankDraft.hasChanges(on: targetDay),
                "A whitespace-only field is **not an edit** over a row carrying no text, which is the "
                    + "assertion that fails if `setNote(_:)` writes `\"\"` instead of `nil`: on this "
                    + "column the two are different values and only one of them means *nothing was "
                    + "given*")
            assertTest(
                blankDraft.note == nil,
                "…and the draft holds no text at all rather than the whitespace it was handed, so the "
                    + "field the sheet binds to is empty in the same sense the column is "
                    + "(\(blankDraft.note.map { "\"\($0)\"" } ?? "nil"))")

            // The same rule on the *entry* rather than the draft, and on the case §11 step 6 walks: a
            // meditation saved with the text field untouched. Named here for the second time so the
            // first clause pins the row's existence — without it the note's own `nil` would be
            // unreachable and the assertion could pass over a draft that produced no row.
            var meditationDraft = ReceptiveInactivityDraft()
            meditationDraft.setName("Meditation")
            meditationDraft.setNote("   ")
            let meditation = meditationDraft.applying(to: targetDay)
            assertTest(
                meditation?.name == "Meditation" && meditation?.note == nil,
                "…and an entry saved with a blank field carries `nil` rather than `\"\"`, which is every "
                    + "meditation this app writes and every row that predates `v22` "
                    + "(\(meditation?.note.map { "\"\($0)\"" } ?? "nil"))")
        }

        // ---- The view model: the card's own read, and the two writers ----

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBReceptiveInactivityRepository(db: db)
            let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!

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
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                        biometricRepository: GRDBBiometricRepository(db: db)))
            }

            // The reader half: a row written straight to storage reaches the property the card draws
            // from, through the view model that draws it rather than through the repository — §14's
            // one-table-two-readers rule, and the assertion that fails if `load(for:)` forgets this
            // repository the way a new source is most likely to be forgotten.
            let soundBath = ReceptiveInactivity(
                date: day, name: "Sound bath", startedAt: day.addingTimeInterval(21 * 3600))
            try await repository.save(soundBath)
            await viewModel.load(for: day)
            let loaded = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            assertTest(
                loaded == ["Sound bath"],
                "`HomeViewModel.load(for:)` reaches the card through the view model that draws it "
                    + "(\(loaded))")

            let second = ReceptiveInactivity(
                date: day, name: "Meditation", startedAt: day.addingTimeInterval(7 * 3600))
            let inserted = await viewModel.saveReceptiveInactivity(second)
            let afterInsert = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            assertTest(inserted, "A new entry writes and reports success, so the sheet can dismiss")
            assertTest(
                afterInsert == ["Meditation", "Sound bath"],
                "…and it lands in the list in the read's own order rather than at the end, which is the "
                    + "re-sort's doing — an append would leave the card ordered by insertion "
                    + "(\(afterInsert))")

            // Editing in place keeps one row: `receptive_inactivities` is primary-keyed on `id` and
            // GRDB's `save` is INSERT-or-UPDATE, so a second entry here would mean the merge minted an
            // identity rather than reusing the one it was handed.
            let edited = ReceptiveInactivity(
                id: second.id, date: day, name: "Yoga nidra", startedAt: second.startedAt)
            let updated = await viewModel.saveReceptiveInactivity(edited)
            let afterUpdate = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            assertTest(updated && afterUpdate == ["Yoga nidra", "Sound bath"],
                       "An edit rewrites the entry in place rather than appending a second one "
                           + "(\(afterUpdate))")
            let storedCount = try await repository.getReceptiveInactivities(for: day).count
            assertTest(
                storedCount == 2,
                "…and storage holds two rows rather than three, read back independently of the list "
                    + "(\(storedCount))")

            // Clearing a time moves the entry to the untimed group at the end, which is the case the
            // local re-sort exists for — nothing else about the value changed.
            let untimedAgain = ReceptiveInactivity(
                id: second.id, date: day, name: "Yoga nidra", startedAt: nil)
            await viewModel.saveReceptiveInactivity(untimedAgain)
            let afterClearing = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            assertTest(
                afterClearing == ["Sound bath", "Yoga nidra"],
                "…and clearing its time moves it behind the timed entry, exactly where a fresh read of "
                    + "the day would put it (\(afterClearing))")

            // ---- Delete, on an id that matches nothing and then on one that does ----

            // **The absent id comes first, and it is asserted against storage as well as against the
            // list.** The store's affected-row count is what makes a delete honest: `false` is the
            // answer that stops a page dismissing itself over a row still on disk, and it has to arrive
            // without throwing, because an absent row is an ordinary answer rather than an error. Read
            // back from the repository rather than from the list, since the list half of that claim is
            // what a wrongly-implemented early return would leave untouched by accident.
            let missing = await viewModel.deleteReceptiveInactivity(UUID())
            let afterMissing = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            let stillStored = try await repository.getReceptiveInactivities(for: day).map(\.name)
            assertTest(
                !missing,
                "Deleting an id that is not stored reports `false` and throws nothing, so the row it "
                    + "did not remove cannot be read as one it did")
            assertTest(
                afterMissing == ["Sound bath", "Yoga nidra"]
                    && stillStored == ["Sound bath", "Yoga nidra"],
                "…and it takes nothing off either the list or storage, so a miss is a no-op on both "
                    + "readers rather than on the one the assertion above happens to look at "
                    + "(\(afterMissing) / \(stillStored))")
            let vanished = await MainActor.run { viewModel.errorMessage }
            assertTest(
                vanished == nil,
                "…and it leaves no error on the banner, because nothing went wrong "
                    + "(\(vanished ?? "nil"))")

            // The real one, and it is deliberately **the only thing that removes this row**: the local
            // removal below runs afterwards so that what is being asserted here is the delete and not a
            // preceding `removeReceptiveInactivity` that had already done the work. Read on both readers
            // again, because the claim is that they agree — a delete that dropped the row from the
            // list without reaching the store, or the reverse, fails on one side of this pair.
            let real = await viewModel.deleteReceptiveInactivity(second.id)
            let afterDelete = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            let remaining = try await repository.getReceptiveInactivities(for: day).map(\.name)
            assertTest(
                real && afterDelete == ["Sound bath"] && remaining == ["Sound bath"],
                "…while a real delete reports success and takes the row off the list *and* off "
                    + "storage, leaving the entry that was not named (\(afterDelete) / \(remaining))")

            // The local removal, which is what Home calls so a row the user just deleted stops being
            // drawn without re-reading the day — the mutation that would hide here is one that emptied
            // the list rather than dropping the id it was handed.
            await MainActor.run { viewModel.removeReceptiveInactivity(soundBath.id) }
            let afterRemove = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            assertTest(
                afterRemove.isEmpty,
                "`removeReceptiveInactivity` drops exactly the id it was handed (\(afterRemove))")
            await MainActor.run { viewModel.removeReceptiveInactivity(soundBath.id) }
            let afterNoOp = await MainActor.run { viewModel.receptiveInactivities.map(\.name) }
            assertTest(
                afterNoOp.isEmpty,
                "…and a second call with the same id is a no-op rather than a fault, since the row is "
                    + "already gone from the list (\(afterNoOp))")
        }

        // ---- The type has no second clock, and no state to be in ----

        // **The structural assertion, and the only form it can take here.** There is no renderer to
        // look at, so the claim *"a receptive inactivity has no span"* is asserted over the type's own
        // stored surface: five fields, and in particular no `endedAt`, no `durationSeconds` and no
        // in-progress flag. A later change that adds one — the natural way to "finish" the feature —
        // is a second clock and an `ACTIVE` state appearing on the card, and it fails here rather than
        // on a phone.
        //
        // **`note` is the fifth and it does not weaken the claim, which is why the list is widened
        // rather than the assertion dropped.** The rule this pins is about *clocks and derived state* —
        // nothing on this row can be computed from anything else on it — and a text payload is neither:
        // an imported dream's prose is supplied by the file, stored verbatim, and prints no range and no
        // state. `v22` added the column and the field together, so the two moved in one change and this
        // is the assertion that would otherwise have gone on passing over a type it no longer describes.
        let surface = Mirror(
            reflecting: ReceptiveInactivity(date: Date(), name: "Dream")
        ).children.compactMap(\.label)
        assertTest(
            surface == ["id", "date", "name", "note", "startedAt"],
            "A receptive inactivity stores five things and derives nothing, so there is no end instant "
                + "to print a range from and no state for the row to be `ACTIVE` in (\(surface))")

        // ---- The row that opens it ----

        // The sheet's title and the menu's row are the same words, and the menu's row is what the user
        // asked for: *"in place where there is option to add with plus sign add ability to 'ADD
        // RECEPTIVE INACTIVITY'"*. Asserted as a pair rather than as two literals, because a title that
        // drifted from the row that opens it would be two names for one surface and nothing on either
        // screen would say so.
        let receptiveRow = ActivityMenu.entries.first { $0.title == ReceptiveInactivitySheet.addTitle }
        assertTest(
            receptiveRow != nil,
            "The `+` menu carries a row titled exactly `\(ReceptiveInactivitySheet.addTitle)`, which is "
                + "the string the sheet's own header states — one name for one surface")
        assertTest(
            receptiveRow?.symbol == ActivityGlyph.receptiveMark,
            "…and it draws `ActivityGlyph.receptiveMark` (`\(ActivityGlyph.receptiveMark)`) rather than "
                + "a literal typed at the call site, so the mark has one definition "
                + "(\(receptiveRow?.symbol ?? "nil"))")
    }
}
