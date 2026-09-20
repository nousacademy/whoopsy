import Foundation
import SwiftUI

@MainActor @Observable public final class DeviceViewModel {
    public var device: WhoopDevice?; public var isScanning = false; public var status = ""; public var preferences = AppPreferences()
    private let manage: ManageBLEConnectionUseCase; private let sync: SyncHistoricalDataUseCase; private let preferencesRepository: any AppPreferencesRepository; private var task: Task<Void, Never>?
    public init(manage: ManageBLEConnectionUseCase, sync: SyncHistoricalDataUseCase, preferencesRepository: any AppPreferencesRepository) { self.manage = manage; self.sync = sync; self.preferencesRepository = preferencesRepository }
    public func load() async { device = await manage.getCurrentDevice(); preferences = await preferencesRepository.load(); task = Task { [weak self, manage] in for await item in manage.deviceStream { guard !Task.isCancelled else { return }; self?.device = item } } }
    public func scan() async { isScanning = true; defer { isScanning = false }; do { try await manage.startScanning(); status = "Scanning for nearby WHOOP straps…" } catch { status = error.localizedDescription } }
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
        } catch {
            status = error.localizedDescription
        }
    }
    public func setBroadcast(_ value: Bool) async { preferences.liveHeartRateBroadcastEnabled = value; await preferencesRepository.save(preferences); status = value ? "Broadcast preference saved. This strap transport is not available yet." : "Broadcast preference disabled." }
}
