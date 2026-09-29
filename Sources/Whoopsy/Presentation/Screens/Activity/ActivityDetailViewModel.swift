import Foundation
import SwiftUI

/// One recorded activity's own page: its strain, its steps, its heart-rate trace, its duration against
/// what is typical for that activity, and its five heart-rate zone rows.
///
/// ## It loads its own comparison history, and it is handed the session
///
/// The session comes in as a `let` on the view — a pushed page takes its subject from whoever pushed
/// it, on the rule `RecoveryDetailView`/`SleepDetailView`/`StrainDetailView` already follow. What the
/// view model fetches is the *history*, which the pushing screen has no reason to hold: the ten prior
/// sessions of the same activity, out of `WorkoutRepository.getWorkoutHistory(days:endingOn:)`.
///
/// **The read is bounded at both ends and anchored on the session's own day.** That overload exists
/// because a window anchored on the present would run on past a session the user opened from a month
/// ago, and would then compare that session against sessions that happened *after* it. The window is
/// taken around `startedAt` rather than around `Date()`, which is the difference that matters here.
///
/// ## It computes nothing, and its two writes change no measurement
///
/// There is no calculate use case anywhere in this type, and there must not be one. This page reads a
/// session that is already stored; `CalculateStrainUseCase` recomputes from `biometric_samples` and
/// saves by primary key, so pointing it at a stored session would be an overwrite rather than a
/// refresh — and would come back empty on every imported session anyway, since an imported day has no
/// samples by construction. `StrainViewModel`'s own warning about workouts having no recompute branch
/// applies here in full.
///
/// The two things it can do to storage are `delete()`, which the overflow menu calls, and `save(_:)`,
/// which the `EDIT ACTIVITY` sheet calls. **Neither writes a measurement and neither invents a
/// number**: a delete removes a row the user asked to remove, and an edit relabels one and moves its
/// two boundaries inside the span it already had. `ActivityEditDraft` is where the second of those is
/// bounded, and its clamp is the reason this type can offer a write at all without becoming a place a
/// calculate use case may be wired into — nothing here produces a strain, a heart rate or a zone
/// share, and the edit's `applying(to:)` hands every one of those back exactly as it found it.
///
/// ## Everything the page draws is a value on this type, not a rule in a `body`
///
/// The zone rows, the duration bar's layout and the heart-rate series are all resolved here — or in a
/// named type this holds — because the runner that tests this app has no renderer. See `ActivityZoneRow`,
/// `ActivityDurationBarLayout` and `ActivityHeartRateSeries`.
@MainActor @Observable public final class ActivityDetailViewModel {

    /// The session this page is about.
    ///
    /// **`private(set)` rather than a `let`, and still not re-pointable at another session.** The only
    /// thing that may write it is `save(_:)`, and what that writes is the same session — same `id`, so
    /// the page's subject cannot move — carrying the edited name and times. A `var` with a public
    /// setter would be exactly the hazard the original comment named: a re-render behind the push, or
    /// any caller at all, could hand this page a different activity than the one it was pushed for.
    public private(set) var session: WorkoutSession

    /// The fast still running, when this page is the *live* one rather than a stored row's.
    ///
    /// **A second field rather than a flag, because the page needs the instant off it.** It carries the
    /// fast's real `startedAt`, which the projection below cannot: `projectedSession(now:)` was built
    /// once at the tap with `endedAt == now`, so the projection's own `durationSeconds` froze at the
    /// moment the page opened.
    ///
    /// **`nil` for every stored session, fasts included** — an ended fast is a row, and its page is the
    /// retrospective one. That distinction is what the tense, the menu and the ticking figure are all
    /// read from.
    public let liveFast: ActiveFast?

    /// Whether this page is a fast that is still running.
    ///
    /// ## It is this flag and never `ActivityFigure.isInProgress`, and that is not a style choice
    ///
    /// A projected session is built with `endedAt: now`, so `isInProgress`'s `now < endedAt` is **false
    /// for a live fast** — the predicate reports a running fast as finished. Deriving the mode from it
    /// would draw the retrospective arm on the live page: no `END FAST`, past-tense guidance, and the
    /// fast's own end clock where the row should read `ACTIVE`.
    ///
    /// `ActivityFigure.isInProgress` is still the right predicate for the questions it was written for —
    /// a *stored* row, where the two instants are real. This page's subject is the one session it is not
    /// correct for, so the page states its own state instead of inferring it.
    public var isLiveFast: Bool { liveFast != nil }

