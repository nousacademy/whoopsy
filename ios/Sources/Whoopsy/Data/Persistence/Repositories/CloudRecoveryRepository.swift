import Foundation

/// The local-first decorator: the one place in this app where a read may reach the database.
///
/// It implements `RecoveryRepository` and wraps two things — the phone's own store and the network port —
/// and it decides which of them answers each call. Nothing above it changes: a view model that asked
/// `GRDBRecoveryRepository` for a day asks this for the same day and gets the same `RecoveryMetric?`,
/// whether that day is on the phone or in D1.
///
/// **The routing is a destination and no longer a boundary, and the difference is the whole of what this
/// file lost.** It used to split every call at a `cutoff` — days before it were the database's, days at
/// or after it were the phone's — which meant a read had to know *which store this day belongs to* before
/// it could answer. Nothing belongs to a store now: the destination says where data is *stored*, both
/// stores hold whatever they were given, and the phone's copy is read first because it is the one that
/// costs nothing and cannot be out of date with itself.
///
/// **A day the phone does not hold is asked of the database exactly once, and only under `.cloud`.** That
/// is what `local first, API on miss` means, and the `only under` is what keeps a user who never opens
/// `STORAGE` from ever making a request: a default install's reads are answered by
/// `GRDBRecoveryRepository` and this wrapper is a pass-through with an extra function call.
///
/// **A fetched day is not written to the phone, and that is a decision rather than an omission.** Caching
/// it would make the phone's own table depend on which screens the user happened to open, and it would
/// be this app *moving data between stores* — the one thing this pane promises it never does. A read is a
/// read: the day is drawn, and it is drawn from the store the destination names for as long as that is
/// where it lives.
///
/// **Settings are read on every call, not cached.** It is a `UserDefaults` read behind an actor and it
/// costs a dictionary lookup, while the alternative is a copy of the destination that goes stale the
/// moment the user flips the switch — and the failure that produces is a day read from the store it was
/// moved *out* of, with nothing on any screen saying so.
public struct CloudRecoveryRepository: RecoveryRepository {

    private let local: any RecoveryRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    private let status: any SyncStatus
    private let calendar: Calendar

    /// - Parameter calendar: used only by the history read's window arithmetic, and injected rather than
    ///   read from `.current` at each use so the day arithmetic can be asserted in a fixed zone. It must
    ///   be the same calendar `HTTPCloudSync` was built with, or one range's two halves are computed in
    ///   two zones — the same trap `RecoveryWindow` documents from the other end.
    public init(
        local: any RecoveryRepository,
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository,
        status: any SyncStatus,
        calendar: Calendar = .current
    ) {
        self.local = local
        self.cloud = cloud
        self.settingsStore = settingsStore
        self.status = status
        self.calendar = calendar
    }

    // MARK: - One day

    /// The phone's copy, or the database's when the phone has none and the destination is the API.
    ///
    /// **The local read comes first and the cloud is the fallback, which is the reverse of the order the
    /// old split implied.** It is also the only order that works now: without a boundary there is no
    /// question this decorator can ask to find out which store a day is in, so it asks the cheap store and
    /// falls back to the expensive one. A day in neither is `nil` — the ordinary absence, drawn as a dash
    /// and never as a zero.
    ///
    /// **Only `.unreachable` degrades, and the note it leaves is the reason this method is longer than a
    /// forwarding call.** A phone that cannot reach the database has nothing to draw for this day, so the
    /// honest answer is `nil` *plus* a mark, and the mark is what lets a screen say *a connection is
    /// needed* rather than *you did not measure this*. The app's standing rule is that an absence is never
    /// presented as a measurement; this is its other face, where an unanswerable question must not be
    /// presented as a measured nothing.
    ///
    /// **The other two errors propagate, and that asymmetry is the point of `CloudSyncError` having three
    /// cases.** A refusal is the server saying it knows something this app does not, and a malformed
    /// answer is a client and a server disagreeing about the shape of a day; degrading over either would
    /// hide a bug behind a missing row, which reads as *not measured* on a screen rather than as the
    /// failure it is.
    public func getRecovery(for date: Date) async throws -> RecoveryMetric? {
        if let stored = try await local.getRecovery(for: date) { return stored }
        guard await storesInCloud() else { return nil }

        do {
            let row = try await cloud.recovery(on: date)
            // A day the database answered is `clear`ed rather than left alone. The marks are
            // per-process and last until something removes them, so without this a phone that lost its
            // connection in the morning would go on drawing its *needs a connection* line over a day it
            // fetched successfully in the afternoon.
            await status.clear(date)
            return row?.metric
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
            await status.markUnavailable(date)
            return nil
        }
    }

    // MARK: - Writing one day

    /// The phone's own table, always, and then the database when the destination is the API.
    ///
    /// **The local write comes first and is never conditional**, which is the largest single difference
    /// from what this method used to do. It wrote cloud-first and skipped the local copy unless the user
    /// had asked to keep it, so a `.delete` policy left a day that existed only in the database — and the
    /// delete that policy was for is gone. With nothing purging either store, the phone's row is the one
    /// that is always right, because it is the one this app computed; the database is a copy of it.
    ///
    /// **A failed push never fails the local write, and never un-writes it.** The cloud call is made
    /// after the local save has returned, so a failure there leaves the day exactly as it should be —
    /// saved, and not yet in the database. `.unreachable` is the case this is about and the only one it
    /// swallows: it is `CloudSyncError`'s own documented *degrade to local storage* case, and here
    /// degrading is doing nothing further, because the local storage write has already happened.
    ///
    /// **Nothing is marked on the swallow**, deliberately, and the reason is that every mark this app has
    /// would say something false. `markUnavailable` means *this day cannot be shown*, and this day can —
    /// it is on the phone, which is where the read above goes first. What reconciles a day the database
    /// missed is the `SYNC` button, which sends a drawn span and is the control that exists for exactly
    /// this; a second, per-day record of *not pushed yet* would be the boundary bookkeeping this design
    /// deleted, rebuilt one row at a time.
    ///
    /// **`.rejected` and `.malformed` still propagate.** They are bugs rather than weather, they are the
    /// two cases `CloudSyncError` documents as never degradable, and the local row stays written in both
    /// — it went in first — so a caller's retry is a safe upsert of a day that is already correct.
    public func saveRecovery(_ recovery: RecoveryMetric, source: String?) async throws {
        try await local.saveRecovery(recovery, source: source)

        guard await storesInCloud() else { return }

        do {
            try await cloud.writeRecovery(RecoverySyncRow(recovery, source: source))
            // The day is now in the database, so whatever was recorded about it is no longer true.
            await status.clear(recovery.date)
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
        }
    }

