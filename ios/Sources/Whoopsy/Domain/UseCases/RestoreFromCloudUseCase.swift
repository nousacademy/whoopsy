import Foundation

/// Fills an empty phone from the database — the **only** read path that asks the API for rows.
///
/// ## Why this exists, and what it replaced
///
/// The seven `Cloud*Repository` decorators used to answer a local miss from the database, and the three
/// history reads asked it unconditionally, so a screen's content could depend on a request: inside
/// 18:00–midnight Eastern a slow or failing call delayed or blanked a day that the phone did not hold.
/// Measured 2026-10-27, a Home load with the cloud out of the window still took 32–39 s, and the network
/// was never the useful part of it — the app's own rule, **"Repositories answer from local storage and
/// nothing else"**, was being contradicted by the sync rather than upheld by it.
///
/// So reads are local-only now (the decorators are constructed with a closed read window and never
/// reach their cloud branch), and the one case that genuinely needs rows the phone does not have — a
/// fresh install pointed at an existing database — is this: a deliberate pull, once, that writes what
/// it finds into the phone's own tables. After it runs, every screen is reading local rows like any
/// other.
///
/// ## It writes through the sync stores, not through the repositories
///
/// The port returns `*SyncRow`s and the stores take them, which is exactly the pair the upload uses —
/// so a restored row and an uploaded row are one shape, and a restore cannot invent a field the wire
/// does not carry. `WorkoutSyncRow` brings its route points and splits with it; the repositories speak
/// domain types and would have had to rebuild them.
///
/// **Bounded to `days`, and it is not a merge**: `restore()` replaces rows in the window, so running it
/// over a phone that already holds data overwrites days this app computed with whatever the database
/// last saw. That is why the *automatic* path, `restoreIfNeeded()`, is guarded on the phone being empty
/// while the pane's `RESTORE` button is not — a person pressing it has been told, in the caption
/// directly above it, that it replaces.
///
/// ## The window is the automatic path's, and only its
///
/// Every other call this app makes is refused outside 18:00–midnight Eastern (`SyncSchedule.isOpen`),
/// because the app's traffic is a schedule rather than a conversation. **A restored phone is the one
/// case that cannot wait for the evening**: the first launch after an uninstall is exactly when its
/// tables are empty, and the pane's own control is a person pressing a button now. So the launch-time
/// repair keeps the window and the explicit press does not — `restore()` makes no window check, and
/// `DIContainer` hands it a client built with the window held open, while `SYNC`, the engine and the
/// automatic restore keep the one the rest of the app obeys.
public actor RestoreFromCloudUseCase {

    /// How far back a restore reaches. Thirty days is the span a fresh install is worth showing and the
    /// span the pane's own control is drawn over; older rows are the export's job, not a restore's.
    public static let days = 30

    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    private let profileStore: any UserProfileSyncStore
    private let inactivityStore: any ReceptiveInactivitySyncStore
    private let recoveryStore: any RecoverySyncStore
    private let sleepStore: any SleepSyncStore
    private let stepCountStore: any StepCountSyncStore
    private let strainStore: any StrainSyncStore
    private let workoutStore: any WorkoutSyncStore

    /// The once-a-day window, and **only `restoreIfNeeded` consults it** — see the type's own note on
    /// why the explicit press is exempt. The client behind `restore()` is built with the window held
    /// open for the same reason, so the two halves of the exemption live at the two seams a request
    /// crosses rather than in this guard alone.
    private let isCallWindowOpen: @Sendable () -> Bool

    /// Announces a restore that actually wrote rows.
    ///
    /// **A saved row is not a drawn one.** The pane this runs from is pushed *over* Home, and a pop
    /// re-fires no `.task` — so without this, a restore would fill the tables and leave the rings
    /// behind it showing what they read before it ran until something else reloaded them. The value is
    /// the number of rows written, so a reader can tell a restore from a refusal.
    private let hub = RestoreHub()

    /// Emits after every restore that wrote at least one row.
    public nonisolated var completions: AsyncStream<Int> { hub.stream }

    public init(
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository,
        profileStore: any UserProfileSyncStore,
        inactivityStore: any ReceptiveInactivitySyncStore,
        recoveryStore: any RecoverySyncStore,
        sleepStore: any SleepSyncStore,
        stepCountStore: any StepCountSyncStore,
        strainStore: any StrainSyncStore,
        workoutStore: any WorkoutSyncStore,
        isCallWindowOpen: @escaping @Sendable () -> Bool = { true }
    ) {
        self.cloud = cloud
        self.settingsStore = settingsStore
        self.profileStore = profileStore
        self.inactivityStore = inactivityStore
        self.recoveryStore = recoveryStore
        self.sleepStore = sleepStore
        self.stepCountStore = stepCountStore
        self.strainStore = strainStore
        self.workoutStore = workoutStore
        self.isCallWindowOpen = isCallWindowOpen
    }

    /// What one restore wrote, per resource.
    public struct Report: Sendable, Equatable {

        /// Why a restore did nothing, when it was refused rather than empty.
        ///
        /// **`.outsideWindow` was here and is gone.** It existed because the explicit press used to be
        /// refused outside 18:00–24:00 Eastern like every other call, and the pane needed a sentence
        /// saying so — `Nothing was found in the database` was being printed for a restore the app had
        /// never attempted. The press no longer obeys that window (see the type's note), so the case
        /// had no producer left, and a `Skipped` arm nothing can return is a sentence about a state the
        /// app cannot be in.
        public enum Skipped: Sendable, Equatable {
            /// This install has not chosen `WHOOPSY SYNC API`.
            case deviceDestination
        }

        public let days: Int
        public let rows: [SyncedResource: Int]
        public let restoredProfile: Bool
        public let skipped: Skipped?

        public var totalRows: Int { rows.values.reduce(0, +) + (restoredProfile ? 1 : 0) }

        public static func empty(days: Int, skipped: Skipped? = nil) -> Report {
            Report(days: days, rows: [:], restoredProfile: false, skipped: skipped)
        }
    }

    /// Pulls the window and writes it to this phone.
    ///
    /// **The destination is checked and the hour is not**, and the asymmetry is the point: the
    /// destination is a fact about the install that cannot change while the button is pressed, while
    /// the hour is a schedule the press is deliberately exempt from. A `.device` install answers with
    /// an empty report rather than throwing — "the app is not configured for this" is not a failure of
    /// a restore, and a caller that had to tell it apart from a network error would need a second
    /// source of truth. Nothing else here refuses before a request.
    @discardableResult
    public func restore(days: Int = RestoreFromCloudUseCase.days, now: Date = Date()) async throws
        -> Report
    {
        let settings = await settingsStore.load()
        guard settings.destination == .cloud else {
            return .empty(days: days, skipped: .deviceDestination)
        }

        let calendar = SyncSchedule.calendar()
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -days, to: today),
              let to = calendar.date(byAdding: .day, value: 1, to: today)
        else { return .empty(days: days) }

        var written: [SyncedResource: Int] = [:]

        // The four day-keyed resources and the two aggregates, in the pane's order. Each is fetched and
        // written whole rather than day by day: the port takes a half-open window and the store's save
        // is one transaction, which is what makes a restore either complete for a resource or absent.
        let recoveries = try await cloud.recoveries(from: from, to: to)
        try await recoveryStore.saveSyncRows(recoveries)
        written[.recoveries] = recoveries.count

        let strains = try await cloud.strains(from: from, to: to)
        try await strainStore.saveSyncStrainRows(strains)
        written[.strains] = strains.count

        let sleeps = try await cloud.sleeps(from: from, to: to)
        try await sleepStore.saveSyncSleepRows(sleeps)
        written[.sleeps] = sleeps.count

        let steps = try await cloud.stepCounts(from: from, to: to)
        try await stepCountStore.saveSyncStepCountRows(steps)
        written[.stepCounts] = steps.count

        let workouts = try await cloud.workouts(from: from, to: to)
        try await workoutStore.saveSyncWorkoutRows(workouts)
        written[.workouts] = workouts.count

        let inactivities = try await cloud.receptiveInactivities(from: from, to: to)
        try await inactivityStore.saveSyncReceptiveInactivityRows(inactivities)
        written[.receptiveInactivities] = inactivities.count

        // **A profile is written only onto a phone that has none.** It is the one row with local-only
        // fields (`docs/GOTCHAS.md`, "A sync upsert can erase a local-only user field"), so replacing a
        // phone's profile with the database's would take back a value the user typed here.
        var restoredProfile = false
        if try await profileStore.syncProfileRow() == nil, let profile = try await cloud.profile() {
            try await profileStore.saveSyncProfileRow(profile)
            restoredProfile = true
        }

        CaptureLog.shared.append(
            "RESTORE days=\(days) rows=\(written.values.reduce(0, +) + (restoredProfile ? 1 : 0)) "
                + "profile=\(restoredProfile ? "yes" : "no")")
        let report = Report(
            days: days, rows: written, restoredProfile: restoredProfile, skipped: nil)
        if report.totalRows > 0 { hub.yield(report.totalRows) }
        return report
    }

    /// The guarded entry point: restore on a launch, when this install is configured for the API, the
    /// call window is open, and **the phone holds no days at all**.
    ///
    /// **The window check lives here rather than in `restore()`, and that is the one difference between
    /// the two entry points.** This one is the app deciding on its own to call out, so it obeys the
    /// same 18:00–midnight schedule as the daily upload; the pane's button is a person deciding, and it
    /// does not. Checked first, before the settings and before the emptiness read, because a closed
    /// window makes the whole attempt unnecessary rather than merely doomed.
    ///
    /// **Emptiness is asked of `recoveries`, and of a two-year window rather than of "a row exists".**
    /// A fresh install has no rows of any description; a phone that has been used has at least the days
    /// it recorded, and a window wider than the restore's own is what keeps an install holding exactly
    /// the last thirty days from being treated as empty and overwritten.
    ///
    /// Nothing here can fail the caller: a restore is background repair, and a failure leaves the phone
    /// exactly as it was — empty — with a line in `capture.txt` and the next launch free to retry.
    public func restoreIfNeeded(now: Date = Date()) async {
        guard isCallWindowOpen() else { return }
        let settings = await settingsStore.load()
        guard settings.destination == .cloud else { return }
        guard await isEmpty(now: now) else { return }

        do {
            let report = try await restore(now: now)
            if report.totalRows > 0 {
                AppLogger.database.notice(
                    "Restored \(report.totalRows, privacy: .public) rows over \(report.days, privacy: .public) days")
            }
        } catch {
            AppLogger.database.error(
                "Restore failed: \(error.localizedDescription, privacy: .public)")
            CaptureLog.shared.append("RESTORE failed=\(error.localizedDescription)")
        }
    }

    private func isEmpty(now: Date) async -> Bool {
        let calendar = SyncSchedule.calendar()
        let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        guard let from = calendar.date(byAdding: .day, value: -730, to: calendar.startOfDay(for: now))
        else { return false }
        // **Two stores, because one stopped being enough.** Recovery rows are now computed on the phone
        // by `RefreshRecoveryUseCase`, so a first foreground can write one before this runs and a
        // recovery-only test would then report the phone as populated while its nights and sessions are
        // missing. Recovery and sleep together are the pair a used phone always has.
        guard let recoveries = try? await recoveryStore.syncRows(from: from, to: to),
              let sleeps = try? await sleepStore.syncSleepRows(from: from, to: to)
        else { return false }
        return recoveries.isEmpty && sleeps.isEmpty
    }
}

/// Fans a completed restore out to attached readers — `NightUpdateHub`'s shape, for its reason.
private final class RestoreHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    var stream: AsyncStream<Int> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func yield(_ rows: Int) {
        lock.lock()
        let readers = Array(continuations.values)
        lock.unlock()
        for reader in readers { reader.yield(rows) }
    }
}
