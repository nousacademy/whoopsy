import Foundation

/// One in-progress edit of a stored activity: the name the user picked and the window they trimmed, held
/// as a plain value so the rules can be asserted.
///
/// ## Why the rules are here and not in the sheet's `body`
///
/// This repo's standing reason, the one `ActivityZoneRow`, `ActivityOverflowMenu`, `ActivityDurationBarLayout`
/// and `DayBarRules` are all named types for: the runner has no renderer, so a clamp or a comparison written
/// into a `View`'s `body` is a rule nothing can check. Every rule below — the clamp, the floor, the
/// minute-write guard, `hasChanges` — is a decision about what an edit *is*, and each one has a failure mode
/// that is invisible on screen.
///
/// ## Two surfaces write this one value
///
/// The sheet draws the time control twice: a drag handle at each end of the chart, and a compact `DatePicker`
/// under `Start Time` / `End Time`. **Both write through this type**, which is the whole reason it exists as
/// one value rather than as two `@State` dates on the view — two surfaces holding their own copy of the same
/// instant are two values free to disagree, and the screen would then show a handle and a picker that name
/// different times with nothing to say which is the edit.
///
/// ## The window narrows and never widens
///
/// `start` cannot go below `original.startedAt` and `end` cannot go above `original.endedAt`. That is
/// deliberate rather than a limitation: the handles are drawn on a chart whose plot *is* the original window,
/// so a handle dragged outside it would have nowhere to be drawn, and — more to the point — extending the
/// window would be inventing time the app never observed. A session's span is the interval the strap (or
/// WHOOP's file) reported; the user is correcting an over-wide one, not authoring a new one.
///
/// ## Identity survives, and that is what makes the edit durable
///
/// An imported row's `id` is `WhoopExportImporter.workoutID(startingAt:endingAt:)` — a function of its own
/// two instants. Editing the times therefore decouples the id from its derivation, and `applying(to:)` keeps
/// the original id deliberately: the row is updated in place rather than re-inserted, the ids of everything
/// filed under it (`workout_route_points`, `workout_splits`) stay valid, and a later re-import re-derives the
/// id the row *used* to have — which is a duplicate the workouts import's own already-recorded skip is what
/// prevents. Keeping the id here is the half of that pair this type owns.
public struct ActivityEditDraft: Equatable, Identifiable, Sendable {

    /// The session's identity, and **not a fresh one per draft**.
    ///
    /// `Identifiable` is here for `.sheet(item:)` and nothing else, and keying it on the session rather
    /// than on a `UUID()` is what makes the presentation mean what it says: the sheet is presented *for
    /// an activity*, so two drafts opened over the same session are the same presentation and a draft
    /// is not a new thing every time it is rebuilt. A fresh `UUID()` would be an identity that changes
    /// on every write to the draft — which is exactly the value the sheet's own `@State` copy mutates.
    public var id: UUID { original.id }

    /// The session as it is stored, which is what every clamp is measured against and what `hasChanges`
    /// compares to.
    ///
    /// Held rather than passed to each method so the two surfaces cannot be handed two different bases, and
    /// so the handle fractions are always the *original* window's — see `startFraction`.
    public let original: WorkoutSession

    /// The activity name the user has selected, exactly as the sheet will write it.
    ///
    /// **A case-only rewrite of the stored label is not expressible here**, and the guard in `setName(_:)`
    /// is why: a picker whose selection is resolved by `ActivityName.matches` will hand back `Basketball`
    /// for a session stored as `basketball` the moment it is drawn, and a draft that accepted that write
    /// would report a change nobody made and enable `SAVE` over it. The cost is that a file which wrote a
    /// name in the wrong case cannot be corrected from this sheet. The trade is taken because the spurious
    /// change is the one that silently rewrites a stored session.
    public private(set) var activityName: String?

    /// The window's two ends as the sheet currently holds them.
    ///
    /// At `init` these are the original's **exact** instants, seconds and all. See `setStart(_:)` for why
    /// that matters and what would otherwise move them.
    public private(set) var start: Date
    public private(set) var end: Date

    /// The shortest window an edit may produce.
    ///
    /// **`min(60, original.durationSeconds)` and not a flat 60.** With an original shorter than a minute,
    /// `end - 60` is *before* `original.startedAt`, and the clamp's own lower bound would then push the
    /// start backwards — extending the window, which is the one thing this type exists to forbid. No bundled
    /// row is under 76 seconds, but a sub-minute session is reachable from a hand-built fixture or an older
    /// build, and the failure would be a trim that lengthened a session.
    public let minimumDuration: TimeInterval

