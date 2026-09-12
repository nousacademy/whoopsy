import Foundation

/// Chooses which health store the composition root hands to the rest of the app.
///
/// There is no `UnavailableHealthStoreClient`. One was planned, but `HealthKitStoreClient` already
/// *is* that client: HealthKit links on macOS and on the simulator, `HKHealthStore()` constructs
/// without complaint, and only the runtime `HKHealthStore.isHealthDataAvailable()` decides whether
/// anything can be read. A separate type would be a second implementation of the same answer, and
/// the branch that selects it would never be the one that runs.
public enum HealthStoreClientFactory {

    /// The real store. Reports itself unavailable wherever no health data exists, including the
    /// macOS host, so callers never need their own platform check.
    public static func make() -> any HealthStoreClient {
        HealthKitStoreClient()
    }

    /// A store that refuses everything, for SwiftUI previews.
    ///
    /// It does not serve fixture readings. Previews are backed by `LocalDatabaseManager.shared`, so
    /// a preview client with data would write invented SDNN days into the developer's real database
    /// — and an invented day is indistinguishable from a measured one once it is in the baseline.
    /// Reporting unavailable keeps the canvas inert, and it is also true: previews have no health
    /// store either.
    public static func makePreview() -> any HealthStoreClient {
        PreviewHealthStoreClient()
    }
}

/// See `HealthStoreClientFactory.makePreview()` for why this returns no data rather than fake data.
public struct PreviewHealthStoreClient: HealthStoreClient {
    public init() {}

    public var isAvailable: Bool { false }

    public var unavailableReason: String? { "Health data is not available in previews." }

    public func requestReadAuthorization() async -> Bool { false }

    public func quantitySamples(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> [HealthQuantitySample] {
        throw HealthStoreUnavailableError(reason: unavailableReason ?? "Unavailable.")
    }

    public func dailyTotal(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> Double? {
        throw HealthStoreUnavailableError(reason: unavailableReason ?? "Unavailable.")
    }

    public func sleepSegments(from start: Date, to end: Date) async throws -> [HealthSleepSegment] {
        throw HealthStoreUnavailableError(reason: unavailableReason ?? "Unavailable.")
    }
}
