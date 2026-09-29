import Foundation
import SwiftUI

@MainActor @Observable public final class SettingsViewModel {
    public var preferences = AppPreferences(); public var healthKitAvailable = false; public var status = ""; public var export: LocalExportResult?; public var isImporting = false
    private let repository: any AppPreferencesRepository; private let healthKit: any HealthKitSyncing; private let whoopExport: any WhoopExportImporting; private let fasting: any FastingImporting; private let exportUseCase: ExportLocalDataUseCase
    public init(repository: any AppPreferencesRepository, healthKit: any HealthKitSyncing, whoopExport: any WhoopExportImporting, fasting: any FastingImporting, exportUseCase: ExportLocalDataUseCase) { self.repository = repository; self.healthKit = healthKit; self.whoopExport = whoopExport; self.fasting = fasting; self.exportUseCase = exportUseCase }
    public var healthKitUnavailableReason: String { healthKit.unavailableReason ?? "HealthKit is unavailable in this build." }

    public func load() async {
        preferences = await repository.load()
        healthKitAvailable = healthKit.isAvailable
        // Import on open when the user has opted in. Nothing else triggers it: both sources write one
        // row per day, so a day the strap missed is only filled if something asks for it.
        if preferences.healthKitSyncEnabled { await importHealthData() }
    }

    public func save() async { await repository.save(preferences) }

    /// Enables HealthKit sync and reports what the import actually found.
    ///
    /// The result of `requestAuthorization` cannot be reported as "access granted" — HealthKit
    /// deliberately never discloses read-permission status, so a user who taps "Don't Allow" and a
    /// user who allows everything both come back `true`. The honest signal is the import: how many
    /// days of data arrived.
    public func authorizeHealthKit() async {
        guard healthKitAvailable else { status = healthKitUnavailableReason; return }
        preferences.healthKitSyncEnabled = await healthKit.requestAuthorization()
        await save()
        guard preferences.healthKitSyncEnabled else { status = "The HealthKit permission prompt could not be shown."; return }
        await importHealthData()
    }

    public func importHealthData() async {
        guard preferences.healthKitSyncEnabled, healthKitAvailable else { return }
        isImporting = true
        defer { isImporting = false }
        do { status = try await healthKit.importRecentHealthData(days: 30).message } catch { status = error.localizedDescription }
    }

    /// Imports the WHOOP export bundled with the app, on the user's explicit request.
    ///
    /// Not run from `load()`. `load()` fires whenever Settings opens, and this writes up to ~900 days
    /// of history — an import that size must follow a deliberate tap, not a screen appearing. The
    /// import is idempotent, so the flag this sets is bookkeeping for the footer, not a guard.
    public func importWhoopExport() async {
        isImporting = true
        defer { isImporting = false }
        do {
            status = try await whoopExport.importBundledExport().message
            preferences.hasImportedWhoopExport = true
            await save()
        } catch {
            status = error.localizedDescription
        }
    }

    /// Imports the Zero fasting history bundled with the app, on the user's explicit request.
    ///
    /// **Its own button rather than a step inside `importWhoopExport()`**, which is the user's
    /// decision: the two are separate files from separate services and one can be re-run without the
    /// other. It is also the only import here that writes a session with **no measurement behind it** —
    /// a fast has no strain and no heart rate — so folding it into a button labelled "WHOOP history"
    /// would put rows in `workouts` that WHOOP never recorded under a control promising otherwise.
    ///
    /// **No `AppPreferences` key.** `hasImportedWhoopExport` exists only to switch one button's label
    /// between "Import" and "Re-import"; a second key to move one word is more surface than it is
    /// worth, and nothing else consults it.
    ///
    /// Idempotent, so a re-import is safe and rewrites the same rows. Unlike the export it is **not
    /// durable against a delete**: a fast deleted on the activity detail page comes back on the next
    /// press, which the caption beside the button says.
    public func importFastingHistory() async {
        isImporting = true
        defer { isImporting = false }
        do {
            status = try await fasting.importBundledFasts().message
        } catch {
            status = error.localizedDescription
        }
    }

    public func exportData() async { do { export = try await exportUseCase.execute(); status = "Local JSON and CSV export is ready." } catch { status = error.localizedDescription } }
}
