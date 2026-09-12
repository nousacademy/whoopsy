import Foundation
import SwiftUI

@MainActor @Observable public final class DeviceViewModel {
    public var device: WhoopDevice?; public var isScanning = false; public var status = ""; public var preferences = AppPreferences()
    private let manage: ManageBLEConnectionUseCase; private let sync: SyncHistoricalDataUseCase; private let preferencesRepository: any AppPreferencesRepository; private var task: Task<Void, Never>?
    public init(manage: ManageBLEConnectionUseCase, sync: SyncHistoricalDataUseCase, preferencesRepository: any AppPreferencesRepository) { self.manage = manage; self.sync = sync; self.preferencesRepository = preferencesRepository }
    public func load() async { device = await manage.getCurrentDevice(); preferences = await preferencesRepository.load(); task = Task { [weak self, manage] in for await item in manage.deviceStream { guard !Task.isCancelled else { return }; self?.device = item } } }
    public func scan() async { isScanning = true; defer { isScanning = false }; do { try await manage.startScanning(); status = "Scanning for nearby WHOOP straps…" } catch { status = error.localizedDescription } }
    public func syncNow() async { do { try await sync.execute(); status = "History sync complete." } catch { status = error.localizedDescription } }
    public func setBroadcast(_ value: Bool) async { preferences.liveHeartRateBroadcastEnabled = value; await preferencesRepository.save(preferences); status = value ? "Broadcast preference saved. This strap transport is not available yet." : "Broadcast preference disabled." }
}
