import Foundation
import SwiftUI

@MainActor @Observable public final class HomeViewModel {
    public var recovery: RecoveryMetric?
    public var strain: StrainScore?
    public var sleep: SleepSession?
    public var heartRate = 0
    public var isLoading = false
    public var errorMessage: String?

    /// The strap's live status, for the battery readout.
    ///
    /// `nil` renders as a dash, and so does a device that is not connected — see the view. That is not
    /// caution for its own sake: `WhoopBLEManager` sets `batteryPercentage: 100` as a literal at
    /// discovery and `WhoopDevice`'s initialiser defaults it to `100` too, so a percentage read off a
    /// strap that is not currently connected is a constant this app wrote down, not a measurement it
    /// took.
    public var device: WhoopDevice?

    /// The sessions recorded on the selected day, earliest first. Empty when there are none.
    public var workouts: [WorkoutSession] = []

    /// The strap's step total for the selected day, or `nil` when it measured no motion for it.
    ///
    /// **Read from `StepRepository` and from nowhere else**, which is the change this property
    /// records: steps used to be the one value on Home that came from HealthKit — a daily *sum*, the
    /// single quantity that is not a reading the app could file under a day key, so it was read on
    /// demand through `HKStatisticsQuery(.cumulativeSum)` and never stored. That made it the one tile
    /// needing a permission this app could not verify was granted, and HealthKit never discloses
    /// read-permission status, so a denial, an empty day and a device with no source were all the same
    /// dash. The strap is now the producer: `TrackStepsUseCase` accumulates the count off the 100 Hz
    /// motion stream and writes one row per day, and this reads it.
    ///
    /// `nil` is the absence rule's ordinary case — a day the strap did not measure has **no row at
    /// all**, not a reserved zero — and the view renders it `—`. A *measured* day of no walking is a
    /// real `0` and renders as a figure; `StepCount.hasMeasurement` is the test that separates them,
    /// and it is the same test the writer gates on.
    public var steps: Int?

    /// The selected day's daytime activation — the aggregate and the windows behind it — or `nil`
    /// when its samples yielded no score.
    ///
    /// One property rather than two, because the tile's number and the chart's line have to come from
    /// one evaluation: a `stress` fetched separately from a `stressWindows` could describe a different
    /// day and nothing on screen would say so.
    public var stressDay: StressDay?

    /// The aggregate figure the tile shows, read through `stressDay`.
    ///
    /// Computed rather than stored. `@Observable` instruments the stored property this reads, so the
    /// tile still invalidates when the day loads, and there is no second field that can drift from the
    /// series it is the mean of.
    public var stress: StressScore? { stressDay?.score }

    /// The selected day's week — the seven days ending on it, with the rolling baselines the four
    /// metric panels print under their values.
    ///
    /// One property rather than the histories it is built from, for the same reason `stressDay` is
    /// one: the chart's seven points, the highlighted day's labels and the four baselines have to
    /// describe the same seven days, and separately-stored arrays could disagree about which day is
    /// which with nothing on screen to say so. The VO₂ max readings are read through from HealthKit
    /// rather than from a repository, and are folded into this same value so that a day cannot be one
    /// date in the chart and another under the panel beside it.
    public var metricWeek: MetricWeek?

    /// The day before the selected one, for the deltas shown under the tiles.
    ///
    /// Carried as whole entities rather than as pre-computed differences so the view can render each
    /// tile's delta by the same rule, including the case where only one of the two days has a value —
    /// which is a dash, not a change from zero.
    public var previousDaySteps: Int?
    public var previousDaySleep: SleepSession?

    private let recoveryRepository: any RecoveryRepository
    private let sleepRepository: any SleepRepository
    private let strainRepository: any StrainRepository
    private let workoutRepository: any WorkoutRepository
    private let userProfileRepository: any UserProfileRepository
    private let stepRepository: any StepRepository
    private let analyzeStress: AnalyzeStressUseCase
    private let manage: ManageBLEConnectionUseCase
    private let streamUseCase: StreamBiometricsUseCase
    private var task: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    public init(
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        workoutRepository: any WorkoutRepository,
        userProfileRepository: any UserProfileRepository,
        stepRepository: any StepRepository,
        analyzeStress: AnalyzeStressUseCase,
        manage: ManageBLEConnectionUseCase,
        streamUseCase: StreamBiometricsUseCase
    ) {
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
        self.workoutRepository = workoutRepository
        self.userProfileRepository = userProfileRepository
        self.stepRepository = stepRepository
        self.analyzeStress = analyzeStress
        self.manage = manage
        self.streamUseCase = streamUseCase
    }

