import Foundation

/// The app's single HealthKit entry point: the importer writes days into local storage, one
/// read-through answers on demand without storing anything, and the write-side export stub below
/// still has no caller.
///
/// It lives beside the rest of the health types rather than in `Data/Exporters/`. It spent its life
/// there while it claimed availability it could not honour — a read-side importer is not an
/// exporter, and keeping availability next to the code that actually queries the store is what
/// stops that claim from drifting again.
public final class HealthKitBridge: HealthKitSyncing, Sendable {

    private let store: any HealthStoreClient
    private let importer: HealthKitImporter

    public init(
        store: any HealthStoreClient,
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        userProfileRepository: any UserProfileRepository,
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.importer = HealthKitImporter(
            store: store,
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            userProfileRepository: userProfileRepository,
            calendar: calendar,
            clock: clock)
    }

    /// A runtime check, not `#if canImport(HealthKit)`. The framework is present in the macOS SDK,
    /// so the compile-time guard is true on the host and guards nothing: it reported HealthKit
    /// available on a platform with no health store at all.
    public var isAvailable: Bool { store.isAvailable }

    public var unavailableReason: String? { store.unavailableReason }

    public func requestAuthorization() async -> Bool {
        await store.requestReadAuthorization()
    }

    public func importRecentHealthData(days: Int) async throws -> HealthImportSummary {
        try await importer.importRecent(days: days)
    }

    public func exportHeartRateSample(bpm: Int, timestamp: Date) async throws {
        // Bridges to HKQuantitySample(type: HKQuantityType.heartRate, ...)
    }
}
