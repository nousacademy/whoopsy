import Foundation
import Whoopsy

/// A health store that answers from arrays.
///
/// Stands in for `HKHealthStore` so the importer's day attribution, skipping and idempotency are
/// assertable with no device, no entitlement and no authorization prompt — the three things that
/// make the real path untestable off-device.
struct FixtureHealthStore: HealthStoreClient {
    var hrv: [HealthQuantitySample] = []
    var restingHeartRate: [HealthQuantitySample] = []

    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
    func requestReadAuthorization() async -> Bool { true }

    func quantitySamples(
        _ metric: HealthQuantityMetric, from start: Date, to end: Date
    ) async throws -> [HealthQuantitySample] {
        // Applies the window the importer asked for, like the real query predicate does. Without
        // this the fixture would hand back samples outside the requested range and hide a wrong
        // range calculation.
        //
        // Spelled out per metric rather than as a two-way ternary. The ternary this replaced sent
        // everything that was not HRV to the resting-heart-rate array, so a new case would have
        // silently answered its query with heart rates — a fixture inventing a reading of the wrong
        // quantity, which is worse than the missing case a `switch` would give.
        let all: [HealthQuantitySample]
        switch metric {
        case .heartRateVariabilitySDNN: all = hrv
        case .restingHeartRate: all = restingHeartRate
        }
        return all.filter { $0.start >= start && $0.start <= end }
    }

    func sleepSegments(from start: Date, to end: Date) async throws -> [HealthSleepSegment] { [] }
}

struct NoSleepSource: SleepRepository {
    func getSleepSession(for date: Date) async throws -> SleepSession? { nil }
    func saveSleepSession(_ session: SleepSession, source: String?) async throws {}
    /// Implements the requirement, not the `days:`-only convenience: once `days:` moved to a protocol
    /// extension it stopped dispatching, so a conformer that still implemented only the old form would
    /// compile and have its body silently never called through `any SleepRepository`.
    func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession] { [] }
}

/// A real repository with a counter on its one windowed read.
///
/// It exists so that "the week chart costs no query of its own" can be **asserted** rather than stated
/// in a doc comment. That claim is the entire justification for `SleepViewModel.resolveWindow` losing
/// its read and taking the history as an argument, and it is exactly the kind of claim that decays
/// silently: adding a `getSleepHistory` call back inside a resolver would leave every figure on the
/// screen correct and only make the page issue two queries that could come back describing different
/// nights — which is the failure the shared read exists to prevent, and one no assertion on a *value*
/// can see.
///
/// Only the history is counted. `getSleepSession` is a keyed read of one row and is not the query this
/// is about.
actor CountingSleepRepository: SleepRepository {
    private let inner: any SleepRepository
    private(set) var historyReads = 0

    init(wrapping inner: any SleepRepository) { self.inner = inner }

    func getSleepSession(for date: Date) async throws -> SleepSession? {
        try await inner.getSleepSession(for: date)
    }

    func saveSleepSession(_ session: SleepSession, source: String?) async throws {
        try await inner.saveSleepSession(session, source: source)
    }

    func getSleepHistory(days: Int, endingOn: Date) async throws -> [SleepSession] {
        historyReads += 1
        return try await inner.getSleepHistory(days: days, endingOn: endingOn)
    }
}