    /// Whether the history read is still in flight. The page draws its figures either way — the
    /// session's own strain, steps and zones need no history — so this gates the *comparisons* only,
    /// and nothing on the page is withheld on it.
    public var isLoading = false

    /// The comparison summary, or the empty one before the read lands.
    ///
    /// The default is a `Summary` taken over no sessions rather than an optional, so every comparison
    /// on the page is withheld by the same condition that withholds it below the floor — there is no
    /// second "loading" state for a badge to get wrong. `ActivityBaseline.Summary`'s own initialiser
    /// is what makes the empty case expressible without an invented number.
    public private(set) var baseline = ActivityBaseline.Summary(
        sessionCount: 0, typicalDuration: nil, meanStrain: nil, meanSteps: nil,
        stepSessionCount: 0, strainSessionCount: 0)

    /// How many prior sessions of this activity the comparison was taken over, `0` below the floor.
    /// Read by the card so the basis is named on the screen rather than implied.
    public var comparisonSessionCount: Int { baseline.sessionCount }

    /// The five zone rows, highest band first, or `[]` when the profile cannot produce a zone table.
    ///
    /// It holds `ActivityZoneRow`s whose `percent` is itself `nil` for a session with no block, so an
    /// empty array and five dashed rows are different answers: the first is a page that cannot name a
    /// band, the second is a session WHOOP did not publish a block for.
    public private(set) var zoneRows: [ActivityZoneRow] = []

    /// The heart-rate series, or `nil` when the session has no samples to plot.
    ///
    /// **`nil` on every session this app can currently show** — see `ActivityHeartRateSeries`. The page
    /// draws `No Data` there, which is the correct output rather than a defect.
    public private(set) var heartRateSeries: ActivityHeartRateSeries?

    /// What a fast's page prints in place of the strain/steps pair: the nights it covered, their mean
    /// Recovery score, and their readings against the user's own baseline.
    ///
    /// **`nil` for every session that is not a fast, and `nil` for a fast that closed over no measured
    /// night.** The two are the same answer on purpose: `ActivityFigure.isFast(session)` is the layout
    /// gate and this is the figure, so a page that fails the gate never pays for the read and a page
    /// that passes it but has nothing to show draws the absence line rather than an empty chart. See
    /// `FastingRecovery`.
    public private(set) var fastingRecovery: FastingRecoverySummary?

    public var errorMessage: String?

    /// Which map the route card draws with, resolved once per load.
    ///
    /// **Resolved here rather than inside the view's `body`**, because the drawing must not be able to
    /// disagree with itself between two evaluations of the same page — a `body` that asked the tile
    /// store on every pass could draw the MapKit card and the offline one in the same frame's two
    /// halves. `RouteMapRenderer.resolve` is the rule and it is a value the runner can assert; this
    /// property is only where its answer is kept.
    ///
    /// `.mapKit` until `load()` runs, which is the honest default rather than an optimistic one: the
    /// MapKit card needs nothing from storage and is what every build without the SDK draws forever.
    public private(set) var routeRenderer: RouteMapRenderer = .mapKit

    /// The offline map, for the card. Held rather than reached for through the environment, so the
    /// page's renderer and the object that draws it are one dependency and cannot come from two places.
    public let offlineMaps: any OfflineMapRendering

    private let workoutRepository: any WorkoutRepository
    private let userProfileRepository: any UserProfileRepository
    private let biometricRepository: any BiometricRepository
    private let recoveryRepository: any RecoveryRepository

