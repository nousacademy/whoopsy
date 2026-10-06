import Foundation
import Whoopsy

// MARK: - 22.5 The run: one engine, seven resources, and the walk they all share

/// **The block that drives a whole run**, over a real `LocalDatabaseManager(inMemory: true)` for all
/// seven stores and `SpyCloudSync` for the far side. Nothing here opens a socket and nothing here can:
/// `CloudSync` is the seam, so what is asserted is the walk's own arithmetic — the ceiling, the skip
/// count, the chunk boundary — and never the Worker's answer.
///
/// **Why a real database rather than seven store doubles.** The engine was built as one walk over a
/// *value*, and what can still go wrong is the pairing: a descriptor wired to the wrong store would walk
/// `sleeps` and call `writeStrains`. A double per store would let that pass, because a double answers
/// whatever it is asked; the real manager answers only for its own table, so a crossed wire shows up as a
/// resource that moved zero rows while its rows sat on disk.
///
/// **The engine reads nothing, and that is asserted rather than assumed.** `CloudSync` has six read
/// methods and a run calls none of them: a day coming *down* is the read path answering a screen that
/// asked for it, which is `CloudRecoveryRepository`'s business and not a press of `SYNC`. A run that read
/// would not be wrong so much as a second, silently disagreeing answer to the same question.
///
/// **Every block below that gets as far as a run asserts `neverRead`**, and the two that refuse before
/// sending assert the call list is empty outright — so *a run only writes* is said once per path rather
/// than once per file.
enum SyncEngineTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped. Built by adding to today rather than subtracting
        /// from a literal, so the assertions hold on whatever day the suite runs — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        /// A recovery row on a day, scored inside the band the server accepts and with every value
        /// derived from the day so two rows never compare equal by accident.
        let recovery: (Int) -> RecoverySyncRow = { offset in
            RecoverySyncRow(date: day(offset), recoveryScore: 40 + abs(offset) % 60,
                            restingHeartRate: 55, hrvValueMs: 41, hrvMetric: .rmssd)
        }

        // MARK: A run with no span refuses before it touches anything

        // The pane withholds `SYNC` in both of these states, so reaching the engine with one means a
        // caller asked for something that is not a thing. The refusal is a throw rather than seven
        // summaries reading *nothing to send*: an array of zeroes looks like a completed run.
        do {
            let (engine, _, spy, _) = makeEngine(SyncSettings())
            do {
                _ = try await engine.run()
                assertTest(false, "A run with no span drawn is refused rather than answered")
            } catch let error as SyncError {
                assertTest(error == .nothingToDo, "…with `nothingToDo`, which is the pane's own state")
            }
            assertTest(await spy.calls.isEmpty, "…and nothing was asked of the far side")
        }

        do {
            let (engine, _, spy, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-5), to: day(-5))))
            do {
                _ = try await engine.run()
                assertTest(false, "A span whose ends are the same day is refused too")
            } catch let error as SyncError {
                assertTest(error == .nothingToDo, "…with the same `nothingToDo`, because it covers no days")
            }
            assertTest(await spy.calls.isEmpty, "…and again nothing was asked")
        }

        // MARK: The engine covers the seven the pane draws, in the pane's own order

        // The two lists are derived from different places — the pane's from `SyncedResource.allCases`,
        // the engine's from the table in `SyncResources` — so this is asserted one against the other
        // rather than either against a literal typed twice. A resource the pane promises and the engine
        // does not hold is a title on a screen over nothing; the reverse is a transfer the user cannot
        // see, which is the worse of the two because nothing on the screen would ever say so.
        do {
            let (engine, _, _, _) = makeEngine(SyncSettings())
            assertTest(engine.resourceNames == SyncedResource.allCases,
                       "The engine's resources are the pane's list, in the pane's order")
            assertTest(engine.resourceNames.count == 7, "…and there are seven of them")
        }

        // MARK: The ceiling is a per-resource bound, applied before the resource is read

        do {
            let (engine, db, spy, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-4001), to: day(0))))
            try await db.saveSyncRows([recovery(-10)])

            do {
                _ = try await engine.run()
                assertTest(false, "A span wider than the server will answer for is refused")
            } catch let error as SyncError {
                assertTest(error == .rangeTooWide(days: 4000),
                           "…by the resource's own ceiling, carried in the error so the sentence can "
                               + "name the number rather than only the fact")
            }
            assertTest(await spy.calls.isEmpty,
                       "…and no request is spent on it. The check is before the read, so an over-wide "
                           + "span costs nothing at all rather than half a run, and the day on disk was "
                           + "never even looked at")
        }

        // The boundary itself, from the other side: one day more is refused, the ceiling's own width is
        // not. `>` and not `>=` — a run that refused its own ceiling would refuse a span the server
        // would have answered, and the pane's sentence would be the only place it showed.
        do {
            let (engine, _, _, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-4000), to: day(0))))
            let results = try await engine.run()
            assertTest(results.count == 7, "A span exactly as wide as the ceiling runs")
        }

        // MARK: A span over days this phone never measured costs no request at all

        do {
            let (engine, _, spy, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-4000), to: day(-3990))))
            let results = try await engine.run()

            assertTest(results.count == 7, "An empty database still answers once per resource")
            assertTest(results.allSatisfy { $0.summary.rows == 0 && $0.summary.skipped == 0 },
                       "…with nothing moved and nothing skipped, which is not an error")
            assertTest(results.map(\.summary.direction) == Array(repeating: .upload, count: 7),
                       "…because the one verb a run has is sending")
            assertTest(results.map(\.summary.unit) == [.profile, .entry, .day, .day, .day, .day, .session],
                       "…and each resource's count is named in its own words, which is what the pane's "
                           + "sentence reads: four resources key one row to a day, a session and an "
                           + "entry are two different tables where a day holds several, and a profile "
                           + "is a singleton")
            assertTest(results.map(\.resource) == SyncedResource.allCases,
                       "…in the pane's order, so the two lines the pane prints are in the order it drew")
            assertTest(await spy.calls.isEmpty,
                       "…and the far side was never contacted: a chunk is written only when it has a row")
            assertTest(await neverRead(spy), "…and nothing was read, on any of the port's six read methods")
        }

        // MARK: An unsendable row is counted, is not sent, and does not fail its chunk

        // Three days of steps, and the middle one is the shape this whole gate exists for: the strap was
        // not worn, so `measuredSeconds` is zero — which on this app is *no measurement* and on the wire
        // is a legal reading of zero steps. Sending it would create a measurement on the far side that
        // this app reports as absent, and `POST /batch` is one all-or-nothing transaction, so the naive
        // fix (send it and let the server refuse) would cost the other day in the same request.
        do {
            let (engine, db, spy, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-10), to: day(0))))
            try await db.saveSyncStepCountRows([
                StepCountSyncRow(date: day(-3), stepCount: 8_412, measuredSeconds: 61_200),
                StepCountSyncRow(date: day(-2), stepCount: 0, measuredSeconds: 0),
                StepCountSyncRow(date: day(-1), stepCount: 11_903, measuredSeconds: 70_400),
            ])

            let results = try await engine.run()
            guard let steps = results.first(where: { $0.resource == .stepCounts })?.summary else {
                assertTest(false, "The run answered for the step counts")
                return
            }

            assertTest(steps.rows == 2, "The two measured days were sent")
            assertTest(steps.skipped == 1, "…and the unmeasured one is counted rather than quietly dropped")
            assertTest(steps.message == "Uploaded 2 days. 1 day could not be sent and is still on this phone.",
                       "…in the sentence the pane prints, which names the count and says where the row "
                           + "stayed — a run that discarded part of a span and reported it as finished is "
                           + "the failure this count exists to make visible")

            let sent = await spy.writtenStepCounts
            assertTest(sent.count == 2, "The request held the two sendable days")
            assertTest(!sent.contains { $0.date == day(-2) },
                       "…and not the unmeasured one, which is what keeps its whole chunk legal")

            let stillHere = try await db.syncStepCountRows(from: day(-10), to: day(0))
            assertTest(stillHere.count == 3, "…and it is still on this phone, because nothing here deletes")

            // The skip belongs to the resource and not to the run: the six beside it moved zero and
            // skipped zero, because a span with no rows in it is an empty span and not a refusal.
            assertTest(results.filter { $0.resource != .stepCounts }.allSatisfy { $0.summary.skipped == 0 },
                       "Every other resource skipped nothing")
            assertTest(await neverRead(spy), "…and the run still read nothing")
        }

        // MARK: A chunk boundary lands between days, and the chunks together are the span

        // Four hundred and fifty days against a batch size of two hundred is two full chunks and a
        // remainder, which is the only place the boundary arithmetic shows. The assertion that matters is
        // the union: no day in two chunks and no day dropped, which is the same half-open guarantee
        // `syncRows(from:to:)` gives a range — a shared instant between two chunks would be one day sent
        // twice, and a bound one day short would lose the day at the seam.
        do {
            let (engine, db, spy, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-450), to: day(0))))

            let offsets = (0 ..< 450).map { -450 + $0 }
            try await db.saveSyncRows(offsets.map(recovery))

            let results = try await engine.run()
            guard let recoveries = results.first(where: { $0.resource == .recoveries })?.summary else {
                assertTest(false, "The run answered for the recoveries")
                return
            }

            let requests: [[RecoverySyncRow]] = await spy.calls.compactMap { call in
                guard case let .writeRecoveries(rows) = call else { return nil }
                return rows
            }
            assertTest(requests.map(\.count) == [200, 200, 50],
                       "A four-hundred-and-fifty-day span is cut into two full requests and a remainder")
            assertTest(recoveries.rows == 450,
                       "…and the run reports the 450 the database said it wrote, summed over the chunks")

            let sentDays = requests.flatMap { $0.map(\.date) }
            assertTest(sentDays.count == 450, "…one row per day across the three requests")
            assertTest(Set(sentDays).count == 450, "…and no day in two chunks")
            assertTest(sentDays == sentDays.sorted(), "…in ascending order, across the boundaries as well as within them")
            assertTest(Set(sentDays) == Set(offsets.map(day)),
                       "…and the chunks together are exactly the span's days: nothing at a seam was "
                           + "dropped and nothing was doubled")
            assertTest(await neverRead(spy), "…and again, a run only writes")
        }

        // MARK: A refusal stops the run, and what landed before it stays landed

        // Seven independent sends and not one transaction, which is safe because every write on the far
        // side is an INSERT-or-UPDATE on the row's own key: re-pressing the button re-sends all seven with
        // the same values. What the stop costs is the sentence about the resources that did finish, which
        // is why the failure is thrown rather than folded into the returned array.
        do {
            let (engine, db, spy, _) = makeEngine(
                SyncSettings(range: SyncSettings.SyncRange(from: day(-3), to: day(0))))
            try await db.saveSyncReceptiveInactivityRows([
                ReceptiveInactivitySyncRow(id: UUID().uuidString, date: day(-2), name: "Meditation",
                                           note: nil, startedAt: nil),
            ])
            try await db.saveSyncRows([recovery(-2)])

            await spy.fail(with: .rejected(code: "invalid_body", message: "no"))

            do {
                _ = try await engine.run()
                assertTest(false, "A refused write fails the run rather than being folded into a summary")
            } catch let error as CloudSyncError {
                assertTest(error == .rejected(code: "invalid_body", message: "no"),
                           "…with the transport's own error, unwrapped — the pane switches on it directly "
                               + "and a wrapper here would be one failure presented two ways")
            }

            assertTest(await spy.writtenInactivities.count == 1,
                       "…and the resource that landed before the refusal is still written: the run stops "
                           + "at the first failure and does not unwind the ones that finished")
            assertTest(await spy.writtenRows.isEmpty,
                       "…while the refused resource reached the far side with nothing: it was read off "
                           + "the phone and never sent, so there is no half-written chunk to reason about")
            assertTest(await neverRead(spy), "…and even a failing run read nothing")
        }

        // MARK: The destination is a switch and the span is a transfer

        // **The user's own ruling, as an assertion**: *"if a DB is selected, it doesnt purge anything, it
        // just switches where data will be stored to."* Switching moves nothing, so the strongest form of
        // it is that the far side is never contacted and the settings are written exactly once.
        do {
            let (engine, _, spy, settings) = makeEngine(SyncSettings())
            let switched = await engine.setDestination(.cloud)
            assertTest(switched.destination == .cloud, "Switching the destination answers with the new settings")
            assertTest(await settings.load().destination == .cloud, "…and stores them")
            assertTest(await spy.calls.isEmpty, "…and sends no row and fetches none, on either arm")
            assertTest(await settings.saveCount == 1, "…because it is one write of the settings and not a run")
        }

        // And the span, which is the one control that *is* a transfer — drawn on its own, before the
        // button, so that a run which fails cannot lose the range the user chose.
        do {
            let (engine, _, _, settings) = makeEngine(SyncSettings())
            let drawn = await engine.setRange(from: day(-7), to: day(0))
            assertTest(drawn.range == SyncSettings.SyncRange(from: day(-7), to: day(0)),
                       "A drawn span is stored as the one pair the run reads")

            let half = await engine.setRange(from: day(-7), to: nil)
            assertTest(half.range == nil,
                       "…and a half-drawn span stores nothing rather than one end of something that is "
                           + "not a span — the pane's two pickers are where that half-state lives")

            let cleared = await engine.setRange(from: nil, to: nil)
            assertTest(cleared.range == nil, "…and clearing both ends clears the span")
            assertTest(await settings.saveCount == 3, "…one write each, and no run anywhere in it")
        }
    }
}

