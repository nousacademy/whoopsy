import Foundation

/// Recorded workout sessions.
///
/// `save` and `latest` were this protocol's entire surface while its only implementation kept them in
/// an in-memory array. `getWorkouts(for:)` is the method a day-keyed screen actually needs: the Home
/// dashboard lists the sessions recorded on the day the user is looking at, and unlike
/// `StrainRepository.getStrain(for:)` — which returns at most one row, because a day has one strain —
/// **several sessions on one day is normal**, so this returns an array.
public protocol WorkoutRepository: Sendable {

    /// Stores a session, **inserting it or updating the row it already has**.
    ///
    /// `workouts` is primary-keyed on `id`, and GRDB's `save` is INSERT-or-UPDATE by primary key, so
    /// this is the one method that both creates and edits a row — there is no separate `update`. The
    /// activity detail page's `EDIT ACTIVITY` sheet relies on exactly that: it hands back a session
    /// carrying the original's `id` with new times and a new name, and the row is rewritten in place
    /// with everything filed under it (`workout_route_points`, `workout_splits`, keyed on `workout_id`)
    /// left valid.
    ///
    /// **The id is therefore the whole of what decides insert-versus-update**, which is why it is worth
    /// knowing where an id comes from before calling this. An imported row's id is derived from its own
    /// two instants (`WhoopExportImporter.workoutID(startingAt:endingAt:)`), a recorded session's is a
    /// fresh `UUID()` from `WorkoutSession.init`, and a caller that builds a session from scratch for a
    /// row that already exists writes a *second* row rather than editing the first.
    func save(_ workout: WorkoutSession) async throws
    func latest() async throws -> WorkoutSession?

    /// The sessions recorded on `date`'s day, earliest first.
    ///
    /// An empty array when nothing was recorded. Never a stand-in: a day with no workout has no
    /// workout, and the ACTIVITIES card renders that as an absent row rather than a plausible one.
    ///
    /// **This is the day-key question**: a session belongs to the one day it started on, which is the
    /// day `LocalDatabaseManager.saveWorkout` snapped its `date` column to. Nothing here appears on a
    /// neighbouring day, however long it ran.
    func getWorkouts(for date: Date) async throws -> [WorkoutSession]

    /// The sessions **underway at any point during** `date`'s day, earliest first — the other question.
    ///
    /// A session longer than a day appears on every day it covered, so an 86-hour fast is returned by
    /// this on all five of its days and by ``getWorkouts(for:)`` on one. Home's `ACTIVITIES` card is the
    /// only caller, and it is the only question it wants to ask: a fast that was running on the day the
    /// user is looking at is a thing that happened that day.
    ///
    /// **The two reads are not interchangeable, and merging them back into one is the regression this
    /// pair exists to prevent.** The strain page's two `HEART RATE ZONES` rows and the zone aggregates
    /// behind them must keep asking the day-key question: `WorkoutSession.zoneSeconds(_:)` scales WHOOP's
    /// share by the session's whole span, so a crossing session counted on both days would add the same
    /// measured time to two days' totals, and `WorkoutZoneTime.aggregate` keys the day off the first
    /// session's start day besides. Note the cost that *is* accepted: for a workout crossing midnight,
    /// Home may list it on a day the strain detail page does not count it on — the disagreement is
    /// invisible for a fast, which carries no zone block and so contributes nothing to any zone card.
    func getWorkouts(covering date: Date) async throws -> [WorkoutSession]

    /// Sessions over the `days` ending on `endingOn`, earliest first — the read behind a day's
    /// comparison against its own recent history.
    ///
    /// Bounded at both ends and anchored on the day the caller is showing, exactly as
    /// `RecoveryRepository.getRecoveryHistory(days:endingOn:)` is: a day-keyed screen showing a past
    /// day must not be handed a window that ran on to the present.
    func getWorkoutHistory(days: Int, endingOn: Date) async throws -> [WorkoutSession]

    /// Removes a session and everything filed under it — its route points and its splits.
    ///
    /// The only destructive operation this app has ever had. **It reports whether a row was actually
    /// removed**, and that is not the same question as "did it throw". A delete that matched no row is
    /// a silent no-op: an id that no longer round-trips through the session's own storage — an imported
    /// session whose id was re-derived, a row removed by an earlier tap — would otherwise report
    /// success, and a caller that dismissed its screen on that signal would leave the row on disk to
    /// reappear at the next read.
    ///
    /// Deleting an id that is not stored is still **not an error**: it returns `false` and throws
    /// nothing. An absent row is an ordinary answer here, in the same shape every reader in this app
    /// gives one.
    func delete(_ id: UUID) async throws -> Bool
}

public protocol AppPreferencesRepository: Sendable { func load() async -> AppPreferences; func save(_ preferences: AppPreferences) async }

/// The app's whole relationship with HealthKit: today, the read-side import.
///
/// One protocol, one injection slot, one implementation. Availability and authorization are shared
/// state, so splitting the read and write directions would let two objects disagree about whether
/// HealthKit works.
public protocol HealthKitSyncing: Sendable {
    /// Whether a health store is usable right now.
    var isAvailable: Bool { get }

    /// Why not, when `isAvailable` is false. Nil when it is true.
    var unavailableReason: String? { get }

    /// Requests read access. `true` means the prompt completed — **not** that access was granted.
    /// HealthKit does not disclose read-permission status, so callers must judge by import results.
    func requestAuthorization() async -> Bool

    /// Imports the last `days` of HRV and resting heart rate into local storage, one row per day.
    /// Days with no reading are skipped rather than stored as zero.
    func importRecentHealthData(days: Int) async throws -> HealthImportSummary
}

/// The WHOOP data export, as a third input alongside the strap and HealthKit.
///
/// Deliberately not folded into `HealthKitSyncing`: this is not a sync. It reads a file that shipped
/// inside the app bundle, it runs only when the user asks for it, and it exists to give a new install
/// the history that predates it. There is no availability question either — the file is either in the
/// build or it is not, which the thrown error answers.
public protocol WhoopExportImporting: Sendable {
    /// Imports the export bundled with the app, writing only days that are not already recorded.
    ///
    /// Idempotent: a second call finds every day present and writes nothing.
    func importBundledExport() async throws -> WhoopImportSummary
}

/// The Zero fasting tracker's history, as a fourth input beside the strap, HealthKit and the export.
///
/// **Its own protocol rather than a case on `WhoopExportImporting`**, on that protocol's own recorded
/// argument: that one is deliberately not folded into `HealthKitSyncing` because it is not a sync, and
/// this is not the same file, not the same format, not the same idempotence rule and not the same
/// summary. Two things about it are genuinely different rather than stylistic.
///
/// **It has no day skip.** Every other import path refuses a day that already holds a row. This one
/// must not: the fast's primary key is Zero's own `FastID`, which is disjoint from every other
/// producer's, so a write here can only ever touch a fast row — and a skip would drop the fasts that
/// land on a day the export or the strap already claimed, which over this file is 16 of the export's
/// 673 rows' worth of days. See `ZeroFastingImporter` for the other half of that pair.
///
/// **It writes a session with no measurement behind it**, which is the reason `v18` exists. Every row
/// it produces carries `nil` for `strain`, `averageHeartRate` and `maxHeartRate`, and the screen draws
/// a dash rather than a `0` for each.
public protocol FastingImporting: Sendable {
    /// Imports the fasting history bundled with the app.
    ///
    /// Idempotent by primary key: a second call updates the same rows rather than appending. Throws
    /// when this build carries no such file, because the file *is* the import.
    func importBundledFasts() async throws -> FastingImportSummary
}
