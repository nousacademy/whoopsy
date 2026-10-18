import Foundation

/// The rows of Home's `+` menu, named so they can be asserted.
///
/// It lives here rather than inline in `HomeDashboardView`'s body for `DayBarRules`' reason, the same
/// one `ActivityGlyph` and `MonthGrid` are separate types for: the test runner has no renderer, and a
/// rule written into a `View`'s body is a rule nothing can check. §14 drives every entry.
///
/// **Each row opens a different surface, and `Action` records which one.**
///
/// `ADD ACTIVITY` opens `AddActivitySheet` on a fresh draft and writes a row to `workouts`;
/// `START ACTIVITY` starts a live session; `ADD RECEPTIVE INACTIVITY` opens
/// `ReceptiveInactivitySheet` and writes a row to `receptive_inactivities`. Three rows, three cases,
/// and `HomeDashboardView` is the one place that switches on them.
///
/// **The action is a case and not a closure**, deliberately, and the reason is the one this type's
/// previous version gave for having no field at all: a `() -> Void` stored in a static list cannot be
/// asserted, cannot be `Equatable`, and can capture anything. A case names the one thing the row does,
/// §18 can assert which row carries it, and a destination still cannot be reached by accident — the
/// switch is exhaustive, so a case added here is a compile error at the one call site rather than a
/// silent no-op.
///
/// **The titles are written in the case they are drawn in**, which is the opposite of the `ACTIVITIES`
/// card's labels. Those uppercase in the drawing because the entity holds `workouts.csv`'s own casing
/// and the label is a producer's string; these are UI literals with no second consumer, so the value is
/// the whole answer and an assertion over it is an assertion about the screen.
///
/// **Every symbol is iOS 13**, well inside the 17.0 deployment target — `figure.ice.skating` and its
/// four iOS-18 siblings are the trap `ActivityGlyph` documents, and neither row here is anywhere near
/// it. A wrong symbol name is still not an error: it draws an empty chip, so §14 asserts every entry's
/// symbol is non-empty, which is the only thing that can see a typo.
public enum ActivityMenu {

    /// One row: the glyph in its leading chip and the word beside it.
    ///
    /// `Sendable` is spelled out rather than left to inference. A `public` struct does not get the
    /// implicit conformance a non-public one does, and the `static let` below is a Swift 6
    /// strict-concurrency error without it — the sibling of the `static var`-for-`static let` failure
    /// `RingsBottomKey`'s comment records.
    public struct Entry: Identifiable, Equatable, Sendable {

        /// What tapping the row does. See the type's note on why this is a case and not a closure.
        ///
        /// **There is no `none` case, deliberately.** The previous version had one, and the row that
        /// held it was the row that did nothing — a defaulted `.none` made *inert* the state a row
        /// reached by omission. With the case gone and no default on `Entry.init`, a row added later
        /// has to name a destination to compile.
        ///
        /// An enum with no associated values is `Equatable` without saying so, which is what lets §18
        /// assert that **exactly one** row carries `.startSession` — a claim about which case a value
        /// holds rather than about whether two values differ.
        public enum Action: Sendable {
            /// Opens `AddActivitySheet` on a fresh draft and writes a `workouts` row with no
            /// measurement attached.
            ///
            /// **It is a case of its own rather than a second `.startSession`, because nothing
            /// runs while it is entered.** No clock starts, `LiveSessionUseCase` is not reached, and
            /// the row is filed on the day being viewed rather than on the present — which is what
            /// makes it the right row on a past day, the same argument `.addReceptiveInactivity`
            /// records. It keeps §18's "exactly one row carries `.startSession`" claim true.
            case addActivity
            /// Starts a live session and pushes `LiveSessionView`.
            case startSession
            /// Opens `ReceptiveInactivitySheet` on an empty draft, and writes a row to
            /// `receptive_inactivities` rather than to `workouts`.
            ///
            /// **It is a third case rather than a second `.startSession`-shaped one, because a receptive
            /// activity is not a recording.** Nothing runs while one is being entered, no clock is
            /// started, and `LiveSessionUseCase` is not reached — so the "exactly one row carries
            /// `.startSession`" claim §18 asserts stays true, and this row cannot become a second path
            /// into a live session by being given the wrong case.
            case addReceptiveInactivity
        }

        public let symbol: String
        public let title: String
        public let action: Action

        /// The title is the identity: two rows that read the same are the same row, and there are three
        /// of them, so a `UUID()` here would be a fresh identity on every render of a static list.
        public var id: String { title }

        public init(symbol: String, title: String, action: Action) {
            self.symbol = symbol
            self.title = title
            self.action = action
        }
    }

