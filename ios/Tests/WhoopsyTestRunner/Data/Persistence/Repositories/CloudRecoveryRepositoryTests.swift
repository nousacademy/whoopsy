import Foundation
import Whoopsy

// MARK: - 22.3 The decorator: local first, the database on a miss, and what happens when it cannot

/// **The one block in §22 that drives a real database and a spy side by side**, because the claim it
/// exists for is a claim about *routing* and routing is only observable when the two stores disagree.
///
/// A local row and a cloud row are written on the same day holding different scores throughout. That is
/// the fixture shape rather than a convenience: with one store empty there is no way to tell a correct
/// route from a broken one, since a decorator that always read `local` and a decorator that always read
/// `cloud` would both answer `nil` on an empty day.
///
/// **What this file asserted before and why none of it is here.** The decorator used to *split* every
/// call at a `cutoff`: days before it were the database's, days at or after it were the phone's, and the
/// two halves of a history were disjoint by construction. Nothing belongs to a store now — the
/// destination says where data is *stored*, both stores hold whatever they were given, and a read asks
/// the cheap store first and falls back to the expensive one. So the boundary assertions are gone, the
/// split's "asks the database once, for exactly the days the window puts before the cutoff" is gone, and
/// what replaced them is the pair this file is now about: **the phone answers whenever it can**, and
/// **the database is asked exactly once, only under `.cloud`, and only for a day the phone missed**.
///
/// **The degradation half is the other half of the same argument.** Three `CloudSyncError` cases exist
/// because the three failures are not interchangeable — an unreachable database is a phone with no
/// signal, and the other two are a server and a client disagreeing — so what is asserted here is that
/// exactly one of them is caught, that the mark it leaves says *this day cannot be shown*, and that a
/// later successful read takes the mark away.
enum CloudRecoveryRepositoryTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped. Built by adding to today rather than subtracting
        /// from a literal, so the assertions hold on whatever day the suite runs — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        /// A measurement, so a row read back through either store carries `hasMeasurement`.
        let metric: (Date, Int) -> RecoveryMetric = { date, score in
            RecoveryMetric(date: date, score: score, hrvValueMs: Double(score) + 0.5, restingHeartRate: 55)
        }

        /// The same measurement as the cloud stores it — nine fields, `source` included, which is the
        /// field `RecoveryMetric` has no home for.
        let cloudRow: (Date, Int) -> RecoverySyncRow = { date, score in
            RecoverySyncRow(date: date, recoveryScore: score, restingHeartRate: 55,
                            hrvValueMs: Double(score) + 0.5, hrvMetric: .rmssd, source: "whoop_export")
        }

        /// A database, a destination and a status log, wired the way `DIContainer` wires them.
        func make(local rows: [(Date, Int)] = [],
                  cloud cloudRows: [RecoverySyncRow] = [],
                  settings: SyncSettings = SyncSettings()) async throws
        -> (CloudRecoveryRepository, SpyCloudSync, SyncStatusLog, LocalDatabaseManager) {
            let db = LocalDatabaseManager(inMemory: true)
            let store = GRDBRecoveryRepository(db: db)
            for (date, score) in rows {
                try await store.saveRecovery(metric(date, score), source: "whoop_export")
            }
            let spy = SpyCloudSync(rows: cloudRows)
            let status = SyncStatusLog()
            let repository = CloudRecoveryRepository(
                local: store,
                cloud: spy,
                settingsStore: InMemorySyncSettingsRepository(settings),
                status: status,
                calendar: calendar)
            return (repository, spy, status, db)
        }

        // MARK: Under `.device` the decorator is transparent, and that is the shipping default

        // The state every user is in until they open the pane, and the state a user who never opens it
        // stays in for the life of the install. The assertion that carries it is the spy's empty call
        // list: a decorator that asked the database and then decided not to use the answer would pass
        // every figure assertion below and open a socket on every screen open.
        do {
            let (repository, spy, status, _) = try await make(local: [(day(-45), 55)])
            let read = try await repository.getRecovery(for: day(-45))
            assertTest(read?.score == 55, "Under `device` a day is read from the phone")

            let history = try await repository.getRecoveryHistory(days: 2, endingOn: day(-45))
            assertTest(history.map(\.score) == [55], "…and so is a history")

            // A day the phone does not hold is `nil` rather than a request. This is the half that a
            // figures-only assertion cannot see: falling back to the database here would draw the
            // database's figure on a pane whose own switch says this phone is where days live.
            let missing = try await repository.getRecovery(for: day(-40))
            assertTest(missing == nil, "…and a day it does not hold is absent rather than fetched")

            let untouched = await spy.calls.isEmpty
            assertTest(untouched, "…so the database is never asked, for any of the three reads")
            let unmarked = await status.unavailableDays()
            assertTest(unmarked.isEmpty, "…and nothing is marked, because nothing was unreachable")
        }

        // MARK: Under `.cloud` the phone still answers first, and that ordering is the design

        do {
            // One day, two figures: 12 is on the phone and 81 is the database's copy of the same day.
            let (repository, spy, _, _) = try await make(
                local: [(day(-45), 12)],
                cloud: [cloudRow(day(-45), 81)],
                settings: SyncSettings(destination: .cloud))

            let read = try await repository.getRecovery(for: day(-45))
            assertTest(read?.score == 12,
                       "A day the phone holds is answered from the phone even under `cloud` — local "
                           + "first is the order the whole design rests on, and the database's 81 for "
                           + "the same day is the assertion that catches a decorator that asked it anyway")

            // The two reads are asked for *no day at all*, which is stronger than "asked for the right
            // day": a request that was made and discarded is still a round trip on every screen open.
            let neverAsked = await spy.calls.isEmpty
            assertTest(neverAsked, "…and the database is not asked for it at all")

            // `getLocalRecovery` is the port's documented constraint, so this is the assertion that
            // fails if the decorator ever routes it: the answer is the phone's own row, and the
            // database is not reached for it under a destination that would otherwise permit it.
            let local = try await repository.getLocalRecovery(for: day(-45))
            assertTest(local?.score == 12, "…while the phone's own copy is still 12, on the same day")
            let stillNothing = await spy.calls.isEmpty
            assertTest(stillNothing, "…and reading it locally did not reach for the database either")
        }

        // MARK: A day the phone missed is the database's, and the fallback is one request

        do {
            let (repository, spy, status, _) = try await make(
                cloud: [cloudRow(day(-45), 81)],
                settings: SyncSettings(destination: .cloud))

            let fetched = try await repository.getRecovery(for: day(-45))
            assertTest(fetched?.score == 81, "A day the phone does not hold is fetched from the database")

            let asked = await spy.readDays
            assertTest(asked == [day(-45)], "…and the database was asked for exactly that day, once")
            let ranges = await spy.readRanges
            assertTest(ranges.isEmpty,
                       "…as a day and not as a range: a single-day read that went through "
                           + "`recoveries(from:to:)` would fetch a window to answer one date")

            // **A fetched day is not written to the phone**, and this is the assertion that keeps it so.
            // Caching it would make the phone's own table depend on which screens the user happened to
            // open, and it would be this app moving data between stores — the one thing the pane
            // promises it never does.
            let notCached = try await repository.getLocalRecovery(for: day(-45))
            assertTest(notCached == nil, "…and it is not written to the phone, because a read is a read")

            // A successful read clears the mark, whether or not it found a row. This is the second half
            // of the note's own argument: a mark that could only be written would go on claiming a day
            // cannot be shown after it was fetched, or after the database said plainly that it holds
            // nothing for it — and *not measured* is not *unreachable*.
            let cleared = await status.unavailableDays()
            assertTest(cleared.isEmpty, "…and a day the database answered for carries no mark")
        }

        // MARK: A database that cannot be reached degrades, and the mark says which absence it is

        do {
            // Two days, and the second is the one the recovery half below needs: `day(-45)` is on the
            // phone and `day(-40)` is only in the database, so the first is answered without a request
            // whatever the connection is doing and the second is the day the outage actually costs.
            let (repository, spy, status, _) = try await make(
                local: [(day(-45), 12)],
                cloud: [cloudRow(day(-45), 81), cloudRow(day(-40), 66)],
                settings: SyncSettings(destination: .cloud))
            await spy.fail(with: .unreachable(message: "The database could not be reached."))

            // The phone's copy is drawn and nothing is marked: this day *can* be shown, so a mark
            // saying it cannot would be a false sentence on the screen — the same argument the write
            // path's swallow is made of, seen from the read side.
            let kept = try await repository.getRecovery(for: day(-45))
            assertTest(kept?.score == 12, "With the database down, the phone's copy still draws its figure")
            let notMarked = await status.unavailableDays()
            assertTest(notMarked.isEmpty,
                       "…and nothing is marked, because a day the phone can show is not unavailable")

            // The absence the mark exists for: a day neither store can answer. `nil` is the honest
            // answer and the mark is the only thing separating *needs a connection* from *never
            // measured* — which is the app's standing rule about absence seen from the other side.
            let gone = try await repository.getRecovery(for: day(-40))
            assertTest(gone == nil, "A day with no copy on the phone draws nothing while the database is down")
            let unavailable = await status.unavailableDays()
            assertTest(unavailable == [day(-40)], "…and is marked as needing a connection")

            // The mark is per-process and lasts until something removes it, so a database that comes
            // back has to take its own mark away — otherwise the morning's outage labels the
            // afternoon's successful read, and the reader is told a figure may be behind when it is not.
            await spy.fail(with: nil)
            let recovered = try await repository.getRecovery(for: day(-40))
            assertTest(recovered?.score == 66, "A database that answers again is read again")
            let cleared = await status.unavailableDays()
            assertTest(cleared.isEmpty, "…and the mark is cleared rather than left over it")

            // A day the phone holds never reaches the database, so a failure cannot mark it — asserted
            // after the mark above was set, so this is a claim about a *new* day rather than about an
            // empty set.
            await spy.fail(with: .unreachable(message: "The database could not be reached."))
            let localDay = try await repository.getRecovery(for: day(-45))
            assertTest(localDay?.score == 12, "A day the phone holds is answered while the database is down")
            let stillEmpty = await status.unavailableDays()
            assertTest(stillEmpty.isEmpty, "…and is not marked, because it was never asked of the database")
        }

        // MARK: A refusal and a malformed answer are not outages, and both propagate

        // The asymmetry is the reason `CloudSyncError` has three cases. Degrading over a refusal would
        // put the phone's number on a screen where the server was saying the request was wrong, and
        // degrading over a malformed answer would hide a client and a server disagreeing about the
        // shape of a day — a wrong figure rather than a missing one.
        do {
            let (repository, spy, status, _) = try await make(
                cloud: [cloudRow(day(-45), 81)],
                settings: SyncSettings(destination: .cloud))
            await spy.fail(with: .rejected(code: "invalid_request", message: "The day was not sent."))

            do {
                _ = try await repository.getRecovery(for: day(-45))
                assertTest(false, "A refusal propagates rather than degrading to an absent day")
            } catch let error as CloudSyncError {
                assertTest(error == .rejected(code: "invalid_request", message: "The day was not sent."),
                           "…as the refusal itself")
            } catch {
                assertTest(false, "…as a CloudSyncError rather than something else")
            }

            // A refusal is not an outage, so nothing is marked: the pane must not tell a reader a day
            // may be behind when the app was told its request was wrong.
            let unmarked = await status.unavailableDays()
            assertTest(unmarked.isEmpty, "…and it leaves no mark, because nothing was unreachable")

            await spy.fail(with: .malformed(message: "the answer carried a day this app cannot read: 2026-02-31"))
            do {
                _ = try await repository.getRecovery(for: day(-45))
                assertTest(false, "A malformed answer propagates rather than degrading")
            } catch let error as CloudSyncError {
                guard case .malformed = error else {
                    assertTest(false, "…as the malformed case, not another one")
                    return
                }
                assertTest(true, "…as the malformed case")
            } catch {
                assertTest(false, "…as a CloudSyncError rather than something else")
            }
        }

        // MARK: A history propagates the very error a single day degrades over

        // The pair is the block, and it is the same asymmetry `getRecoveryHistory`'s own doc comment
        // argues: one day has somewhere to hang a sentence, so answering it with a mark is honest and
        // complete; a history has no such place, and a truncated merge is a shorter array, which every
        // screen in this app draws as *you did not measure these days* — about days the database holds.
        do {
            let (repository, spy, _, _) = try await make(
                local: [(day(-2), 43)],
                cloud: [cloudRow(day(-6), 74)],
                settings: SyncSettings(destination: .cloud))
            await spy.fail(with: .unreachable(message: "The database could not be reached."))

            let single = try await repository.getRecovery(for: day(-6))
            assertTest(single == nil,
                       "The same outage on a single day degrades — the phone has no copy, so nothing is "
                           + "drawn and a mark is left")
            let marked = try await repository.getLocalRecovery(for: day(-2))
            assertTest(marked?.score == 43, "…while a day the phone does hold is unaffected by it")

            do {
                _ = try await repository.getRecoveryHistory(days: 6, endingOn: day(0))
                assertTest(false, "…and on a history it propagates rather than returning a short array")
            } catch let error as CloudSyncError {
                assertTest(error == .unreachable(message: "The database could not be reached."),
                           "…as the same unreachable error")
            } catch {
                assertTest(false, "…as a CloudSyncError rather than something else")
            }

            // The half the throw protects is the *local* one: the phone's own days were read before the
            // request was made, and a decorator that returned them would be answering a merge request
            // with one store's rows under a screen that cannot tell the difference. Disarming the spy is
            // what makes this a claim about the merge rather than a second reading of the throw.
            await spy.fail(with: nil)
            let localOnly = try await repository.getRecoveryHistory(days: 2, endingOn: day(-2))
            assertTest(localOnly.map(\.score) == [43],
                       "…and once the database answers again the window is the phone's day, with nothing "
                           + "added to it — the same day, from the same store, as an ordinary read")
        }

        // MARK: A history is a merge, and the phone's row wins on a day both hold

        // A window covering both stores, with a deliberate overlap on `day(-4)`: the database holds 58
        // there and the phone holds 33. The scores are distinct so the merged array pins membership *and*
        // order, and the overlapping day pins precedence — which is the property the old split got for
        // free by keeping the two halves disjoint. `day(-7)` is seeded in the database and deliberately
        // *outside* the window, so its absence is the range bound's assertion rather than an accident of
        // what was seeded; `day(0)` is inside the window and on neither store, so its absence is the
        // ordinary one.
        do {
            let cloudDays = [cloudRow(day(-7), 52), cloudRow(day(-6), 74),
                             cloudRow(day(-5), 61), cloudRow(day(-4), 58)]
            let localDays = [(day(-4), 33), (day(-3), 43), (day(-2), 55), (day(-1), 47)]
            let (repository, spy, _, _) = try await make(
                local: localDays,
                cloud: cloudDays,
                settings: SyncSettings(destination: .cloud))

            let history = try await repository.getRecoveryHistory(days: 6, endingOn: day(0))
            assertTest(history.map(\.date) == [day(-6), day(-5), day(-4), day(-3), day(-2), day(-1)],
                       "A straddling window draws every day the two stores hold, oldest first, and no day "
                           + "the window does not name — `day(-7)` is in the database and outside it")
            assertTest(Set(history.map(\.date)).count == 6,
                       "…which is six distinct days, not seven slots — the overlap on `day(-4)` is keyed "
                           + "rather than concatenated, and a concatenating merge would draw that day twice")
            assertTest(history.map(\.score) == [74, 61, 33, 43, 55, 47],
                       "…and the phone's 33 wins on the day both stores hold, because the phone's figure "
                           + "is the one this app computed")

            // The window is asked for once and as a range, half-open at the top: `days: 6` from `day(0)`
            // is seven days inclusive, so the request covers `[day(-6), day(0)]`. `startOfNextDay` and
            // not `endOfDay` is this repo's half-open rule — `23:59:59` is the last instant of a day, and
            // a bound one second short drops a row written at midnight.
            let ranges = await spy.readRanges
            assertTest(ranges.count == 1, "A history asks the database once, not once per day")
            if let range = ranges.first {
                assertTest(range.from == day(-6) && range.to == day(0).startOfNextDay,
                           "…for exactly the days the window names, to the first instant of the day "
                               + "after its last")
            } else {
                assertTest(false, "…and there is a range to read")
            }

            let noSingleReads = await spy.readDays.isEmpty
            assertTest(noSingleReads, "…and not for the days one at a time")

            // A window the database holds nothing in is the phone's window, unchanged — the merge's
            // *nothing was added* arm, which is a different state from an empty result and is the one a
            // destination flipped on a phone holding history actually produces.
            let phoneOnly = try await repository.getRecoveryHistory(days: 1, endingOn: day(-1))
            assertTest(phoneOnly.map(\.score) == [55, 47],
                       "A window the database holds nothing in is the phone's window, unchanged")
        }

        // A destination with no span and no rows anywhere is still not an error.
        do {
            let (repository, _, _, _) = try await make(settings: SyncSettings(destination: .cloud))
            let history = try await repository.getRecoveryHistory(days: 6, endingOn: day(0))
            assertTest(history.isEmpty,
                       "A range neither store holds comes back empty rather than throwing")
        }

        // MARK: Writing — the phone first, always, and then the database when the destination says so

        do {
            // Under `device` the write never leaves the phone, and nothing is sent. This is the half of
            // *a destination is a switch* that a read assertion cannot see: a day written while the
            // phone is the destination must not be pushed to a database the user has not chosen.
            let (repository, spy, _, _) = try await make()
            try await repository.saveRecovery(metric(day(-45), 70), source: "whoop_export")

            let untouched = await spy.calls.isEmpty
            assertTest(untouched, "Under `device` a write reaches the phone and nothing else")
            let stored = try await repository.getLocalRecovery(for: day(-45))
            assertTest(stored?.score == 70, "…and the day is on the phone, which is where it was going")
        }

        do {
            let (repository, spy, status, _) = try await make(settings: SyncSettings(destination: .cloud))
            try await repository.saveRecovery(metric(day(-45), 70), source: "whoop_export")

            let written = await spy.storedRow(on: day(-45))
            assertTest(written?.recoveryScore == 70, "Under `cloud` a day is sent to the database")
            assertTest(written?.source == "whoop_export", "…carrying the provenance the entity cannot hold")
            assertTest(written?.hrvValueMs == 70.5, "…and its measured fields")

            // **The phone's copy is written too, and unconditionally.** It used to be conditional on a
            // `localCopyPolicy` — and under `delete` a day existed only in the database, which is what
            // the delete that policy was for left behind. Nothing purges either store now, so the
            // phone's row is the one that is always right, because it is the one this app computed.
            let copy = try await repository.getLocalRecovery(for: day(-45))
            assertTest(copy?.score == 70, "…and the phone's copy is written beside it, whatever the "
                           + "destination — there is no policy left that could withhold it")

            let oneWrite = await spy.writtenRows.count
            assertTest(oneWrite == 1, "…in one write, not a read and a write")
            let cleared = await status.unavailableDays()
            assertTest(cleared.isEmpty, "…and the day carries no mark, because it is now in both stores")
        }

        // The phone's row survives a push the database refuses, and the refusal still surfaces.
        //
        // **The ordering is the whole point.** The local write returns before the request is made, so a
        // failure there leaves the day exactly as it should be — saved, and not yet in the database —
        // rather than in the state the old cloud-first order produced, where a refused upload left the
        // day on neither store and the reader with no figure at all.
        do {
            let (repository, spy, status, _) = try await make(settings: SyncSettings(destination: .cloud))
            await spy.fail(with: .rejected(code: "invalid_request", message: "The day was not sent."))

            do {
                try await repository.saveRecovery(metric(day(-45), 70), source: nil)
                assertTest(false, "A refused write surfaces rather than being swallowed")
            } catch let error as CloudSyncError {
                assertTest(error == .rejected(code: "invalid_request", message: "The day was not sent."),
                           "…as the refusal it is")
            } catch {
                assertTest(false, "…as a CloudSyncError rather than something else")
            }

            let keptLocally = try await repository.getLocalRecovery(for: day(-45))
            assertTest(keptLocally?.score == 70,
                       "…and the phone keeps the day regardless, because it was written first — the "
                           + "local save is never conditional on the request")
            let unmarked = await status.unavailableDays()
            assertTest(unmarked.isEmpty,
                       "…and a refusal marks nothing, because a refusal is not an outage")

            // An unreachable database is the one case that is swallowed, and it is swallowed *silently*
            // — no mark at all. Every mark this app has would say something false here: a day the phone
            // holds is not *unavailable*, and what reconciles a day the database missed is the `SYNC`
            // button rather than a per-day record of *not pushed yet*, which would be the boundary
            // bookkeeping this design deleted, rebuilt one row at a time.
            await spy.fail(with: .unreachable(message: "The database could not be reached."))
            do {
                try await repository.saveRecovery(metric(day(-44), 64), source: nil)
                assertTest(true, "An unreachable database does not fail a write that landed on the phone")
            } catch {
                assertTest(false, "…and does not surface, because the local row is already saved")
            }
            let savedAnyway = try await repository.getLocalRecovery(for: day(-44))
            assertTest(savedAnyway?.score == 64, "…which it is, holding the figure that was handed in")
            let stillUnmarked = await status.unavailableDays()
            assertTest(stillUnmarked.isEmpty,
                       "…and nothing is marked, because this day can be shown — it is on the phone, "
                           + "which is where the read goes first")
        }
    }
}
