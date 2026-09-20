import Foundation
import SwiftUI

/// The device screen's state: which strap is connected, and which model the user says it is.
///
/// Separate from `DeviceViewModel`, which owns the Settings → Device page. That page is about
/// *connecting*; this one is about *what the strap is*, which is the question the wire format turns
/// on. Two screens, two days, two view models — the same reason Home and the Sleep tab each build
/// their own `SleepViewModel`.
@MainActor @Observable public final class DeviceDetailViewModel {
    /// The connected strap, as the BLE layer currently describes it.
    public private(set) var device: WhoopDevice?

    /// The model shown in the picker.
    ///
    /// Seeded from the strap's *resolved* generation, which is the user's stored choice when there is
    /// one and the name heuristic otherwise. `isModelSaved` is what tells the two apart on screen,
    /// because they are the same value here and a different claim about where it came from.
    public var model: WhoopHardwareGeneration = .whoop4

    /// Whether a model for this strap has actually been chosen, as opposed to inferred.
    public private(set) var isModelSaved = false

    public private(set) var status = ""

    private let manage: ManageBLEConnectionUseCase
    private let strapModels: any StrapModelRepository
    private let protocols: any WhoopProtocolProviding
    private var task: Task<Void, Never>?

    public init(
        manage: ManageBLEConnectionUseCase,
        strapModels: any StrapModelRepository,
        protocols: any WhoopProtocolProviding
    ) {
        self.manage = manage
        self.strapModels = strapModels
        self.protocols = protocols
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

    /// The battery reading, or `nil` when there is not one.
    ///
    /// `WhoopDevice.batteryPercentage` is not optional and defaults to `100`, which `WhoopBLEManager`
    /// writes at discovery — so an unconnected strap would otherwise report a confident fabricated
    /// "100%". Returning `nil` rather than a number is what keeps that off the screen; the same rule
    /// Home's badge follows.
    public var batteryPercentage: Int? {
        guard let device, device.connectionState == .connected else { return nil }
        return device.batteryPercentage
    }

    public func load() async {
        device = await manage.getCurrentDevice()
        await refreshModelState()
        // A second subscriber beside `HomeViewModel.observeDevice()` and `DeviceViewModel.load()`.
        // The stream is multicast precisely so this is safe — see the registry in `WhoopBLEManager`.
        task = Task { [weak self, manage] in
            for await item in manage.deviceStream {
                guard !Task.isCancelled else { return }
                self?.device = item
                await self?.refreshModelState()
            }
        }
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
}
