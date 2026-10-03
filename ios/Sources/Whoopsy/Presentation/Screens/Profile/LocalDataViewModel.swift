import Foundation
import SwiftUI

/// The `LOGS` tab: every way data enters and leaves this app.
///
/// **This is `SettingsViewModel` under a different name with the profile fields shorn off**, and both
/// halves of that are deliberate. The user's decision was that the whole import/export surface moves off
/// `More → Settings` and onto the profile page's `LOGS` tab — WHOOP history, Zero fasting, Apple Health
/// and the JSON+CSV export, all four — and the structural question that leaves is which type owns them.
///
/// **A rename-with-shrink rather than one view model drawn on two screens.** `MainContainerView` builds
/// one view model per screen and does not share one between two, the deliberate exception being two
/// *routes to the same page* — which is what `deviceViewModel` is. Settings and `LOGS` are two different
/// pages that can be pushed one on top of the other, so a shared instance would have them fighting over
/// one `status` string and one `isImporting` flag: finishing an import on one would rewrite the other's
/// footer under a page that is no longer on screen. It also keeps the name honest, since a
/// `SettingsViewModel` living on the Profile page would lie about what it is.
///
/// **The four methods and their doc comments moved verbatim.** Their arguments are about these actions
/// rather than about the page they were drawn on — the HealthKit result being the only honest signal of
/// a permission that is never disclosed, the export import needing a deliberate tap rather than firing
/// from `load()`, the fasting import being the one that writes a session with no measurement behind it —
/// and re-deriving them here would be the way those arguments got lost.
///
/// **What is left on `SettingsViewModel` is the Privacy toggle**, which is the whole of that page now.
@MainActor @Observable public final class LocalDataViewModel {

    public var preferences = AppPreferences()
    public var healthKitAvailable = false
    public var status = ""
    public var export: LocalExportResult?
    public var isImporting = false

    private let repository: any AppPreferencesRepository
    private let healthKit: any HealthKitSyncing
    private let whoopExport: any WhoopExportImporting
    private let fasting: any FastingImporting
    private let exportUseCase: ExportLocalDataUseCase

    public init(
        repository: any AppPreferencesRepository,
        healthKit: any HealthKitSyncing,
        whoopExport: any WhoopExportImporting,
        fasting: any FastingImporting,
        exportUseCase: ExportLocalDataUseCase
    ) {
        self.repository = repository
        self.healthKit = healthKit
        self.whoopExport = whoopExport
        self.fasting = fasting
        self.exportUseCase = exportUseCase
    }

    public var healthKitUnavailableReason: String {
        healthKit.unavailableReason ?? "HealthKit is unavailable in this build."
    }

    /// Reads the preferences the health toggle is drawn from, and runs the opt-in import.
    ///
    /// **Called from the `LOGS` tab's own `.task(id:)` and never from the page's**, which is a
    /// deliberate narrowing rather than a tidy-up: `load()` fires the Apple Health import whenever
    /// `healthKitSyncEnabled` is set, and a reader who opened the profile page to type their weight has
    /// not asked for a 30-day HealthKit query. Tying it to the tab is what makes "when `LOGS` opens"
    /// literal.
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

    /// Imports one of the three WHOOP export files bundled with the app, on the user's explicit request.
    ///
    /// Not run from `load()`. `load()` fires whenever this tab opens, and the cycle file alone writes up
    /// to ~900 days of history — an import that size must follow a deliberate tap, not a screen
    /// appearing. Every import is idempotent, so nothing here is a guard.
    ///
    /// **One method taking a file rather than three methods**, mirroring the seam: the three buttons are
    /// three cases of one action, and three near-identical bodies would be three places for the
    /// `isImporting` bracket to drift. The file is the only thing that varies.
    ///
    /// **It no longer writes a preference.** `hasImportedWhoopExport` existed to switch one button's
    /// label between "Import" and "Re-import", and with three buttons there is no such label: the
    /// action is the same on every press, because every import here is idempotent by design. The field
    /// is gone from `AppPreferences` rather than left unread — a single `Bool` could not have described
    /// which of the three files had been imported anyway, so keeping it would have been keeping a
    /// question the new shape cannot ask.
    public func importWhoop(_ file: WhoopExportFile) async {
        isImporting = true
        defer { isImporting = false }
        do {
            status = try await whoopExport.importBundled(file).message
        } catch {
            status = error.localizedDescription
        }
    }

    /// Imports the Zero fasting history bundled with the app, on the user's explicit request.
    ///
    /// **Its own button rather than a case on `WhoopExportFile`**, which is the user's decision: the two
    /// are separate files from separate services and one can be re-run without the other. It is also the
    /// only import here that writes a session with **no measurement behind it** — a fast has no strain
    /// and no heart rate — so folding it into the WHOOP section would put rows in `workouts` that WHOOP
    /// never recorded under a control promising otherwise. It is a different protocol for that reason
    /// and not merely a fourth case: `FastingImporting` has no day skip and its own summary type.
    ///
    /// **No `AppPreferences` key**, on the same reasoning the WHOOP imports lost theirs: nothing on the
    /// screen changes with it.
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

    /// Writes this app's own record out, on the user's explicit request.
    ///
    /// **No `isImporting` bracket**, unlike the three imports above it, and the asymmetry is real rather
    /// than an omission: those change a database under the reader and their spinner is honest about it,
    /// where this only reads one. A spinner over a read would say the app is busy doing something to
    /// the data, and an `Importing…` caption over an export would name the wrong direction.
    ///
    /// **The sentence is the exporter's own** (`LocalExportResult.message`), on
    /// `WhoopImportSummary.message`'s precedent: it counts the rows and tables that went into the file,
    /// which is a figure this view model has no way to compose and which the runner can assert on the
    /// value rather than on a screen it cannot render.
    public func exportData() async {
        do {
            let result = try await exportUseCase.execute()
            export = result
            status = result.message
        } catch {
            status = error.localizedDescription
        }
    }
}
