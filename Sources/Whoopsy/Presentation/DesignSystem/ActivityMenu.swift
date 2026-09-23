import Foundation

/// The rows of Home's `+` menu, named so they can be asserted.
///
/// It lives here rather than inline in `HomeDashboardView`'s body for `DayBarRules`' reason, the same
/// one `ActivityGlyph` and `MonthGrid` are separate types for: the test runner has no renderer, and a
/// rule written into a `View`'s body is a rule nothing can check. §14 drives every entry.
///
/// **`ADD ACTIVITY` is inert; `START ACTIVITY` launches a live session.**
///
/// The two rows are no longer the same kind of thing, which is what `Action` records. `ADD ACTIVITY`
/// opens the import path, which does not exist yet — so its `Action` is `.none` and tapping it only
/// closes the menu. `START ACTIVITY` carries `.startSession`, and `HomeDashboardView` is the one place
/// that switches on it.
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
        /// `none` is a real answer and not a placeholder for one: it is the row that opens no screen.
        ///
        /// An enum with no associated values is `Equatable` without saying so, which is what lets §18
        /// assert that **exactly one** row carries `.startSession` — a claim about which case a value
        /// holds rather than about whether two values differ.
        public enum Action: Sendable {
            /// Opens nothing. `ADD ACTIVITY`'s import path is not built.
            case none
            /// Starts a live session and pushes `LiveSessionView`.
            case startSession
        }

        public let symbol: String
        public let title: String
        public let action: Action

        /// The title is the identity: two rows that read the same are the same row, and there are two
        /// of them, so a `UUID()` here would be a fresh identity on every render of a static list.
        public var id: String { title }

        public init(symbol: String, title: String, action: Action = .none) {
            self.symbol = symbol
            self.title = title
            self.action = action
        }
    }

    /// The rows, top to bottom.
    ///
    /// The order is the drawing's: `ADD ACTIVITY` above `START ACTIVITY`, and §14 pins the pair in that
    /// order so reversing them is a failure rather than a preference. **Exactly one row carries
    /// `.startSession`** and §18 asserts it is this one — a second live-actionable row would be a
    /// second recording path.
    public static let entries: [Entry] = [
        Entry(symbol: "plus", title: "ADD ACTIVITY", action: .none),
        Entry(symbol: "clock", title: "START ACTIVITY", action: .startSession),
    ]

    /// The rows to draw for a day.
    ///
    /// **Every day is offered the menu; only today is offered a way to record.** The `+` is drawn
    /// whatever day is on screen, and off today it still opens the card and still lists
    /// `ADD ACTIVITY` — the row withheld is `START ACTIVITY`, because a session is something a user
    /// starts *now* and a day that already happened has nothing to start. So the day filters the *rows*
    /// rather than hiding the button, which is also why `ADD ACTIVITY` does not disappear with it: its
    /// import path is not bound to a day, so no other day has a reason to withhold it.
    ///
    /// **The filter is on the `Action`, not on the title.** What is withheld is a row that *records*,
    /// which is the same property `HomeDashboardView`'s `switch` acts on — so a second recording row
    /// added to `entries` later is withheld here without this body being taught about it, and a row
    /// renamed to something else is not silently admitted.
    ///
    /// It **forwards** to `DayBarRules.isToday` rather than restating a comparison, so the screen has one
    /// definition of "today" and not two. The choice of `isToday` over the shorter `!isFuture` is
    /// load-bearing and is not visible on today: the two agree there and disagree on **every past day**,
    /// which is the case this rule exists for — `DayBarRules.canStepForward` documents the same fork in
    /// the same direction. §14 drives it.
    public static func entries(on day: Date, now: Date = Date()) -> [Entry] {
        guard !DayBarRules.isToday(day, now: now) else { return entries }
        return entries.filter { $0.action != .startSession }
    }
}
