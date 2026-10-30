import Foundation
import SwiftUI

@MainActor @Observable public final class SleepViewModel {
    public var session: SleepSession?; public var isLoading = false; public var errorMessage: String?

    /// The day the last load was for, so a deferred result computed for one day cannot land on another.
    private var loadedDay: Date?

    /// The composite sleep score the ring prints, or `nil` when the night cannot produce two terms.
    ///
    /// **Read from the week, not computed a second time.** `MetricWeek` scores its seven days over the
    /// same history, so the ring and the sleep page's weekly chart cannot disagree about the selected
    /// night. The week ends on the day being shown, which is why `days.last` is the anchor.
    ///
    /// It is a distinct quantity from `session.sleepSufficiencyPercentage`: that is the ratio the
    /// `HOURS VS. NEEDED` row and the Recovery input read, while this is `SleepScoreScoring`'s
    /// weighted composite. The page draws both, deliberately.
    public private(set) var sleepScore: Int?

    /// The night's Sleep Consistency, resolved on load.
    ///
    /// **Stored first, computed second, and `nil` when neither applies.** An imported night carries
    /// WHOOP's own figure in `sleeps.sleep_consistency` and that is what the screen prints — this app
    /// does not overwrite a measurement with its own estimate, the same rule that keeps `Sleep need
    /// (min)` on an imported row from being routed through `SleepNeedMath`. A strap night has no
    /// stored figure, so `SleepConsistencyMath` reads one off the night and its four predecessors. A
    /// night with fewer than four predecessors has neither, and the row draws a dash.
    ///
    /// **It is a separate property rather than a computed one on `Session`, because resolving it costs
    /// a second repository read** — the four nights before the one being shown. That read is skipped
    /// entirely when the row already carries a figure, which on an imported history is every night.
    public private(set) var sleepConsistency: Int?

    /// The naps taken on the day being shown, earliest first. **Empty is an ordinary answer** — it
    /// means the user did not nap, which is true of all but eight days in the export — so the screen
    /// draws no nap row at all rather than a row reading `—`. That is the same distinction the four
    /// metrics draw between a missing row and a stored placeholder, applied to a whole card row: an
    /// absent nap is not a nap of unknown length.
    public private(set) var naps: [SleepNap] = []

    /// The night's four stages read against the nights before it, for the typical-range card.
    ///
    /// **`nil` is exactly two states and the screen must treat them the same**: no night for the day,
    /// and a night with no sleep period. `SleepStageRangeScoring.summary(for:priorNights:)` returns
    /// `nil` for both, and both mean the card is not drawn — see that method's doc comment for why a
    /// four-zero-percent card is not one of the options.
    ///
    /// A **thin window is not `nil`**: the shares and durations are readings the night really has, and
    /// only the bands are withheld. That state comes back as a `Summary` whose rows carry no `typical`,
    /// which is the difference the card draws as bars without markers.
    public private(set) var stageSummary: SleepStageRangeScoring.Summary?

    /// The five nights the consistency score was read against, the two rules their average draws, and
    /// the figure over its window mean — the consistency card's whole content.
    ///
    /// **`nil` in two states and the screen treats them the same.** There is no night for the day, or
    /// there is a night with fewer than four predecessors: `SleepConsistencyMath` declines to score
    /// both, so `sleepConsistency` is `nil` for the first and the summary's own gate refuses the
    /// second. Either way no card is drawn, which is the absence rule the typical-range card takes one
    /// element up the page — and it costs nothing, because the figure the card would have headed itself
    /// with is already on the breakdown row above it.
    ///
    /// **It is a separate property from `sleepConsistency` rather than a computed one**, because the two
    /// have different inputs: the score can come off the stored row, while the chart always needs the
    /// window. See `resolveConsistencySummary`.
    public private(set) var consistencySummary: SleepConsistencyScoring.Summary?