    /// How far back the history read reaches.
    ///
    /// **Not `ActivityBaseline.sessionWindowCount`**, and the difference is the whole reason this is a
    /// separate number: the window is ten *sessions of this activity*, and a read of ten *days* would
    /// find nothing at all for an activity done twice a month. Measured over the bundled export, a
    /// `Running` session's tenth prior needs a read far wider than ten days. A year is the compromise:
    /// it covers the export's own span for every activity, and the cap of ten sessions is applied to
    /// what comes back, so a wide read costs a larger array and changes no answer.
    ///
    /// It is deliberately **not** symmetric around the session. Looking that far forward would reach
    /// into sessions that had not happened yet, which `ActivityBaseline.window` filters out anyway —
    /// so the read asks for a year back and stops at the session's own day.
    public static let historyLookbackDays = 365

    /// **`liveFast` is defaulted, and it is the one parameter here that is.** Every other one is a
    /// dependency a page cannot work without; this is a fact about *which* page it is, and every
    /// existing call site — Home's stored rows, `WhoopsyPreviews` and §19's fixtures — is a stored
    /// session. A required parameter would be three call sites taught a third defaulted argument that
    /// is `nil` at all of them.
    ///
    /// **`offlineMaps` is required, for the reason the other four are.** A defaulted one would let a
    /// page ship that resolves every route to the MapKit card with nothing anywhere saying why — the
    /// argument `DIContainer.liveSessionUseCase`'s own `offlineMaps` parameter records. It is placed
    /// before `liveFast` so the defaulted argument stays last.
    public init(
        session: WorkoutSession,
        workoutRepository: any WorkoutRepository,
        userProfileRepository: any UserProfileRepository,
        biometricRepository: any BiometricRepository,
        recoveryRepository: any RecoveryRepository,
        offlineMaps: any OfflineMapRendering,
        liveFast: ActiveFast? = nil
    ) {
        self.session = session
        self.workoutRepository = workoutRepository
        self.userProfileRepository = userProfileRepository
        self.biometricRepository = biometricRepository
        self.recoveryRepository = recoveryRepository
        self.offlineMaps = offlineMaps
        self.liveFast = liveFast
    }

    /// Loads the comparison history and the session's own trace.
    ///
    /// The zone rows are resolved **before** any of that, because they need no history: the profile's
    /// zone table and the session's own stored percentages are both already available, so a page whose
    /// history read is slow still draws five real rows. The trace is read over the session's own window
    /// and is independent of the history for the same reason.
    public func load() async {
        isLoading = true
        defer { isLoading = false }

        await loadZoneRows()
        await loadHeartRateSeries()
        await loadFastingRecovery()
        loadRouteRenderer()

        do {
            let history = try await workoutRepository.getWorkoutHistory(
                days: Self.historyLookbackDays, endingOn: session.startedAt)
            // `window` excludes the session itself by identity and filters to its own activity name and
            // to instants strictly before it — one definition, in the domain, not repeated here.
            let window = ActivityBaseline.window(for: session, in: history)
            baseline = ActivityBaseline.summary(for: session, priorSessions: window)
        } catch {
            // A failed read leaves the empty summary in place, so the page draws its own figures with
            // every comparison withheld rather than an error where a badge would be. The session is
            // already stored; the comparison is the only thing lost.
            errorMessage = "Could not load this activity's history."
        }
    }

    /// Removes the session this page is about, and reports whether it actually went.
    ///
    /// **The `Bool` is the repository's, not this method's guess at it.** A delete that matched no row —
    /// an imported session whose id no longer round-trips, a row a second tap already removed — must
    /// not read as success, because the caller dismisses the page on that signal and Home drops the row
    /// from its list: the user would be returned to a Home that no longer shows the session, and the
    /// row would be back at the next load. `WorkoutRepository.delete(_:)` carries that argument in full.
    ///
    /// A failure is reported through `errorMessage`, like every other failed read here. Note that
    /// **`errorMessage` is drawn by no view in this app** — this page included — so the visible
    /// consequence of a *failed* delete is that the menu closes and the page stays. That is the honest
    /// outcome (nothing was removed, so nothing dismisses) and it is silent about why; the same is true
    /// of the five other view models that set this field, and of a failed `save(_:)` below. Fixing that
    /// is a wider change than this one.
    public func delete() async -> Bool {
        do {
            let removed = try await workoutRepository.delete(session.id)
            if !removed {
                // Not an error — the row is simply not there any more — but it is not a success either,
                // so the page must not dismiss on it.
                errorMessage = "This activity is no longer stored."
            }
            return removed
        } catch {
            errorMessage = "Could not delete this activity."
            return false
        }
    }

