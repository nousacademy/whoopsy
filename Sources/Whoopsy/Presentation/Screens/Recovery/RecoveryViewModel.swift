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

    private let calculate: CalculateRecoveryUseCase
    private let repository: any RecoveryRepository
    private let sleepRepository: any SleepRepository

    public init(
        calculate: CalculateRecoveryUseCase,
        repository: any RecoveryRepository,
        sleepRepository: any SleepRepository
    ) {
        self.calculate = calculate
        self.repository = repository
        self.sleepRepository = sleepRepository
    }

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
        isLoading = true
        defer { isLoading = false }
        do {
            var stored = try await repository.getRecovery(for: date)
            if shouldCompute(for: date, stored: stored) {
                stored = try await calculate.execute(for: date)
            }
            recovery = stored

            // Fetched last so that a score computed just above, which lands on today, is in the trend
            // rather than one load behind it.
            history = try await repository.getRecoveryHistory(days: 14, endingOn: date)

            await loadBaselines(for: date, todayHrvMetric: displayedHrvMetric)
        } catch {
            errorMessage = error.localizedDescription
        }
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
    /// Only for today, and only when nothing has been measured for it. Both halves are load-bearing.
    /// The `isToday` test keeps the recompute off every past day: raw samples exist only for days the
    /// app was running, so a past day would come back as no row at all over a stored one.
    /// The `hasMeasurement` test keeps it off a day that already holds a reading — including the case
    /// where the strap recorded today, and the hypothetical where an export covers today — and it also
    /// stops the tab re-scoring itself on every appearance for the rest of the day.
    ///
    /// A day with no measurement is not the same as a day with no row, which is why this tests the
    /// measurement and not `nil`: the strap may have recorded nothing yet and still record something
    /// later today, and a placeholder row left on disk by an older build
    /// (`RecoveryMetric.hasMeasurement`) is a legitimate candidate to fill.
    private func shouldCompute(for date: Date, stored: RecoveryMetric?) -> Bool {
        Calendar.current.isDateInToday(date) && stored?.hasMeasurement != true
    }

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