    /// The window's mean efficiency, for the figure under the efficiency card's own.
    ///
    /// **A pure derivation from the window the other two cards already read**, and that is why it is a
    /// third resolution off one read rather than a fourth repository call — `resolveWindow`'s doc
    /// comment carries the argument, and this is the third reader of the same nights.
    ///
    /// **`nil` is a thin window**, below `RecoveryScoring.minimumBaselineDays` measured nights, and
    /// `MetricHeadline` prints the figure alone in that case. It is the *missing side* and not a
    /// deliberate absence: unlike the consistency card's mean, this comparison restates nothing on the
    /// card, because the card's middle is a note rather than a chart.
    public private(set) var typicalEfficiency: Double?

    /// The night's two timeline lanes, or `nil` when it has no recorded timeline.
    ///
    /// **A pure derivation from `session`, and one that only became possible when `v12` gave the
    /// segments a column.** Before that this was `[]` on every night the screen could show, because
    /// `AnalyzeSleepUseCase` built the array and the write dropped it — so the *only* night that could
    /// ever have drawn a timeline was the one being computed live, and a re-read of the same night
    /// lost it. Reading `session` here is now enough for both, which is why this is a `private(set)`
    /// stored value resolved in `load` rather than a computed one: `load` is where the choice between
    /// the stored row and the live classification is made, and a computed property would have to
    /// restate it.
    ///
    /// **`nil` is the whole gate** — no segments, or a night with no duration — and the card answers
    /// it with its note. See `SleepTimelineLanes.make`, which owns that rule rather than this screen.
    public private(set) var timelineLanes: SleepTimelineLanes?

    /// The night's heart rate, read from the samples the strap wrote while it was worn.
    ///
    /// Named for the **card** it is read for rather than for the quantity: it is drawn inside
    /// `SleepDetailView.hoursOfSleepCard` and nowhere else, and a property called `heartRateSeries`
    /// read at that call site said the card was about heart rate. The points are still `bpm`;
    /// `HoursOfSleepChartSeries` carries the argument in full.
    ///
    /// **`nil` is the screen's `No Data`, and on this machine it is every night.** Nothing has ever
    /// written a `biometric_samples` row here — no strap has been connected — so this reads `nil` on
    /// every night the export can show. That is the honest output rather than a broken one, and the
    /// card says so in words instead of drawing an empty frame.
    ///
    /// A type rather than a `[BiometricSample]` on the view model because the drawing has rules —
    /// where a gap breaks the line, where the scale sits — and the runner that tests this app has no
    /// renderer, so a rule left in a `body` is a rule nothing can assert. See `HoursOfSleepChartSeries`.
    public private(set) var hoursOfSleepSeries: HoursOfSleepChartSeries?

    /// The night's within-sleep stress — the trace, the aggregate and the band breakdown — or `nil`.
    ///
    /// **`nil` on every night this app can currently show, and for the same reason
    /// `hoursOfSleepSeries` is.** Nothing has ever written a `biometric_samples` row on this machine,
    /// and the export carries no R-R series, so `AnalyzeSleepStressUseCase` finds nothing to score and
    /// the card is absent. That is the card's *ordinary* state rather than a fault — see its own doc
    /// comment, which lists the three situations `nil` covers.
    ///
    /// **It is stored rather than computed**, on the same rule the three windowed properties above
    /// take: resolving it costs a read per prior night, so a computed one would re-issue fourteen
    /// repository reads on every body evaluation.
    public private(set) var sleepStress: SleepStressNight?

