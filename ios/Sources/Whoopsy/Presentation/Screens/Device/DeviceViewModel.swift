import Foundation
import SwiftUI

/// The device page's state: which strap is connected, what the user says it is, and when it last
/// delivered anything.
///
/// **One view model for one page.** This used to be two — `DeviceViewModel` for More → Device, and a
/// `DeviceDetailViewModel` for the page Home's badge pushed — and the two screens disagreed about the
/// same strap: the Settings copy printed `device?.batteryPercentage ?? 0`, so it showed a fabricated
/// `0%` with no strap attached and a fabricated `100%` the moment one was discovered, while the badge's
/// page gated correctly. The user's instruction was to merge them, and the merge is what makes the
/// gated reading the only one there is.
@MainActor @Observable public final class DeviceViewModel {
    /// The connected strap, as the BLE layer currently describes it.
    public private(set) var device: WhoopDevice?

    public var isScanning = false
    public private(set) var status = ""
    public var preferences = AppPreferences()

    /// The model shown in the ADVANCED tab's picker.
    ///
    /// Seeded from the strap's *resolved* generation, which is the user's stored choice when there is
    /// one and the name heuristic otherwise. `isModelSaved` is what tells the two apart on screen,
    /// because they are the same value here and a different claim about where it came from.
    public var model: WhoopHardwareGeneration = .whoop4

    /// Whether a model for this strap has actually been chosen, as opposed to inferred.
    public private(set) var isModelSaved = false

    /// The instant the strap last delivered something to this app, or `nil` when it never has.
    ///
    /// **The producer is the newest stored sample, and it is deliberately not
    /// `WhoopDevice.lastSyncTime`.** That field exists on the entity and no code path ever writes it —
    /// `WhoopBLEManager.resolvedDevice` propagates it from a device that was itself built with `nil` —
    /// so a figure read from it would be the entity's default dressed as a reading, which is the
    /// fabrication class this repo has shipped before. `biometric_samples.timestamp` is a real column
    /// written by the BLE path, and the newest of them is the last moment the strap was actually heard
    /// from.
    ///
    /// It reads `nil` in every database on this machine: `biometric_samples` holds 0 rows here, because
    /// no strap has ever been connected. That is an honest dash rather than a bug — see
    /// `DeviceSettingsView.lastSyncText`.
    public private(set) var lastSync: Date?

    private let manage: ManageBLEConnectionUseCase
    private let sync: SyncHistoricalDataUseCase
    private let preferencesRepository: any AppPreferencesRepository
    private let strapModels: any StrapModelRepository
    private let protocols: any WhoopProtocolProviding
    private let biometrics: any BiometricRepository
    private var task: Task<Void, Never>?

    public init(
        manage: ManageBLEConnectionUseCase,
        sync: SyncHistoricalDataUseCase,
        preferencesRepository: any AppPreferencesRepository,
        strapModels: any StrapModelRepository,
        protocols: any WhoopProtocolProviding,
        biometrics: any BiometricRepository
    ) {
        self.manage = manage
        self.sync = sync
        self.preferencesRepository = preferencesRepository
        self.strapModels = strapModels
        self.protocols = protocols
        self.biometrics = biometrics
    }

    /// Whether a strap is attached well enough to be told about.
    ///
    /// `device.id` is empty while the manager is scanning or idle — `startScanning` yields a device
    /// with no id at all — so an id is the honest test for "there is a strap here", not `device != nil`.
    public var hasDevice: Bool {
        guard let device else { return false }
        return !device.id.isEmpty
    }

    /// Whether this build can frame commands for the model currently selected.
    ///
    /// Drives the caption under the picker. A `false` here is the whole reason
    /// `WhoopProtocolProviding` is a dependency of a *view model*: choosing WHOOP 5.0 and being told
    /// nothing would leave the user waiting for a sync that cannot happen.
    public var supportsSync: Bool {
        protocols.supportsProprietarySync(model)
    }