    /// The last instant the start may take, and the first the end may take.
    ///
    /// **`original.startedAt.endOfDay` is load-bearing, not tidiness.** `LocalDatabaseManager.saveWorkout`
    /// re-snaps a row's `date` column from `startedAt`, so a start dragged past midnight would file the
    /// session on the *next* day — out of the day its `workouts.csv` row belongs to, and out of the day the
    /// import's already-recorded skip keys on, so the next re-import would insert a duplicate of a session
    /// that is still on disk. Clamping the start to its own day makes the day key invariant under every edit
    /// this sheet can make.
    ///
    /// **The cost, stated plainly:** a session that starts at 23:48 cannot be trimmed to start later than
    /// 23:59:59. Its *end* is unconstrained, so such a session can still be shortened from the right.
    private var latestStart: Date {
        min(end.addingTimeInterval(-minimumDuration), original.startedAt.endOfDay)
    }

    private var earliestEnd: Date { start.addingTimeInterval(minimumDuration) }

    /// A draft over `session` with nothing changed.
    ///
    /// **`start` and `end` are taken verbatim and are not clamped here**, which is what keeps an untouched
    /// sheet from reporting a change: 381 of the bundled export's 673 rows carry non-zero seconds, so a
    /// clamp or a minute-floor applied at `init` would move the window of every one of them and a
    /// name-only `SAVE` would silently shift the times. Clamping happens on a *write*, in the setters below.
    public init(_ session: WorkoutSession) {
        self.original = session
        self.activityName = session.activityName
        self.start = session.startedAt
        self.end = session.endedAt
        self.minimumDuration = max(0, min(60, session.durationSeconds))
    }

    // MARK: - The two surfaces' writes

    /// Selects an activity name.
    ///
    /// **A write that names the activity already selected is dropped**, and `ActivityName.matches` is the
    /// test rather than an exact string comparison — see `activityName`'s note. This is the same rule
    /// `hasChanges` reads, deliberately: the guard and the comparison must not be two opinions about what
    /// counts as a change to the name.
    public mutating func setName(_ name: String?) {
        guard !ActivityName.matches(name, activityName) else { return }
        activityName = name
    }

    /// Moves the start from the chart handle's position, as a fraction of the **original** window.
    public mutating func setStart(fraction: Double) {
        setStart(instant(atFraction: fraction))
    }

    /// Moves the end from the chart handle's position, as a fraction of the **original** window.
    public mutating func setEnd(fraction: Double) {
        setEnd(instant(atFraction: fraction))
    }

    /// Moves the start to an instant — the `DatePicker`'s write, and the handle's once it has been mapped
    /// to a time.
    ///
    /// **The minute-write guard is the reason an untouched sheet is not a change.** A `.hourAndMinute`
    /// `DatePicker` reads and writes whole minutes while the stored instant usually is not: shown `2:17 PM`
    /// for a session starting at `2:17:33`, it can hand back `2:17:00`, and a draft that accepted that would
    /// report a change, enable `SAVE`, and rewrite the session's start 33 seconds earlier for a user who
    /// never touched a control. So a write whose minute is the minute already held is dropped, and the
    /// original's exact instant survives — which is exactly the state where the user has expressed no
    /// intent this type can tell apart from the value it already has.
    ///
    /// Once a minute *has* been chosen, the value stored is that whole minute: the sheet's two surfaces can
    /// only ever express minute resolution, so writing a finer value back would be a precision neither of
    /// them offered. The one cost is that a user who moves a handle and moves it back lands on `2:17:00`
    /// rather than `2:17:33` — a real edit, made and unmade, at the resolution the control has.
    public mutating func setStart(_ instant: Date) {
        let candidate = Self.minuteFloored(instant)
        guard candidate != Self.minuteFloored(start) else { return }
        start = Self.clamped(candidate, low: original.startedAt, high: latestStart)
    }

    /// Moves the end to an instant. The mirror of `setStart(_:)`, including its minute-write guard.
    public mutating func setEnd(_ instant: Date) {
        let candidate = Self.minuteFloored(instant)
        guard candidate != Self.minuteFloored(end) else { return }
        end = Self.clamped(candidate, low: earliestEnd, high: original.endedAt)
    }

    // MARK: - What the chart draws