    // MARK: - A range

    /// The phone's window, with the database's rows folded in under it.
    ///
    /// **Local wins where the two overlap, and the overlap is now the ordinary case rather than a thing
    /// the boundary prevented.** The phone recomputes and rewrites its own recent days; the database holds
    /// whatever was last pushed, which may be older. A reader is owed the app's own figure for a day it
    /// has, so the local row overwrites the cloud row on the same day rather than the other way round.
    ///
    /// **This is a merge and not a split, and the two properties the old split got for free have to be
    /// done by hand here.** The halves used to be disjoint by construction and already in order; the two
    /// sources now genuinely agree about some days, so the window is keyed by day and sorted — and the
    /// argument for *not* sorting, which this method used to carry, is exactly the argument that no longer
    /// holds. A keyed merge is the cheapest thing that gets both right, and it is also the thing that makes
    /// the precedence above statable as one line rather than as an ordering argument.
    ///
    /// **A failed read propagates here, where a failed single-day read degrades.** The asymmetry is
    /// deliberate and it is about what can be said afterwards. A single day has exactly one place to hang
    /// a sentence, so answering it with a mark is honest and complete. A history has no such place: a
    /// truncated merge is a shorter array, which is indistinguishable from a genuinely short history, and
    /// every screen in this app draws absence as a dash or an empty column — so degrading would state
    /// *you did not measure these days* about days the database holds. That is the fabrication this repo
    /// forbids everywhere, and it would be invisible besides: `HomeViewModel` puts a thrown error into
    /// `errorMessage` where a reader can see it, while a silently short chart says nothing at all.
    ///
    /// **The window arithmetic is the app's own convention, which is `days: N` ⟹ `N + 1` days inclusive
    /// at both ends** — `LocalDatabaseManager.historyWindow(days:endingOn:)` is the definition. The upper
    /// bound handed to the cloud is `last.startOfNextDay` and not `last.endOfDay`, on this repo's
    /// half-open rule: `23:59:59` is the last instant of a day, and a bound one second short drops a row
    /// written at midnight.
    public func getRecoveryHistory(days: Int, endingOn: Date) async throws -> [RecoveryMetric] {
        let stored = try await local.getRecoveryHistory(days: days, endingOn: endingOn)
        guard await storesInCloud() else { return stored }

        let last = endingOn.startOfDay
        guard let first = calendar.date(byAdding: .day, value: -days, to: last) else {
            // A date the calendar cannot express from these two. Unreachable for any real pair, and
            // answered by the phone rather than by the cloud because a window this decorator cannot
            // reason about is not a window it should be asking a server for.
            return stored
        }

        let fetched = try await cloud.recoveries(from: first, to: last.startOfNextDay).map(\.metric)
        return Self.merged(cloud: fetched, local: stored)
    }

    /// The two answers as one ascending window, with the phone's row winning on a day both hold.
    ///
    /// Keyed on `startOfDay` rather than on the `Date` itself, because a row's date is an instant that two
    /// producers need not have written identically — the local writer snaps, the wire carries a day key
    /// that is parsed back to a midnight, and keying on the raw value would file one day twice and draw it
    /// twice.
    ///
    /// Local second so it overwrites, and the loop order *is* the precedence rule: written the other way
    /// round the database would win, and the app would show a figure it did not compute over one it did.
    private static func merged(cloud: [RecoveryMetric], local: [RecoveryMetric]) -> [RecoveryMetric] {
        var byDay: [Date: RecoveryMetric] = [:]
        for metric in cloud { byDay[metric.date.startOfDay] = metric }
        for metric in local { byDay[metric.date.startOfDay] = metric }
        return byDay.values.sorted { $0.date < $1.date }
    }

    // MARK: - The one read that never leaves the phone

    /// Unconditional, for every day, whatever the destination says.
    ///
    /// **This is the port's own constraint being honoured rather than a rule invented here.** The
    /// protocol documents this method as *keeping the intent at the call site*, so that a future
    /// non-local implementation cannot leak a synthesised row into a caller's decision about whether to
    /// compute and write a day — and a decorator that answered it from the database would be exactly the
    /// leak it was written to prevent. A caller asking this question is asking what is on the phone, and
    /// the answer cannot depend on where future writes are going.
    public func getLocalRecovery(for date: Date) async throws -> RecoveryMetric? {
        try await local.getLocalRecovery(for: date)
    }

    // MARK: - Routing

    /// Whether this install stores its days in the database.
    ///
    /// **`.device` is false and it is the default**, so a fresh install — and a user who never opens
    /// `STORAGE` — reaches `local` on every call and never constructs a request. There is no third arm and
    /// no *both*: the destination is one switch, and a day is read from the phone first whatever it says.
    private func storesInCloud() async -> Bool {
        await settingsStore.load().destination == .cloud
    }
}
