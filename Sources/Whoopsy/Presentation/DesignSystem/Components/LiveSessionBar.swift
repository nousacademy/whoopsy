import SwiftUI

/// The rules behind the bar Home pins above everything else while a session is recording.
///
/// It holds no drawing — `HomeDashboardView` builds the bar itself, exactly as `ActivityDetailView`
/// draws `ActivityOverflowMenu`'s hand-built rows — and that split is this repo's standing arrangement
/// rather than a preference: the test runner has no renderer, so a rule written into a `body` is a rule
/// nothing can assert. What is left here is the whole of the bar's behaviour, which is *when it exists*,
/// *which session it is about*, *what mark it draws* and *what it says*.
///
/// **There are two kinds of live session and one bar.** A fast runs underneath an activity — the user's
/// own answer — so the bar is about whichever of the two is the more recent thing happening, and the
/// two draw differently: an activity is `Theme.recoveryRed`, a fast takes the fill of the fasting zone
/// it has reached. That is why `Subject` exists rather than a pair of optional dates: the *identity* of
/// the session is what the colour, the words and the tap's destination are all derived from.
public enum LiveSessionBar {

    /// Which live session the bar describes, and when it started.
    ///
    /// Carries no clock and no `now`, deliberately. `HomeDashboardView` reads the use case's state in
    /// its `body` and that read is what registers the `@Observable` dependency; the colour needs `now`
    /// and so is built inside a `TimelineView`. A single function returning both *whether* the bar
    /// exists and *what colour* it is would force the read inside the timeline closure and attribute
    /// the dependency to `TimelineView` instead of Home — and the bar would then survive END for up to
    /// a minute, which is the exact property the four `subject(...)` assertions below exist to pin.
    public enum Subject: Equatable, Sendable {

        /// A regular activity is recording. Its name is what the picker chose.
        case activity(name: String, startedAt: Date)

        /// A fast is running. It has no name of its own to carry — a fast is one thing, and
        /// `WhoopActivityCatalog.fastingName` is what every layer already calls it.
        case fast(startedAt: Date)

        /// The instant the clock counts from. A `Text(_:style: .timer)` is drawn *from* an anchor, so
        /// this is the one field the visible drawing cannot do without.
        public var anchor: Date {
            switch self {
            case .activity(_, let startedAt): startedAt
            case .fast(let startedAt): startedAt
            }
        }

        /// What the session is called, in the words the rest of the app uses for it.
        public var name: String {
            switch self {
            case .activity(let name, _): name
            case .fast: WhoopActivityCatalog.fastingName
            }
        }

        /// The mark the bar draws in front of its clock, from the session's own name.
        ///
        /// **It is a property here rather than `ActivityGlyph.mark(for:)` written into the `body`** for
        /// this file's standing reason — the runner has no renderer, so a rule written into a `body` is
        /// a rule nothing can assert. And there is a plausible wrong answer to pin: `mark(for: nil)`.
        /// That is `figure.run`, which is a *wrong* drawing rather than a missing one, and it is exactly
        /// what a `.fast` arm reading `activeFast?.startedAt` without the name would fall into — a
        /// running figure over a fasting bar, which no build and no screenshot of a different bar would
        /// report.
        ///
        /// **The name is resolved through `ActivityGlyph`, the app's one name-to-mark mapping**, so the
        /// bar's icon and the `ACTIVITIES` card's chip cannot draw one activity two ways. `.fast`
        /// synthesises its name in the `case` above and asks the same table for it as a picked session
        /// does.
        ///
        /// **A fast therefore draws the app's one composite — `fork.knife`, then `timer` — and the
        /// `timer` half is deliberately not dropped.** It sits in front of a clock, so the second symbol
        /// reads as a repeat of the figure beside it; but `ActivityGlyph` has no accessor that hands back
        /// a single symbol, precisely so a composite cannot be truncated by accident, and honouring the
        /// redundancy would mean reintroducing `symbol(for:)` and losing the fit assertions that exist
        /// because a pair is wider than a symbol. It also draws the mark the card's own fast row draws,
        /// which is the reading that matters: *fasting, for a duration*, on both surfaces.
        public var mark: ActivityGlyph.Drawing {
            ActivityGlyph.mark(for: name)
        }
    }

