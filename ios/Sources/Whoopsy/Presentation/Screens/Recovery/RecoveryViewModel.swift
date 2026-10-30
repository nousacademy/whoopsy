import Foundation
import SwiftUI

@MainActor @Observable public final class RecoveryViewModel {
    public var recovery: RecoveryMetric?; public var history: [RecoveryMetric] = []; public var isLoading = false; public var errorMessage: String?

    /// The trailing baselines the day's four figures are read against, or `nil` before the first
    /// load. Read through `RecoveryScoring` so they are the same numbers the day's score was computed
    /// from, not a parallel average that happens to sit under the same ring.
    public private(set) var baselines: RecoveryScoring.Baselines?

    /// The day's own night, or `nil` when no session is stored for it.
    ///
    /// Only its sleep performance is used here. It is read rather than derived from the recovery row
    /// because there is no sleep term *on* that row worth reading: `RecoveryMetric` carries a
    /// respiratory rate and no performance, and the score's sleep term was folded into `score` at
    /// scoring time and not kept.
    public private(set) var sleepSession: SleepSession?

    /// The seven days ending on the day shown, for the week charts — built from the **recovery and
    /// sleep histories**, and deliberately not from strain.
    ///
    /// `MetricWeek` joins three histories and is the app's canonical week. This page draws four of the
    /// six figures it carries, and they come from two of those three: recovery score, HRV, resting
    /// rate and respiratory rate are all columns on a `recoveries` row, and sleep performance is
    /// computed from a `sleeps` row. **Strain is the one that is `nil` on every slot here**, and that
    /// `nil` means *not asked for* rather than *not measured* — nothing on this page plots it, so the
    /// read is not taken. A reader of this property must not treat that field as an absence: reading
    /// strain off this week would report every day of it as unmeasured. Passing it a strain history is
    /// the fix if a view ever needs one; passing this week to something that plots strain is not.
    ///
    /// The two reads are both taken over the day's own window rather than the week's, because
    /// `MetricWeek` keeps the seven slots it was asked for and ignores the rest — so one read serves
    /// the week and the day together. The sleep history is a second query and not a wider view of the
    /// first: nothing on a `recoveries` row carries a sleep performance, so there is no window of one
    /// that would do.
    ///
    /// `nil` before the first load, and on a failed one — the charts are then absent rather than
    /// empty, which is the same rule each chart applies inside a loaded week.
    public private(set) var week: MetricWeek?

    private let repository: any RecoveryRepository
    private let sleepRepository: any SleepRepository

    /// **No calculator, and that is the page's contract now.** A ring page reads; the one writer that
    /// scores a day is `RefreshRecoveryUseCase`, driven from the foreground after the night refresh, so
    /// a calculation happens once per night and is stored. See that type for what this replaced.
    public init(
        repository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        refreshRecovery: RefreshRecoveryUseCase? = nil
    ) {
        self.repository = repository
        self.sleepRepository = sleepRepository
        self.refreshRecovery = refreshRecovery
    }

    /// The writer that scores the day, when the page has one.
    ///
    /// **Optional for the runner's fixtures' sake**, and used so a page opened before the background
    /// score lands fills itself: the foreground chain runs a drain first, so a ring tapped in the
    /// minutes after launch can otherwise read a day that is about to be written.
    private let refreshRecovery: RefreshRecoveryUseCase?

    private var recoveryTask: Task<Void, Never>?

    /// Subscribes to computed rows. Idempotent, on `HomeViewModel.observeNights()`'s rule.
    public func observeRecovery() {
        guard recoveryTask == nil, let refreshRecovery else { return }
        let stream = refreshRecovery.updates
        recoveryTask = Task { [weak self] in
            for await written in stream {
                guard !Task.isCancelled, let self else { return }
                guard let day = self.loadedDay, written.date.startOfDay == day else { continue }
                CaptureLog.shared.append(
                    "RECOVERY page picked up day=\(written.date.ISO8601Format())")
                await self.load(for: day)
            }
        }
    }

    /// The day the last load was for, so an update for another day is dropped.
    private var loadedDay: Date?

