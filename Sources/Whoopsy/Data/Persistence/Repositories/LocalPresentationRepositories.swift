import Foundation

// `LocalWorkoutRepository` used to live here: an actor wrapping a `[WorkoutSession]` array, which
// meant a recorded workout was gone at the next launch and `latest()` was never called by anything.
// It is `GRDBWorkoutRepository` now. Nothing in this file is workout-related.

public final class UserDefaultsAppPreferencesRepository: AppPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "org.whoopsy.presentation.preferences"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() async -> AppPreferences {
        AppPreferences(analyticsEnabled: defaults.bool(forKey: key + ".analytics"), healthKitSyncEnabled: defaults.bool(forKey: key + ".health"), liveHeartRateBroadcastEnabled: defaults.bool(forKey: key + ".broadcast"), hasImportedWhoopExport: defaults.bool(forKey: key + ".whoopExport"))
    }
    public func save(_ preferences: AppPreferences) async {
        defaults.set(preferences.analyticsEnabled, forKey: key + ".analytics")
        defaults.set(preferences.healthKitSyncEnabled, forKey: key + ".health")
        defaults.set(preferences.liveHeartRateBroadcastEnabled, forKey: key + ".broadcast")
        defaults.set(preferences.hasImportedWhoopExport, forKey: key + ".whoopExport")
    }
}

// `HealthKitBridge` declares its own `HealthKitSyncing` conformance — it moved to `Data/Health/`
// and now carries real query code, so it no longer needs a conforming extension declared here.