    /// Which live session the bar is about, or `nil` when it must not be drawn at all.
    ///
    /// ## The activity wins, and that is the user's decision rather than a precedence accident
    ///
    /// A fast does not block an activity — 18 hours in, you can go for a run — and while the run is on
    /// the bar describes **the run**. The fast keeps counting underneath and the bar returns to it the
    /// moment the run ends, still counting from the fast's own start.
    ///
    /// ## The activity's gate is two questions and not one
    ///
    /// **`isActivityRunning` is tested first, and it is a different question from "does the session
    /// have a start instant".** `LiveSessionUseCase.end()` clears `isRunning` at its top and `startedAt`
    /// only in `reset()`, which runs from a `defer` after the lock-screen card has been ended and the
    /// `workouts` row written — two awaits later. So there is a real window in which a session is
    /// stopped and still carries its start instant, and a gate keyed on `startedAt != nil` would go on
    /// counting over Home for the length of a database round trip after the user pressed END.
    ///
    /// The `startedAt` clause is not decoration either: the visible clock is `Text(_:style: .timer)`,
    /// which is drawn *from* an anchor, so a running session with none has no clock to draw. It is
    /// withheld rather than drawn as `--:--` — that pair is `LiveSessionView`'s word for a session that
    /// has not started, and a bar that only exists while a session is running can never honestly be in
    /// that state. **Falling through to the fast is what that clause buys**: a run with no anchor is
    /// not a reason to hide a fast that is genuinely running.
    ///
    /// An activity whose picked name is missing falls back to `WhoopActivityCatalog.abstentionName`,
    /// which is the same word `end()` writes onto the row for exactly this case — so the bar and the
    /// stored row cannot disagree about what an unnamed session was called.
    ///
    /// **The day is deliberately not a parameter.** `HomeDashboardView.selectedDate` pages through
    /// history, but a recording is about now: the bar belongs on screen on a day in 2024 exactly as it
    /// does on today, because the session it describes is running on neither of them. A gate that
    /// consulted the day would make the bar vanish on every day but one, which is the same mistake
    /// `ActivityFigure.fastingEndText` records against reading `DayBarRules.isToday` where the subject
    /// is the session's own state.
    public static func subject(
        isActivityRunning: Bool,
        activityName: String?,
        activityStartedAt: Date?,
        activeFast: ActiveFast?
    ) -> Subject? {
        if isActivityRunning, let activityStartedAt {
            return .activity(
                name: activityName ?? WhoopActivityCatalog.abstentionName,
                startedAt: activityStartedAt)
        }
        if let activeFast {
            return .fast(startedAt: activeFast.startedAt)
        }
        return nil
    }

    /// What VoiceOver announces for the bar.
    ///
    /// The bar is a `Button` whose only visible content is a clock the system draws, so its accessible
    /// name has to carry the meaning the drawing carries for the eye: this is a *recording*, what is
    /// being recorded, and how long it has been going. Written here rather than as a string built in
    /// the body, for the reason the type exists at all.
    ///
    /// **The name goes in, and for an ordinary session that changes nothing.** The default name is
    /// WHOOP's abstention word `Activity`, so the sentence reads exactly as it did before this took a
    /// subject — `Activity recording, 12 minutes 34 seconds elapsed` — while a session picked as
    /// `Basketball` says so. A fast says `Fast`.
    ///
    /// `now` is a parameter so an assertion about it does not depend on the clock, which is
    /// `DayBarRules`' rule. The elapsed time is clamped at zero because the caller is a view that reads
    /// `Date()` once per render: an unclamped negative would announce *-1 minutes -30 seconds*, and no
    /// state of this app can have measured a negative span.
    public static func accessibilityLabel(for subject: Subject, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(subject.anchor)))
        return "\(subject.name) recording, \(elapsed / 60) minutes \(elapsed % 60) seconds elapsed"
    }

    /// What the bar does when tapped.
    ///
    /// **A function of the subject rather than a constant, because the tap forks.** Both arms open the
    /// live session's own page off the same process-held use case, but they are two different pages —
    /// `LiveSessionView` for an activity, the fasting layout of `ActivityDetailView` for a fast — and
    /// one hint would describe a destination the tap does not always reach. The two sentences are
    /// constants here rather than literals at the call site for `ActivityFigure.inProgressText`'s
    /// reason: they are authored words, and a screen that restated one could describe a different page.
    public static func accessibilityHint(for subject: Subject) -> String {
        switch subject {
        case .activity: "Opens the activity session"
        case .fast: "Opens the fasting session"
        }
    }
}
