import Foundation
import GRDB

public final class GRDBUserProfileRepository: UserProfileRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    public func getUserProfile() async throws -> UserProfile {
        guard let record = try await db.getProfile() else {
            return UserProfile(maxHeartRate: 190, restingHeartRate: 60)
        }
        return UserProfile(
            maxHeartRate: record.maxHeartRate,
            restingHeartRate: record.restingHeartRate
        )
    }

    public func saveUserProfile(_ profile: UserProfile) async throws {
        let record = UserProfileRecord(
            id: "primary",
            maxHeartRate: profile.maxHeartRate,
            restingHeartRate: profile.restingHeartRate
        )
        try await db.saveProfile(record)
    }
}