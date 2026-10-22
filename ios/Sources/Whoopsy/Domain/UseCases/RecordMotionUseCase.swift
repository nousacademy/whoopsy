import Foundation

/// Records the strap's motion as 30-second epochs, so sleep onset has a signal other than heart rate.
///
/// **This is the other half of the onset change.** `AnalyzeSleepUseCase` no longer decides that a
/// night happened from a heart-rate band, because a heart rate cannot tell sleep from lying still
/// awake. It reads these epochs instead and requires a sustained quiet run; a night whose motion
/// never settles is reported as no night however low the rate sat.
///
/// The stream is multicast, so this is an addition beside `TrackStepsUseCase`, not a replacement:
/// the pedometer reads the same batches for steps and this reads them for stillness.
///
/// **One row per 30-second window, and the mean is what the detector thresholds.** A batch is a
/// second or so of 100 Hz axes, so a window is written many times as its batches arrive; the row is
/// an upsert on `start`, and the last write holds the window's final mean. `maxMagnitudeG` is kept
/// because a mean can hide a single movement, and `sampleCount` says how much of the window was
/// actually measured.
public actor RecordMotionUseCase {
    private let bleRepository: any WhoopBLEDeviceRepository
    private let motionRepository: any MotionEpochRepository

    /// The window length the sleep classifier consumes, and therefore the only grid this writer
    /// produces. Changing it here without changing `AnalyzeSleepUseCase` would feed the detector
    /// windows it does not expect.
    public static let epochSeconds: TimeInterval = 30

    private struct Accumulator {
        var sum: Double = 0
        var count: Int = 0
        var max: Double = 0
        var mean: Double { count > 0 ? sum / Double(count) : 0 }
        mutating func add(_ magnitude: Double) {
            sum += magnitude
            count += 1
            max = Swift.max(max, magnitude)
        }
    }

    private var accumulators: [Date: Accumulator] = [:]
    private var isRunning = false

    public init(
        bleRepository: any WhoopBLEDeviceRepository,
        motionRepository: any MotionEpochRepository
    ) {
        self.bleRepository = bleRepository
        self.motionRepository = motionRepository
    }

    /// Consumes the motion stream for as long as it lives. Returns when the stream ends.
    ///
    /// Idempotent, on `TrackStepsUseCase.start()`'s rule: a second call while one is running returns
    /// immediately rather than attaching a second consumer.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        AppLogger.ble.notice("RecordMotionUseCase: attached to the motion stream")
        for await batch in bleRepository.motionStream {
            await ingest(batch)
        }
    }

    private func ingest(_ batch: MotionBatch) async {
        let axes = batch.accelerometerG
        let count = Swift.min(axes.x.count, Swift.min(axes.y.count, axes.z.count))
        guard count > 0 else { return }

        let start = Self.epochStart(for: batch.start)
        var accumulator = accumulators[start] ?? Accumulator()
        for index in 0..<count {
            let x = axes.x[index]
            let y = axes.y[index]
            let z = axes.z[index]
            // `|a|` in Gs, so gravity is included and a still strap reads ≈1.0 rather than 0.
            accumulator.add((x * x + y * y + z * z).squareRoot())
        }
        accumulators[start] = accumulator

        let epoch = MotionEpoch(
            start: start,
            end: start.addingTimeInterval(Self.epochSeconds),
            meanMagnitudeG: accumulator.mean,
            maxMagnitudeG: accumulator.max,
            sampleCount: accumulator.count)
        do {
            try await motionRepository.saveMotionEpoch(epoch)
        } catch {
            AppLogger.database.error(
                "Failed saving motion epoch: \(error.localizedDescription)")
        }
        evictStaleAccumulators(keeping: start)
    }

    /// The 30-second boundary containing `date`, on a fixed epoch grid so a window written from two
    /// overlapping batches lands on one row.
    public static func epochStart(for date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / epochSeconds).rounded(.down) * epochSeconds)
    }

    /// Two days is more than the classifier ever asks for and keeps a long-lived process from
    /// growing a dictionary without bound. The rows themselves stay in the database.
    private func evictStaleAccumulators(keeping day: Date) {
        let cutoff = day.addingTimeInterval(-2 * 86_400)
        accumulators = accumulators.filter { $0.key >= cutoff }
    }
}