    /// The seven days ending on the night shown, for the page's `Weekly Trends` chart — or `nil` before
    /// the first load, on a failed one, and **whenever the read found nothing to plot**.
    ///
    /// **Built from the same read the three windowed cards above are taken over**, and that is the
    /// whole reason it costs no query of its own: `resolveWindow` already holds
    /// `RecoveryScoring.baselineWindowLookbackDays` (180) of nights ending on this day, which is more
    /// than a week and is a superset of it. `MetricWeek` keeps the seven slots it is asked for and
    /// ignores the rest, so handing it the wide read is what it is for — and a second read of the same
    /// table over a narrower window would be a second chance for the chart and the cards above it to
    /// describe different nights, which is the failure `resolveWindow` exists to prevent.
    ///
    /// **It is on the view model rather than a local in `load`, because of what it does to that read's
    /// guard.** The window is guarded on `session`: with no night there is nothing for the three cards
    /// to describe, so the read used to be skipped on a nightless day. This chart is not about the
    /// night — it is about the week around it, and a reader who opens an empty today on an imported
    /// history has six measured nights behind it. So the read is now unconditional and this is the
    /// second consumer that justifies the change; a week hung off `window` would have inherited that
    /// guard and drawn nothing on exactly the day the chart is most worth having.
    ///
    /// **Only `sleepSufficiency` and `sleepScore` are populated, and the other fields' `nil` means
    /// *not asked for*.**
    /// `MetricWeek` joins three histories and this screen passes one, so `strain` and `recoveryScore`
    /// are `nil` on every slot — `RecoveryViewModel.week` carries the same narrowing and documents the
    /// trap in full: on this type `nil` is the word for *nothing was measured*, so a view handed this
    /// week and asked to plot strain would report every day of it as unmeasured. Nothing here plots
    /// anything but the bars, and the fix if one ever needs a second series is to pass the second
    /// history rather than to read through the `nil`.
    ///
    /// `nil` from the series rather than from here is what decides the card is absent: a week holding no
    /// classified night produces `WeekBarSeries(sleepSufficiencyWeek:) == nil`, on every night this
    /// machine can show for a fresh install, and the section's heading goes with it.
    public private(set) var week: MetricWeek?

    /// The night's need split into the parts the stored row can source, or `nil` when it can source
    /// none.
    ///
    /// **A pure derivation from `session`, and that is why it is computed rather than stored.** The
    /// three properties above it each cost a repository read or a repository read plus a model, and
    /// that is the whole reason they are `private(set)` stored values; this one reads two columns off a
    /// session already in hand, so a stored copy would be a fourth thing to keep in step with `load`
    /// for no read saved.
    ///
    /// **The rule about *which* columns may be split is `SleepNeedBreakdown`'s, not this screen's.**
    /// That type carries the argument — the export stores the need and the debt and nothing else, and a
    /// fit over all 910 nights recovers the debt as an additive component at ~1.0, which is what makes
    /// `need − debt` a quantity WHOOP itself names rather than one this app invented. A screen building
    /// the subtraction itself would be the second place that argument is made, and the second place is
    /// where it would be made wrongly.
    ///
    /// `nil` covers every night the split cannot describe: one with no stored debt (every imported
    /// night before `v10` added the column), one whose debt exceeds its need, and **every strap night**
    /// — because the identity the two rows are named for holds only for a need that contains the debt
    /// term, and `SleepNeedMath`'s does not. `SleepSession.hasWhoopSleepNeed` is that fact and this is
    /// its only reader. The card draws its two bars and no breakdown box.
    public var needBreakdown: SleepNeedBreakdown.Breakdown? {
        guard let session else { return nil }
        return SleepNeedBreakdown.breakdown(
            needSeconds: session.targetSleepNeedSeconds,
            debtSeconds: session.sleepDebtSeconds,
            hasWhoopNeed: session.hasWhoopSleepNeed)
    }

    private let analyze: AnalyzeSleepUseCase; private let repository: any SleepRepository
    private let napRepository: any NapRepository

    /// The night model, which shares nothing with `analyze` but the samples it reads: this one scores
    /// the window that use case discards, against a baseline drawn from prior *nights* rather than
    /// prior days. See `AnalyzeSleepStressUseCase`.
    private let analyzeSleepStress: AnalyzeSleepStressUseCase

    /// A fourth read, and a different table from the other three: the night's own window into
    /// `biometric_samples`, which is where the live `0x2A37` path writes. Held as the protocol rather
    /// than a concrete store for the same reason the other two are — the suite drives this with
    /// fixtures.
    private let biometricRepository: any BiometricRepository

    /// The profile, read for the one field the sleep score needs — `age`. A failed read costs the
    /// age fallback and does not raise the page's error banner; the rest of the page does not need it.
    private let userProfileRepository: any UserProfileRepository

