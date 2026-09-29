import SwiftUI

/// The rows of the activity detail page's `•••` menu, named so they can be asserted.
///
/// It lives here rather than inline in `ActivityDetailView`'s body for `ActivityMenu`'s reason, the one
/// `DayBarRules` and `ActivityGlyph` are separate types for: the test runner has no renderer, and a rule
/// written into a `View`'s body is a rule nothing can check. §19 drives every entry.
///
/// **The action is a case and not a closure**, on `ActivityMenu.Entry.Action`'s terms verbatim: a
/// `() -> Void` stored in a static list cannot be asserted, cannot be `Equatable`, and can capture
/// anything. A case names the one thing the row does, §19 can assert which row carries it, and a
/// destination still cannot be reached by accident — the switch in the view is exhaustive, so a case
/// added here is a compile error at the page's one call site rather than a silent no-op.
///
/// **The titles are written in the case they are drawn in**, which is the reference's own casing:
/// `Edit`, `Delete`, `Cancel`. These are UI literals with no second consumer, so the value is the whole
/// answer and an assertion over it is an assertion about the screen.
///
/// **The tint is a property of the row rather than a branch in the body.** Which row is destructive is
/// a fact about the menu, and the drawing reads it from here; a `entry.action == .delete ? red : blue`
/// written into the `body` would be a rule the runner cannot see, which is the same reason
/// `ActivityDelta` carries its own colour instead of leaving it to the badge.
public enum ActivityOverflowMenu {

    /// One row: the word, what tapping it does, and how it is drawn.
    ///
    /// `Sendable` is spelled out rather than left to inference, on `ActivityMenu.Entry`'s note: a
    /// `public` struct does not get the implicit conformance a non-public one does, and the `static let`
    /// below is a Swift 6 strict-concurrency error without it.
    public struct Entry: Identifiable, Equatable, Sendable {

        /// What tapping the row does. See the type's note on why this is a case and not a closure.
        public enum Action: Sendable {
            /// Opens the `EDIT ACTIVITY` sheet over the page. It closed the menu without reaching
            /// anything until that sheet existed — the user's instruction was *"edit we will wire
            /// later"* — and it was the repo's one documented control without a destination. See
            /// `ActivityDetailView.presentEdit()`.
            case edit
            /// Removes the session and everything filed under it, then returns to Home.
            case delete
            /// **Ends the running fast and writes its row**, then returns to Home.
            ///
            /// The live menu's only acting row, and the one destination a running fast's page has that
            /// a stored session's does not. It is deliberately **not** a second `Delete`: a delete
            /// removes a row that exists, while this *creates* one from the session still running, and
            /// the two are different acts on different things.
            ///
            /// It is also why the live menu carries no `Edit`. There is nothing stored to edit until
            /// the fast is over, and `ActivityEditSheet` writes through `WorkoutRepository.save` —
            /// which would leave the running fast running and put a second row on Home beside it.
            case endFast
            /// Closes the menu and changes nothing else.
            case cancel
        }

        public let title: String
        public let action: Action

        /// The title is the identity, on `ActivityMenu.Entry`'s rule: these are UI literals with no
        /// second consumer, so two rows that read the same are the same row and a `UUID()` here would
        /// be a fresh identity on every render of a static list.
        public var id: String { title }

        /// Whether tapping this row removes something that cannot be brought back.
        ///
        /// It is a named property rather than a comparison written at the two sites that need it —
        /// `tint` below and §19 — for this repo's standing reason: a rule stated twice is two rules
        /// that agree today. The row that is destructive and the row drawn in the red are then the same
        /// fact read once, so a second destructive row cannot be added to the tint without the
        /// assertion beside it moving too.
        public var isDestructive: Bool { action == .delete }

        /// The row's text colour.
        ///
        /// **`Delete` is the only row that takes a colour with a meaning.** `recoveryRed` is the app's
        /// only red, and the two rows beside it take `Theme.actionTint` — the role-named blue, not
        /// `strainRing`, which is the strain figure's colour and is drawn a few inches above this menu.
        public var tint: Color {
            isDestructive ? Theme.recoveryRed : Theme.actionTint
        }

        public init(title: String, action: Action) {
            self.title = title
            self.action = action
        }
    }

