import Foundation
import SwiftUI

@MainActor @Observable public final class StrainViewModel {
    public var strain: StrainScore?; public var target = 12.0; public var isLoading = false; public var errorMessage: String?

    /// The day's workouts, earliest first.
    ///
    /// **This is what gates the activity card.** A day with no workout shows no card at all — the two
    /// `HEART RATE ZONES` rows are a reading *of a workout*, and there is no honest dash to draw for
    /// "there was no workout" when the rows above them are also dashes. An empty array is a day
    /// without one, never a stand-in.
    public var workouts: [WorkoutSession] = []

    /// The day's zone time, summed over the workouts that carry a zone block.
    ///
    /// `nil` when none of them does — which is the answer for a day this app recorded itself, since
    /// the live path writes no zone percentages. The two rows then draw a dash, per the rule that a
    /// field absent from every CSV is a dash and not a zero. A measured day whose workouts all read
    /// `0%` in every band is a real `0:00` and is **not** `nil`; see `WorkoutZoneTime.aggregate`.
    public var zoneTime: WorkoutZoneTime?

    /// The trailing window's mean zone time, or `nil` when that window held too few days.
    ///
    /// `nil` below `RecoveryScoring.minimumBaselineDays` days carrying zone data: a window with one
    /// day in it has a mean, and printing it as "your average" would present a single workout as a
    /// baseline. The step baseline one property down is withheld on the same rule and the same
    /// constant, so the card's two columns cannot come to disagree about how much history a mean needs.
    public var zone1to3Baseline: Double?
    public var zone4to5Baseline: Double?

    /// The day's step count, or `nil` when the strap did not measure it.
    ///
    /// **This is the one row on the card this app measured itself.** The two zone rows are WHOOP's own
    /// figures read out of the export; this comes off the strap's accelerometer, decoded from live
    /// `0x2B`/43 notifications or a drained type-47 record, accumulated by `TrackStepsUseCase` and
    /// stored one row per day. See `StepRepository` for why the table has no `source` column.
    ///
    /// `nil` is the absence rule's ordinary case — a day the strap was not worn has **no row at all**
    /// — and a *measured* day of no walking is a real `0`, which is why the read goes through
    /// `StepCount.measuredStepCount` rather than through the row's existence. On every day this
    /// machine can currently show, this is `nil`: `stepCounts` holds no rows in any database here.
    public var steps: Int?

    /// The trailing window's mean step count, or `nil` when that window held too few measured days.
    ///
    /// An `Int` and not a `Double`, because the figure beside it is a count — a mean of `5,169.4`
    /// would be a precision the producer never had. `MetricChange` decides "the same" by comparing the
    /// two strings the row's own formatter produces, so a truncated mean and a count that print alike
    /// are the same as far as the screen is concerned, which is the type's documented rule.
    public var stepsBaseline: Int?

    private let calculate: CalculateStrainUseCase
    private let repository: any StrainRepository
    private let workoutRepository: any WorkoutRepository
    private let stepRepository: any StepRepository

    public init(
        calculate: CalculateStrainUseCase,
        repository: any StrainRepository,
        workoutRepository: any WorkoutRepository,
        stepRepository: any StepRepository
    ) {
        self.calculate = calculate
        self.repository = repository
        self.workoutRepository = workoutRepository
        self.stepRepository = stepRepository
    }

    /// Loads the day the screen is showing by reading it — see
    /// `RecoveryViewModel.load(for:)` for why the read is the point.
    ///
    /// The recompute test is the **measurement**, not the row, which is what
    /// `RecoveryViewModel.shouldCompute` has always tested — the two tabs used to disagree.
    /// `CalculateStrainUseCase` no longer writes a row for a day it could not measure, so a test on
    /// `nil` would now mostly agree by accident; what it still gets wrong is a placeholder row left on
    /// disk by an older build, which reads as a settled day and never recomputes, pinning the tab to
    /// "No data" for the rest of the day even once samples arrive.
    ///
    /// **Workouts have no recompute branch, and must not grow one.** They are read from the database
    /// and from nowhere else: an imported workout comes from a CSV that is not re-read on a day
    /// change, and a live one is written by `ActiveWorkoutViewModel` as it is recorded. There is
    /// nothing for a screen to recalculate.
    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var stored = try await repository.getStrain(for: date)
            if Calendar.current.isDateInToday(date), stored?.hasMeasurement != true {
                stored = try await calculate.execute(for: date)
            }
            strain = stored

