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

    /// The day totals this use case has written, for whichever screen is drawing the current day.
    ///
    /// **A saved row is not a drawn one.** `HomeViewModel` reads `stepCounts` once per day selection,
    /// and this writer flushes a new total every second of motion — so a screen opened before the strap
    /// started moving would hold the dash it read at launch for as long as it stays open, which is a
    /// tile that never populates rather than one that is a little late. This stream is the hand-off
    /// that closes that gap, exactly as `LiveSessionUseCase`'s `onEnded` is for a finished session.
    ///
    /// `nonisolated` so a view model can bind to it without awaiting the actor: subscribers observe a
    /// value, they never drive one.
    public nonisolated var stepUpdates: AsyncStream<StepCount> { hub.stream }

    private nonisolated let hub = StepUpdateHub()

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

        AppLogger.ble.notice("TrackStepsUseCase: attached to the motion stream")
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
            AppLogger.ble.notice("TrackStepsUseCase: first motion for day \(String(describing: day), privacy: .public) (batch.start \(String(describing: batch.start), privacy: .public))")
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
        noteRateIfMinuteRolled(accumulator, for: day)
        let row = StepCount(
            date: day,
            stepCount: accumulator.stepCount,
            measuredSeconds: accumulator.measuredSeconds)
        do {
            try await stepRepository.saveStepCount(row)
            // Only once the store has it: a subscriber drawing this figure would otherwise show a
            // count the database cannot answer back, which is the one way a live tile can be more
            // current than the truth.
            hub.yield(row)
            // `.debug` rather than `.notice`: this fires once per second of motion, so persisting it
            // would bury the day-keying line above under a page of counts.
            AppLogger.ble.debug("TrackStepsUseCase: wrote \(row.stepCount, privacy: .public) steps for \(String(describing: row.date), privacy: .public)")
        } catch {
            AppLogger.database.error("Failed saving step count: \(error.localizedDescription)")
        }
    }

    /// Last logged minute and count per day, so the rate line prints once a minute rather than once
    /// per batch.
    private var lastRateLog: [Date: (minute: Int, steps: Int)] = [:]

    /// One line a minute carrying the two numbers that separate a **mis-scaled** counter from one
    /// that **counts while still** — and they need different fixes.
    ///
    /// `measuredSeconds` grows by the batches' own spans, so comparing its growth against wall time
    /// says whether the strap is delivering 100 Hz records at the expected rate or handing the same
    /// motion to the accumulator more than once. `steps` growth over the same minute is the rate: a
    /// deliberate walk is ~100–130 steps a minute, and anything near the 180/min refractory cap means
    /// the detector is firing on arm movement rather than on footfalls.
    private func noteRateIfMinuteRolled(_ accumulator: StepAccumulator, for day: Date) {
        let minute = Int(accumulator.measuredSeconds / 60)
        guard let previous = lastRateLog[day] else {
            lastRateLog[day] = (minute, accumulator.stepCount)
            AppLogger.ble.notice("""
                TrackSteps rate: begin at steps=\(accumulator.stepCount, privacy: .public) \
                measured=\(Int(accumulator.measuredSeconds), privacy: .public)s
                """)
            return
        }
        guard minute > previous.minute else { return }
        lastRateLog[day] = (minute, accumulator.stepCount)
        let minutes = minute - previous.minute
        let steps = accumulator.stepCount - previous.steps
        // The log line's own timestamp is the wall clock, so it is not repeated here — and `Domain`
        // cannot reach the presentation layer's date formatter anyway.
        AppLogger.ble.notice("""
            TrackSteps rate: +\(steps, privacy: .public) steps in \(minutes, privacy: .public) measured \
            min (total steps=\(accumulator.stepCount, privacy: .public), measured \
            \(Int(accumulator.measuredSeconds) / 60, privacy: .public) min)
            """)
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

/// Fans written day totals out to every attached reader.
///
/// **A lock rather than the actor's isolation, and the choice is forced by `stepUpdates` being
/// `nonisolated`.** A subscriber binds to the stream from a view model's own task, which has no reason
/// to await this actor — and an actor-isolated `AsyncStream` property would put every subscriber
/// behind the writer's mailbox for a value it only reads. This is `WhoopBLEManager`'s three registries
/// in miniature, including the reason they are registries at all: a second reader must not orphan a
/// first, and the failure if one does is silent.
///
/// The type is private to this file because nothing outside the use case may yield into it. A screen
/// that could publish a day total could publish a **fabricated** one, and the row it stands beside
/// would not agree with it.
private final class StepUpdateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<StepCount>.Continuation] = [:]

    var stream: AsyncStream<StepCount> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func yield(_ count: StepCount) {
        lock.lock()
        let readers = Array(continuations.values)
        lock.unlock()
        for reader in readers { reader.yield(count) }
    }
}