    /// Writes an edit, and reports whether it went.
    ///
    /// **The `Bool` is the same contract `delete()` has, for the same reason**: the caller dismisses
    /// the sheet on `true` and leaves it up on `false`, so a write that threw must not read as success.
    /// Nothing is written to `session` until the repository has taken the row — a page that showed the
    /// new times over a failed write would be displaying an edit that is not on disk.
    ///
    /// ## It re-runs the whole load, and that is deliberate
    ///
    /// Four separate things on this page are derived from `session`, and a trim moves three of them.
    /// `zoneRows` is the one that is easy to spot: each row's time is `share × durationSeconds`, so a
    /// shortened span rescales all five printed durations while the percentages stay WHOOP's, and a
    /// save that swapped only `session` would leave `DURATION` printing the new span over five rows
    /// still scaled by the old one — two figures for one span, which is the disagreement
    /// `zoneSeconds(_:)` exists to make impossible. `heartRateSeries` is read over
    /// `startedAt…endedAt` and would otherwise keep plotting a window the session no longer has.
    ///
    /// **The comparison window is the third, and it is the one that would be missed.** `baseline` is
    /// read with `endingOn: session.startedAt` and `ActivityBaseline.window(for:in:)` filters to
    /// instants strictly before it, so moving the start moves the boundary that decides which prior
    /// sessions are in the comparison — a session at the old boundary could join or drop out. It is
    /// re-derived by the same call rather than by a third hand-written step here, because a `load()`
    /// that gains a fourth derived value would otherwise have to be remembered in two places.
    ///
    /// **The fourth is `fastingRecovery`, and it is the one that moves most.** Both rules that decide
    /// which nights a fast covered are built from `startedAt` and `endedAt` — the enclosure boundary is
    /// `startedAt.startOfDay` and the baseline window is taken strictly before `startedAt` — so a trim
    /// of either handle can add a night to the mean, drop one from it, and move the baseline it is
    /// measured against. `FastingRecovery.summary(for:history:)` is re-run by the same call rather than
    /// by a fourth hand-written step, and the read it needs is the 180-day one below.
    ///
    /// The identity is what makes this safe to re-read: `applying(to:)` keeps the original `id`, so the
    /// window's own exclusion of the session from its own baseline still excludes this one.
    public func save(_ draft: ActivityEditDraft) async -> Bool {
        let edited = draft.applying(to: session)
        do {
            try await workoutRepository.save(edited)
        } catch {
            errorMessage = "Could not save this activity."
            return false
        }
        session = edited
        await load()
        return true
    }

    /// The profile's five bands, paired with the session's own stored shares.
    private func loadZoneRows() async {
        do {
            let profile = try await userProfileRepository.getUserProfile()
            let zones = StrainAccumulatorMath.computeZones(
                maxHR: profile.maxHeartRate, restHR: profile.restingHeartRate)
            zoneRows = ActivityZoneRow.rows(for: session, zones: zones)
        } catch {
            // No table, no rows: the page draws the zone block's absence rather than five invented
            // bands. `rows(for:zones:)` answers `[]` for a table that is not five long, so this and
            // that guard produce the same screen.
            zoneRows = []
        }
    }

    /// The session's heart rate over its own window.
    private func loadHeartRateSeries() async {
        do {
            let samples = try await biometricRepository.getSamples(
                from: session.startedAt, to: session.endedAt)
            heartRateSeries = ActivityHeartRateSeries(
                samples: samples, start: session.startedAt, end: session.endedAt)
        } catch {
            // `nil` is the same answer a session with no samples gives, and the page draws `No Data`
            // for both — a read that failed and a read that found nothing are the same thing to a
            // reader, which is why `HoursOfSleepChartSeries` collapses them too.
            heartRateSeries = nil
        }
    }

