import Foundation

/// Which quantities this app may ask HealthKit for.
///
/// Deliberately not `HKQuantityTypeIdentifier`: this file must not import HealthKit, so that the
/// importer and its tests can be compiled and exercised on a machine with no HealthKit store, and
/// so a protocol the Data layer depends on does not leak framework types into its signature.
///
/// Most of these are **scalar readings** — one value per sample, which is what `quantitySamples`
/// returns. `stepCount` is not: steps accumulate through the day and only their **sum over a
/// window** means anything, so a per-sample read of it would hand back a few hundred fragments
/// nobody can use. It is read through `dailyTotal(_:from:to:)` instead.
public enum HealthQuantityMetric: String, CaseIterable, Sendable {
    /// The only HRV quantity Apple exposes. There is no RMSSD type in HealthKit.
    case heartRateVariabilitySDNN
    case restingHeartRate
    /// Cumulative, not a reading — see the type comment. Summed, never sampled.
    case stepCount

    /// The unit this metric is stored in, for documentation and for import conversion.
    public var unitDescription: String {
        switch self {
        case .heartRateVariabilitySDNN: return "ms"
        case .restingHeartRate: return "count/min"
        case .stepCount: return "count"
        }
    }
}

/// One scalar reading, flattened out of HealthKit's object graph.
///
/// `HKQuantitySample` is not `Sendable`, so a query result can never be resumed out of a
/// continuation intact. Everything crossing that boundary is reduced to these plain values inside
/// the query callback.
public struct HealthQuantitySample: Sendable, Equatable {
    public let value: Double
    public let start: Date
    public let end: Date

    public init(value: Double, start: Date, end: Date) {
        self.value = value
        self.start = start
        self.end = end
    }
}

/// Sleep stages, mapped down to the four the app models plus the in-bed envelope.
public enum HealthSleepStage: String, Sendable, CaseIterable {
    /// The `inBed` envelope. Overlaps every other stage and must be excluded from stage totals.
    case inBed
    case awake
    case light
    case deep
    case rem
}

public struct HealthSleepSegment: Sendable, Equatable {
    public let stage: HealthSleepStage
    public let start: Date
    public let end: Date

    public init(stage: HealthSleepStage, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Thrown when the importer is invoked somewhere HealthKit cannot serve.
public struct HealthStoreUnavailableError: Error, LocalizedError, Sendable {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public var errorDescription: String? { reason }
}

/// Read access to a health store, abstracted so the importer is testable without a device.
///
/// Only reads are modelled. The app's HealthKit *export* path is separate and unrelated — see
/// `HealthKitBridge`.
public protocol HealthStoreClient: Sendable {
    /// Whether a usable health store exists right now. A compile-time `canImport` check is not
    /// enough: HealthKit links on macOS but `HKHealthStore.isHealthDataAvailable()` returns false
    /// there, so code guarded only by `canImport` claims availability it cannot honour.
    var isAvailable: Bool { get }

    /// Human-readable explanation when `isAvailable` is false.
    var unavailableReason: String? { get }

    /// Requests **read** access. A `true` result means the prompt completed, not that the user
    /// granted anything: HealthKit never reveals read-permission status, so a denial also reports
    /// success. Treat the import result as the real signal.
    func requestReadAuthorization() async -> Bool

    func quantitySamples(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> [HealthQuantitySample]

    /// The **sum** of a cumulative metric over a window — how many steps were taken between `start`
    /// and `end`.
    ///
    /// Returns `nil`, not `0`, when the window holds no samples. The two are different claims: a day
    /// with no step data means HealthKit has nothing for it (or the user declined, which HealthKit
    /// will not disclose), while a measured zero steps is a real — if sedentary — day. Collapsing them
    /// would put a confident "0 steps" on a day nobody measured, which is the same failure the rest of
    /// this codebase renders as a dash.
    func dailyTotal(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> Double?

    func sleepSegments(from start: Date, to end: Date) async throws -> [HealthSleepSegment]
}
