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

    private let analyze: AnalyzeSleepUseCase; private let repository: any SleepRepository
    private let napRepository: any NapRepository
    public init(
        analyze: AnalyzeSleepUseCase,
        repository: any SleepRepository,
        napRepository: any NapRepository
    ) {
        self.analyze = analyze
        self.repository = repository
        self.napRepository = napRepository
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
            stageSummary = try await resolveStageSummary(for: stored, on: date)
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
            for: Self.night(from: session),
            history: history.map(Self.night(from:)))
    }

    /// The two boundaries and the day key, which is all the consistency model reads.
    private static func night(from session: SleepSession) -> SleepConsistencyMath.Night {
        SleepConsistencyMath.Night(
            day: session.date, onset: session.startTime, wake: session.endTime)
    }

    /// The night against its window, for the typical-range card.
    ///
    /// **Both halves are reused rather than re-derived.** The read is
    /// `RecoveryScoring.baselineWindowLookbackDays` back, capped at
    /// `RecoveryScoring.baselineWindowDays` by `RecoveryScoring.baselineWindow(before:in:)` — the same
    /// pair `RecoveryViewModel.loadBaselines` uses, so this screen's "typical" and the Recovery
    /// screen's "vs. last 30 days" cannot come to be taken over different nights. That helper also
    /// snaps the anchor to the calendar day internally, which matters here for the reason its own doc
    /// comment records: `date` is the instant the screen was pushed with, hours after midnight, and
    /// compared raw the night would fall inside its own baseline.
    ///
    /// The lookback is `180` and not `30` because the window is the last thirty days **that have
    /// rows** — a recording gap means thirty rows can reach far further back than thirty days, and a
    /// read of `30` would silently hand the helper a thinner window than the card's own count floor
    /// allows. Anchored on the night's own day rather than `Date()`, so paging to an imported night
    /// asks for the nights before *that* one, exactly as `resolveConsistency` does.
    ///
    /// Guarded on the session first: with no night there is nothing to describe and the read would be
    /// spent for nothing.
    private func resolveStageSummary(
        for session: SleepSession?, on date: Date
    ) async throws -> SleepStageRangeScoring.Summary? {
        guard let session else { return nil }

        let history = try await repository.getSleepHistory(
            days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)

        return SleepStageRangeScoring.summary(
            for: session,
            priorNights: RecoveryScoring.baselineWindow(before: date, in: history))
    }
}
