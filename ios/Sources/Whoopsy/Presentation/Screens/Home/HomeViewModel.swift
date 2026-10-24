import Foundation
import SwiftUI

@MainActor @Observable public final class HomeViewModel {
    public var recovery: RecoveryMetric?
    public var strain: StrainScore?
    public var sleep: SleepSession?

    /// The composite sleep score Home's ring prints, or `nil` when the night cannot produce two terms.
    ///
    /// Read from the same `MetricWeek` the tiles and the week chart are built from — the week ends on
    /// the selected day, so `days.last` is the anchor — which is what keeps this ring and the sleep
    /// page's ring on one figure. It is not `sleep.sleepSufficiencyPercentage`: that ratio is the
    /// `HOURS VS. NEEDED` row and the Recovery input.
    public private(set) var sleepScore: Int?

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

    /// Drops one session from the list Home is drawing, after it has been deleted from storage.
    ///
    /// **A local removal rather than a reload, and that is the design rather than a shortcut.** Home
    /// learns of a deletion from `ActivityDetailView`'s `onDeleted`, which fires on the way out of a
    /// pushed page — and whether a `.task` re-fires when a destination pops is undocumented behaviour
    /// that differs by OS version, so nothing may depend on it. `load(for:)` is also nine reads with a
    /// `streamUseCase` re-subscription, and it is not reentrant; calling it here would race whatever else
    /// is loading.
    ///
    /// It is exact because **no other figure on Home is built from a workout**: `metricWeek` comes from
    /// the strain, recovery and sleep histories plus the profile's maximal heart rate, `monthTiers` is
    /// recovery-only, and the steps and stress tiles read their own tables. So there is nothing else to
    /// invalidate, and the removal converges whether or not the day is ever re-read.
    ///
    /// Removing an id that is not in the list is a no-op, not a fault: it can only mean the list was
    /// already reloaded without it.
    public func removeWorkout(_ id: UUID) {
        workouts.removeAll { $0.id == id }
    }

