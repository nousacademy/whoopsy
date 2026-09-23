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
/// ## It writes nothing
///
/// There is no calculate use case anywhere in this type, and there must not be one. This page reads a
/// session that is already stored; `CalculateStrainUseCase` recomputes from `biometric_samples` and
/// saves by primary key, so pointing it at a stored session would be an overwrite rather than a
/// refresh — and would come back empty on every imported session anyway, since an imported day has no
/// samples by construction. `StrainViewModel`'s own warning about workouts having no recompute branch
/// applies here in full.
///
/// ## Everything the page draws is a value on this type, not a rule in a `body`
///
/// The zone rows, the duration bar's layout and the heart-rate series are all resolved here — or in a
/// named type this holds — because the runner that tests this app has no renderer. See `ActivityZoneRow`,
/// `ActivityDurationBarLayout` and `ActivityHeartRateSeries`.
@MainActor @Observable public final class ActivityDetailViewModel {

    /// The session this page is about. Immutable: a view model that could be re-pointed at another
    /// session would let a re-render behind the push move the page's subject.
    public let session: WorkoutSession

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
        sessionCount: 0, typicalDuration: nil, meanStrain: nil, meanSteps: nil, stepSessionCount: 0)

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

    public var errorMessage: String?

    private let workoutRepository: any WorkoutRepository
    private let userProfileRepository: any UserProfileRepository
    private let biometricRepository: any BiometricRepository

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

    public init(
        session: WorkoutSession,
        workoutRepository: any WorkoutRepository,
        userProfileRepository: any UserProfileRepository,
        biometricRepository: any BiometricRepository
    ) {
        self.session = session
        self.workoutRepository = workoutRepository
        self.userProfileRepository = userProfileRepository
        self.biometricRepository = biometricRepository
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
        guard let steps = session.steps else { return "—" }
        return Self.wholeNumber(Double(steps))
    }

    /// The strain as the page prints it. Never a dash: `WorkoutSession.strain` is non-optional, and the
    /// live session's accumulator produces a real `0.0` for a session it watched that never left zone 1.
    public var strainText: String { session.strain.formattedOneDecimal() }

    /// The session's length as the page prints it — `0:15:58`.
    public var durationText: String { session.durationSeconds.formattedClockDuration() }
}
