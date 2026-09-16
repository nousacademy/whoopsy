import Foundation
import SwiftUI

@MainActor @Observable public final class SleepViewModel {
    public var session: SleepSession?; public var isLoading = false; public var errorMessage: String?

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

    /// A fourth read, and a different table from the other three: the night's own window into
    /// `biometric_samples`, which is where the live `0x2A37` path writes. Held as the protocol rather
    /// than a concrete store for the same reason the other two are — the suite drives this with
    /// fixtures.
    private let biometricRepository: any BiometricRepository

    public init(
        analyze: AnalyzeSleepUseCase,
        repository: any SleepRepository,
        napRepository: any NapRepository,
        biometricRepository: any BiometricRepository
    ) {
        self.analyze = analyze
        self.repository = repository
        self.napRepository = napRepository
        self.biometricRepository = biometricRepository
    }

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
    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var stored = try await repository.getSleepSession(for: date)
            if Calendar.current.isDateInToday(date), stored == nil {
                stored = try await analyze.execute(for: date)
            }
            session = stored
            sleepConsistency = try await resolveConsistency(for: stored)
            // One wide read, two resolutions off it. Both the typical-range card and the consistency
            // card's window mean are taken over `RecoveryScoring.baselineWindow(before:in:)`, and
            // reading it twice would be two reads that could come back describing different nights.
            let window = try await resolveWindow(for: stored, on: date)
            stageSummary = resolveStageSummary(from: window)
            consistencySummary = resolveConsistencySummary(from: window)
            typicalEfficiency = resolveTypicalEfficiency(from: window)
            timelineLanes = resolveTimelineLanes(for: stored)
            hoursOfSleepSeries = try await resolveHoursOfSleepSeries(for: stored)
            // Read for the day the screen is showing, not for today. A nap is keyed on the day it was
            // taken, so paging the day stepper has to move this read with it — anchoring on `Date()`
            // would print one day's nap beside another day's night.
            naps = try await napRepository.getNaps(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The stored figure, else one computed from the night and its four most recent predecessors, else
    /// `nil`.
    ///
    /// The read is anchored on the **night's own day** and not on `Date()`, so a screen opened on an
    /// imported night asks for the nights before *that* one — and widening it to
    /// `SleepConsistencyMath.historyLookbackDays` is what covers a recording gap: measured on the
    /// bundled export, four prior nights span more than five calendar days on 17 of 891 nights. The
    /// window is a date range rather than a count, so the math truncates the list to four records
    /// itself rather than being handed exactly four.
    private func resolveConsistency(for session: SleepSession?) async throws -> Int? {
        guard let session else { return nil }
        if let stored = session.sleepConsistency { return stored }

        let history = try await repository.getSleepHistory(
            days: SleepConsistencyMath.historyLookbackDays, endingOn: session.date)

        return SleepConsistencyMath.consistency(
            for: SleepConsistencyScoring.night(from: session),
            history: history.map(SleepConsistencyScoring.night(from:)))
    }

    /// The wide read both windowed cards are taken over, and the two windows it yields.
    ///
    /// **Read once and shared, because the two cards must describe the same nights.** The
    /// typical-range card's bands and the consistency card's window mean are both taken over
    /// `RecoveryScoring.baselineWindow(before:in:)`, and a second read of the same range would be a
    /// second chance for the two to come back describing different history — the failure
    /// `SleepStageRangeScoring` documents at `typicalPerformancePercent`. The window helper itself is
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
    /// Guarded on the session first: with no night there is nothing to describe and the read would be
    /// spent for nothing.
    private func resolveWindow(for session: SleepSession?, on date: Date) async throws -> Window? {
        guard let session else { return nil }

        let history = try await repository.getSleepHistory(
            days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)

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
}