    public init(
        analyze: AnalyzeSleepUseCase,
        repository: any SleepRepository,
        napRepository: any NapRepository,
        biometricRepository: any BiometricRepository,
        analyzeSleepStress: AnalyzeSleepStressUseCase,
        userProfileRepository: any UserProfileRepository,
        refreshNights: RefreshNightsUseCase? = nil
    ) {
        self.analyze = analyze
        self.repository = repository
        self.napRepository = napRepository
        self.biometricRepository = biometricRepository
        self.analyzeSleepStress = analyzeSleepStress
        self.userProfileRepository = userProfileRepository
        self.refreshNights = refreshNights
    }

    /// The writer that classifies nights, when the page has one.
    ///
    /// **Optional so the runner's fixtures keep their shape**, and used for one thing: a night that
    /// lands while this page is open is re-read, so a page opened before the morning's drain finished
    /// fills itself instead of staying blank until it is pushed again.
    private let refreshNights: RefreshNightsUseCase?

    /// Subscribes to classified nights. Idempotent, on `HomeViewModel.observeNights()`'s rule.
    public func observeNights() {
        guard nightsTask == nil, let refreshNights else { return }
        let stream = refreshNights.nightUpdates
        nightsTask = Task { [weak self] in
            for await written in stream {
                guard !Task.isCancelled, let self else { return }
                guard let day = self.loadedDay, written.date.startOfDay == day else { continue }
                CaptureLog.shared.append(
                    "SLEEP page picked up night=\(written.date.ISO8601Format())")
                await self.load(for: day)
            }
        }
    }

    private var nightsTask: Task<Void, Never>?

    /// Loads the night the screen is showing by reading it — see
    /// `RecoveryViewModel.load(for:)` for why the read is the point.
    ///
    /// This view model had no repository at all, so the screen could not display a stored night even
    /// in principle: it recomputed from raw samples on every appearance, and a day with no samples —
    /// every imported day — had nothing to show.
    ///
    /// `AnalyzeSleepUseCase` is the mildest of the three writers, and the guard below is still not
    /// optional. It returns `nil` *before* writing when the overnight window holds fewer than
    /// `minimumEpochSamples`, which is what keeps it harmless for an imported day; but it has no
    /// existing-row check, so given samples it would happily overwrite a session that is already
    /// stored. Reading first removes the question.
    /// Whether a stored night must be re-classified before this page draws it.
    ///
    /// **Three answers, in order.** A night an import supplied is never touched — WHOOP's own figures
    /// are not this app's to re-decide. A row with no recorded version is re-run once, because the
    /// rule that produced it is unknowable and this is the only way it converges. A row whose version
    /// matches is re-run only when the night's newest input is later than its watermark, which is the
    /// drain-finished-late case and nothing else.
    ///
    /// A current-version row with no watermark cannot be produced by this build; it is treated as
    /// stale rather than trusted, the conservative direction for a night that is about to be read.
    private func shouldReclassify(_ stored: SleepSession?, on date: Date) async -> Bool {
        if stored?.hasWhoopSleepNeed == true { return false }
        guard let stored else { return true }
        guard stored.algorithm == SleepAlgorithm.current else { return true }
        guard let watermark = stored.scoredThrough else { return true }
        // The one read, paid only on the path that can still say "no": a night of the current
        // version whose row already covers everything the analyzer can see is answered from storage.
        let edge = try? await analyze.inputEdge(for: date)
        return SleepReclassification.isOwed(
            watermark: watermark, inputEdge: edge, nightEnd: stored.endTime,
            endedAtDataEdge: stored.endedAtDataEdge)
    }

