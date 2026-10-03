import Foundation

/// Counts the day's steps off the strap's motion stream and stores them.
///
/// `AnalyzeSleepUseCase`'s producer shape — read the day, guard, compute, write once — with one
/// difference that shapes everything below: **this one never finishes.** A night is classified when
/// it is over; a day's step count is accumulated while it happens, from a 100 Hz stream that runs for
/// as long as the app is connected. So this is a long-running consumer rather than a call, and it is
/// started once from `MainContainerView`'s app-level task.
///
/// ## Why it is not driven from a screen
///
/// `HomeViewModel.load(for:)` runs on **every day-step tap**, and a subscription per tap is the
/// documented multicast failure: the manager's continuation dictionary accumulates a subscriber per
/// call, and the streams are the app's only source of motion. Worse, the failure is silent — a
/// `for await` that stops receiving looks exactly like a strap that went quiet. One subscription for
/// the life of the process, and this actor's own `isRunning` guard is what enforces it.
///
/// ## Why the count is accumulated and never recomputed
///
/// A day of 100 Hz motion across three axes is ~26M samples. None of it is stored: `StepAccumulator`
/// consumes each batch and keeps the running figure, and `stepCounts` holds one row per day. There is
/// no series to re-walk, which is why this is a stored total rather than a projection — see
/// `StepCount`.
///
/// ## Why an actor
///
/// It holds mutable state that outlives a single call — one accumulator per day it is filling — and
/// it is fed from a stream. A `final class … : Sendable` with a lock would work; an actor makes the
/// serialisation structural instead of a rule the next editor has to remember.
public actor TrackStepsUseCase {
    private let bleRepository: any WhoopBLEDeviceRepository
    private let stepRepository: any StepRepository

    /// One accumulator per day being filled, keyed by `startOfDay`.
    ///
    /// **A dictionary rather than a single accumulator, and that is the banked path's requirement
    /// rather than a generality.** A drained record from last night is stamped last night, and it can
    /// arrive while today's live stream is running. One accumulator would have to choose between
    /// filing last night's steps under today — a wrong-day row, which is the failure the timestamp
    /// field exists to avoid — and rebuilding its filter state per batch, which at a 1-second gravity
    /// window and a 2-second threshold window against 1-second batches means a **permanently** cold
    /// filter and a badly under-counted day. Two accumulators cost two windows of state.
    ///
    /// Each day's row is written after every batch, so the stored figure is always current and an
    /// evicted accumulator loses only filter state — never a count. See `evictStaleAccumulators`.
    private var accumulators: [Date: StepAccumulator] = [:]

    /// Whether a consumer is already attached. See the type's comment.
    private var isRunning = false

    /// How many days of accumulators are held.
    ///
    /// Two, because a drain fills today and yesterday at most in ordinary use and the current day is
    /// always retained regardless. The bound exists so a strap replaying a month of history cannot
    /// grow this without limit; the work it drops is filter state, not counts.
    private static let retainedDays = 2

    public init(
        bleRepository: any WhoopBLEDeviceRepository,
        stepRepository: any StepRepository
    ) {
        self.bleRepository = bleRepository
        self.stepRepository = stepRepository
    }

    /// Consumes the motion stream for as long as it lives. Returns when the stream ends.
    ///
    /// Idempotent: a second call while one is running returns immediately rather than attaching a
    /// second consumer.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        for await batch in bleRepository.motionStream {
            await ingest(batch)
        }
    }

    /// Feeds one batch into its day's accumulator and writes that day's row.
    private func ingest(_ batch: MotionBatch) async {
        let day = Calendar.current.startOfDay(for: batch.start)

        // The accumulator is created on first sight of a day and seeded from that day's stored row,
        // which is what makes a relaunch mid-day **continue** the count rather than restart it. The
        // filter state is not persisted — see `StepAccumulator` for the two-second transient that
        // costs — but the count and the measured span both are.
        let accumulator: StepAccumulator
        if let existing = accumulators[day] {
            accumulator = existing
        } else {
            let stored = try? await stepRepository.getStepCount(for: day)
            accumulator = StepAccumulator(
                sampleRateHz: 1.0 / batch.sampleIntervalSeconds,
                baselineStepCount: stored?.stepCount ?? 0,
                measuredSeconds: stored?.measuredSeconds ?? 0)
        }

        var updated = accumulator
        updated.accept(
            accelerometerXG: batch.accelerometerG.x,
            accelerometerYG: batch.accelerometerG.y,
            accelerometerZG: batch.accelerometerG.z,
            sampleIntervalSeconds: batch.sampleIntervalSeconds,
            // The samples' own instants, on the batch's scale. Only differences are read, so a live
            // batch's arrival instant and a banked batch's strap unix time are both usable — and
            // using the real instant rather than a synthetic counter is what makes the refractory
            // interval respect a gap *between* two batches instead of fusing their seam.
            startSeconds: batch.start.timeIntervalSince1970)
        accumulators[day] = updated

        await write(updated, for: day)
        evictStaleAccumulators(keeping: day)
    }

    /// Writes the day's row, on the absence rule: **a writer persists only when it produced a
    /// measurement, and the test it uses is the one its readers use.**
    ///
    /// That test is `measuredSeconds > 0` — the same comparison `StepCount.hasMeasurement` makes and
    /// the same one the readers gate on. It is not `stepCount > 0`: a measured day of no walking is a
    /// real `0` that must be stored and must render as a figure, not as a dash. A batch carries a
    /// second of sample time, so in practice every batch writes; the guard is here so the rule is
    /// structural rather than implied by the batch size.
    private func write(_ accumulator: StepAccumulator, for day: Date) async {
        guard accumulator.measuredSeconds > 0 else { return }
        do {
            try await stepRepository.saveStepCount(
                StepCount(
                    date: day,
                    stepCount: accumulator.stepCount,
                    measuredSeconds: accumulator.measuredSeconds))
        } catch {
            AppLogger.database.error("Failed saving step count: \(error.localizedDescription)")
        }
    }

    /// Drops accumulators for days outside the retention window.
    ///
    /// Safe by construction rather than by care: every day's row is written after every batch, so the
    /// only thing held in an accumulator is filter state. Dropping one costs a cold filter if that day
    /// is fed again — a second or two of under-count — and can never lose a step that was counted.
    private func evictStaleAccumulators(keeping day: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retainedDays, to: day) ?? day
        accumulators = accumulators.filter { $0.key >= cutoff }
    }
}
