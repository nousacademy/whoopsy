import Foundation

/// Keeps the day's Strain current, and repairs the days a late drain delivers.
///
/// ## The problem this closes
///
/// `CalculateStrainUseCase` computed a day once: `StrainViewModel.load` called it only when the day had
/// no measured row, and it had no other caller. So the first time the strain page was opened the score
/// was frozen — Home's ring read that stored row for the rest of the day, and a drain that recovered
/// heart rate for a past day was never scored at all. A day is an integral, and an integral computed
/// once is a snapshot.
///
/// ## The trigger is a watermark, not a comparison
///
/// Every stored row carries `scoredThrough`: the newest input instant it included. A day is recomputed
/// only when the newest input the phone now holds is **later** than that, which makes the common case —
/// a day that has not changed since the last tick — one indexed read and no write. Comparing *scores*
/// instead would have to recompute to compare, and a "never let the score fall" rule would freeze a
/// cold-start maximum and resting heart rate forever.
///
/// ## The loop
///
/// `start()` ticks every five minutes for the life of the process, and each tick considers **today and
/// yesterday**. Yesterday is in the tick for the day boundary: the last tick before midnight is up to
/// five minutes early, and without revisiting yesterday the final minutes of every day would never be
/// scored. Once yesterday's watermark covers its input the check is free, so the cost is one tick's.
///
/// The immediate ticks — on `scenePhase == .active` and after a drain — call `refreshToday()` and
/// `refresh(from:to:)` directly; they do not need a second loop.
///
/// ## What is never repaired
///
/// A row whose score came from WHOOP's export is a measurement from another source and is never
/// overwritten by this app's estimate (`StrainScore.isDeviceScored`). The backfill additionally stops
/// at the newest imported day, because the export is a contiguous span and a day before it is inside
/// that span even when the export carried no strain for it — filling those gaps with this app's number
/// would be the same crossing `AnalyzeSleepUseCase` refuses between a computed and an imported need.
///
/// ## The one ordering caveat
///
/// `RecordMotionUseCase` consumes the same drain's stream separately, so a backfill fired the instant
/// `SyncHistoricalDataUseCase` returns may see heart rate before that day's motion windows are on disk.
/// Nothing is lost: the watermark is behind, so the next tick recomputes the day with the motion term.
public actor RefreshStrainUseCase {
    private let calculate: CalculateStrainUseCase
    private let strainRepository: any StrainRepository
    private let biometricRepository: any BiometricRepository
    private let motionEpochRepository: any MotionEpochRepository

    /// How often the foreground loop looks for new input.
    ///
    /// Five minutes, not one: the score moves smoothly enough that a minute-level tick is invisible on
    /// the ring, and each tick that finds new input costs a whole day's read. The immediate ticks on
    /// foreground and after a drain are what make the first number after a sync appear at once.
    public static let tickSeconds: TimeInterval = 300

    /// The most calendar days one drain's backfill will score, newest first.
    ///
    /// A fortnight of backlog is real — the strap holds 14 days — and scoring all of it in one pass
    /// would read fourteen days of 86,000 samples on the main thread's time budget after a syncing
    /// screen has already reported success. Seven, newest first, because the recent days are the ones
    /// a user opens; the rest are logged rather than silently dropped.
    public static let maximumBackfillDays = 7

    /// The rows this use case has saved, for whichever screen is drawing the day.
    ///
    /// **A saved row is not a drawn one.** `StrainViewModel` reads its day once per selection and
    /// `HomeViewModel` once per day tap, and this writer rewrites the row through the day — so a screen
    /// opened in the morning would hold the morning's figure for as long as it stays open. The stream is
    /// yielded **after** the save, so a subscriber can never draw a score the database cannot answer.
    ///
    /// `nonisolated` so a view model binds without awaiting the actor, on `TrackStepsUseCase.stepUpdates`'
    /// rule: subscribers observe a value, they never drive one.
    public nonisolated var strainUpdates: AsyncStream<StrainScore> { hub.stream }

    private nonisolated let hub = StrainUpdateHub()

    private var isRunning = false
    /// Days currently being computed. The actor is reentrant across `await`, so two ticks can both pass
    /// the watermark check before either writes; this is what makes the second a no-op.
    private var inFlightDays: Set<Date> = []

    public init(
        calculate: CalculateStrainUseCase,
        strainRepository: any StrainRepository,
        biometricRepository: any BiometricRepository,
        motionEpochRepository: any MotionEpochRepository
    ) {
        self.calculate = calculate
        self.strainRepository = strainRepository
        self.biometricRepository = biometricRepository
        self.motionEpochRepository = motionEpochRepository
    }

    /// Runs the foreground loop until the task is cancelled.
    ///
    /// Idempotent on `TrackStepsUseCase.start()`'s rule: a second call while one is running returns
    /// rather than starting a second loop.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        AppLogger.database.notice("RefreshStrainUseCase: foreground loop started")
        while !Task.isCancelled {
            await tick()
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// Today and yesterday. See the type's comment for why yesterday is not redundant.
    public func tick() async {
        let today = Date().startOfDay
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        await refresh(yesterday)
        await refresh(today)
    }

    /// Recomputes today if it has input newer than its stored row.
    public func refreshToday() async {
        await refresh(Date())
    }

    /// Scores the days a drain delivered.
    ///
    /// Newest first and at most `maximumBackfillDays`; a day that is already current costs one read.
    /// `nil` for either end is a no-op — a strap that did not say which days it carried is not evidence
    /// for any of them.
    public func refresh(from oldest: Date?, to newest: Date?) async {
        guard let oldest, let newest else { return }
        let first = oldest.startOfDay
        let last = newest.startOfDay
        guard first <= last else { return }

        let importedThrough: Date?
        do {
            importedThrough = try await strainRepository.getNewestImportedStrainDay()
        } catch {
            AppLogger.database.error(
                "Strain backfill: could not read the import boundary: \(error.localizedDescription)")
            return
        }

        var day = last
        var examined = 0
        while day >= first {
            if let importedThrough, day <= importedThrough {
                // The export is a contiguous span, so every remaining day is behind it too.
                AppLogger.database.notice("""
                    Strain backfill: stopping at \(day.description, privacy: .public), at or before \
                    the newest imported day \(importedThrough.description, privacy: .public)
                    """)
                return
            }
            examined += 1
            if examined > Self.maximumBackfillDays {
                AppLogger.database.notice("""
                    Strain backfill: scored the newest \(Self.maximumBackfillDays, privacy: .public) \
                    day(s); older days back to \(day.description, privacy: .public) were left for now
                    """)
                return
            }
            await refresh(day)
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: day) else { return }
            day = previous
        }
    }

    /// One day: read its row and its newest input, and recompute only when the input is newer.
    private func refresh(_ day: Date) async {
        let start = day.startOfDay
        do {
            let stored = try await strainRepository.getLocalStrain(for: start)
            // An imported day, or one this phone did not compute, is not this app's to rewrite.
            if let stored, !stored.isDeviceScored { return }

            // The heart-rate guard, checked before the whole day is read: a day with motion and no
            // heart rate never gets a row (`StrainDayMath` refuses to invent a rate), so recomputing
            // it every tick would be a day's read that can only ever throw its result away.
            guard let newestSample = try await biometricRepository.getLatestSampleTimestamp(
                from: start, to: start.startOfNextDay) else { return }

            var inputEdge = newestSample
            if let epoch = try await motionEpochRepository.getLatestMotionEpoch(
                from: start, to: start.startOfNextDay) {
                let edge = epoch.start.addingTimeInterval(
                    MotionLoadMath.coveredSeconds(sampleCount: epoch.sampleCount))
                if edge > inputEdge { inputEdge = edge }
            }

            if let watermark = stored?.scoredThrough, watermark >= inputEdge { return }
            guard !inFlightDays.contains(start) else { return }
            inFlightDays.insert(start)
            defer { inFlightDays.remove(start) }

            guard let score = try await calculate.execute(for: start) else { return }
            // Only once the store has it — the same ordering and the same reason as `TrackStepsUseCase`.
            hub.yield(score)
            AppLogger.database.debug("""
                RefreshStrainUseCase: scored \(start.description, privacy: .public) at \
                \(score.score, privacy: .public) (motion load \(score.motionLoad ?? 0, privacy: .public))
                """)
        } catch {
            AppLogger.database.error(
                "Strain refresh failed for \(start.description): \(error.localizedDescription)")
        }
    }
}

/// Fans saved strain rows out to every attached reader.
///
/// A lock rather than the actor's isolation, for `StepUpdateHub`'s reason: `strainUpdates` is
/// `nonisolated`, so a subscriber binds from a view model's task without awaiting this actor. Private
/// to this file because nothing outside the use case may yield into it — a screen that could publish a
/// score could publish one the database does not hold.
private final class StrainUpdateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<StrainScore>.Continuation] = [:]

    var stream: AsyncStream<StrainScore> {
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

    func yield(_ score: StrainScore) {
        lock.lock()
        let readers = Array(continuations.values)
        lock.unlock()
        for reader in readers { reader.yield(score) }
    }
}