    /// What a fast's page prints, read only for a session that draws the fasting layout.
    ///
    /// ## The gate comes first, and it is what keeps the read off every other page
    ///
    /// `ActivityFigure.isFast(session)` is the same call the *view* makes to choose its layout, and
    /// this method reads nothing until it passes. That is not an optimisation: the read is
    /// `baselineWindowLookbackDays` (180) of recovery rows, and paying it on every basketball session's
    /// page would be a cost with no reader.
    ///
    /// ## The window is 180 days, and it is anchored on the fast rather than on today
    ///
    /// `RecoveryScoring.baselineWindow` takes the last 30 days *that have rows*, so a read of 30 days
    /// would find rather fewer than thirty — and a fast in a sparse stretch of history would come back
    /// with a baseline built from a handful of days, or none. The 180 is
    /// `RecoveryScoring.baselineWindowLookbackDays`, the same number every other baseline caller reads
    /// over, so this page cannot come to disagree with the Recovery screen about how far back a
    /// baseline reaches.
    ///
    /// **`endingOn:` is `session.endedAt` and not `Date()`**, which is this read's one real trap. The
    /// page opens on a session that may be months old — every one of the bundled fasts is — and a
    /// window anchored on the present would reach back 180 days from *today* and return nothing from
    /// 2024 at all, so an 86-hour fast that really covered four nights would draw the absence line for
    /// a reason that has nothing to do with the fast. This is the same rule the comparison history
    /// above follows when it anchors on `session.startedAt`.
    ///
    /// The span is widened by the fast's own length, because the read has to straddle two anchors: the
    /// **baseline** is taken 180 days before `startedAt`, while the latest *enclosed night* is
    /// `endedAt.startOfDay`. Ending the read on `endedAt` and reaching back only 180 days would clip the
    /// oldest days off a multi-day fast's own baseline — the read would be bounded at
    /// `endedAt − 180` where the window wants to see `startedAt − 180`.
    ///
    /// The history is passed through **unfiltered and unwindowed**: `FastingRecovery.summary` applies
    /// the enclosure rule and the baseline window itself, so there is one definition of each and this
    /// method holds neither.
    private func loadFastingRecovery() async {
        guard ActivityFigure.isFast(session) else {
            fastingRecovery = nil
            return
        }

        let fastSpanDays = Int((session.durationSeconds / 86_400).rounded(.up))
        let spanDays = RecoveryScoring.baselineWindowLookbackDays + fastSpanDays

        do {
            let history = try await recoveryRepository.getRecoveryHistory(
                days: spanDays, endingOn: session.endedAt)
            fastingRecovery = FastingRecovery.summary(for: session, history: history)
        } catch {
            // `nil` is the same answer a fast that enclosed no night gives, and the page draws one line
            // for both. A read that failed and a fast that covered nothing are the same thing to a
            // reader, which is why the chart's slot has one absence state and not two.
            fastingRecovery = nil
        }
    }

    // MARK: - What the page draws, resolved

    /// The session's length, banded against what is typical for this activity.
    ///
    /// `nil` when the window held too few sessions to produce a band — and the bar is then absent
    /// rather than drawn on an invented scale. See `ActivityDurationBarLayout.make`.
    public var durationLayout: ActivityDurationBarLayout? {
        ActivityDurationBarLayout.make(
            durationSeconds: session.durationSeconds, typical: baseline.typicalDuration)
    }

    /// The strain badge: the session's strain against the window's mean.
    ///
    /// **A neutral comparison with no verdict**, which is the whole of why `MetricChange` is not used
    /// here — see `ActivityDelta`. Strain is neither good nor bad by direction, and the badge says so
    /// by carrying no verdict to colour itself from.
    public var strainDelta: ActivityDelta? {
        ActivityDelta.between(
            current: session.strain, mean: baseline.meanStrain, formatted: { $0.formattedOneDecimal() })
    }