    /// The rows, top to bottom.
    ///
    /// The order is the drawing's: `ADD ACTIVITY` above `START ACTIVITY` above `ADD RECEPTIVE INACTIVITY`,
    /// and §14 pins the three in that order so reversing them is a failure rather than a preference.
    /// **Exactly one row carries `.startSession`** and §18 asserts it is this one — a second
    /// live-actionable row would be a second recording path.
    ///
    /// **`ADD RECEPTIVE INACTIVITY` is appended last rather than placed beside `ADD ACTIVITY`**, and that
    /// is a compatibility decision as much as a drawing one: the first two rows are the menu as it has
    /// always been, and appending keeps every existing position where §14 and §18 already pin it. It is
    /// also the honest grouping — the two `ADD` rows write to different tables, and only the third
    /// opens a surface about something that is not a recorded session at all.
    ///
    /// Its symbol is `ActivityGlyph.receptiveMark` and not a `figure.*` mark, because the two rows above
    /// it are about the body doing something and this one is about the mind receiving something — which
    /// is the distinction the card it writes to is named for. **It is read from that constant rather than
    /// written here**, so the glyph on this row and the glyph the sheet's own NAME row draws while it has
    /// no name yet are one value; two literals would be two places for one mark to be changed.
    public static let entries: [Entry] = [
        Entry(symbol: "plus", title: "ADD ACTIVITY", action: .addActivity),
        Entry(symbol: "clock", title: "START ACTIVITY", action: .startSession),
        Entry(
            symbol: ActivityGlyph.receptiveMark,
            title: "ADD RECEPTIVE INACTIVITY",
            action: .addReceptiveInactivity
        ),
    ]

    /// The rows to draw for a day.
    ///
    /// **Every day is offered the menu; only today is offered a way to record.** The `+` is drawn
    /// whatever day is on screen, and off today it still opens the card and still lists
    /// `ADD ACTIVITY` — the row withheld is `START ACTIVITY`, because a session is something a user
    /// starts *now* and a day that already happened has nothing to start. So the day filters the *rows*
    /// rather than hiding the button, which is also why `ADD ACTIVITY` does not disappear with it: a
    /// hand-added session is filed on the day being viewed rather than on the present, so paging back
    /// to the day the walk happened is exactly when the row is wanted.
    ///
    /// **The filter is on the `Action`, not on the title.** What is withheld is a row that *records*,
    /// which is the same property `HomeDashboardView`'s `switch` acts on — so a second recording row
    /// added to `entries` later is withheld here without this body being taught about it, and a row
    /// renamed to something else is not silently admitted.
    ///
    /// **Both `ADD` rows survive both filters, and that is correct on both counts rather than an
    /// accident of their actions.** Off today they survive because neither is bound to the present the
    /// way a recording is: a dream is filed on the morning it happened and a hand-added walk on the day
    /// it was walked, and a user paging back to that day is exactly who the rows are for. While an
    /// activity is recording they survive because there is nothing to conflict with — entering a
    /// meditation or a past session writes one row and starts no clock, so neither is a second
    /// recording.
    ///
    /// It **forwards** to `DayBarRules.isToday` rather than restating a comparison, so the screen has one
    /// definition of "today" and not two. The choice of `isToday` over the shorter `!isFuture` is
    /// load-bearing and is not visible on today: the two agree there and disagree on **every past day**,
    /// which is the case this rule exists for — `DayBarRules.canStepForward` documents the same fork in
    /// the same direction. §14 drives it.
    /// **`recording` is appended last, after `now:`, and that is a compatibility decision rather than
    /// an ordering one.** Six call sites pass this function two arguments — five in the runner and one
    /// in `HomeDashboardView` — and a defaulted parameter inserted before `now:` would break all six at
    /// compile time. The suite reports nothing rather than reporting a failure when it does not build,
    /// so the parameter goes where it costs nothing.
    public static func entries(
        on day: Date, now: Date = Date(), recording: Recording = .none
    ) -> [Entry] {
        // A live **activity** withholds the row, because there cannot be two of them: `start()` is
        // idempotent, so a second tap would push a session screen onto a session that is already
        // running and record nothing. A live **fast** does not, which is the user's own rule — a fast
        // runs underneath an activity and 18 hours in is exactly when a run is worth recording.
        if recording == .activity { return entries.filter { $0.action != .startSession } }
        guard !DayBarRules.isToday(day, now: now) else { return entries }
        return entries.filter { $0.action != .startSession }
    }

    /// What is live right now, as the menu sees it.
    ///
    /// **A UI-facing input rather than a policy store.** `LiveSessionUseCase` is still the only thing
    /// that knows what is running, and this is the answer it hands to one caller; `start()`'s own
    /// idempotence is what makes a *wrong* answer inert rather than a second recording. It is a plain
    /// enum so the rule above stays a value the runner can drive with no use case, no database and no
    /// session — which is the only form this claim can take in a build with no renderer.
    ///
    /// It is deliberately **not** a `Bool` named `isRecording`: a fast and an activity answer the
    /// availability question differently, and one flag could not hold both answers.
    public enum Recording: Sendable {
        /// Nothing is live.
        case none

        /// A regular activity is recording. This is the state that withholds `START ACTIVITY`.
        case activity

        /// A fast is running and no activity is. The menu is unchanged.
        case fast
    }
}
