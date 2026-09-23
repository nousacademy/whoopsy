import Foundation
import GRDB

public final class GRDBUserProfileRepository: UserProfileRepository, Sendable {
    private let db: LocalDatabaseManager

    public init(db: LocalDatabaseManager = .shared) {
        self.db = db
    }

    /// The cold-start pair used when no row exists at all.
    ///
    /// These two stay non-optional on `UserProfile` because the Karvonen zone table cannot be built
    /// without them, so this is a defined starting point rather than an absence — the difference being
    /// that a zone table is computed *from* them and a calorie figure is reported *as* the user's.
    /// `weightKg` is deliberately absent from this fallback and must stay that way: a fresh install has
    /// measured nothing about the user, and a weight conjured here would be a body this app invented.
    private static let coldStartMaxHeartRate = 190
    private static let coldStartRestingHeartRate = 60

    public func getUserProfile() async throws -> UserProfile {
        guard let record = try await db.getProfile() else {
            return UserProfile(
                maxHeartRate: Self.coldStartMaxHeartRate,
                restingHeartRate: Self.coldStartRestingHeartRate,
                weightKg: nil
            )
        }
        return UserProfile(
            maxHeartRate: record.maxHeartRate,
            restingHeartRate: record.restingHeartRate,
            weightKg: record.weightKg
        )
    }

    /// Writes the profile back, carrying `weightKg` through **unchanged when it is `nil`**.
    ///
    /// `nil` is a real value here rather than "leave it alone": the profile page clears a weight by
    /// saving a profile with none, and a save that quietly preserved the old number would make the
    /// field unclearable. The two are the same only under `save`, which is INSERT-or-UPDATE by primary
    /// key and writes the whole row.
    public func saveUserProfile(_ profile: UserProfile) async throws {
        let record = UserProfileRecord(
            id: "primary",
            maxHeartRate: profile.maxHeartRate,
            restingHeartRate: profile.restingHeartRate,
            weightKg: profile.weightKg
        )
        try await db.saveProfile(record)
    }
}