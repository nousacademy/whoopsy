import Foundation

/// The rows of Home's `+` menu, named so they can be asserted.
///
/// It lives here rather than inline in `HomeDashboardView`'s body for `DayBarRules`' reason, the same
/// one `ActivityGlyph` and `MonthGrid` are separate types for: the test runner has no renderer, and a
/// rule written into a `View`'s body is a rule nothing can check. §14 drives every entry.
///
/// **Both rows are inert.** Neither carries a destination, a route or a view model — the menu is the
/// whole of what the `+` does, and nothing exists behind either word yet. That is why this type holds
/// two strings and a symbol and no closure: a row that cannot name where it goes cannot be wired
/// somewhere by accident.
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
        public let symbol: String
        public let title: String

        /// The title is the identity: two rows that read the same are the same row, and there are two
        /// of them, so a `UUID()` here would be a fresh identity on every render of a static list.
        public var id: String { title }

        public init(symbol: String, title: String) {
            self.symbol = symbol
            self.title = title
        }
    }

    /// The rows, top to bottom.
    ///
    /// The order is the drawing's: `ADD ACTIVITY` above `START ACTIVITY`, and §14 pins the pair in that
    /// order so reversing them is a failure rather than a preference.
    public static let entries: [Entry] = [
        Entry(symbol: "plus", title: "ADD ACTIVITY"),
        Entry(symbol: "clock", title: "START ACTIVITY"),
    ]
}
