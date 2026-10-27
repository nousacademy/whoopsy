import Foundation

/// Counts the day's steps off the strap and stores them — from the strap's **own counter** where it
/// has one, and from the motion stream's peaks where it does not.
///
/// `AnalyzeSleepUseCase`'s producer shape — read the day, guard, compute, write once — with one
/// difference that shapes everything below: **this one never finishes.** A night is classified when
/// it is over; a day's step count is accumulated while it happens. So this is a long-running consumer
/// rather than a call, and it is started once from `MainContainerView`'s app-level task.
///
/// ## Two producers, and why both are needed
///
/// A 5.0/MG banks an `R18` record about once a second carrying the firmware's own cumulative
/// pedometer (`StepCounterAccumulator`). That is the better source: it is the strap's own
/// classification of its own motion, and it is unaffected by the problem the peak detector cannot
/// solve — a wrist gesture and a footfall are the same shape at 100 Hz. A 4.0 has no such field, and
/// a 5.0/MG that has never been drained has no history to read, so `StepAccumulator` remains: the
/// 100 Hz live motion stream, peak-counted, rhythm-gated.
///
/// ## The one rule that keeps them from double counting
///
/// **Banked motion never reaches the peak detector.** `MotionPayloadDecoder` accepts a banked `R21`
/// record from a drain as readily as a live one — and a drain's window is exactly the window the
/// counter's `R18` records describe. Feeding both would count every drained step twice. So `ingest`
/// drops any batch whose timestamp came off the strap (`timestampIsFromStrap`), and the counter owns
/// all history; the detector sees only live motion.
///
/// Inside a drain, a counter record's instant is the point up to which the strap's own count is
/// authoritative. Live motion the detector has already counted before that instant is discarded when
/// the next record overtakes it — `tailLastBatchStart <= sample.timestamp` — because the counter is
/// about to count it again. The few seconds of lag between the drain and the live edge cost their
/// detector steps once; they come back in the counter's next interval.
///
/// ## Why the ledger is persisted before the row
///
/// `stepCounts` has no provenance column, so a stored total cannot say how much came from the counter
/// and how much from the detector. The ledger in `StepCounterStateStore` can, and it is written
/// **before** the row: on a relaunch the ledger is the truth and the row is recomputed from it. A row
/// written first would be a number nothing could reproduce.
///
/// ## Why it is not driven from a screen
///
/// `HomeViewModel.load(for:)` runs on **every day-step tap**, and a subscription per tap is the
/// documented multicast failure: the manager's continuation dictionary accumulates a subscriber per
/// call, and the streams are the app's only source of motion. Worse, the failure is silent — a
/// `for await` that stops receiving looks exactly like a strap that went quiet. One subscription for
/// the life of the process, and this actor's own `isRunning` guard is what enforces it.
///
/// ## Why an actor
///
/// It holds mutable state that outlives a single call — one accumulator or ledger per day it is
/// filling — and it is fed from two streams at once. A `final class … : Sendable` with a lock would
/// work; an actor makes the serialisation structural instead of a rule the next editor has to
/// remember.
public actor TrackStepsUseCase {
    private let bleRepository: any WhoopBLEDeviceRepository
    private let stepRepository: any StepRepository
    private let stateStore: any StepCounterStateStore

    /// One detector-only accumulator per day, keyed by `startOfDay`.
    ///
    /// **A dictionary rather than a single accumulator, and that is the banked path's requirement
    /// rather than a generality.** A live batch from a walk and one from the previous evening can
    /// arrive in one connection. One accumulator would have to choose between filing last night's
    /// steps under today — a wrong-day row — and rebuilding its filter state per batch, which at a
    /// 1-second gravity window against 1-second batches means a permanently cold filter.
    private var accumulators: [Date: StepAccumulator] = [:]

    /// One counter ledger per day once the strap's counter has covered any of it.
    private var ledgers: [Date: Ledger] = [:]

    /// The counter continuation, which belongs to the stream rather than a day: a delta can cross
    /// midnight, and it is credited to the later sample's day.
    private var counter = StepCounterAccumulator()

    /// The ledger a previous process left, if it is recent enough to resume.
    ///
    /// **Not applied at launch, but at the first counter record for that day.** Applying it at launch
    /// would create a ledger for a day the counter may never cover in this process, and every live
    /// batch on that day would then be treated as tail rather than detector — a different rule for a
    /// day nothing has established deserves one.
    private var restoredState: StepCounterState?

    /// Whether a consumer is already attached. See the type's comment.
    private var isRunning = false

    /// The day totals this use case has written, for whichever screen is drawing the current day.
    ///
    /// **A saved row is not a drawn one.** `HomeViewModel` reads `stepCounts` once per day selection,
    /// and this writer flushes a new total every second of motion — so a screen opened before the strap
    /// started moving would hold the dash it read at launch for as long as it stays open, which is a
    /// tile that never populates rather than one that is a little late. This stream is the hand-off
    /// that closes that gap.
    ///
    /// `nonisolated` so a view model can bind to it without awaiting the actor: subscribers observe a
    /// value, they never drive one.
    public nonisolated var stepUpdates: AsyncStream<StepCount> { hub.stream }

    private nonisolated let hub = StepUpdateHub()

    /// How many days of accumulators and ledgers are held.
    ///
    /// Two, because a drain fills today and yesterday at most in ordinary use and the current day is
    /// always retained regardless. The bound exists so a strap replaying a month of history cannot
    /// grow this without limit.
    private static let retainedDays = 2

    public init(
        bleRepository: any WhoopBLEDeviceRepository,
        stepRepository: any StepRepository,
        stateStore: any StepCounterStateStore
    ) {
        self.bleRepository = bleRepository
        self.stepRepository = stepRepository
        self.stateStore = stateStore
    }

    /// Consumes both step streams for as long as they live. Returns when they end.
    ///
    /// Idempotent: a second call while one is running returns immediately rather than attaching a
    /// second consumer to either stream.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        if let state = stateStore.load() {
            restoredState = state
            counter = StepCounterAccumulator(
                previousCounter: state.lastCounter,
                previousSeconds: state.lastSeconds,
                previousWasSoftware: state.lastSoftware,
                hasSeenClass: state.hasSeenClass)
        }

        // Captured once: reading `motionStream` in the task would create a second subscription per
        // stream construction, and `AsyncStream` does not replay.
        let motion = bleRepository.motionStream
        let counters = bleRepository.stepCounterStream

        AppLogger.ble.notice("TrackStepsUseCase: attached to the motion and step-counter streams")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                for await batch in motion {
                    await self.ingest(batch)
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                for await sample in counters {
                    await self.ingestCounter(sample)
                }
            }
            await group.waitForAll()
        }
    }

    // MARK: - The motion stream

    /// Feeds one **live** batch into its day and writes that day's row.
    ///
    /// A banked batch is refused: the counter owns history, and counting the same drain through the
    /// peak detector is the double count the type's comment describes. `RecordMotionUseCase` still
    /// consumes that batch for sleep epochs — this is one consumer's rule, not the stream's.
    private func ingest(_ batch: MotionBatch) async {
        guard !batch.timestampIsFromStrap else { return }

        let day = Calendar.current.startOfDay(for: batch.start)

        if var ledger = ledgers[day] {
            // A counter-covered day: only the live tail counts, and only until the next counter
            // record overtakes it.
            let tail = ledger.tail ?? StepAccumulator(
                sampleRateHz: 1.0 / batch.sampleIntervalSeconds,
                baselineStepCount: ledger.tailBaselineSteps,
                measuredSeconds: ledger.tailBaselineMeasured)
            var updated = tail
            updated.accept(
                accelerometerXG: batch.accelerometerG.x,
                accelerometerYG: batch.accelerometerG.y,
                accelerometerZG: batch.accelerometerG.z,
                sampleIntervalSeconds: batch.sampleIntervalSeconds,
                startSeconds: batch.start.timeIntervalSince1970)
            ledger.tail = updated
            ledger.tailLastBatchStart = batch.start
            ledgers[day] = ledger
            await writeLedger(day)
            evictStaleState(keeping: day)
            return
        }

        // A detector-only day, seeded from the day's stored row so a relaunch continues the count
        // rather than restarting it.
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
            // The samples' own instants, on the batch's scale. Only differences are read, so the
            // refractory interval respects a gap *between* two batches instead of fusing their seam.
            startSeconds: batch.start.timeIntervalSince1970)
        accumulators[day] = updated

        let row = StepCount(
            date: day,
            stepCount: updated.stepCount,
            measuredSeconds: updated.measuredSeconds)
        await write(row, for: day)
        evictStaleState(keeping: day)
    }

    // MARK: - The counter stream

    /// Folds one R18 counter record into its day's ledger.
    private func ingestCounter(_ sample: StepCounterSample) async {
        let outcome = counter.accept(
            counter: sample.counter,
            seconds: sample.timestamp.timeIntervalSince1970,
            activityClass: sample.activityClass,
            softwareOverride: sample.counterIsSoftware,
            acceleration: sample.acceleration)

        let day = Calendar.current.startOfDay(for: sample.timestamp)

        var ledger: Ledger
        if let existing = ledgers[day] {
            ledger = existing
        } else {
            // The first counter record for this day. From here the counter is the day's historical
            // source, so the detector-only accumulator is dropped — its steps are in the window the
            // counter is about to describe. Any steps it already wrote are superseded by the ledger's
            // total, which is why the write below replaces the row rather than adding to it.
            accumulators[day] = nil
            if let restored = restoredState, Calendar.current.isDate(restored.day, inSameDayAs: day) {
                ledger = Ledger(
                    counterSteps: restored.counterSteps,
                    counterMeasuredSeconds: restored.counterMeasuredSeconds,
                    tailBaselineSteps: restored.tailSteps,
                    tailBaselineMeasured: restored.tailMeasuredSeconds)
                // Applied once. A later record for the same day continues from the ledger, and a
                // record for another day must not inherit this day's totals.
                restoredState = nil
            } else {
                ledger = Ledger()
            }
        }

        ledger.counterSteps += outcome.countedTicks
        ledger.counterMeasuredSeconds += outcome.measuredSeconds

        // The counter now vouches for everything up to this record's instant. If the tail's last live
        // batch is behind it, those steps are about to be counted again — drop them. A batch ahead of
        // the history (the drain lags the live edge by seconds) is kept and will be overtaken later.
        if let lastBatch = ledger.tailLastBatchStart, lastBatch <= sample.timestamp {
            ledger.tail = nil
            ledger.tailBaselineSteps = 0
            ledger.tailBaselineMeasured = 0
            ledger.tailLastBatchStart = nil
        }

        ledgers[day] = ledger
        await writeLedger(day)
        evictStaleState(keeping: day)
    }

    // MARK: - The ledger

    /// A counter-covered day: the strap's own ticks plus the live detector steps after its coverage.
    ///
    /// The tail is `nil` until a live batch arrives, and `tailBaseline*` carries a restored tail
    /// across a relaunch. Two values rather than one optional accumulator so that "no live motion
    /// since the last write" and "a live tail of zero steps" are the same answer — they are.
    private struct Ledger {
        var counterSteps: Int = 0
        var counterMeasuredSeconds: TimeInterval = 0
        var tail: StepAccumulator?
        var tailBaselineSteps: Int = 0
        var tailBaselineMeasured: TimeInterval = 0
        var tailLastBatchStart: Date?

        var stepCount: Int { counterSteps + (tail?.stepCount ?? tailBaselineSteps) }
        var measuredSeconds: TimeInterval {
            counterMeasuredSeconds + (tail?.measuredSeconds ?? tailBaselineMeasured)
        }
    }

    /// Writes a counter-covered day: ledger first, row second.
    ///
    /// **The ordering is the rule.** The ledger is what a relaunch recomputes from, so a row that got
    /// ahead of it would be a total nothing could reproduce. The row is a projection of the ledger and
    /// is written from it, never the other way round.
    ///
    /// **It is throttled to once a second per day, with a trailing flush.** A drain of a backlog
    /// delivers records faster than a hundred a second (measured: ~120/s on the owner's 5.0), and a
    /// `UserDefaults` document plus a SQLite upsert per record flooded `cfprefsd` and the database for
    /// a figure that changes by a step or two. The in-memory ledger is always current; what lags is at
    /// most one second of records, which the trailing flush and the next record both close.
    private func writeLedger(_ day: Date, force: Bool = false) async {
        guard let ledger = ledgers[day] else { return }

        let now = Date()
        if !force, let last = lastLedgerWrite[day],
           now.timeIntervalSince(last) < Self.ledgerWriteInterval {
            pendingLedgerWrites.insert(day)
            scheduleLedgerFlush()
            return
        }
        lastLedgerWrite[day] = now
        pendingLedgerWrites.remove(day)

        let row = StepCount(
            date: day,
            stepCount: ledger.stepCount,
            measuredSeconds: ledger.measuredSeconds)

        stateStore.save(StepCounterState(
            day: day,
            counterSteps: ledger.counterSteps,
            counterMeasuredSeconds: ledger.counterMeasuredSeconds,
            tailSteps: ledger.tail?.stepCount ?? ledger.tailBaselineSteps,
            tailMeasuredSeconds: ledger.tail?.measuredSeconds ?? ledger.tailBaselineMeasured,
            lastCounter: counter.previousCounter,
            lastSeconds: counter.previousSeconds,
            lastSoftware: counter.previousWasSoftware,
            hasSeenClass: counter.hasSeenActivityClass))

        await write(row, for: day)
    }

    /// The shortest gap between two ledger writes for one day, in seconds.
    private static let ledgerWriteInterval: TimeInterval = 1.0

    /// Days whose latest ledger has not been written yet because the throttle skipped it.
    private var pendingLedgerWrites: Set<Date> = []
    private var lastLedgerWrite: [Date: Date] = [:]
    private var ledgerFlushTask: Task<Void, Never>?

    /// Writes the pending days once the burst that skipped them has stopped.
    ///
    /// One task at a time; it sleeps for the throttle interval and then writes whatever is still
    /// pending. Without it the last record of a drain could sit unwritten until the next record, which
    /// on a disconnected strap may be hours.
    private func scheduleLedgerFlush() {
        guard ledgerFlushTask == nil else { return }
        ledgerFlushTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(TrackStepsUseCase.ledgerWriteInterval * 1_000_000_000))
            await self?.flushPendingLedgerWrites()
        }
    }

    private func flushPendingLedgerWrites() async {
        ledgerFlushTask = nil
        let days = pendingLedgerWrites
        pendingLedgerWrites.removeAll()
        for day in days {
            await writeLedger(day, force: true)
        }
    }

    /// Writes the day's row, on the absence rule: **a writer persists only when it produced a
    /// measurement, and the test it uses is the one its readers use.**
    ///
    /// That test is `measuredSeconds > 0` — the same comparison `StepCount.hasMeasurement` makes and
    /// the same one the readers gate on. It is not `stepCount > 0`: a measured day of no walking is a
    /// real `0` that must be stored and must render as a figure, not as a dash.
    private func write(_ row: StepCount, for day: Date) async {
        guard row.measuredSeconds > 0 else { return }
        noteRateIfMinuteRolled(row)
        do {
            try await stepRepository.saveStepCount(row)
            // Only once the store has it: a subscriber drawing this figure would otherwise show a
            // count the database cannot answer back, which is the one way a live tile can be more
            // current than the truth.
            hub.yield(row)
            // `.debug` rather than `.notice`: this fires once per second of motion, so persisting it
            // would bury the day-keying line under a page of counts.
            AppLogger.ble.debug("TrackStepsUseCase: wrote \(row.stepCount, privacy: .public) steps for \(String(describing: row.date), privacy: .public)")
        } catch {
            AppLogger.database.error("Failed saving step count: \(error.localizedDescription)")
        }
    }

    /// Last logged minute and count per day, so the rate line prints once a minute rather than once
    /// per record.
    private var lastRateLog: [Date: (minute: Int, steps: Int)] = [:]

    /// One line a minute carrying the two numbers that separate a **mis-scaled** source from one that
    /// **counts while still** — and they need different fixes.
    ///
    /// `measuredSeconds` grows by the records' own spans, so comparing its growth against wall time
    /// says whether the strap is delivering at the expected rate or handing the same motion to the
    /// counter more than once. `steps` growth over the same minute is the rate: a deliberate walk is
    /// ~100–130 steps a minute, and anything near 240/min (the counter's ceiling) means the counter is
    /// counting motion ticks rather than steps.
    private func noteRateIfMinuteRolled(_ row: StepCount) {
        let minute = Int(row.measuredSeconds / 60)
        guard let previous = lastRateLog[row.date] else {
            lastRateLog[row.date] = (minute, row.stepCount)
            AppLogger.ble.notice("""
                TrackSteps rate: begin at steps=\(row.stepCount, privacy: .public) \
                measured=\(Int(row.measuredSeconds), privacy: .public)s
                """)
            return
        }
        guard minute > previous.minute else { return }
        lastRateLog[row.date] = (minute, row.stepCount)
        let minutes = minute - previous.minute
        let steps = row.stepCount - previous.steps
        AppLogger.ble.notice("""
            TrackSteps rate: +\(steps, privacy: .public) steps in \(minutes, privacy: .public) measured \
            min (total steps=\(row.stepCount, privacy: .public), measured \
            \(Int(row.measuredSeconds) / 60, privacy: .public) min)
            """)
    }

    /// Drops accumulators, ledgers and the restored state outside the retention window.
    ///
    /// Safe by construction rather than by care: every day's row is written after every input, so the
    /// only thing held is filter state and the ledger's totals — and the ledger's totals are persisted
    /// first. Dropping one costs a cold filter if that day is fed again, never a step already counted.
    private func evictStaleState(keeping day: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retainedDays, to: day) ?? day
        accumulators = accumulators.filter { $0.key >= cutoff }
        ledgers = ledgers.filter { $0.key >= cutoff }
        lastRateLog = lastRateLog.filter { $0.key >= cutoff }
        if let restoredState, restoredState.day < cutoff {
            self.restoredState = nil
            stateStore.clear()
        }
    }
}

/// Fans written day totals out to every attached reader.
///
/// **A lock rather than the actor's isolation, and the choice is forced by `stepUpdates` being
/// `nonisolated`.** A subscriber binds to the stream from a view model's own task, which has no reason
/// to await this actor — and an actor-isolated `AsyncStream` property would put every subscriber
/// behind the writer's mailbox for a value it only reads. This is `WhoopBLEManager`'s registries in
/// miniature, including the reason they are registries at all: a second reader must not orphan a
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