    /// The step badge: the session's own count against the window's mean count.
    ///
    /// `nil` on every session this app can currently show, for two independent reasons that each
    /// withhold it: `session.steps` is `nil` on any session this app did not record itself (all 673
    /// imported rows), and `meanSteps` is `nil` because no prior session carried a count either. Either
    /// absence is enough, which is `ActivityDelta.between`'s `nil`-side rule.
    ///
    /// The mean is rounded to a whole step before comparison, because the figure beside it is a count:
    /// `MetricChange`'s "compare the formatted pair" rule means a mean of `5169.4` and a count of `5169`
    /// are the same as far as the row is concerned, and rounding here rather than inside the formatter
    /// keeps the badge's text and the compared value the same number.
    public var stepsDelta: ActivityDelta? {
        let mean = baseline.meanSteps.map { $0.rounded() }
        return ActivityDelta.between(
            current: session.steps.map(Double.init),
            mean: mean,
            formatted: { Self.wholeNumber($0) })
    }

    /// A count as the page prints it — `693`, `5,169` — with no decimal place.
    ///
    /// `formattedOneDecimal()` would print a step count as `693.0`, which is a precision the producer
    /// never had: the strap counts steps in whole units.
    public nonisolated static func wholeNumber(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// The session's step count as the page prints it — the figure, or the dash an unmeasured session
    /// draws.
    ///
    /// **A dash and never `0`.** `0` is a measured session of no walking; `nil` is a session whose
    /// motion was not measured at all. `WorkoutSession.steps` carries that distinction and the writer
    /// keeps it — see its own comment.
    public var stepsText: String {
        guard let steps = session.steps else { return ActivityFigure.dash }
        return Self.wholeNumber(Double(steps))
    }

    /// The strain as the page prints it — the figure, or the dash when nothing measured one.
    ///
    /// A thin forward to `ActivityFigure.strainText`, which is where the rule and its reasoning live:
    /// the view model exposes it because the page reads every other figure off this type, and the
    /// alternative — the view reaching for `session.strain` itself — is the arrangement that let
    /// `HomeDashboardView` and this page hold two copies of one rule.
    public var strainText: String { ActivityFigure.strainText(for: session) }

    /// The session's length as the page prints it — `0:15:58`.
    public var durationText: String { session.durationSeconds.formattedClockDuration() }

    /// The path this session recorded, or `nil` when it has none to draw.
    ///
    /// **A computed property and not a fifth value `load()` refreshes**, which is a refinement `save`'s
    /// own comment implies rather than contradicts: it counts four derived values because four of them
    /// come from *other tables* — the zones from the profile, the trace from `biometric_samples`, the
    /// baseline from the last ten sessions, the fasting summary from `recoveries` — and each of those
    /// reads has to be re-run when the session moves. A route has no read behind it at all.
    /// `GRDBWorkoutRepository.makeSessions` fetches `workout_route_points` per workout, so
    /// `session.route` is already in hand the moment `session` is, and a trim or a rename that
    /// replaced `session` replaces the route with it. Storing it would be a second copy of one value,
    /// and the copy is the one that goes stale.
    ///
    /// The cost is that this is recomputed on every `body` evaluation — a filter, a sort and a sum of
    /// great-circle distances over the session's fixes. That is a few thousand `sin` calls on a
    /// multi-hour route, which is far inside a frame, and it buys the page the property that matters:
    /// the drawing can never describe a session that is no longer on screen.
    ///
    /// **`nil` is the page's whole absence for this block**, and it is the ordinary case rather than
    /// the exception — the `RECORD ROUTE` toggle is the only producer of these rows, it is off by
    /// default, and no session this app can currently show has ever had it on. See `ActivityRoute` for
    /// why the section is then absent with no note rather than drawn as an empty frame.
    public var route: ActivityRoute? {
        ActivityRoute(points: session.route)
    }

    /// Asks what is on disk for the region this session named, and turns that into a renderer.
    ///
    /// **A session with no region asks nothing.** `offlineRegionID` is `nil` for every session recorded
    /// with the switch off — which is most of them, and every row written before `v19` — and the `??`
    /// passes `.absent` for those, which is literally true of them: nothing was downloaded for this
    /// session. That is `RouteMapRenderer.resolve`'s own documented contract, so the rule stays in one
    /// place and this call site states no second version of it.
    ///
    /// It is synchronous and cheap: `state(for:)` reads this app's own record of what it asked the tile
    /// store for, not the store itself. That is what makes it affordable inside `load()`.
    private func loadRouteRenderer() {
        let state = session.offlineRegionID.map { offlineMaps.state(for: $0) } ?? .absent
        routeRenderer = RouteMapRenderer.resolve(session: session, state: state)
    }

    // MARK: - What a fast's page draws

    /// Whether this session draws the fasting layout.
    ///
    /// A thin forward to `ActivityFigure.isFast`, which is where the rule lives and which
    /// `loadFastingRecovery()` gates its read on. The view reads it here rather than calling the domain
    /// itself so that the page's layout decision and the read behind it are visibly the same call.
    public var isFast: Bool { ActivityFigure.isFast(session) }

    /// The fast's length as its own headline prints it — `3 days 6 hrs`.
    ///
    /// **Not `durationText`.** That is the `0:15:58` clock shape, which the `TYPICAL RANGE` card prints
    /// as `DURATION` and which is right for a session measured in minutes; a fast runs for days and that
    /// shape would print `78:01:00`. The two are different readings of the same span on one page, so
    /// they are two properties — see `Double.formattedDayHoursMinutes()`.
    /// **`now` is a parameter because this figure ticks on a live fast, and neither obvious spelling
    /// of that works.** `session.durationSeconds` is a subtraction of two frozen instants, so wrapping
    /// *it* in a `TimelineView` re-renders a constant — the row would sit at whatever it read when the
    /// page opened. And the projection itself is built once at the tap (its identity has to stay
    /// stable, or SwiftUI tears the page down and rebuilds it), so `endedAt` is the tap and not now.
    ///
    /// So the live arm measures from `liveFast.startedAt` to the clock the caller supplies, which is
    /// the `TimelineView`'s — and it goes through **the same formatter** the stored arm does, so the
    /// live figure and the row it becomes when it ends cannot print one span two ways. The stored arm
    /// ignores `now` entirely; it has both of its instants already.
    ///
    /// The clamp is the caller's clock read against the anchor, on `LiveSessionBar.accessibilityLabel`'s
    /// rule: no state of this app has measured a negative span.
    public func totalDurationText(at now: Date = Date()) -> String {
        guard let liveFast else { return session.durationSeconds.formattedDayHoursMinutes() }
        return max(0, now.timeIntervalSince(liveFast.startedAt)).formattedDayHoursMinutes()
    }

    /// The mean Recovery score over the nights this fast covered, as the page prints it — `54%`.
    ///
    /// A dash when the fast enclosed no measured night, which is the same absence the chart's slot draws
    /// a line for. **The `%` is the app's existing rendering of a recovery score** — `RecoveryDetailView`'s
    /// gauge prints `67%` — and not a second convention: the score is already a 0–100 quantity.
    public var fastingScoreText: String {
        guard let score = fastingRecovery?.meanScore else { return ActivityFigure.dash }
        return "\(score)%"
    }

    /// The tier colour the score is drawn in.
    ///
    /// Through `RecoveryMetric.RecoveryState(score:).color`, the app's one tier-to-`Color` mapping, so
    /// this figure and Home's ring cannot come to draw one score two colours. `textPrimary` when there
    /// is no score, because a dash is not a tier and must not be given one — the same reason Home's ring
    /// draws no fill behind its `—`.
    ///
    /// **The rounding happens before the tiering and that is deliberate.** `meanScore` is already the
    /// rounded mean — `FastingRecovery` rounds it — so what is tiered here is the figure the screen
    /// prints, and a mean of 66.5 cannot be a green `67%` over a yellow rule. A mean is not a score the
    /// formula produced, so which tier it lands on is a decision rather than arithmetic, and §19 pins it
    /// at the boundary.
    public var fastingScoreColor: Color {
        guard let score = fastingRecovery?.meanScore else { return Theme.textPrimary }
        return RecoveryMetric.RecoveryState(score: score).color
    }

    /// The badge under the score: what the figure was averaged over, or `nil` when there is none.
    ///
    /// **The basis, and not a verdict.** The reference's badge reads `METABOLICALLY IMPROVED`, which
    /// this app cannot say — it has no glucose and no ketone reading anywhere, on any file, so a claim
    /// about metabolic state would be invented. What it does know is how many nights the figure came
    /// from, which is the same provenance `comparisonBasis` prints under the two stat columns.
    public var fastingBadgeText: String? {
        guard let summary = fastingRecovery else { return nil }
        return Self.fastingBadgeText(nightCount: summary.scoredNightCount)
    }

    /// `OVER 4 NIGHTS`, singular where it has to be.
    ///
    /// `scoredNightCount` and not `nights.count`: the two are equal today, since `FastingRecovery`
    /// filters to measured nights before it builds the summary, and naming the count the *score* was
    /// taken over is the honest basis either way.
    public nonisolated static func fastingBadgeText(nightCount: Int) -> String {
        nightCount == 1 ? "OVER 1 NIGHT" : "OVER \(nightCount) NIGHTS"
    }

    /// The nights the fast covered as a chart, or `nil` when there is nothing to draw.
    ///
    /// **Two ways to be `nil` and they are different answers**, which is why this is derived here and
    /// not conflated with `fastingRecovery`'s own absence: the summary is `nil` when the fast enclosed
    /// no measured night, while a summary can exist and still yield nothing to plot when the baseline
    /// window behind it was too thin. `FastingRecoveryChartView`'s two strings say which.
    public var fastingChartSeries: FastingRecoveryChartSeries? {
        guard let summary = fastingRecovery else { return nil }
        return FastingRecoveryChartSeries(summary: summary)
    }

    /// The line under the chart: what the figure above it is read *as*, and what to do about it.
    ///
    /// ## Why this is its own band table and not `RecoveryState`
    ///
    /// **The score's colour and the sentence's band are two scales on one screen, and that is the
    /// user's decision rather than an oversight.** `fastingScoreColor` above tiers through
    /// `RecoveryState` (67 / 34) because that is the app's one tier-to-colour mapping and a score that
    /// were green here and yellow on Home would be the worse fault; this reads
    /// `FastingRecoveryGuidance.Band` (67 / **50**) because a fast is itself a stressor and the reading
    /// that means *maintain* on an ordinary day does not mean it on day four of not eating. Between 34
    /// and 50 the figure is therefore yellow and the words are a stop signal, deliberately. The
    /// paragraph is drawn in `Theme.textSecondary` and carries no band colour at all, so the divergence
    /// is never two colours under one number — see `FastingRecoveryGuidance`'s own doc.
    ///
    /// ## The tense is the fast's own state, not the screen's
    ///
    /// `ActivityFigure.isInProgress(session)` and **not** `DayBarRules.isToday`, which is the half
    /// `fastingEndText` adds for its own question. The page is drawn almost entirely for fasts that have
    /// already ended — all 170 bundled ones have — so the retrospective arm is what a reader sees and
    /// the live one is reachable only from a fixture. A live-arm sentence printed under a fast that
    /// finished three days ago would be advice the reader cannot take.
    ///
    /// `nil` exactly when `fastingScoreText` is a dash: the sentence names the figure, so it cannot be
    /// drawn without one, and a fast enclosing no measured night gets the chart slot's absence line and
    /// nothing here.
    public var fastingGuidance: FastingRecoveryGuidance.Statement? {
        guard let summary = fastingRecovery, let score = summary.meanScore else { return nil }
        return FastingRecoveryGuidance.statement(
            score: score,
            nightCount: summary.scoredNightCount,
            // **`isLiveFast` rather than `ActivityFigure.isInProgress(session)`**, which is the one
            // place in the app the projection makes that predicate wrong: a projected fast has
            // `endedAt == now`, so `isInProgress` reports a *running* fast as finished and the line
            // would tell the reader to do it next time while it is still going. The two agree on every
            // stored row, and the live page is the one page where they part.
            isInProgress: isLiveFast || ActivityFigure.isInProgress(session)
        )
    }
}
