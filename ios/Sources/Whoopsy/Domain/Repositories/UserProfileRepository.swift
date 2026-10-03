import Foundation

public protocol UserProfileRepository: Sendable {
    /// Fetch the local user profile
    func getUserProfile() async throws -> UserProfile

    /// Update user profile
    func saveUserProfile(_ profile: UserProfile) async throws
}
