import Foundation

/// `StepCounterStateStore` over `UserDefaults`, one JSON document under one key.
///
/// **One key and a `Codable` document rather than six loose keys**, unlike
/// `UserDefaultsAppPreferencesRepository`. The fields are one fact — a continuation and two totals
/// that only mean anything together — and six independent keys could be half-written in a way no
/// reader could detect. A single `Data` is written by one `set` and read by one `object(forKey:)`,
/// which is the closest `UserDefaults` gets to a transaction.
///
/// It is deliberately **not** `@unchecked Sendable`'s usual lock dance: the caller is
/// `TrackStepsUseCase`, an actor, and it is the only writer. `UserDefaults` itself is thread-safe.
public final class UserDefaultsStepCounterStateStore: StepCounterStateStore, @unchecked Sendable {

    /// The key the document lives under.
    public static let defaultsKey = "org.whoopsy.steps.counterState"

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsStepCounterStateStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> StepCounterState? {
        // `object(forKey:)` rather than `data(forKey:)`: the latter answers `nil` for both an absent
        // key and a stored non-Data value, and only one of those is a fresh install. The distinction
        // does not change the answer here — both are `nil` — but reading the object first is what
        // keeps a corrupted value from being silently treated as no state at all.
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data else { return nil }
        return try? decoder.decode(StepCounterState.self, from: data)
    }

    public func save(_ state: StepCounterState) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
