import Foundation

/// Where `SyncSettings` is kept between launches.
///
/// **Neither method throws, and that is `AppPreferencesRepository`'s shape rather than an oversight.**
/// There is no absent case to signal: a store holding nothing is a fresh install, and a fresh install
/// is `SyncSettings()` — one destination, this phone, and no span drawn. `load()` therefore answers a
/// value on every path including the one where the storage was never written, and a caller never has
/// to decide what a *missing* answer means, because there is no such answer to have.
///
/// `load()` rather than a `settings` property, because the conforming store is free to be an actor
/// with this as its only door — the same reason `AppPreferencesRepository` has this exact pair.
///
/// **The sync's settings deliberately do not live in `AppPreferences`.** That struct is exported: it is
/// what `ExportLocalDataUseCase` writes into the JSON's `settings` block, and §6 of the runner asserts
/// that shape. A control that decides where a user's history is *stored* has no business in a file that
/// records what the app looks like, and whether an export should carry it is a real question this slice
/// answers by not answering it — the two stores are separate so the question stays open rather than
/// being settled by whatever the export happened to pick up.
public protocol SyncSettingsRepository: Sendable {
    /// The stored destination and span, or a fresh install's default if nothing has been stored.
    func load() async -> SyncSettings

    /// Replace the stored boundary. Called by the storage pane when the user moves either control, and
    /// by nothing else: nothing about a run writes it back, because a run no longer has a position to
    /// record — the span it walks is the span the user drew.
    func save(_ settings: SyncSettings) async
}
