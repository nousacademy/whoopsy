import Foundation

public protocol UserProfileRepository: Sendable {
    /// Fetch the local user profile
    func getUserProfile() async throws -> UserProfile

    /// The stored profile, or `nil` when the user has never filled the form in — the one read that
    /// never substitutes the cold-start 190/60 pair, so a caller can tell *no row* from *a row holding
    /// the default*.
    func getLocalUserProfile() async throws -> UserProfile?

    /// Update user profile
    func saveUserProfile(_ profile: UserProfile) async throws
}
