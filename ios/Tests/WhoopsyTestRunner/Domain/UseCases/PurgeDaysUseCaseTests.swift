import Foundation
import Whoopsy

/// The purge's own rules: what it refuses, which side it visits first, and what it does when the
/// database cannot be reached.
///
/// **The block that matters is the third one.** Every other operation in this app may degrade to the
/// local copy when the API is unreachable, because a missing figure is acceptable and a wrong one is
/// not. A delete has nothing to degrade *to* — a local removal without the database's is a cache
/// eviction, and `docs/GOTCHAS.md` records the day that came back — so the assertion here is that a
/// failed cloud call leaves **every local row exactly where it was**, not that it reports an error.
enum PurgeDaysUseCaseTests {

    /// A `DayPurgeStore` that counts its calls and removes nothing, so a block can tell "the database
    /// was asked" from "it was not" without a real table.
    actor CountingPurgeStore: DayPurgeStore {
        private(set) var calls: [(from: Date, to: Date)] = []

        func purgeMeasuredDays(from: Date, to: Date) async throws -> DayPurgeTally {
            calls.append((from: from, to: to))
            var tally = DayPurgeTally()
            tally.recoveries = 1
            tally.samples = 100
            return tally
        }
    }

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: -2, to: today)!

        // ── A device-destination purge never reaches the port ──────────────────────────────────────
        do {
            let cloud = SpyCloudSync()
            let store = CountingPurgeStore()
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .device))
            let useCase = PurgeDaysUseCase(cloud: cloud, store: store, settingsStore: settings)

            let report = try await useCase.run(from: first, to: today)

            let calls = await cloud.calls
            assertTest(calls.isEmpty,
                       "With DEVICE STORAGE there is nothing on the server to remove, so the port is "
                           + "not called at all: \(calls)")
            assertTest(report.remote == nil,
                       "…and the report says the database was never asked, rather than reporting a "
                           + "zero it did not measure")
            assertTest(report.days == 3, "The range is counted inclusive at both ends (got \(report.days))")
            let storeCalls = await store.calls
            assertTest(storeCalls.count == 1, "…and the phone was asked once")
        }

        // ── A cloud-destination purge asks the database first, then the phone ─────────────────────
        do {
            let cloud = SpyCloudSync()
            let store = CountingPurgeStore()
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = PurgeDaysUseCase(cloud: cloud, store: store, settingsStore: settings)

            let report = try await useCase.run(from: first, to: today)

            let calls = await cloud.calls
            assertTest(calls == [.purge(from: first, to: today)],
                       "The purge reaches the database once, over the range it was given: \(calls)")
            assertTest(report.remote != nil,
                       "…and reports what the database removed rather than leaving it unstated")
            assertTest(report.local.total > 0 && report.message.contains("Deleted 3 days"),
                       "…and the sentence names the span: \(report.message)")
        }

        // ── The refusal: a failed cloud call deletes nothing here either ──────────────────────────
        do {
            let cloud = SpyCloudSync()
            await cloud.fail(with: .unreachable(message: "no route to host"))
            let store = CountingPurgeStore()
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = PurgeDaysUseCase(cloud: cloud, store: store, settingsStore: settings)

            var refused = false
            do {
                _ = try await useCase.run(from: first, to: today)
            } catch let refusal as PurgeDaysUseCase.Refusal {
                refused = true
                assertTest(refusal.errorDescription?.contains("nothing was deleted") == true,
                           "The refusal says what did not happen: \(refusal.errorDescription ?? "-")")
            }

            assertTest(refused,
                       "A failed database call ends the operation — it does not fall back to a local "
                           + "delete, which is the cache eviction this whole design avoids")
            let storeCalls = await store.calls
            assertTest(storeCalls.isEmpty,
                       "…and the phone was not touched at all: \(storeCalls.count) call(s)")
        }

        // ── The range rules, refused before anything is asked of either side ─────────────────────
        do {
            let cloud = SpyCloudSync()
            let store = CountingPurgeStore()
            let settings = InMemorySyncSettingsRepository(SyncSettings(destination: .cloud))
            let useCase = PurgeDaysUseCase(cloud: cloud, store: store, settingsStore: settings)

            var reversedRefused = false
            do {
                _ = try await useCase.run(from: today, to: first)
            } catch PurgeDaysUseCase.Refusal.reversedRange {
                reversedRefused = true
            }
            assertTest(reversedRefused, "A reversed range is refused rather than answered as a no-op")

            let farPast = calendar.date(byAdding: .day, value: -40, to: today)!
            var wideRefused = false
            do {
                _ = try await useCase.run(from: farPast, to: today)
            } catch let PurgeDaysUseCase.Refusal.tooWide(days) {
                wideRefused = days == 41
            }
            assertTest(wideRefused,
                       "A range over \(PurgeDaysUseCase.maximumDays) days is refused, and the refusal "
                           + "names the span it counted")

            let calls = await cloud.calls
            let storeCalls = await store.calls
            assertTest(calls.isEmpty && storeCalls.isEmpty,
                       "…and neither side was asked anything, so a refused range cannot half-delete")
        }

        // ── The bound itself, for the reason the server's has one ────────────────────────────────
        assertTest(PurgeDaysUseCase.maximumDays == 31,
                   "The client's cap is 31 days — the Worker's `MAX_DELETE_DAYS`, restated on this side "
                       + "because each half must refuse on its own")
    }
}