    /// Writes the night's two bounds and re-reads the page from the row that was saved.
    ///
    /// **Only the times.** The stage totals, the need and the provenance are carried through by
    /// `SleepSession.withEditedTimes`, which also advances the row's watermark — see its doc comment
    /// for why an edit has to move `scoredThrough` or the next re-classification would redraw it.
    ///
    /// **The source is handed back with the save.** `saveSleepSession(_:source:)` writes the column
    /// from its caller, and an imported night that was saved with `nil` would stop being recognisable
    /// as WHOOP's own — `hasWhoopSleepNeed` is read off exactly that string, and the page's edit would
    /// silently turn an imported night into one this app claims to have classified.
    ///
    /// Returns whether the write landed; a failed one leaves the page on the row it had, which is the
    /// same rule the activity page's editor follows.
    @discardableResult
    public func saveTimes(start: Date, end: Date) async -> Bool {
        guard let session else { return false }
        let span = end.timeIntervalSince(start)
        guard span > 0, span <= SleepTimeEditDraft.maximumSpanSeconds else { return false }

        let edited = session.withEditedTimes(start: start, end: end)
        do {
            try await repository.saveSleepSession(
                edited,
                source: edited.hasWhoopSleepNeed ? WhoopExportImporter.sourceLabel : nil)
        } catch {
            AppLogger.database.error(
                "Sleep edit \(self.loadedDay?.description ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        CaptureLog.shared.append(
            "SLEEP edit day=\(edited.date.startOfDay.ISO8601Format()) "
                + "start=\(edited.startTime.ISO8601Format()) "
                + "end=\(edited.endTime.ISO8601Format())")
        await load(for: edited.date)
        return true
    }

    public func load(for date: Date) async {
        let started = Date()
        var reclassified = false
        let day = date.startOfDay
        // **The clear is conditional on the day actually changing, and both halves are corrections.**
        // Clearing on every load blanked the chart and the ring for the whole of a same-day reload —
        // and this page re-loads on the way back from a push, so that was the ring "emptying out".
        // Clearing on *none* of them was the opposite mistake: the page takes its day as a plain `let`,
        // but the **view model** is one instance reused for whichever day Home is showing, so opening
        // it on a second day drew the first day's night, scores and cards until every read returned —
        // and kept them for good if one threw.
        if loadedDay != day {
            session = nil
            sleepScore = nil
            sleepConsistency = nil
            naps = []
            stageSummary = nil
            consistencySummary = nil
            typicalEfficiency = nil
            timelineLanes = nil
            hoursOfSleepSeries = nil
            sleepStress = nil
            week = nil
            errorMessage = nil
        }
        loadedDay = day
        isLoading = true
        defer { isLoading = false }
        do {
            async let profileRead = userProfileRepository.getUserProfile()
            var stored = try await repository.getSleepSession(for: date)
            // **The night is read unless something says it is stale, and the two somethings are a
            // rule change and new input.** A stored `algorithm` that is not `SleepAlgorithm.current`
            // is a classification made by a rule this build no longer applies, so it is re-run; a
            // watermark older than the night's newest epoch or sample is a row a drain has since
            // outgrown, so it is re-run. Everything else is answered from storage — which is what
            // "already calculated" has to mean, and what makes the page open at once.
            //
            // **This replaced an unconditional re-run, and the unconditional version was destructive.**
            // It re-classified on every open, and a night whose drain had not yet delivered its
            // motion could legitimately classify as absent — over a rule that had not changed — and
            // the old code then deleted the row, taking Home's ring and the page's whole timeline
            // with it until the next night. The deletion survives only for the one case that earns
            // it: a stored row whose algorithm no longer exists here.
            if Calendar.current.isDateInToday(date), await shouldReclassify(stored, on: date) {
                reclassified = true
                let provisional = stored
                let analysisStarted = Date()
                stored = try await analyze.execute(for: date)
                AppLogger.database.notice("""
                    Sleep page \(date.description, privacy: .public): re-classified in \
                    \(Int(Date().timeIntervalSince(analysisStarted) * 1000), privacy: .public) ms, \
                    had=\(provisional != nil, privacy: .public) got=\(stored != nil, privacy: .public)
                    """)
                if stored == nil, let provisional {
                    if provisional.algorithm != SleepAlgorithm.current {
                        // The current rule denies a night an older rule accepted, so the row goes.
                        AppLogger.database.notice("""
                            Sleep page \(date.description, privacy: .public): the classifier found no \
                            night under \(SleepAlgorithm.current.rawValue, privacy: .public); the row \
                            was classified by \(provisional.algorithm?.rawValue ?? "no recorded version", privacy: .public) and is removed
                            """)
                        try? await repository.deleteSleepSession(for: date)
                    } else {
                        // Same rule, inconclusive input: keep what this app already measured. A short
                        // read is evidence of a short read, not of an absent night.
                        AppLogger.database.notice("""
                            Sleep page \(date.description, privacy: .public): re-classification was \
                            inconclusive over input the row had not seen; the stored night is kept
                            """)
                        stored = provisional
                    }
                }
            }
            // One wide read, five consumers. Both the typical-range card and the consistency card's
            // window mean are taken over `RecoveryScoring.baselineWindow(before:in:)`, the sleep-stress
            // model takes the same narrowed window as its baseline, the week chart takes the read
            // whole, and the composite reads its four priors from it — and reading it more than once
            // would be two reads that could come back describing different nights.
            //
            // **Unconditional, where it used to be guarded on the night.** "With no night there is
            // nothing to describe and the read would be spent for nothing" was true while the three
            // cards above were its only consumers; the week chart is about the seven days rather than
            // about the night, so an empty today on an imported history is a day it has six bars to
            // draw for. See `week`.
            let history = try await repository.getSleepHistory(
                days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)
            let profile = try? await profileRead
            session = stored
            sleepConsistency = stored.flatMap {
                SleepScoreScoring.resolveConsistency(for: $0, history: history)
            }
            let window = resolveWindow(for: stored, on: date, from: history)
            week = MetricWeek(endingOn: date, sleep: history, age: profile?.age)
            // The week ends on the selected day, so the ring and the weekly chart read one slot.
            sleepScore = week?.days.last?.sleepScore
            stageSummary = resolveStageSummary(from: window)
            consistencySummary = resolveConsistencySummary(from: window)
            typicalEfficiency = resolveTypicalEfficiency(from: window)
            timelineLanes = resolveTimelineLanes(for: stored)
            hoursOfSleepSeries = try await resolveHoursOfSleepSeries(for: stored)
            // Resolved from `window` and not from a read of its own, so the prior nights its baseline
            // is drawn from are the same nights the two "typical" cards above were taken over. The
            // order matters in one direction only: `window` is resolved above, and this is the fourth
            // thing taken from it.
            // **The one thing on this page that was allowed to block it, and no longer is.** The
            // within-sleep stress model reads up to `StressMath.baselineDays` prior nights' samples —
            // roughly a fortnight of a night's second-by-second rows — so awaiting it here held the
            // whole page, cards and all, until it finished. It is a single card: the page draws
            // without it and the card appears when the model lands. The result is cached per night
            // (keyed on the night's own watermark) so a second open in the same launch costs nothing.
            loadSleepStress(for: stored, from: window, day: date.startOfDay)
            // Read for the day the screen is showing, not for today. A nap is keyed on the day it was
            // taken, so paging the day stepper has to move this read with it — anchoring on `Date()`
            // would print one day's nap beside another day's night.
            naps = try await napRepository.getNaps(on: date)
            CaptureLog.shared.append(
                "SLEEP page day=\(date.startOfDay.ISO8601Format()) "
                    + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) "
                    + "night=\(session == nil ? "no" : "yes") "
                    + "reclassified=\(reclassified ? "yes" : "no")")
        } catch {
            errorMessage = error.localizedDescription
            CaptureLog.shared.append(
                "SLEEP page day=\(date.startOfDay.ISO8601Format()) "
                    + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) error=yes")
        }
    }

