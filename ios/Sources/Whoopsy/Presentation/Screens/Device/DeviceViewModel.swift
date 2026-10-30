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

    /// The most recent live heart rate this app received, and the instant it arrived.
    ///
    /// **Both fields or neither**: a rate with no arrival instant cannot be aged, and
    /// `DeviceSettingsView.liveHeartRateText` refuses to draw one. The pair is written by the live
    /// telemetry subscription in `load()` — the standard `0x2A37` notification on a 4.0 and packet 40
    /// on a 5.0/MG — and never by a drained record, which is history rather than a pulse.
    public private(set) var liveHeartRate: Int?
    public private(set) var liveHeartRateAt: Date?

    private let manage: ManageBLEConnectionUseCase
    private let sync: SyncHistoricalDataUseCase
    /// The drain's other half — see `syncNow()`. Handed in rather than reached for, on the rule that a
    /// view model is constructed in `MainContainerView` and nowhere else.
    private let refreshStrain: RefreshStrainUseCase
    private let preferencesRepository: any AppPreferencesRepository
    private let protocols: any WhoopProtocolProviding
    private let biometrics: any BiometricRepository
    private var task: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?

    public init(
        manage: ManageBLEConnectionUseCase,
        sync: SyncHistoricalDataUseCase,
        refreshStrain: RefreshStrainUseCase,
        preferencesRepository: any AppPreferencesRepository,
        protocols: any WhoopProtocolProviding,
        biometrics: any BiometricRepository
    ) {
        self.manage = manage
        self.sync = sync
        self.refreshStrain = refreshStrain
        self.preferencesRepository = preferencesRepository
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

    /// The generation this page speaks to **the strap's**, not a stored choice.
    ///
    /// **The model picker is gone, and this replaces it.** It existed because nothing in the app could
    /// tell a 5.0 from a 5.0 MG except its owner; the strap's own Device Information Service answers
    /// `0x2A24` and does separate them, so `WhoopBLEManager` now resolves the generation from that
    /// string, the service list and — only when neither has spoken — the advertised name. What the
    /// page draws is the answer that resolution produced.
    private var connectedModel: WhoopHardwareGeneration {
        device?.hardwareGeneration ?? .whoop4
    }

    /// Whether this build can frame commands for the connected strap's generation.
    public var supportsSync: Bool {
        protocols.supportsProprietarySync(connectedModel)
    }

    /// What the sync caption calls the envelope, e.g. `4.0`. Falls back to the model's own name when
    /// the catalog frames nothing, which only happens on the branch that prints no caption.
    public var protocolEnvelopeName: String {
        protocols.protocolEnvelopeName(connectedModel) ?? connectedModel.displayName
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
        switch connectedModel {
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
        // **Ask the strap what it has stored, on every open of this page.** The advertisement a phone
        // shows may be CoreBluetooth's cached name, so it cannot settle whether a rename took; this
        // read is the strap's own answer, and its raw reply lands in `Documents/capture.txt`.
        if isConnected { await manage.requestAdvertisingName() }
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
            }
        }

        // The pulse subscription, guarded the same way and for the same reason. A second `for await`
        // on one instance would orphan the first continuation in the multicast registry, and the
        // symptom — a figure that stops updating — is indistinguishable from a strap that went quiet.
        guard telemetryTask == nil else { return }
        telemetryTask = Task { [weak self, manage] in
            for await sample in manage.liveTelemetryStream {
                guard !Task.isCancelled else { return }
                self?.liveHeartRate = sample.heartRate
                self?.liveHeartRateAt = sample.timestamp
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
            // **The records are on disk; the days they cover are not scored until this runs.** A
            // backlog drain can deliver a fortnight, and the foreground loop would reach each past day
            // only on a later tick — with no screen ever opening one, the strain would stay absent.
            await refreshStrain.refresh(from: outcome.oldestRecord, to: outcome.newestRecord)
        } catch {
            status = error.localizedDescription
            // A drain that stopped early still wrote what it read — see `WhoopSyncError.recordRange`.
            if let range = (error as? WhoopSyncError)?.recordRange {
                await refreshStrain.refresh(from: range.oldest, to: range.newest)
            }
        }
    }

    /// Scans for a strap — which on this app *is* pairing.
    ///
    /// There is no discovery list to choose from: `WhoopBLEManager.didDiscover` connects to the first
    /// matching peripheral immediately, so a "Pair a Device" button and a "Scan" button are the same
    /// action and there is nothing else this could offer. A device picker in the style of the reference
    /// would need a discovery stream the BLE layer does not have.
    /// Restarts the strap's firmware and reports what happened, on `syncNow()`'s shape.
    ///
    /// **The link drops when the strap restarts**, and the standing connect re-establishes it — so the
    /// message says that rather than reporting a failure when the disconnect arrives.
    public func rebootStrap() async {
        status = "Restarting the strap… the link will drop and come back."
        do {
            try await manage.rebootStrap()
        } catch {
            status = error.localizedDescription
        }
    }

    /// Whether the connected strap can take the persistent-recording command: a live link to a 5.0/MG.
    ///
    /// **Not `supportsSync`**, which answers a different question — whether this *build* frames the
    /// selected model at all. `0x9A` is published for the 5.0/MG alone; the 4.0's table lists the byte
    /// but nothing here has captured a body for it, so the command is refused there whatever the build
    /// can frame.
    public var supportsPersistentRecording: Bool {
        isConnected && (connectedModel == .whoop5 || connectedModel == .whoop5MG)
    }

    /// Asks the strap to persist its motion recording, or to stop.
    ///
    /// **The sentence says *requested*, because the strap's ACK does not confirm the setting** — only a
    /// later drain can. The two actions are explicit rather than a switch: the app cannot read the
    /// flag, so a toggle would draw a state it does not know.
    ///
    /// See `docs/TODO.md` §7.2 for the experiment and `WhoopCommandFrames.persistentR21` for the
    /// opcode's battery warning.
    public func setPersistentRecording(_ enabled: Bool) async {
        status = enabled ? "Requesting persistent recording…" : "Reverting persistent recording…"
        do {
            try await manage.setPersistentRecording(enabled)
            status = enabled
                ? "Persistent recording ON requested. The strap does not confirm the setting — sync history to check."
                : "Persistent recording OFF requested. If the optical engine stays on, reboot the strap."
        } catch {
            status = error.localizedDescription
        }
    }

    public func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            try await manage.startScanning()
            status = "Scanning for nearby straps…"
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
    /// The name the strap advertises **as the strap itself reports it**, falling back to what the scan
    /// heard until `GET_ADVERTISING_NAME` has answered.
    ///
    /// The fallback matters: `device.name` comes from the advertisement, which CoreBluetooth caches, so
    /// it can lag a rename by minutes. `device.advertisingName` is the stored value read straight off
    /// the strap and is the only one that answers "did it take?".
    public var advertisingName: String? { device?.advertisingName ?? device?.name }

    /// Asks the strap to advertise a different name, and reports only that the request was sent.
    ///
    /// **The strap does not confirm this write**, on either generation — see
    /// `WhoopCommandFrames.setAdvertisingName`. So the status line says *requested*, and the name in
    /// the next advertisement is the only evidence; the caller is told to look there rather than left
    /// believing the rename took.
    public func rename(_ name: String) async {
        let clamped = WhoopCommandFrames.clampedAdvertisingName(name)
        guard !clamped.isEmpty else {
            status = "A strap needs a name of at least one character."
            return
        }
        do {
            try await manage.setAdvertisingName(clamped)
            status = "Rename sent to the strap: \(clamped). Reading it back…"
            // Ask the strap what it stored a moment later, so the row can show the *true* name rather
            // than an advertisement the phone may be caching. The write is not acknowledged; this read
            // is the acknowledgement.
            try? await Task.sleep(for: .seconds(2))
            await manage.requestAdvertisingName()
        } catch {
            status = "Could not send the rename: \(error.localizedDescription)"
        }
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