    /// Loads the day the screen is showing — by **reading** it, not by recomputing it.
    ///
    /// This is the whole fix for "the imported history is invisible", and the read is what makes it
    /// safe. A stored day has no raw samples to recompute from — an imported day has none by
    /// construction, and a strap day's samples are long gone — so the use case has nothing to score
    /// and would return `nil`, blanking a day the user can see data for.
    ///
    /// The overwrite hazard that used to make this dangerous is gone with the placeholder: a day the
    /// use case cannot measure is now a day it does not write, where it once saved
    /// `score: 0, hrvValueMs: 0, restingHeartRate: 0` **over** whatever was stored, wiping a row and
    /// its `source` label on the way past. Reading first is still the rule, and `shouldCompute` is
    /// still the only gate that lets a recompute through — see it for what that gate now protects.
    public func load(for date: Date) async {
        let started = Date()
        let day = date.startOfDay
        // **A day being left behind takes its figures with it.** `RecoveryDetailView` is shown twice —
        // as the Recovery tab's whole page and as Home's pushed copy — and both draw from a view model
        // that outlives a single day (the tab wraps `Date()`, which moves at midnight). Without this,
        // the day being replaced stayed on screen until every read returned. A same-day reload clears
        // nothing, which is the correction the ring needed.
        if loadedDay != day {
            recovery = nil
            history = []
            week = nil
            baselines = nil
            sleepSession = nil
            errorMessage = nil
        }
        loadedDay = day
        isLoading = true
        defer { isLoading = false }
        do {
            var stored = try await repository.getRecovery(for: date)
            // **The stored day is drawn before anything recomputes.** A recompute reads the whole
            // night's samples and a thirty-day baseline, and this used to run before the assignment —
            // so opening today's ring blanked the page for the length of the calculation instead of
            // showing the row that was already on disk. The recompute replaces it below when it lands.
            recovery = stored

            // Fetched last so that a score computed just above, which lands on today, is in the trend
            // rather than one load behind it.
            history = try await repository.getRecoveryHistory(days: 14, endingOn: date)

            // Over the same window, and not off the read above: sleep performance is computed from a
            // `sleeps` row, and no column of a `recoveries` row carries one. `MetricWeek` keeps the
            // seven slots it was asked for and ignores the rest, so one read serves week and day.
            let nights = try await sleepRepository.getSleepHistory(days: 14, endingOn: date)
            week = MetricWeek(endingOn: date, recovery: history, sleep: nights)

            await loadBaselines(for: date, todayHrvMetric: displayedHrvMetric)
            CaptureLog.shared.append(
                "RECOVERY load day=\(date.startOfDay.ISO8601Format()) "
                    + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) "
                    + "row=\(recovery == nil ? "no" : "yes")")
            logScoreArithmetic(for: date)
        } catch {
            errorMessage = error.localizedDescription
            CaptureLog.shared.append(
                "RECOVERY load day=\(date.startOfDay.ISO8601Format()) "
                    + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) error=yes")
        }
    }

    /// The stored day's score arithmetic, printed from the baselines this page already read.
    ///
    /// **The scorer's own line only prints when it scores**, and a day is scored once — so the
    /// question "why is this row 60%?" usually arrives on a day with no `RECOVERY score` line in the
    /// capture at all. The page holds the same three pieces the scorer used: the row's readings and
    /// the trailing window's means and spreads, read through the same `RecoveryScoring` call. This
    /// line reconstructs the z-scores from them so the answer is a lookup the next time the page is
    /// opened, without a re-score and without a second derivation.
    private func logScoreArithmetic(for date: Date) {
        guard let row = recovery, row.hasMeasurement, let baselines else { return }
        let zHRV = BaselineStatisticsMath.zScore(
            value: row.hrvValueMs, mean: baselines.hrvMeanMs, stdDev: baselines.hrvStdDevMs)
        let zRHR = BaselineStatisticsMath.zScore(
            value: Double(row.restingHeartRate),
            mean: baselines.restingHeartRateMean,
            stdDev: baselines.restingHeartRateStdDev)
        let sleep = sleepSession.map { Double($0.sleepSufficiencyPercentage) / 100.0 }
        CaptureLog.shared.append(
            "RECOVERY read day=\(date.startOfDay.ISO8601Format()) score=\(row.score) "
                + "hrv=\(String(format: "%.1f", row.hrvValueMs))"
                + " base=\(String(format: "%.1f", baselines.hrvMeanMs))"
                + "±\(String(format: "%.1f", baselines.hrvStdDevMs)) "
                + "z=\(String(format: "%.2f", zHRV)) "
                + "rhr=\(row.restingHeartRate)"
                + " base=\(String(format: "%.1f", baselines.restingHeartRateMean))"
                + "±\(String(format: "%.1f", baselines.restingHeartRateStdDev)) "
                + "z=\(String(format: "%.2f", zRHR)) "
                + "sleep=\(sleep.map { String(format: "%.2f", $0) } ?? "-") "
                + "days=\(baselines.hrvObservationCount)")
    }

    /// The trailing window's baselines, and the day's own night.
    ///
    /// **Why a 180-day read for a 30-day window.** The scoring window is the last thirty days that
    /// *have rows*, not the last thirty calendar days — `RecoveryScoring.baselineWindow` — so on a
    /// history with gaps it reaches further back than a month to fill. Reading exactly thirty days
    /// would not fail loudly; it would quietly build the printed baseline from a different set of days
    /// than the score above it used. `baselineWindowLookbackDays` carries the measurement behind the
    /// 180.
    ///
    /// The two reads are taken together because neither depends on the other, and the day's own night
    /// is the first element of the sleep window rather than a third query.
    ///
    /// `todayHrvMetric` is passed in rather than read off `recovery` here so that the metric the mean
    /// is narrowed to is the same one `hrvTrend` plots — the never-mix rule applied once, at the
    /// caller, rather than twice with two chances to disagree.
    private func loadBaselines(for date: Date, todayHrvMetric: HRVMetric) async {
        do {
            async let windowRead = repository.getRecoveryHistory(
                days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)
            async let nightRead = sleepRepository.getSleepSession(for: date)
            async let nightsRead = sleepRepository.getSleepHistory(
                days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)

            let window = RecoveryScoring.baselineWindow(before: date, in: try await windowRead)
            let night = try await nightRead
            let nights = try await nightsRead

            sleepSession = night
            baselines = RecoveryScoring.baselines(
                history: window,
                todayHrvMetric: todayHrvMetric,
                // The same window's nights, strictly before the day, so a night never contributes to
                // the mean it is printed against — the rule `baselineWindow` applies to the days.
                sleepingNights: RecoveryScoring.baselineWindow(before: date, in: nights))
        } catch {
            // A failed read leaves the baselines `nil` and the screen prints an unadorned value
            // rather than a comparison against a window that was never loaded. Same reasoning as
            // `zText`'s dash: "not loaded" is not "at baseline".
            baselines = nil
            sleepSession = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Whether to fall through to the calculating use case.
    ///
    /// Today only, for `isToday`'s own reason: raw samples exist only for days the app was running,
    /// so a past day would come back as no row at all over a stored one.
    ///
    /// **A stored RMSSD row is provisional once a classified night exists, and this is the gate that
    /// replaces it.** A screen that reads a stored row never re-runs the estimator, so before this
    /// rule every fix to the window, the filter or the difference gate left its predecessor's number
    /// on disk until a migration deleted the day — three such migrations (`v29`–`v31`) each existed
    /// only to clear one. Recomputing is the permanent answer: `execute` writes with an upsert keyed
    /// on the day, so the row converges on the current rule and a later fix needs no migration.
    ///
    /// Two guards keep that narrow. The recompute needs a **sleep session**, because without one the
    /// HRV window is an arbitrary eight hours and opening the tab before the night is classified would
    /// overwrite a real row with a fallback — which is exactly how today's 58.3 ms fallback was
    /// written. And it applies only to an **RMSSD** row: HealthKit supplies SDNN, a different
    /// quantity, and this path must never replace it (`docs/ALGORITHMS.md`'s never-mix rule).
    ///
    /// A day with no measurement is not the same as a day with no row, which is why the first branch
    /// tests the measurement and not `nil`: the strap may record something later today, and a
    /// placeholder row left by an older build (`RecoveryMetric.hasMeasurement`) is fillable.
    /// Which metric the screen is presenting. Once HealthKit SDNN days and strap RMSSD days share
    /// this table, a screen that does not name a metric is showing an unlabelled mix.
    public var displayedHrvMetric: HRVMetric {
        recovery?.hrvMetric ?? history.last?.hrvMetric ?? .rmssd
    }

    /// History narrowed to one metric — the only correct input for a trend line. Plotting the raw
    /// history would put SDNN and RMSSD on one axis, where a normal SDNN day looks like a collapse.
    ///
    /// Days with no measurement are excluded rather than plotted as 0: the placeholder means "we have
    /// no reading", and on an HRV axis a 0 is indistinguishable from a physiological crash.
    public func hrvTrend(for metric: HRVMetric) -> [Double] {
        history.filter { $0.hrvMetric == metric && $0.hasMeasurement }.map(\.hrvValueMs)
    }
}