    /// The wide read both windowed cards are taken over, and the two windows it yields.
    ///
    /// **Read once and shared, because the two cards must describe the same nights.** The
    /// typical-range card's bands and the consistency card's window mean are both taken over
    /// `RecoveryScoring.baselineWindow(before:in:)`, and a second read of the same range would be a
    /// second chance for the two to come back describing different history — the failure
    /// `SleepStageRangeScoring` documents at `typicalSufficiencyPercent`. The window helper itself is
    /// reused rather than re-derived for the same reason: it is the pair `RecoveryViewModel
    /// .loadBaselines` uses, so this screen's "typical" and the Recovery screen's "vs. last 30 days"
    /// cannot be taken over different nights either.
    ///
    /// It **carries the unpinned history as well as the window**, and the difference is not cosmetic:
    /// the typical-range card's bands need the last thirty days *that have rows*, while
    /// `SleepConsistencyScoring.typicalScore` reads each of those nights' own score against its own
    /// four predecessors — nights that can lie before the window's own oldest row. A caller with only
    /// the window would score the window's oldest nights against a history stopping at their edge.
    ///
    /// The lookback is `180` and not `30` because the window is the last thirty days **that have
    /// rows** — a recording gap means thirty rows can reach far further back than thirty days, and a
    /// read of `30` would silently hand the helper a thinner window than either card's own count floor
    /// allows. Anchored on the night's own day rather than `Date()`, so paging to an imported night
    /// asks for the nights before *that* one, exactly as `resolveConsistency` does.
    ///
    /// **It takes the history rather than reading it, and the read moved up into `load`.** It used to
    /// fetch its own and guard on the session first — "with no night there is nothing to describe and
    /// the read would be spent for nothing" — and that is no longer the whole truth: the week chart is
    /// built from the same read and is about the seven days rather than about the night. Two consumers
    /// and one read means the read cannot be inside a guard that only one of them needs. The guard on
    /// the session stays, because the *window* is still only meaningful with a night in it.
    private func resolveWindow(
        for session: SleepSession?, on date: Date, from history: [SleepSession]
    ) -> Window? {
        guard let session else { return nil }

        return Window(
            session: session,
            history: history,
            priorNights: RecoveryScoring.baselineWindow(before: date, in: history))
    }