    /// What the sync caption calls the envelope, e.g. `4.0`. Falls back to the model's own name when
    /// the catalog frames nothing, which only happens on the branch that prints no caption.
    public var protocolEnvelopeName: String {
        protocols.protocolEnvelopeName(model) ?? model.rawValue
    }

    /// The honest caveat under that caption — **and it differs per generation, because the two have
    /// different open questions rather than the same one twice.**
    ///
    /// The 4.0's is unvalidatedness alone: the envelope matches two independent references and its
    /// checksums are pinned by published vectors, but no frame it builds has been seen by a strap. The
    /// 5.0's has a second, more specific blocker — §7 Q6, the command characteristic's authenticated
    /// SMP bond, which nothing in this project establishes is completable from a third-party iOS app.
    /// One generic sentence for both would hide the reason a 5.0 sync is the more likely of the two to
    /// do nothing, which is the one thing this caption exists to say.
    ///
    /// It is drawn on the ADVANCED tab rather than behind an ⓘ button: the reference screenshot has one
    /// in its top bar, and a second route to the same words would be a control whose only purpose is to
    /// reveal something already on the page.
    public var protocolCaveat: String {
        switch model {
        case .whoop4:
            return "That envelope has not been validated against real hardware yet, so a strap may still ignore what this app sends."
        case .whoop5, .whoop5MG:
            return "Two things are unproven here. The envelope has never been validated against real hardware, and this model's command characteristic needs an authenticated bond that no third-party app in this project has established — so a 5.0 is the strap most likely to ignore what this app sends."
        case .standardBleHR, .simulator:
            return ""
        }
    }

    /// Whether the strap is attached right now, as opposed to merely discovered.
    public var isConnected: Bool {
        device?.connectionState == .connected
    }

    public func load() async {
        device = await manage.getCurrentDevice()
        preferences = await preferencesRepository.load()
        await refreshModelState()
        await refreshLastSync()

        // **Idempotent, and that guard is a fix rather than tidying.** `.task` fires once per push and
        // this view model is built once in `MainContainerView`, so a second `load()` on the same
        // instance would abandon the first `for await` **without cancelling it** — leaving a
        // continuation registered in `deviceStream`'s multicast dictionary for the life of the process.
        // That is the silent failure `WhoopBLEManager`'s registry exists to prevent: a consumer that
        // stops receiving looks exactly like a strap that went quiet.
        //
        // A second subscriber beside `HomeViewModel.observeDevice()` is safe by construction — the
        // stream is multicast precisely so it is — but a second subscriber *on one instance* is not a
        // subscriber at all.
        guard task == nil else { return }
        task = Task { [weak self, manage] in
            for await item in manage.deviceStream {
                guard !Task.isCancelled else { return }
                self?.device = item
                await self?.refreshModelState()
            }
        }
    }

    /// Runs a drain and says what happened, in three states rather than one.
    ///
    /// **This used to print "History sync complete." before anything had completed** — the use case
    /// sent a request and returned, so the sentence described an intention. The drain now runs to its
    /// conclusion before this line executes, which is why the string can be earned rather than
    /// asserted, and why it is worth three of them: a strap that reported it was done, a strap that
    /// caught up to the present, and a drain that stopped for any other reason are three different
    /// facts and only the first two support the word "complete".
    ///
    /// The pending string matters because a 5.0's idle window is 60 s. Without it the button appears
    /// to do nothing for a minute — and the button takes no other busy state, so this is the only
    /// signal there is.
    public func syncNow() async {
        status = "Syncing history…"
        do {
            let outcome = try await sync.execute()
            let records = "\(outcome.recordCount) record(s) in \(outcome.batchCount) batch(es)"
            status = outcome.ending == .caughtUpToLiveEdge
                ? "History sync complete — caught up to now, \(records)."
                : "History sync complete — \(records)."
            // The drain is the app's one producer of stored samples on a strap that has been off the
            // wrist for a while, so this is the read most likely to move the header's LAST SYNC row.
            await refreshLastSync()
        } catch {
            status = error.localizedDescription
        }
    }