            async let today = workoutRepository.getWorkouts(for: date)
            async let history = workoutRepository.getWorkoutHistory(
                days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)
            // The strap's own count, and its window. Read here rather than left to the view for the
            // reason the two reads above are: a screen computing a mean is a screen holding a second
            // definition of `baselineWindow`.
            async let stepsDay = stepRepository.getStepCount(for: date)
            async let stepsHistory = stepRepository.getStepCountHistory(
                days: RecoveryScoring.baselineWindowLookbackDays, endingOn: date)

            let sessions = try await today
            workouts = sessions
            zoneTime = WorkoutZoneTime.aggregate(sessions)

            let baseline = Self.zoneBaselines(from: try await history, for: date)
            zone1to3Baseline = baseline?.zone1to3
            zone4to5Baseline = baseline?.zone4to5

            steps = try await stepsDay?.measuredStepCount
            stepsBaseline = Self.stepBaseline(from: try await stepsHistory, for: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The trailing window's mean zone time per day, or `nil` when too few days carried any.
    ///
    /// The window is `RecoveryScoring.baselineWindow(before:in:)` — the same rule the recovery page's
    /// four means and this screen's step baseline are taken over, strictly-before and capped at
    /// thirty — rather than a filter written here. It is fetched over `baselineWindowLookbackDays`
    /// for the reason that constant documents: the window is the last thirty days *that have rows*,
    /// so a gappy history reaches further back than thirty calendar days, and a shorter read silently
    /// prints a mean taken over fewer days than the window claims.
    ///
    /// **The history is collapsed to days before the window is taken, and the sort is load-bearing.**
    /// Several workouts share a day, so summing them is what makes the unit of the mean a day rather
    /// than a session; and `baselineWindow` takes the trailing thirty *after* filtering, which is only
    /// the right thirty if the series is oldest-first — which `Dictionary(grouping:)` does not
    /// preserve. Days with no zone block drop out here rather than counting as zeroes, which is what
    /// keeps a week of live-recorded sessions from dragging the mean toward nothing.
    private static func zoneBaselines(
        from history: [WorkoutSession], for date: Date
    ) -> (zone1to3: Double, zone4to5: Double)? {
        let perDay = Dictionary(grouping: history) { $0.startedAt.startOfDay }
        let days = perDay.values.compactMap { WorkoutZoneTime.aggregate($0) }.sorted { $0.date < $1.date }

        let window = RecoveryScoring.baselineWindow(before: date, in: days)
        guard window.count >= RecoveryScoring.minimumBaselineDays else { return nil }

        let count = Double(window.count)
        return (
            zone1to3: window.reduce(0) { $0 + $1.zone1to3Seconds } / count,
            zone4to5: window.reduce(0) { $0 + $1.zone4to5Seconds } / count)
    }

    /// The trailing window's mean step count, or `nil` when too few measured days were in it.
    ///
    /// **The unmeasured rows are dropped before the window is taken**, which is the one place this
    /// differs from `zoneBaselines` above — not in rule but in what the rows can be. No writer produces
    /// a zero-second row (`TrackStepsUseCase` persists only what it measured, using the same
    /// `hasMeasurement` comparison its readers use), but one is constructible and the entity's own
    /// `hasMeasurement` documents it as reader tolerance. Letting one into the window would feed a
    /// fabricated `0` into the mean — the strongest possible claim that the user did not walk — where
    /// `zoneBaselines` drops a day with no zone block for the same reason.
    ///
    /// No grouping step is needed: `stepCounts` is day-keyed on the snapped date, so one row is
    /// already one day. And no sort is needed either — `getStepCountHistory(days:endingOn:)` returns
    /// oldest-first, which is the order `baselineWindow`'s trailing slice depends on.
    private static func stepBaseline(from history: [StepCount], for date: Date) -> Int? {
        let window = RecoveryScoring.baselineWindow(
            before: date, in: history.filter(\.hasMeasurement))
        guard window.count >= RecoveryScoring.minimumBaselineDays else { return nil }
        return window.reduce(0) { $0 + $1.stepCount } / window.count
    }
}
