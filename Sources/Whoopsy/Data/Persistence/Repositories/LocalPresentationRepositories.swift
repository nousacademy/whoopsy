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

/// Which model each strap is, remembered in `UserDefaults`.
///
/// **`UserDefaults` rather than a GRDB table, and the reason is a deliberate trade.** A migration is
/// frozen once shipped, and a failing one `fatalError`s the app at launch — so a schema version is a
/// permanent cost paid for data that is a *preference about the user's hardware*, not a measurement.
/// The repo already keeps its non-measured settings here, beside `UserDefaultsAppPreferencesRepository`
/// and in the same shape, so this adds no new mechanism.
///
/// What that knowingly gives up: a peripheral identifier is stable across launches but not across a
/// reinstall, so a reinstall loses the mapping. That degrades to the name heuristic plus one tap on
/// the device screen, which is a prompt rather than a wrong answer.
///
/// One key holding a dictionary, rather than a key per device — the peripheral identifiers are not
/// known in advance, so there is no bounded key set to enumerate and `UserDefaults` has no way to
/// list the keys a prefix owns.
public final class UserDefaultsStrapModelRepository: StrapModelRepository, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "org.whoopsy.strapModels"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func allModels() async -> [String: WhoopHardwareGeneration] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: String] else { return [:] }
        // An unreadable raw value is dropped rather than defaulted. A generation this build no longer
        // has a case for is not a strap that can be described, and guessing one here would put a
        // model on the device screen that the user never chose.
        return raw.compactMapValues(WhoopHardwareGeneration.init(rawValue:))
    }

    public func setModel(_ model: WhoopHardwareGeneration?, forDeviceId: String) async {
        var models = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        models[forDeviceId] = model?.rawValue
        defaults.set(models, forKey: key)
    }
}

// `HealthKitBridge` declares its own `HealthKitSyncing` conformance — it moved to `Data/Health/`
// and now carries real query code, so it no longer needs a conforming extension declared here.