    /// Scans for a strap — which on this app *is* pairing.
    ///
    /// There is no discovery list to choose from: `WhoopBLEManager.didDiscover` connects to the first
    /// matching peripheral immediately, so a "Pair a Device" button and a "Scan" button are the same
    /// action and there is nothing else this could offer. A device picker in the style of the reference
    /// would need a discovery stream the BLE layer does not have.
    public func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            try await manage.startScanning()
            status = "Scanning for nearby WHOOP straps…"
        } catch {
            status = error.localizedDescription
        }
    }

    /// Drops the link to the strap, and nothing else.
    ///
    /// **It is a disconnect and not a forget**, which is why the page's caption states the limit rather
    /// than repeating the reference's *"This will remove the Bluetooth connection."* — that sentence is
    /// true of the link and would read as true of the pairing. `disconnect()` reaches
    /// `WhoopBLEManager.cancelPeripheralConnection`, which ends the link and leaves the stored model
    /// choice — keyed on the peripheral identifier in `UserDefaults` — untouched, and `didDiscover`
    /// links to the first matching peripheral on the very next scan. There is no forget path in this
    /// codebase to call, so there is nothing else this method could do.
    ///
    /// **The device is deliberately not re-read here.** `cancelPeripheralConnection` is asynchronous:
    /// the state change arrives on `didDisconnectPeripheral` and reaches this object through
    /// `manage.deviceStream`, which `load()` already holds a subscription to. Reading
    /// `getCurrentDevice()` on the next line would return the *old* `.connected` object and assign it
    /// back over the stream's answer, so the button would appear to do nothing at all. The status line
    /// is the only immediate acknowledgement, and it names the half that actually happened.
    public func unpair() async {
        await manage.disconnect()
        status = "Bluetooth link dropped. Scanning again will link to this strap."
    }

    public func setBroadcast(_ value: Bool) async {
        preferences.liveHeartRateBroadcastEnabled = value
        await preferencesRepository.save(preferences)
        status = value ? "Broadcast preference saved. This strap transport is not available yet." : "Broadcast preference disabled."
    }

    /// Records the user's choice and re-resolves the strap's generation.
    ///
    /// The state write is synchronous and the persistence is not, so the picker moves on the tap
    /// rather than a turn of the run loop later. The `refreshStrapModel` call is what makes the choice
    /// real: without it the generation — and so the envelope every command is framed with — would not
    /// change until the strap was rediscovered.
    public func choose(_ value: WhoopHardwareGeneration) {
        model = value
        Task { await persist(value) }
    }

    private func persist(_ value: WhoopHardwareGeneration) async {
        guard let id = device?.id, !id.isEmpty else {
            status = "No strap to assign a model to. Connect one first."
            return
        }
        await strapModels.setModel(value, forDeviceId: id)
        await manage.refreshStrapModel()
        device = await manage.getCurrentDevice()
        await refreshModelState()
        status = supportsSync
            ? "Saved. \(value.rawValue) is what this strap will be treated as."
            : "Saved. Syncing with \(value.rawValue) is not implemented yet — see below."
    }

    private func refreshModelState() async {
        let saved = await strapModels.allModels()
        guard let device, !device.id.isEmpty else {
            isModelSaved = false
            model = device?.hardwareGeneration ?? model
            return
        }
        isModelSaved = saved[device.id] != nil
        model = device.hardwareGeneration
    }

    /// The newest stored sample's instant, or `nil` when there is none.
    ///
    /// A throw is folded into `nil` deliberately: a read that failed and a database that has never held
    /// a sample both leave the page unable to name an instant, and the dash is the conservative answer
    /// for both. What must not happen is a caught error rendering as a time.
    private func refreshLastSync() async {
        lastSync = try? await biometrics.getLatestSample()?.timestamp
    }
}
