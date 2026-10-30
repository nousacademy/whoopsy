import SwiftUI

/// The hand-built overflow menu both detail pages draw: a dimmed page, one card per group of rows, and
/// the tab bar's own gap between the acting rows and `Cancel`.
///
/// **It was `ActivityDetailView`'s private drawing and is lifted here because a second page needed the
/// same menu.** The sleep page's `•••` opens a two-row menu — `Edit` and `Cancel` — and copying eighty
/// lines of scrim, card and row geometry would be two definitions of one look, free to drift on the
/// first re-measurement — the same argument `WeekBarChartView` and `BandMarkGlyph` carry.
///
/// **The grouping is the caller's, and the drawing never branches on an action.** `ActivityOverflowMenu`
/// owns which rows exist and how they are split into cards; this view draws one card per group, in order,
/// and the split is what puts the gap before `Cancel`. A `entry.action == .cancel` branch written here
/// would be a rule the runner cannot see, and it is also why the live fast's one-row menu draws with no
/// change at all.
///
/// **Each card is rounded on all four of its own corners, and the stack draws nothing itself.** The
/// alternative the menu first had — round the stack's two outer ends and leave the inner edges square —
/// put a square corner on the last row of the first card, which is a free end rather than an edge
/// meeting anything. Matching a card's ends to each other is a property of the card, so the radius is
/// this background's and nothing clips.
///
/// **The fill is the card's own bounds and nothing more.** The overlay is bounded by the safe area, so a
/// bottom-aligned card's last row clears the home indicator by construction; a background shape with no
/// `.ignoresSafeArea` fills to that same line and stops, which is what keeps the `Cancel` card its row
/// and only its row.
public struct OverflowMenuOverlay: View {

    /// The rows, split into the cards they are drawn in. See `ActivityOverflowMenu.groups`.
    private let groups: [[ActivityOverflowMenu.Entry]]

    /// What a row does. **The caller closes the menu** — see each page's `perform`, which closes before
    /// switching so every row behaves the same way, `Cancel` included.
    private let onSelect: (ActivityOverflowMenu.Entry.Action) -> Void

    private let onDismiss: () -> Void

    /// Read aloud when the scrim itself is the dismissed-by-double-tap element.
    private let dismissLabel: String

    public init(
        groups: [[ActivityOverflowMenu.Entry]],
        dismissLabel: String = "Dismisses the options",
        onSelect: @escaping (ActivityOverflowMenu.Entry.Action) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.groups = groups
        self.dismissLabel = dismissLabel
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(ActivityOverflowMenu.scrimOpacity)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(dismissLabel))
                .transition(.opacity)

            menu
                .transition(.move(edge: .bottom))
        }
    }

    private var menu: some View {
        VStack(spacing: ActivityOverflowMenu.groupSpacing) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                card(group)
            }
        }
    }

    private func card(_ group: [ActivityOverflowMenu.Entry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().overlay(Theme.cardBorder) }
                row(entry)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: ActivityOverflowMenu.cardCornerRadius)
                .fill(Theme.homeCard)
        }
    }

    /// One row. `frame(maxWidth: .infinity)` is the whole of the row's width, and `rowHeight` is a
    /// constant on the value rather than a padding here so the rows cannot come out at different
    /// heights. `buttonStyle(.plain)` is load-bearing: the default style tints its label and adds a hit
    /// shape, which would recolour the word the entry specifies.
    private func row(_ entry: ActivityOverflowMenu.Entry) -> some View {
        Button {
            onSelect(entry.action)
        } label: {
            Text(entry.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(entry.tint)
                .frame(maxWidth: .infinity)
                .frame(height: ActivityOverflowMenu.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