// MARK: - Helpers

/// One engine over one in-memory database, one spy cloud and one settings store.
///
/// **All seven stores are the same `LocalDatabaseManager`**, which is what the app does: `DIContainer`
/// hands `SyncResources.all` one manager for all seven, because each resource's door into its own table
/// is a bare extension on it and a phone has one database. A block that wanted to prove a *crossed* wire
/// would have to hand in seven managers and seed them differently; what catches it here instead is that
/// each resource's rows are in its own table, so a descriptor pointed at a sibling's store moves zero.
///
/// The settings store is handed back as well as the engine, because a block that changed the span and
/// then rebuilt would be asserting a fresh object rather than the same one.
private func makeEngine(_ settings: SyncSettings) -> (
    engine: SyncEngine,
    db: LocalDatabaseManager,
    spy: SpyCloudSync,
    settings: InMemorySyncSettingsRepository
) {
    let db = LocalDatabaseManager(inMemory: true)
    let spy = SpyCloudSync()
    let store = InMemorySyncSettingsRepository(settings)
    let engine = SyncEngine(
        resources: SyncResources.all(
            cloud: spy,
            profileStore: db,
            inactivityStore: db,
            recoveryStore: db,
            sleepStore: db,
            stepCountStore: db,
            strainStore: db,
            workoutStore: db),
        settingsStore: store)
    return (engine, db, spy, store)
}

/// Whether a spy was never asked a question, on any of the port's six read methods.
///
/// **A run is a transfer out, and these six collectors are its whole evidence.** The read path belongs to
/// `CloudRecoveryRepository`, which answers a screen asking for a day it does not hold — so a run that
/// read would be a second answer to the same question, arriving from a caller nobody asked. Written as
/// one predicate because six `isEmpty` assertions per block, four times over, is a line a later edit
/// drops without noticing.
private func neverRead(_ spy: SpyCloudSync) async -> Bool {
    let recoveriesByRange = await spy.readRanges
    let recoveriesByDay = await spy.readDays
    let strainsByRange = await spy.readStrainRanges
    let strainsByDay = await spy.readStrainDays
    let workoutsByRange = await spy.readWorkoutRanges
    let workoutsById = await spy.readWorkoutIds

    return recoveriesByRange.isEmpty && recoveriesByDay.isEmpty
        && strainsByRange.isEmpty && strainsByDay.isEmpty
        && workoutsByRange.isEmpty && workoutsById.isEmpty
}
