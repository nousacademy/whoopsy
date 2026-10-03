import Foundation
import GRDB

/// The one translator between `UserProfile` and its row.
///
/// **Both mappers carry every field the record declares, and that is a requirement rather than
/// tidiness.** GRDB's `save` is INSERT-or-UPDATE over the **whole row**, so a `saveUserProfile` that
/// built a three-field `UserProfileRecord` would write `NULL` over `name`, `birthDate`, `gender` and
/// `heightCm` on every save — no throw, no log, and the symptom is a form that is empty on the second
/// launch. The record's own doc comment says the same thing from the other side; §18 asserts it.
///
/// The `Gender` ↔ raw `String` translation happens here and nowhere else, because `UserProfileRecord`
/// cannot name a type from `Domain` and this is the only place both are in scope.
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
    ///
    /// **The other five are deliberately absent from this fallback and must stay that way.** A fresh
    /// install has measured nothing and been told nothing about the user, and a weight conjured here
    /// would be a body this app invented; a name, a birthday, a height or a gender conjured here would
    /// be the same fabrication in a field the user is about to type into, which is the one place they
    /// would believe it. `v20` deleted exactly those defaults from the entity, and this fallback is
    /// where they would come back.
    private static let coldStartMaxHeartRate = 190
    private static let coldStartRestingHeartRate = 60

    public func getUserProfile() async throws -> UserProfile {
        guard let record = try await db.getProfile() else {
            return UserProfile(
                maxHeartRate: Self.coldStartMaxHeartRate,
                restingHeartRate: Self.coldStartRestingHeartRate,
                weightKg: nil,
                heightCm: nil,
                gender: nil
            )
        }
        return UserProfile(
            name: record.name,
            birthDate: record.birthDate,
            maxHeartRate: record.maxHeartRate,
            restingHeartRate: record.restingHeartRate,
            weightKg: record.weightKg,
            heightCm: record.heightCm,
            gender: record.gender.flatMap(UserProfile.Gender.init(rawValue:))
        )
    }

    /// Writes the profile back, carrying every field through **unchanged when it is `nil`**.
    ///
    /// `nil` is a real value here rather than "leave it alone": the profile page clears a field by
    /// saving a profile without it, and a save that quietly preserved the old value would make the
    /// field unclearable. The two are the same only under `save`, which is INSERT-or-UPDATE by primary
    /// key and writes the whole row.
    ///
    /// **`record.gender` is the raw `String` and `profile.gender` is the enum, and the mapping is
    /// one-way on each side**: writing takes `rawValue` (which is total, since the enum cannot hold a
    /// value that is not a case), and reading takes `init(rawValue:)` (which is not, and is why an
    /// unrecognised word becomes `nil` — a vocabulary this build cannot describe is *not supplied*,
    /// never a neighbouring case the user did not pick).
    public func saveUserProfile(_ profile: UserProfile) async throws {
        let record = UserProfileRecord(
            id: "primary",
            maxHeartRate: profile.maxHeartRate,
            restingHeartRate: profile.restingHeartRate,
            weightKg: profile.weightKg,
            name: profile.name,
            birthDate: profile.birthDate,
            gender: profile.gender?.rawValue,
            heightCm: profile.heightCm
        )
        try await db.saveProfile(record)
    }
}
