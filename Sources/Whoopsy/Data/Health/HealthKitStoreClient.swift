import Foundation
@preconcurrency import HealthKit

/// Reads from a real `HKHealthStore`.
///
/// Not gated on `#if canImport(HealthKit)` for the production path: HealthKit is present in the
/// **macOS** SDK as well as iOS, so `canImport` is true on the host and guards nothing. The real
/// gate is the runtime `HKHealthStore.isHealthDataAvailable()`, which is false on macOS. This type
/// therefore compiles everywhere and reports itself unavailable where it cannot work.
public actor HealthKitStoreClient: HealthStoreClient {

    private let store = HKHealthStore()

    public init() {}

    /// `nonisolated` because the protocol requirement is synchronous and callers ask before any
    /// work starts. `isHealthDataAvailable()` is a class method and touches no actor state.
    public nonisolated var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public nonisolated var unavailableReason: String? {
        HKHealthStore.isHealthDataAvailable()
            ? nil
            : "Health data is not available on this device. On macOS the HealthKit framework links, "
                + "but no health store exists — run the app on an iPhone to import."
    }

    // MARK: - Types

    /// The quantity types this client will read. Not all are imported yet; the extra ones are
    /// authorized in one prompt so a later importer does not need a second consent screen.
    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
        for metric in HealthQuantityMetric.allCases {
            if let type = quantityType(for: metric) { types.insert(type) }
        }
        return types
    }

    private static func quantityType(for metric: HealthQuantityMetric) -> HKQuantityType? {
        switch metric {
        case .heartRateVariabilitySDNN:
            return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .restingHeartRate:
            return HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case .respiratoryRate:
            return HKObjectType.quantityType(forIdentifier: .respiratoryRate)
        case .oxygenSaturation:
            return HKObjectType.quantityType(forIdentifier: .oxygenSaturation)
        case .sleepingWristTemperature:
            return HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature)
        case .stepCount:
            return HKObjectType.quantityType(forIdentifier: .stepCount)
        }
    }

    /// HealthKit stores every quantity in a canonical unit and converts on read. Getting this wrong
    /// does not fail loudly — it silently rescales every value (SpO2 read as a fraction when you
    /// expected percent reads as 0.97, not 97).
    private static func unit(for metric: HealthQuantityMetric) -> HKUnit? {
        switch metric {
        case .heartRateVariabilitySDNN:
            return HKUnit.secondUnit(with: .milli)
        case .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .oxygenSaturation:
            return HKUnit.percent()
        case .sleepingWristTemperature:
            return HKUnit.degreeCelsius()
        case .stepCount:
            return HKUnit.count()
        }
    }

    // MARK: - Authorization

    public func requestReadAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            // `true` here means the prompt completed. The user may still have denied every read
            // scope and HealthKit will not say so.
            return true
        } catch {
            return false
        }
    }

    // MARK: - Queries

    public func quantitySamples(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> [HealthQuantitySample] {
        guard isAvailable else {
            throw HealthStoreUnavailableError(reason: unavailableReason ?? "Health data unavailable.")
        }
        guard let type = Self.quantityType(for: metric), let unit = Self.unit(for: metric) else {
            throw HealthStoreUnavailableError(
                reason: "This device does not support \(metric.rawValue).")
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: [.strictStartDate])
        let descriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [descriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // Flatten to plain Doubles inside the callback. `HKQuantitySample` is not Sendable,
                // so it must not be what the continuation carries across.
                let values: [HealthQuantitySample] =
                    (samples as? [HKQuantitySample])?.map { sample in
                        HealthQuantitySample(
                            value: sample.quantity.doubleValue(for: unit),
                            start: sample.startDate,
                            end: sample.endDate)
                    } ?? []
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    /// `HKStatisticsQuery`, not `HKSampleQuery`: a cumulative metric is only meaningful summed, and
    /// letting HealthKit do the addition avoids pulling a day's several hundred step samples across
    /// the continuation to add them up here.
    ///
    /// `sumQuantity` is nil exactly when the window holds no samples, which maps straight onto the
    /// protocol's `nil` — so "nothing measured" and "measured zero" stay distinguishable.
    public func dailyTotal(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> Double? {
        guard isAvailable else {
            throw HealthStoreUnavailableError(reason: unavailableReason ?? "Health data unavailable.")
        }
        guard let type = Self.quantityType(for: metric), let unit = Self.unit(for: metric) else {
            throw HealthStoreUnavailableError(
                reason: "This device does not support \(metric.rawValue).")
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: [.strictStartDate])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // `statistics` itself is not Sendable either, so only the Double crosses back.
                let sum = statistics?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: sum)
            }
            store.execute(query)
        }
    }

    public func sleepSegments(from start: Date, to end: Date) async throws -> [HealthSleepSegment] {
        guard isAvailable else {
            throw HealthStoreUnavailableError(reason: unavailableReason ?? "Health data unavailable.")
        }
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthStoreUnavailableError(reason: "Sleep analysis is unavailable on this device.")
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: [.strictStartDate])
        let descriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [descriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let segments: [HealthSleepSegment] =
                    (samples as? [HKCategorySample])?.compactMap { sample in
                        guard
                            let value = HKCategoryValueSleepAnalysis(
                                rawValue: sample.value)
                        else { return nil }
                        return HealthSleepSegment(
                            stage: Self.stage(for: value),
                            start: sample.startDate,
                            end: sample.endDate)
                    } ?? []
                continuation.resume(returning: segments)
            }
            store.execute(query)
        }
    }

    /// Maps Apple's AASM-derived stages onto the four this app models.
    ///
    /// `asleepUnspecified` and `asleepCore` both become `light`: Core is the bulk of NREM and is
    /// what the app's "light" bucket has always meant. `.asleep` is the deprecated pre-iOS-16
    /// spelling and maps the same way.
    private static func stage(for value: HKCategoryValueSleepAnalysis) -> HealthSleepStage {
        switch value {
        case .inBed: return .inBed
        case .awake: return .awake
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        case .asleepCore, .asleepUnspecified, .asleep: return .light
        @unknown default: return .light
        }
    }
}