    /// The night against its window, for the typical-range card.
    private func resolveStageSummary(from window: Window?) -> SleepStageRangeScoring.Summary? {
        guard let window else { return nil }
        return SleepStageRangeScoring.summary(
            for: window.session, priorNights: window.priorNights)
    }

    /// The five nights, their two rules and the figure, for the consistency card — or `nil`.
    ///
    /// **It takes the score as an input rather than resolving one**, because the score has a different
    /// source from everything else on the card: an imported night carries WHOOP's own figure in
    /// `sleeps.sleep_consistency` and the chart is drawn either way. `sleepConsistency` is resolved
    /// before this in `load`, which is the one ordering this depends on.
    ///
    /// `nil` when there is no score, and `nil` again from `SleepConsistencyScoring.summary` when the
    /// history holds fewer than four nights before this one. **The second case is not hypothetical on
    /// an imported history**: WHOOP scores its own earliest nights, so the export's first few days can
    /// carry a stored figure with no four predecessors in this app's database. There is then no rule
    /// and no chart, and the card is absent — which hides no reading, because the figure it would have
    /// printed is the one the breakdown row above already shows.
    private func resolveConsistencySummary(
        from window: Window?
    ) -> SleepConsistencyScoring.Summary? {
        guard let window, let score = sleepConsistency else { return nil }

        return SleepConsistencyScoring.summary(
            for: window.session,
            history: window.history,
            score: score,
            typicalScore: SleepConsistencyScoring.typicalScore(
                in: window.priorNights, history: window.history))
    }

    /// The window's mean efficiency, for the efficiency card's comparison.
    ///
    /// It takes the **narrowed** window and not the whole history, on
    /// `SleepConsistencyScoring.typicalScore`'s rule: every "typical" figure on this screen is taken
    /// over the same nights, and a mean over the un-narrowed history would silently be taken over a
    /// different set than the bands one card up. `SleepEfficiencyScoring` does not re-window, so this is
    /// the only place the narrowing happens.
    ///
    /// `nil` with no night, because with nothing to describe the read was never made.
    private func resolveTypicalEfficiency(from window: Window?) -> Double? {
        guard let window else { return nil }
        return SleepEfficiencyScoring.typicalEfficiency(in: window.priorNights)
    }

    /// The night's timeline lanes, or `nil` when it has no recorded timeline.
    ///
    /// It takes the **session** rather than a window, and reads the night's own bounds as the lanes'
    /// scale: the timeline is drawn within the sleep period, so `startTime`/`endTime` — the in-bed
    /// bounds the efficiency ratio is already taken over — are what its fractions are of.
    ///
    /// No read of its own, which is why it is a plain function of an argument rather than an `async`
    /// resolver like its three siblings: the segments are already on the session, whether that came
    /// from storage or from `AnalyzeSleepUseCase` a moment ago.
    private func resolveTimelineLanes(for session: SleepSession?) -> SleepTimelineLanes? {
        guard let session else { return nil }
        return SleepTimelineLanes.make(
            segments: session.sleepStages,
            start: session.startTime,
            end: session.endTime)
    }

