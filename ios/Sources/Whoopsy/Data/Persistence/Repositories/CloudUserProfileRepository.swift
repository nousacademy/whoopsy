import Foundation

/// The local-first decorator for `user_profiles`: a save mirrors to the database, and a phone that has
/// never stored a profile is asked of it, on `CloudRecoveryRepository`'s rule.
///
/// **The read-back is gated on the absence of a *local row*, not on the profile being the cold-start.**
/// `getUserProfile()` answers the 190/60 pair when nothing is stored, so the decorator asks
/// `getLocalUserProfile()` — which returns `nil` for no row — and only then reaches the database. A phone
/// that *has* a stored profile never makes the request, so an offline edit is not overwritten by a stale
/// cloud copy.
public struct CloudUserProfileRepository: UserProfileRepository {

    private let local: any UserProfileRepository
    private let cloud: any CloudSync
    private let settingsStore: any SyncSettingsRepository
    /// Injected so the runner is not a function of the hour it runs. `DIContainer` passes
    /// `SyncSchedule.isOpen`; the default keeps every test and preview open.
    private let isCallWindowOpen: @Sendable () -> Bool

    public init(
        local: any UserProfileRepository,
        cloud: any CloudSync,
        settingsStore: any SyncSettingsRepository,
        isCallWindowOpen: @escaping @Sendable () -> Bool = { true }
    ) {
        self.local = local
        self.cloud = cloud
        self.settingsStore = settingsStore
        self.isCallWindowOpen = isCallWindowOpen
    }

    public func getUserProfile() async throws -> UserProfile {
        let stored = try await local.getUserProfile()
        guard await storesInCloud() else { return stored }

        // Only the absence of a *row* triggers the fallback: a phone holding the cold-start pair as a
        // real, user-set profile must not be overwritten by a cloud copy.
        guard try await local.getLocalUserProfile() == nil else { return stored }
        do {
            guard let row = try await cloud.profile() else { return stored }
            return row.profile
        } catch let error as CloudSyncError {
            guard case .unreachable = error else { throw error }
            return stored
        }
    }

    public func getLocalUserProfile() async throws -> UserProfile? {
        try await local.getLocalUserProfile()
    }

    /// **Local only** — the daily run writes the database copy. See `SyncSchedule`.
    public func saveUserProfile(_ profile: UserProfile) async throws {
        try await local.saveUserProfile(profile)
    }

    private func storesInCloud() async -> Bool {
        guard await settingsStore.load().destination == .cloud else { return false }
        return isCallWindowOpen()
    }
}