    /// The rows split into the cards they are drawn in: the two that act on the session, and the one
    /// that dismisses the menu.
    ///
    /// **The grouping is the rule that puts a gap before `Cancel`, and it is here rather than in the
    /// drawing** for this type's standing reason: the page draws one card per group and separates them
    /// by `groupSpacing`, so an `entry.action == .cancel` branch written into a `body` would be a rule
    /// the runner cannot see — the same reason the tint is a property above rather than a ternary at
    /// the call site. §19 asserts this shape, which is what makes the gap's *position* a fact rather
    /// than a consequence of how the rows happen to be listed.
    ///
    /// **`Cancel` is apart because it is not an action on the session.** The two rows above it do
    /// something to the activity; it is the way out of the menu, and the reference draws that as a card
    /// of its own — which is also why it is not merely a third hairline-separated row in one card.
    /// **A function of `isLive` rather than two lists, and the default is what keeps it one menu.**
    /// There are two shapes and one gap rule, one row height and one radius; writing the live shape as
    /// a second `static let` would be a second definition of all four, free to drift from the first.
    ///
    /// **The default does not make the change free.** These were properties, so making them functions
    /// moves every call site — `ActivityDetailView`'s drawing and §19's assertions — by one `()` each.
    /// That is loud rather than silent on purpose: a menu that silently changed shape would leave the
    /// assertions pinning the old one and passing.
    public static func groups(isLive: Bool = false) -> [[Entry]] {
        guard isLive else { return storedGroups }
        return [
            [
                Entry(title: "End Fast", action: .endFast),
            ],
            [
                Entry(title: "Cancel", action: .cancel),
            ],
        ]
    }

    /// Every row, top to bottom — the flat reading of `groups`, which stays the one definition of the
    /// menu's contents and their order.
    ///
    /// **`Delete` is the app's only destructive row and §19 asserts it is the only one whose `tint` is
    /// the red**, which is the assertion that fails if a row is reordered or a second destructive row
    /// is added without anyone deciding to. `Cancel` is the last row and the last group alike, so the
    /// gap the page draws falls between the acting row and it on any reading of this list.
    ///
    /// **That claim survives the live shape**, because `isDestructive` is `action == .delete` and
    /// `End Fast` is not one — which is the point of the property being named rather than written out
    /// at each of the two sites that need it.
    public static func entries(isLive: Bool = false) -> [Entry] {
        groups(isLive: isLive).flatMap { $0 }
    }

    /// The stored session's menu, which is what `groups` was as a `static let`.
    private static let storedGroups: [[Entry]] = [
        [
            Entry(title: "Edit", action: .edit),
            Entry(title: "Delete", action: .delete),
        ],
        [
            Entry(title: "Cancel", action: .cancel),
        ],
    ]

    /// The scrim's opacity, and it is deliberately Home's own number.
    ///
    /// `HomeDashboardView`'s calendar and its `+` menu both dim their page with
    /// `Color.black.opacity(0.45)`, and the reason is the same one here: the dimming is meant to say
    /// *this page is still here, under a control that belongs to it*, so it is partial rather than
    /// blacking the screen out. Three overlays in one app that dimmed by three different amounts would
    /// read as three different kinds of modal.
    public static let scrimOpacity: Double = 0.45

    /// One row's height. A constant rather than a `padding(.vertical,)` at the drawing, because the
    /// three rows have to be the same height as each other and a screen reader's tap target has a
    /// minimum — 54 pt clears it on every device this app runs on.
    public static let rowHeight: CGFloat = 54

    /// The space between the menu's two cards — the one thing that separates `Cancel` from the rows
    /// above it, and it is deliberately a *space* rather than a third hairline.
    ///
    /// A rule between `Delete` and `Cancel` would say the two are neighbours in one list, which is what
    /// every other pair of rows in this menu is; a gap says the last one is apart, and that is the
    /// distinction the reference draws. The dimmed page shows through this gap and through nothing else
    /// in the menu, which is why the two cards carry their own fills rather than sharing one.
    ///
    /// **Eight points, and it is bounded at both ends for a reason.** `rowHeight`'s note reads the other
    /// way here: a gap as tall as a row would read as a fourth, empty button, and one small enough to
    /// mistake for a hairline would make the separation invisible. The `Cancel` row keeps
    /// `rowHeight` and the full width — it is the same size as the rows above it, and this constant is
    /// the whole of what makes it a separate card.
    public static let groupSpacing: CGFloat = 8

    /// The radius on a card's corners. **Every corner of every card** — there are four per card and two
    /// cards, and no corner in this menu is square.
    ///
    /// A constant and not a literal at the drawing because the two cards have to come out at the same
    /// radius as each other: a card rounded at one value beside a card rounded at another is the one
    /// defect in this menu that neither a build nor a screenshot can see, since both cards would look
    /// rounded and only their corners would disagree.
    ///
    /// **The cards are separate objects, not one stack with a gap cut in it** — which is what a single
    /// radius per card says, and what the earlier arrangement (round the stack's outer ends, leave the
    /// inner edges square) did not: that left a square corner under `Delete`, the last row of the first
    /// card and therefore an end of it rather than an edge meeting anything.
    ///
    /// 18 pt is the iOS grouped-list card radius and is what `HomeDashboardView`'s cards use; it is not
    /// derived from anything here.
    public static let cardCornerRadius: CGFloat = 18
}