    /// Replaces one session in the list Home is drawing, after the activity page has edited it.
    ///
    /// **It is not a mirror of `removeWorkout(_:)`, and the difference is the re-sort.** That method
    /// drops a row and the order of what is left cannot move; this one can change the value the list is
    /// ordered by, because a trim moves `startedAt` and Home's `ACTIVITIES` card draws the list in the
    /// order it is stored. `getWorkoutHistory(days:endingOn:)` documents itself as returning *"earliest
    /// first"*, so a replacement that kept its old slot would leave the card in an order no read of the
    /// day would produce — and it would stay wrong until the day was reloaded. Re-sorting here is what
    /// keeps the local list and a fresh read the same list.
    ///
    /// **There is a drop case, and the list is now the covering read's rather than the day key's.**
    /// `ActivityEditDraft` clamps a session's *start* to `original.startedAt.endOfDay`, so it cannot
    /// leave the day it was on — but that clamp constrains only one of the sheet's two handles, and the
    /// *end* handle can be dragged down to `start + minimumDuration` (60 s). Shortening a three-day fast
    /// that way removes it from days 2 and 3 while Home, showing one of them, would otherwise go on
    /// drawing the row — and because that day is now **after** `endedAt`, `elapsedSeconds(byEndOf:)`
    /// clamps to the whole duration and the pill shows the fast's *overall* zone. That is exactly the
    /// wrong answer this screen's day-scoped pill exists to remove, so the drop is not an edge case to
    /// leave: a session the day no longer covers is filtered out here, and a session it does not yet
    /// cover is not appended either.
    ///
    /// Replacing an id that is in the list keeps its slot's identity, and the list is not otherwise
    /// re-read, for `removeWorkout(_:)`'s reason: no other figure on Home is built from a workout.
    public func updateWorkout(_ workout: WorkoutSession, on day: Date) {
        if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[index] = workout
        } else if workout.covers(day) {
            workouts.append(workout)
        }
        workouts.removeAll { !$0.covers(day) }
        workouts.sort { $0.startedAt < $1.startedAt }
    }

    /// Writes one hand-added session for `day` and folds it into the list Home is drawing, reporting
    /// whether the write succeeded so the page can dismiss its sheet only when there is something to
    /// dismiss.
    ///
    /// **The merge is `updateWorkout(_:on:)` rather than an append**, for its own reasons and for one
    /// of this feature's: a new row is inserted-or-appended by that method and the list is re-sorted,
    /// so the card's order matches what a fresh read of the day would return — and if the write is a
    /// second presentation of the same draft it replaces rather than duplicates, because the draft's id
    /// is the row's primary key and `save` is INSERT-or-UPDATE by it.
    ///
    /// **A failed write leaves the list untouched and puts the failure on `errorMessage`**, which is
    /// this screen's banner, so the sheet stays up with the entry still in it — `saveReceptiveInactivity`
    /// records the same contract for the sheet one row away in the menu.
    @discardableResult
    public func saveActivity(_ activity: WorkoutSession, on day: Date) async -> Bool {
        do {
            try await workoutRepository.save(activity)
            updateWorkout(activity, on: day)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

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

    /// The receptive inactivities filed on the selected day, in the order the store returns them.
    ///
    /// **A second list beside `workouts` rather than a filtered view of one**, because the two are
    /// different tables: a receptive inactivity is not a session with the instants missing, it is a row
    /// in `receptive_inactivities` that has no instants to miss. Every rule this screen applies to a
    /// workout — the covering read, the fast pill, the strain figure — would have to be guarded away
    /// here, which is the shape this type exists to avoid.
    ///
    /// Empty on a day with none, which is the ordinary case rather than an absence to draw: the card
    /// says so in words.
    public var receptiveInactivities: [ReceptiveInactivity] = []

    /// Drops one entry from the list Home is drawing, after it has been deleted from storage.
    ///
    /// `removeWorkout(_:)`'s method, for its reasons: the removal is local because the page that
    /// reported it is on its way out and whether a `.task` re-fires on a pop is undocumented, and it is
    /// exact because no other figure on Home is built from a receptive inactivity. Removing an id that is
    /// not in the list is a no-op rather than a fault.
    public func removeReceptiveInactivity(_ id: UUID) {
        receptiveInactivities.removeAll { $0.id == id }
    }

    /// Writes one entry for `day` and folds the result into the list Home is drawing, reporting whether
    /// the write succeeded so the page can dismiss its sheet only when there is something to dismiss.
    ///
    /// **The re-sort is the whole of the merge, and it is `updateWorkout(_:on:)`'s reason.** A saved
    /// entry can move the value the list is ordered by — an edit adding or clearing a time — so an
    /// insertion kept at the end of the array would leave the card in an order no read of the day would
    /// produce. It sorts by `ReceptiveInactivity.isOrderedBefore`, which is the Domain statement of the
    /// read's own `ORDER BY`, so the local list and a fresh read of the same day are one list.
    ///
    /// A failed write leaves the list untouched and puts the failure on `errorMessage`, which is the
    /// screen's banner — the sheet stays up with the user's edit still in it.
    @discardableResult
    public func saveReceptiveInactivity(_ activity: ReceptiveInactivity) async -> Bool {
        do {
            try await receptiveInactivityRepository.save(activity)
            if let index = receptiveInactivities.firstIndex(where: { $0.id == activity.id }) {
                receptiveInactivities[index] = activity
            } else {
                receptiveInactivities.append(activity)
            }
            receptiveInactivities.sort(by: ReceptiveInactivity.isOrderedBefore)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes one entry from storage and, on a real removal, from the list Home is drawing.
    ///
    /// **The local drop happens only when the store reports it removed a row.** `delete(_:)` answers
    /// from the affected-row count rather than from "did it throw", so an id that matched nothing comes
    /// back `false` — and a page that dropped the row anyway would stop drawing an entry that is still
    /// on disk, which is the one failure a delete path must not have.
    @discardableResult
    public func deleteReceptiveInactivity(_ id: UUID) async -> Bool {
        do {
            guard try await receptiveInactivityRepository.delete(id) else { return false }
            removeReceptiveInactivity(id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

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
    private let receptiveInactivityRepository: any ReceptiveInactivityRepository
    private let userProfileRepository: any UserProfileRepository
    private let stepRepository: any StepRepository
    private let analyzeStress: AnalyzeStressUseCase
    private let manage: ManageBLEConnectionUseCase
    private let streamUseCase: StreamBiometricsUseCase

    /// The day's step writer, read for its one output: the totals it stores as the strap walks.
    ///
    /// **Handed in rather than reached for, and required rather than defaulted**, so a screen cannot
    /// ship without it and quietly go back to a tile that only moves when the day changes — the exact
    /// "saved row is not a drawn one" failure this subscription exists to close.
    private let trackSteps: TrackStepsUseCase

    /// The day's strain writer, read for the same one output `trackSteps` provides: rows it saves as
    /// the day is scored.
    ///
    /// Handed in and required for `trackSteps`' reason — without it Home's ring would hold whatever
    /// `strains` held when the day was tapped, and the ring is the figure the whole model exists to
    /// move.
    private let refreshStrain: RefreshStrainUseCase

    private var task: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var stepsTask: Task<Void, Never>?
    private var strainTask: Task<Void, Never>?

    /// The day `load(for:)` last read, so a live write can be matched against the day on screen.
    private var loadedDay: Date?

    /// How many live writes for `loadedDay` have been folded in since the last `load`, which is what
    /// lets the load refuse to overwrite one it did not see.
    private var liveStepWrites = 0

    /// The same counter for the day's strain, kept separate from the step one because the two writers
    /// flush on different schedules and one must not be able to excuse the other's stale read.
    private var liveStrainWrites = 0

    public init(
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        workoutRepository: any WorkoutRepository,
        receptiveInactivityRepository: any ReceptiveInactivityRepository,
        userProfileRepository: any UserProfileRepository,
        stepRepository: any StepRepository,
        analyzeStress: AnalyzeStressUseCase,
        manage: ManageBLEConnectionUseCase,
        streamUseCase: StreamBiometricsUseCase,
        trackSteps: TrackStepsUseCase,
        refreshStrain: RefreshStrainUseCase
    ) {
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
        self.workoutRepository = workoutRepository
        self.receptiveInactivityRepository = receptiveInactivityRepository
        self.userProfileRepository = userProfileRepository
        self.stepRepository = stepRepository
        self.analyzeStress = analyzeStress
        self.manage = manage
        self.trackSteps = trackSteps
        self.refreshStrain = refreshStrain
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

    /// Follows the day's step total as the strap writes it.
    ///
    /// **This is the tile's only live source, and without it the tile never populates in the ordinary
    /// case.** `load(for:)` reads `stepCounts` once per day selection, and `TrackStepsUseCase` stores a
    /// new total every second of motion — so Home, which is open before the strap has produced its
    /// first batch, holds the `—` it read at launch for as long as the screen stays up. Switching day
    /// and back would show the figure, which is precisely what makes the stale screen read as "steps
    /// are never recorded".
    ///
    /// Idempotent, on `observeDevice()`'s rule: the view calls it from `.task` without tracking whether
    /// the subscription exists.
    public func observeSteps() {
        guard stepsTask == nil else { return }
        stepsTask = Task { [weak self, trackSteps] in
            for await written in trackSteps.stepUpdates {
                guard !Task.isCancelled else { return }
                self?.applyLiveStepCount(written)
            }
        }
    }

    /// Folds one written total into the tile, if it belongs to the day on screen.
    ///
    /// A write for any other day is dropped rather than queued: the screen draws one day, and a total
    /// from yesterday is not a stale version of today's figure. `liveStepWrites` is bumped here and
    /// only here, so it counts exactly the writes `load(for:)` could otherwise undo.
    private func applyLiveStepCount(_ written: StepCount) {
        guard let loadedDay, written.date == loadedDay else { return }
        liveStepWrites += 1
        steps = written.measuredStepCount
    }

    /// Follows the day's Strain as `RefreshStrainUseCase` writes it.
    ///
    /// `observeSteps()`'s sibling and for its reason: `load(for:)` reads `strains` once per day
    /// selection, and the day's score is rewritten as samples arrive — so without this the ring shows
    /// whatever it read when the day was tapped, which on a morning open is `—` and stays `—`.
    ///
    /// Idempotent, on `observeDevice()`'s rule.
    public func observeStrain() {
        guard strainTask == nil else { return }
        let stream = refreshStrain.strainUpdates
        strainTask = Task { [weak self] in
            for await written in stream {
                guard !Task.isCancelled else { return }
                self?.applyLiveStrain(written)
            }
        }
    }

    /// Folds one written row into the ring, if it belongs to the day on screen.
    ///
    /// A row for another day is dropped rather than queued: the screen draws one day, and yesterday's
    /// score is not a stale version of today's. `liveStrainWrites` is bumped here and only here, so it
    /// counts exactly the writes `load(for:)` could otherwise undo.
    private func applyLiveStrain(_ written: StrainScore) {
        guard let loadedDay, written.date.startOfDay == loadedDay else { return }
        liveStrainWrites += 1
        strain = written
    }

    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }

        // Cleared first so a failure on one day does not outlive the day it describes.
        errorMessage = nil
        sleepScore = nil
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date

        // The day is recorded **before** the reads, so a step total written while they are in flight
        // is matched against the day being loaded rather than the one being left. `stepWritesBefore`
        // is the other half: a write that lands during the load is newer than the read that follows
        // it, and assigning the read would put the dash back under a figure the user just watched
        // arrive.
        let day = date.startOfDay
        loadedDay = day
        let stepWritesBefore = liveStepWrites
        let strainWritesBefore = liveStrainWrites

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
            // The **covering** read, not the day-key one: a fast that was underway on this day is a
            // thing that happened on this day, so an 86-hour fast draws a row on all five of its days
            // rather than on its start day alone. Every other reader of `workouts` — the strain page's
            // zone rows, the zone aggregates, the export's day skip — keeps asking `getWorkouts(for:)`,
            // and `WorkoutRepository` documents why the two must not be merged.
            async let w = workoutRepository.getWorkouts(covering: date)
            // The **day-keyed** read, and the contrast with the line above is the two tables' shapes
            // rather than an inconsistency: a receptive inactivity has no end, so there is no overlap for
            // a covering read to express and no `covering:` sibling on its repository to call. One entry
            // is on one day.
            async let ra = receptiveInactivityRepository.getReceptiveInactivities(for: date)
            async let st = analyzeStress.executeDay(for: date)
            // One day each, read rather than computed. These sit with the other repository reads
            // rather than in the HealthKit pair's old position outside the `do`: a step row is stored
            // data, so a read that fails is a real error the same way a failed recovery read is, and
            // the screen's banner is the honest place for it. Outside, a throw would have had to be
            // swallowed with `try?` and the tile would then have drawn a dash — the same thing it draws
            // for a day the strap never measured, which is a state it can be in and this is not.
            async let stepsToday = stepRepository.getStepCount(for: date)
            async let stepsYesterday = stepRepository.getStepCount(for: previousDay)
            // Seven days ending on the selected one, for the strain and recovery slots. The sleep
            // read is wider — `MetricWeek.sleepScoreLookbackDays` — because each slot's composite
            // needs four prior nights for its consistency term, and the oldest of the seven slots
            // needs records from before the week. `MetricWeek` keeps the seven slots it was asked
            // for and ignores the rest rather than being handed a window it has to trust.
            async let strainHistory = strainRepository.getStrainHistory(
                days: MetricWeek.dayCount, endingOn: date)
            async let recoveryHistory = recoveryRepository.getRecoveryHistory(
                days: MetricWeek.dayCount, endingOn: date)
            async let sleepHistory = sleepRepository.getSleepHistory(
                days: MetricWeek.sleepScoreLookbackDays, endingOn: date)

            recovery = try await r
            let readStrain = try await s
            // **The same yield the step read makes, one writer over.** `s` was started before the
            // other reads and awaited here, so a score saved in that window is newer than this answer
            // and has already been folded in by `applyLiveStrain`. Assigning would put the older
            // figure back under a ring the user just watched move.
            if liveStrainWrites == strainWritesBefore, loadedDay == day { strain = readStrain }
            sleep = try await sl
            previousDaySleep = try await slPrevious
            workouts = try await w
            receptiveInactivities = try await ra
            stressDay = try await st
            // The absence gate, applied as the row becomes the tile's number. `hasMeasurement` is
            // `measuredSeconds > 0` — the same comparison `TrackStepsUseCase` makes before it writes,
            // which is the rule: a writer persists only when it produced a measurement, and the test
            // it uses is the one its readers use. A *measured* day of no walking is a real `0` and
            // passes through as one; a row holding no measured span draws a dash.
            let readSteps = try await stepsToday.flatMap(Self.measuredSteps)
            // **The read yields to a live write it did not see.** `stepsToday` was started before the
            // other reads and awaited after them, so a total stored in that window is newer than this
            // answer — and it has already been folded into the tile by `applyLiveStepCount`. Assigning
            // here would overwrite the newer figure with the older one, which is the same defect from
            // the opposite direction. The day is re-checked because a second `load` may have moved on
            // while this one was awaiting.
            if liveStepWrites == stepWritesBefore, loadedDay == day { steps = readSteps }
            previousDaySteps = try await stepsYesterday.flatMap(Self.measuredSteps)
            let profile = try? await profileRead
            metricWeek = MetricWeek(
                endingOn: date,
                strain: try await strainHistory,
                recovery: try await recoveryHistory,
                sleep: try await sleepHistory,
                maxHeartRate: profile?.maxHeartRate,
                age: profile?.age)
            sleepScore = metricWeek?.days.last?.sleepScore
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
                // A measured-but-unscored day is not a tier: its reserved `0` is "no score", and
                // painting it red would state a result the app refused to produce.
                guard row.hasScore else { return }
                tiers[calendar.startOfDay(for: row.date)] = row.state
            }
        } catch {
            monthTiers = [:]
            errorMessage = error.localizedDescription
        }
    }
}
