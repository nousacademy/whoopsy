import Foundation

/// Recorded workout sessions.
///
/// `save` and `latest` were this protocol's entire surface while its only implementation kept them in
/// an in-memory array. `getWorkouts(for:)` is the method a day-keyed screen actually needs: the Home
/// dashboard lists the sessions recorded on the day the user is looking at, and unlike
/// `StrainRepository.getStrain(for:)` — which returns at most one row, because a day has one strain —
/// **several sessions on one day is normal**, so this returns an array.
public protocol WorkoutRepository: Sendable {
    func save(_ workout: WorkoutSession) async throws
    func latest() async throws -> WorkoutSession?

    /// The sessions recorded on `date`'s day, earliest first.
    ///
    /// An empty array when nothing was recorded. Never a stand-in: a day with no workout has no
    /// workout, and the ACTIVITIES card renders that as an absent row rather than a plausible one.
    func getWorkouts(for date: Date) async throws -> [WorkoutSession]
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

    /// The steps HealthKit recorded on `date`, or `nil` when it has no number to show.
    ///
    /// Does not throw, deliberately. On this platform the failure modes are indistinguishable from
    /// the outside: HealthKit never discloses read-permission status, so a denial, an empty day, a
    /// device with no step source and an unavailable store all arrive here as "no number". A caller
    /// that cannot tell them apart cannot report them apart either, and the honest rendering of all
    /// four is the same dash. Throwing would only invite a caller to show an error for a day the
    /// user simply did not carry their phone on.
    func stepCount(on date: Date) async -> Int?
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
