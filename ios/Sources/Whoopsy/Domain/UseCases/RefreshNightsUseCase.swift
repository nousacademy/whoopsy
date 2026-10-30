import Foundation

/// Turns the nights a drain just delivered into stored sleep rows, and tells whoever is drawing Home.
///
/// **Why this exists.** Home's sleep ring and the `SLEEP` row on the ACTIVITIES card read `sleeps`, and
/// the only writer is `AnalyzeSleepUseCase` — called from the sleep page. So a morning drain wrote a
/// night's samples and nothing turned them into a night until the user opened a *different* screen;
/// and popping back did not redraw Home, because a pop re-fires no `.task`. Measured on 2026-10-26: a
/// drain of 32,274 records ending `complete`, with the ring still `—` until the sleep page was opened.
///
/// **It applies the sleep page's own rule rather than a second one.** A day is classified when it has
/// no stored row, when the row's `algorithm` is not `SleepAlgorithm.current`, or when the row's
/// `scoredThrough` is older than the newest input the analyzer can see — `SleepReclassification`'s
/// test, which is the same call `SleepViewModel.shouldReclassify` makes. An imported night
/// (`hasWhoopSleepNeed`) is never touched.
///
/// **Bounded on purpose.** The first sync of a fresh install can deliver fourteen days, and classifying
/// all of them would spend a minute of the user's foreground on nights nobody is looking at. The
/// range's **newest three days** are classified here — today's night, the one before it, and one spare
/// — and anything older stays the sleep page's job, which classifies on open.
public actor RefreshNightsUseCase {

    /// How many of the drained range's newest days one call will classify.
    public static let maximumNightsPerDrain = 3

    private let analyze: AnalyzeSleepUseCase
    private let repository: any SleepRepository
    private let calendar: Calendar
    private let hub = NightUpdateHub()

    public init(
        analyze: AnalyzeSleepUseCase,
        repository: any SleepRepository,
        calendar: Calendar = .current
    ) {
        self.analyze = analyze
        self.repository = repository
        self.calendar = calendar
    }

    /// Every classified night, for a screen that is already on the day it belongs to.
    public nonisolated var nightUpdates: AsyncStream<SleepSession> { hub.stream }

    /// Classifies every owed day in `oldest…newest`, newest first, and reports how many rows it wrote.
    ///
    /// A `nil` range is a drain that delivered no records, and costs nothing. Failures are swallowed
    /// per day: one night the analyzer cannot read must not stop the others, and a night it cannot
    /// read leaves the stored row exactly as it was — the keep-versus-delete rule the page already
    /// applies.
    @discardableResult
    public func refresh(from oldest: Date?, to newest: Date?, now: Date = Date()) async -> Int {
        let days = Self.days(from: oldest, to: newest, now: now, calendar: calendar)
        // **The line a capture needs when a ring does not fill.** Whether the refresher ran at all, on
        // which days, whether each was owed, and what the analyzer answered — one line per day, so
        // "unclassified" and "unclassifiable" can be told apart without opening a screen.
        CaptureLog.decision(
            "NIGHTS refresh range=\(oldest?.ISO8601Format() ?? "-")..\(newest?.ISO8601Format() ?? "-") "
                + "days=\(days.count)")
        var written = 0
        for day in days {
            let decision = await isOwed(day)
            let owed = decision.owed
            var outcome = "skip"
            if owed {
                do {
                    if let session = try await analyze.execute(for: day) {
                        // **Only a night that draws differently is published.** `execute` always writes
                        // — the watermark it advances is the point — but a re-classification that
                        // reproduced the same night must not hand it to the ring: that publish is what
                        // made Home redraw on every foreground for a figure that had not changed.
                        if decision.stored.map({ !session.drawsSame(as: $0) }) ?? true {
                            hub.yield(session)
                            written += 1
                            outcome = "saved start=\(session.startTime.ISO8601Format()) "
                                + "end=\(session.endTime.ISO8601Format())"
                        } else {
                            outcome = "current"
                        }
                    } else {
                        outcome = "no-night"
                    }
                } catch {
                    outcome = "error=\(error.localizedDescription)"
                }
            }
            let line = "NIGHTS day=\(day.ISO8601Format()) owed=\(owed) \(outcome)"
            AppLogger.database.notice("\(line, privacy: .public)")
            CaptureLog.decision(line)
        }
        return written
    }

    /// The days to consider, **newest first**, capped at `maximumNightsPerDrain`.
    ///
    /// A night is keyed by the day it woke on, so the range's newest day is the one a morning drain
    /// just produced — but **today is always included, even with an empty range.** A drain whose
    /// cursor is already past the night delivers nothing, and that is precisely when today's records
    /// are sitting in storage with no row: measured 2026-10-26, where a launch whose drain answered
    /// with zero records classified no day at all and Home's ring stayed a dash. A day with a current
    /// row costs one indexed read and is skipped by `isOwed`, so including today is free after the
    /// first time.
    ///
    /// `oldest` beyond the cap is left to the sleep page: the cap is a foreground-cost bound, not a
    /// claim that the older nights do not exist.
    public static func days(
        from oldest: Date?,
        to newest: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let end = newest.map { calendar.startOfDay(for: $0) } ?? today
        let start = oldest.map { calendar.startOfDay(for: $0) } ?? end

        var days: [Date] = []
        var day = end
        while day >= start, days.count < maximumNightsPerDrain {
            days.append(day)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        if !days.contains(today) {
            // Today goes in and the **oldest range day** comes out, not today: the cap is a bound on
            // how much backlog one foreground will classify, and it must not be paid by leaving the
            // ring the user is looking at empty.
            days.append(today)
            days.sort(by: >)
            if days.count > maximumNightsPerDrain {
                days = Array(days.prefix(maximumNightsPerDrain))
            }
        }
        return days
    }

    /// `SleepViewModel.shouldReclassify`, in the one place both callers can read it.
    ///
    /// It answers with the stored row as well as the verdict, because the caller needs it twice: to
    /// decide, and then to compare the re-classification against so an unchanged night is not
    /// published. Reading it twice would be a second read that could disagree.
    private func isOwed(_ day: Date) async -> (owed: Bool, stored: SleepSession?) {
        let stored = try? await repository.getSleepSession(for: day)
        // An imported night is WHOOP's own classification and is never re-run here.
        if stored?.hasWhoopSleepNeed == true { return (false, stored) }
        guard let stored else { return (true, nil) }
        guard stored.algorithm == SleepAlgorithm.current,
              let watermark = stored.scoredThrough
        else { return (true, stored) }
        let edge = try? await analyze.inputEdge(for: day)
        let owed = SleepReclassification.isOwed(
            watermark: watermark, inputEdge: edge, nightEnd: stored.endTime,
            endedAtDataEdge: stored.endedAtDataEdge)
        // **The three instants, for the capture that has to explain a skip.** A night left as a
        // fragment is diagnosed from exactly this line: a stored end far behind a watermark that is
        // itself far behind the edge says the row saw data the night did not include, and the
        // figures make that arithmetically checkable rather than a theory.
        CaptureLog.decision(
            "NIGHTS check day=\(day.ISO8601Format()) "
                + "watermark=\(watermark.ISO8601Format()) "
                + "end=\(stored.endTime.ISO8601Format()) "
                + "edge=\(edge?.ISO8601Format() ?? "-") "
                + "dataEdge=\(stored.endedAtDataEdge.map { String(describing: $0) } ?? "-") owed=\(owed)")
        return (owed, stored)
    }
}

/// Fans classified nights out to every attached reader.
///
/// A lock rather than the actor's isolation, for `StrainUpdateHub`'s reason: `nightUpdates` is
/// `nonisolated`, so a subscriber binds from a view model's task without awaiting this actor. Private
/// to this file because nothing outside the use case may yield into it — a publisher that could be
/// written from anywhere could hand a screen a night the database does not hold.
private final class NightUpdateHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SleepSession>.Continuation] = [:]

    var stream: AsyncStream<SleepSession> {
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

    func yield(_ session: SleepSession) {
        lock.lock()
        let readers = Array(continuations.values)
        lock.unlock()
        for reader in readers { reader.yield(session) }
    }
}