    /// Where the start handle sits across the plot, `0` at the original start and `1` at the original end.
    ///
    /// **Computed from `start` on every read rather than stored**, so the handle and the readout above it
    /// cannot disagree — a stored fraction is a second copy of the same fact, and the one thing this sheet
    /// must never do is draw a handle at one time and print another.
    ///
    /// It is a fraction of the **original** window and not of the edited one, which is what keeps the trace
    /// still while the handles move: the plot is the session as it was recorded, and re-scaling it against
    /// the draft would slide the whole drawing under the finger that is dragging it.
    public var startFraction: Double { fraction(of: start) }
    public var endFraction: Double { fraction(of: end) }

    private func fraction(of date: Date) -> Double {
        let span = original.durationSeconds
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(original.startedAt) / span))
    }

    private func instant(atFraction fraction: Double) -> Date {
        original.startedAt.addingTimeInterval(fraction * original.durationSeconds)
    }

    /// The window as the sheet prints it, ready for `formattedClockDuration()`.
    public var durationSeconds: TimeInterval { end.timeIntervalSince(start) }

    // MARK: - What `SAVE` writes

    /// Whether the draft says anything different from the session it was opened on.
    ///
    /// **The times are compared as exact instants.** An untouched sheet leaves them byte-identical to the
    /// original's — that is what `init` and `setStart(_:)`'s minute-write guard are for — so this is false
    /// for a sheet nobody touched even on a row carrying seconds, which is the property that keeps a
    /// name-only `SAVE` from moving the window.
    ///
    /// The name is compared with `ActivityName.matches`, the same rule `setName(_:)` guards on: "the same
    /// activity" is the question, so a draft holding a differently-cased spelling of the stored name is not
    /// a change to save. The two are equivalent for every state `setName(_:)` can reach, and reading the
    /// rule through one definition is what keeps them so.
    public var hasChanges: Bool {
        start != original.startedAt
            || end != original.endedAt
            || !ActivityName.matches(activityName, original.activityName)
    }

    /// The session this draft describes, given the row it is to be written over.
    ///
    /// **It replaces exactly three fields and passes everything else through from `base`**: the name and the
    /// two instants are the draft's, and the id, source, strain, the two heart rates, the route, the splits,
    /// the step count and `hrZonePercents` are the session's. The pass-through is the point — a trim is not a
    /// re-measurement, and a draft that rebuilt a session from its own fields would zero a strain, drop a
    /// route and lose the zone block on an edit that touched only a name.
    ///
    /// **`hrZonePercents` travelling through unchanged is what the page's five rows depend on.**
    /// `WorkoutSession.zoneSeconds(_:)` derives a row's time as `share × durationSeconds`, so the percentages
    /// stay WHOOP's own figures and the printed times rescale against the trimmed span — one share, one
    /// duration, still derived from each other, which is the rule that keeps a row's `22%` and its `0:03:32`
    /// from contradicting each other. (The alternative — clearing the block — would replace five readings with
    /// five dashes on an edit that measured nothing.)
    ///
    /// Callers pass the draft's own `original` in the ordinary case. The parameter exists so that this stays a
    /// pure function of a draft and a base row, and so that what it hands back is visibly the base's fields
    /// with three of them overridden rather than a session rebuilt from scratch.
    public func applying(to base: WorkoutSession) -> WorkoutSession {
        WorkoutSession(
            id: base.id,
            startedAt: start,
            endedAt: end,
            strain: base.strain,
            averageHeartRate: base.averageHeartRate,
            maxHeartRate: base.maxHeartRate,
            route: base.route,
            splits: base.splits,
            source: base.source,
            activityName: activityName,
            hrZonePercents: base.hrZonePercents,
            steps: base.steps)
    }

    // MARK: - Arithmetic

    /// `value`, held inside `low...high`.
    ///
    /// `max(low, high)` on the upper bound means a hand-built pair that is inside out resolves to `low`
    /// rather than to a `min`/`max` sequence whose answer depends on their order — there is no state this
    /// type can reach where `high < low`, but the helper is what makes that a fact rather than an argument.
    private static func clamped(_ value: Date, low: Date, high: Date) -> Date {
        min(max(value, low), max(low, high))
    }

    /// The whole minute at or before `date`.
    ///
    /// Floored in unix seconds and not through `Calendar`, which is exact here for the reason it is exact in
    /// `SleepClockAxis`: every time zone's offset from UTC is a whole number of minutes, so a boundary in
    /// unix time is a boundary on the wall clock too.
    private static func minuteFloored(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
