import Foundation

/// Computes today's Recovery **once per night**, off any screen, and publishes the stored row.
///
/// ## Why the calculation left the page
///
/// `RecoveryViewModel` used to re-score today on open, and its gate could never converge: it recomputed
/// while a night existed and the stored row was RMSSD, and a recompute writes an RMSSD row — so every
/// push of the ring re-read the whole night's samples and a thirty-day baseline to reproduce a figure
/// that had not moved. Measured 2026-10-27, opening a ring showed nothing while that ran.
///
/// The rule this replaces it with is the user's own: **a calculation happens once, is stored, and is
/// read**. The page now only reads; this is the writer, and its subject is *the night a day's score was
/// computed from*. **The row itself says whether it is current** — `recoveries.algorithm` names the
/// formula and `recoveries.scored_through` the newest input it included (both added in `v39`) — so a
/// relaunch reads that pair instead of re-folding the night. Before the columns existed this type kept
/// the watermark in a dictionary, which meant the first foreground after every launch re-scored today
/// to reproduce a row that was already on disk.
///
/// **It runs from the foreground, after the night refresh, and nowhere else.** That is the same place
/// `RefreshNightsUseCase` and `RefreshStrainUseCase` are called from, so the three writers that turn
/// sensor data into stored rows share one trigger and a page never has to be open for a day to become
/// current.
public actor RefreshRecoveryUseCase: RecoveryRescoring {

    private let calculate: CalculateRecoveryUseCase
    private let repository: any RecoveryRepository
    private let sleepRepository: any SleepRepository
    private let calendar: Calendar
    private let hub = RecoveryUpdateHub()

    /// Days this process has **refused** to score, and the edge each refusal was made against.
    ///
    /// **The one thing that cannot be stored is the refusal, and it is the one thing that has to be
    /// remembered.** A refused day writes no row — that is the absence rule — so there is no watermark
    /// to compare next time and the night would be folded again on every foreground. This remembers
    /// the refusal for the life of the process, so a night that genuinely cannot be measured costs one
    /// attempt per launch rather than one per foreground. A drain that rewrites the night moves the
    /// edge and earns exactly one retry.
    private var refusedEdges: [Date: Date] = [:]

    public init(
        calculate: CalculateRecoveryUseCase,
        repository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        calendar: Calendar = .current
    ) {
        self.calculate = calculate
        self.repository = repository
        self.sleepRepository = sleepRepository
        self.calendar = calendar
    }

    /// Whether a stored row has to be replaced, given the input the day has now.
    ///
    /// **Pure so the rule can be asserted without a database**, and it is two questions rather than
    /// one. *Is the row current* — `algorithm == RecoveryAlgorithm.current`; a row written before the
    /// column, or by a formula this build no longer applies, is owed a calculation whatever its
    /// watermark says. And *has anything arrived since* — the day's edge is newer than the stored
    /// watermark. `nil` on either stored field means the row cannot say, which is the safe direction.
    ///
    /// The edge is the night's `scoredThrough`, or its end when it carries none: the night is the
    /// whole of a recovery day's input.
    public static func isOwed(
        edge: Date, storedEdge: Date?, algorithm: RecoveryAlgorithm?
    ) -> Bool {
        guard algorithm == .current else { return true }
        guard let storedEdge else { return true }
        return edge > storedEdge
    }

    /// Every recovery row this use case computes, for a screen that is already on the day.
    public nonisolated var updates: AsyncStream<RecoveryMetric> { hub.stream }

    /// Scores today if — and only if — the stored row says it has not seen this night.
    ///
    /// **Two indexed reads answer that**, the night and the row, before anything expensive happens.
    /// The row's own `algorithm` and `scored_through` are the record; nothing is remembered in the
    /// process, which is what makes a relaunch behave like a second foreground rather than a
    /// first one. A row written before `v39` carries neither field, so it is re-scored once and
    /// stamped — the same single calculation every install paid before the columns existed.
    ///
    /// Nothing here can stop the caller: a day with no night, a read that throws and a calculation that
    /// refuses the day are all ordinary absences, and a background writer that failed must leave the
    /// stored row exactly as it was.
    @discardableResult
    public func refreshToday(now: Date = Date(), force: Bool = false) async -> RecoveryMetric? {
        let day = calendar.startOfDay(for: now)

        guard let night = try? await sleepRepository.getSleepSession(for: day) else {
            CaptureLog.decision(
                "RECOVERY check day=\(day.ISO8601Format()) outcome=no-night")
            return nil
        }
        // The night is the whole of a recovery day's input, so its watermark — or its end, for a night
        // that carries none — is the edge the row has to have seen.
        let edge = night.scoredThrough ?? night.endTime

        // A refusal leaves no row, so it has no watermark to compare: the process remembers it for
        // this edge only. A drain that rewrites the night moves the edge and earns one retry.
        guard refusedEdges[day] != edge else { return nil }

        let stored = try? await repository.getLocalRecovery(for: day)
        // **Another producer's row is not this one's to replace.** A HealthKit day is SDNN and this
        // scorer writes RMSSD — recomputing it would mix two quantities in one baseline, the rule
        // `docs/ALGORITHMS.md` treats as a correctness bug — and an imported day is measured history.
        // `isLocallyComputed` is the single test both answers already agree on.
        // **The decision, not only the result.** `NIGHTS` has logged why a night was skipped since the
        // gate existed; this one logged only when it scored, so a question about a stored score had no
        // line to read — the arithmetic below says how a score was made, and this says whether it was
        // made at all and against which edge.
        func logCheck(_ outcome: String) {
            CaptureLog.decision(
                "RECOVERY check day=\(day.ISO8601Format()) "
                    + "edge=\(edge.ISO8601Format()) "
                    + "scoredThrough=\(stored?.scoredThrough?.ISO8601Format() ?? "-") "
                    + "algorithm=\(stored?.algorithm?.rawValue ?? "-") outcome=\(outcome)")
        }

        if let stored, !stored.isLocallyComputed {
            logCheck("foreign-source")
            return nil
        }
        // **`force` is the purge's, and only the purge's.** Deleting a *different* day moves neither
        // this night nor its watermark, but it changes the baseline window the score was computed
        // against — so the row is stale in a way its own audit fields cannot see. Everything below the
        // gate still applies: a foreign row is still not this scorer's to replace.
        if !force, let stored, !Self.isOwed(
            edge: edge, storedEdge: stored.scoredThrough, algorithm: stored.algorithm)
        {
            logCheck("current")
            return nil
        }

        guard let metric = try? await calculate.execute(for: day) else {
            // The scorer refused the day — no measurement to write. Recorded for this edge so a
            // foreground loop does not re-read the night's samples every time for the same refusal.
            refusedEdges[day] = edge
            return nil
        }
        refusedEdges[day] = nil
        hub.yield(metric)
        CaptureLog.decision(
            "RECOVERY scored day=\(day.ISO8601Format()) score=\(metric.score)")
        return metric
    }
}

/// Fans computed rows out to every attached reader — `NightUpdateHub`'s shape, for its reason.
private final class RecoveryUpdateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecoveryMetric>.Continuation] = [:]

    var stream: AsyncStream<RecoveryMetric> {
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

    func yield(_ metric: RecoveryMetric) {
        lock.lock()
        let readers = Array(continuations.values)
        lock.unlock()
        for reader in readers { reader.yield(metric) }
    }
}