    /// Deep sleep plus REM — the two stages WHOOP calls restorative. `nil` when the night is absent.
    ///
    /// An absent night is the normal case on a strap-less install: an unclassifiable night is never
    /// written, so `sleep` being `nil` is a real answer and not a gap to be defaulted.
    public var restorativeSleepSeconds: TimeInterval? {
        guard let sleep else { return nil }
        return sleep.deepSleepSeconds + sleep.remSleepSeconds
    }

    public var previousDayRestorativeSleepSeconds: TimeInterval? {
        guard let sleep = previousDaySleep else { return nil }
        return sleep.deepSleepSeconds + sleep.remSleepSeconds
    }

    /// Subscribes to the strap's status stream, for the battery readout.
    ///
    /// Separate from `load(for:)` because the day stepper calls that on every tap, and re-subscribing
    /// to a stream on each one would stack a new listener per tap for no new information. Idempotent
    /// so the view can call it from `.task` without tracking whether it already has.
    public func observeDevice() async {
        guard deviceTask == nil else { return }
        device = await manage.getCurrentDevice()
        deviceTask = Task { [weak self, manage] in
            for await item in manage.deviceStream {
                guard !Task.isCancelled else { return }
                self?.device = item
            }
        }
    }

    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }

        // Cleared first so a failure on one day does not outlive the day it describes.
        errorMessage = nil
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date

        do {
            // The VO₂ estimate's only non-per-day input, started with the other reads so it overlaps
            // them. Awaited below with `try?` on purpose: a profile this app cannot read is not an
            // error the user can act on — it costs one panel its anchor — so it must not raise the
            // screen's error banner over an otherwise fully-loaded day.
            async let profileRead = userProfileRepository.getUserProfile()

            async let r = recoveryRepository.getRecovery(for: date)
            async let s = strainRepository.getStrain(for: date)
            async let sl = sleepRepository.getSleepSession(for: date)
            async let slPrevious = sleepRepository.getSleepSession(for: previousDay)
            async let w = workoutRepository.getWorkouts(for: date)
            async let st = analyzeStress.executeDay(for: date)
            // One day each, read rather than computed. These sit with the other repository reads
            // rather than in the HealthKit pair's old position outside the `do`: a step row is stored
            // data, so a read that fails is a real error the same way a failed recovery read is, and
            // the screen's banner is the honest place for it. Outside, a throw would have had to be
            // swallowed with `try?` and the tile would then have drawn a dash — the same thing it draws
            // for a day the strap never measured, which is a state it can be in and this is not.
            async let stepsToday = stepRepository.getStepCount(for: date)
            async let stepsYesterday = stepRepository.getStepCount(for: previousDay)
            // Seven days ending on the selected one. The history window is inclusive at both ends and
            // runs from `endingOn - days`, so these come back holding up to eight days; `MetricWeek`
            // keeps the seven slots it was asked for and ignores the rest rather than being handed a
            // window it has to trust.
            async let strainHistory = strainRepository.getStrainHistory(
                days: MetricWeek.dayCount, endingOn: date)
            async let recoveryHistory = recoveryRepository.getRecoveryHistory(
                days: MetricWeek.dayCount, endingOn: date)
            async let sleepHistory = sleepRepository.getSleepHistory(
                days: MetricWeek.dayCount, endingOn: date)

            recovery = try await r
            strain = try await s
            sleep = try await sl
            previousDaySleep = try await slPrevious
            workouts = try await w
            stressDay = try await st
            // The absence gate, applied as the row becomes the tile's number. `hasMeasurement` is
            // `measuredSeconds > 0` — the same comparison `TrackStepsUseCase` makes before it writes,
            // which is the rule: a writer persists only when it produced a measurement, and the test
            // it uses is the one its readers use. A *measured* day of no walking is a real `0` and
            // passes through as one; a row holding no measured span draws a dash.
            steps = try await stepsToday.flatMap(Self.measuredSteps)
            previousDaySteps = try await stepsYesterday.flatMap(Self.measuredSteps)
            metricWeek = MetricWeek(
                endingOn: date,
                strain: try await strainHistory,
                recovery: try await recoveryHistory,
                sleep: try await sleepHistory,
                maxHeartRate: (try? await profileRead)?.maxHeartRate)
        } catch {
            errorMessage = error.localizedDescription
        }

        task?.cancel()
        task = Task { [weak self, streamUseCase] in
            for await sample in streamUseCase.execute() {
                guard !Task.isCancelled else { return }
                self?.heartRate = sample.heartRate
            }
        }
    }

    /// A stored step row as the tile reads it: the count, or `nil` when the row holds no measurement.
    ///
    /// Static and shared by the day and its predecessor so the two tiles cannot come to gate
    /// differently — the same reason `MetricChange` was lifted out of this screen. The gate itself is
    /// `StepCount.measuredStepCount`, forwarded rather than restated: the strain detail page's `STEPS`
    /// row reads the same rows, and two copies of the ternary are two chances to write it the other
    /// way round.
    private static func measuredSteps(_ count: StepCount) -> Int? {
        count.measuredStepCount
    }

    // MARK: - The month calendar

    /// The recovery tier per day of the month the calendar is displaying, keyed by `startOfDay`.
    ///
    /// **A day absent from this map is a day with no measurement**, which is what the calendar draws
    /// grey. It is not keyed on whether a row exists: a row left by an older build holds `score: 0`
    /// and reports `.red`, so a map built from row existence would paint an unworn night as a hard
    /// red day — the same fabrication the dash convention exists to prevent, in a calendar cell.
    /// `hasMeasurement` is the gate, as it is for every other reader.
    public private(set) var monthTiers: [Date: RecoveryMetric.RecoveryState] = [:]

    /// Whether ``loadMonth(containing:)`` is still reading. The calendar draws its grid either way:
    /// a month with nothing stored is not a month still loading, and testing `monthTiers.isEmpty`
    /// to decide would spin forever on a month the export never covered.
    public private(set) var isLoadingMonth = false

    /// Reads one displayed month for the calendar.
    ///
    /// Separate from `load(for:)` and deliberately not cached. `load(for:)` runs on every chevron
    /// tap and a month read riding along with it would fetch a month of rows to draw a bar showing
    /// one day; and a cache would be a second source of truth that an import — which writes hundreds
    /// of rows behind More → Settings — could silently invalidate while the calendar held a stale
    /// month. One indexed range query over a table of ~910 rows is cheaper than that risk.
    public func loadMonth(containing month: Date) async {
        let calendar = Calendar.current
        guard let grid = MonthGrid.make(for: month, calendar: calendar),
              let first = grid.days.first,
              let last = grid.days.last
        else {
            monthTiers = [:]
            return
        }

        isLoadingMonth = true
        defer { isLoadingMonth = false }

        do {
            // The window is inclusive at both ends and runs from `endingOn - days`, so the distance
            // between the month's own bounds is exactly the month. `days: 30` would reach into the
            // previous month on a 31-day one, and `days: dayCount` would pull in the 1st of the next
            // — which the grid, joining on day keys, would then be free to paint. Anchoring
            // `endingOn` on the month's last day rather than on `Date()` is what makes this read the
            // same one whatever day the app happens to run on.
            let span = calendar.dateComponents([.day], from: first, to: last).day ?? 0
            let rows = try await recoveryRepository.getRecoveryHistory(days: span, endingOn: last)
            monthTiers = rows.reduce(into: [:]) { tiers, row in
                guard row.hasMeasurement else { return }
                tiers[calendar.startOfDay(for: row.date)] = row.state
            }
        } catch {
            monthTiers = [:]
            errorMessage = error.localizedDescription
        }
    }
}
