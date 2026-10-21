import Foundation

/// Where the sync destination is kept durably, so "sync API selected" survives an uninstall.
///
/// The one value on `SyncSettings` that must outlive the app's `UserDefaults`: a delete wipes
/// `UserDefaults`, and a fresh install that forgot it was a cloud install could not read its own rows
/// back. `KeychainDestinationStore` is the production implementation; a test injects a fake.
public protocol DestinationStore: Sendable {
    /// The stored destination, or `nil` when nothing was ever written or the value is unreadable.
    func load() async -> SyncSettings.Destination?

    /// Upsert the destination — replace it if present — so switching back to `.device` updates rather
    /// than leaving a stale `.cloud` behind.
    func save(_ destination: SyncSettings.Destination) async
}