    /// The wide read and the two windows taken from it.
    private struct Window {
        let session: SleepSession
        /// `RecoveryScoring.baselineWindowLookbackDays` back, un-narrowed.
        let history: [SleepSession]
        /// The last `baselineWindowDays` **that have rows**, strictly before the night.
        let priorNights: [SleepSession]
    }

    /// The night's heart-rate samples, read over the night's own window.
    ///
    /// The window is `session.startTime ... session.endTime` — the **in-bed bounds**, not the day's.
    /// A day-scoped read would ask for midnight to midnight while the night it is describing runs from
    /// the previous evening, so most of the trace would be filtered away by the series itself, which
    /// keeps only points inside the bounds it was given.
    ///
    /// Guarded on the session first, like the two resolvers above: with no night there is no window to
    /// ask for and the read would be spent for nothing.
    ///
    /// A read failure is **not** caught here. It propagates to `load`'s own `catch` and becomes
    /// `errorMessage`, which is the same treatment the two sibling reads get — and the right one, since
    /// a repository that threw is a fault and not the ordinary absence that `nil` means.
    private func resolveHoursOfSleepSeries(for session: SleepSession?) async throws
        -> HoursOfSleepChartSeries? {
        guard let session else { return nil }

        let samples = try await biometricRepository.getSamples(
            from: session.startTime, to: session.endTime)

        return HoursOfSleepChartSeries(
            samples: samples, start: session.startTime, end: session.endTime)
    }

    /// Resolves the sleep-stress card **off the page's critical path**, from a cache when it can.
    ///
    /// See the call site: the model reads a fortnight of prior nights, and that is the heaviest thing
    /// this screen does. `SleepStressCache` remembers the answer per night and per watermark, so a
    /// pushed-and-popped page — or the same page after a day change and back — does not pay for it
    /// twice in one launch. A failure assigns `nil`, which draws no card: the absence rule, not an
    /// error the page should hold itself for.
    private func loadSleepStress(
        for session: SleepSession?, from window: Window?, day: Date
    ) {
        guard let session, let window else {
            sleepStress = nil
            return
        }
        let key = session.scoredThrough
        let analysis = analyzeSleepStress
        let nights = window.priorNights
        let cache = SleepStressCache.shared

        Task { [weak self] in
            if let cached = await cache.cached(for: day, key: key) {
                await MainActor.run {
                    guard let self, self.loadedDay == day else { return }
                    self.sleepStress = cached
                }
                return
            }
            let value = try? await analysis.execute(for: session, priorNights: nights)
            await cache.store(value, for: day, key: key)
            await MainActor.run {
                guard let self, self.loadedDay == day else { return }
                self.sleepStress = value
            }
        }
    }


}

/// The within-sleep stress model's answer, remembered per night.
///
/// **Process-wide and in memory**, because the call it saves is the most expensive one on the sleep
/// page — up to `StressMath.baselineDays` prior nights' samples — and the pages that need it are pushed
/// and popped repeatedly. The key is the night's own `scoredThrough` watermark, so a night a drain has
/// reclassified misses the cache rather than serving the older answer. Nothing here is persisted: the
/// durable form would be a stored table, which is a migration rather than a cache.
actor SleepStressCache {

    static let shared = SleepStressCache()

    private var values: [Date: (key: Date?, value: SleepStressNight?)] = [:]

    /// A double optional on purpose: `nil` is a miss, `.some(nil)` is a cached *absence* — a night the
    /// model declined, which is a real answer and must not be recomputed either.
    func cached(for day: Date, key: Date?) -> SleepStressNight?? {
        guard let entry = values[day], entry.key == key else { return nil }
        return .some(entry.value)
    }

    func store(_ value: SleepStressNight?, for day: Date, key: Date?) {
        values[day] = (key, value)
    }

    /// For the runner: the cache is process-wide, and a block that seeded one would hide a recompute
    /// from the next.
    func reset() { values.removeAll() }
}
