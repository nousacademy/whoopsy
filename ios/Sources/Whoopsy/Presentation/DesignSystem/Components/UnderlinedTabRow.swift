import SwiftUI

/// Text tabs with a rule under the selected one — the row the device page drew inline and the profile
/// page now draws too.
///
/// **It was lifted on its second reader**, which is this repo's rule for a shared definition rather
/// than a preference: `SleepStageType.color` left `HypnogramChartView`, and `BandMarkGlyph` and
/// `StrapGlyph` moved into this folder, each when a second screen wanted the same answer. Before the
/// lift, `grep -rn "tracking(0.9)" Sources/` returned exactly one screen, so there was one call site to
/// re-point and no API to negotiate.
///
/// **The rule is drawn on every tab and filled on one**, which is the detail that is easy to "tidy"
/// away. A cleared `Rectangle` and a coloured one are the same height, so the row does not move by a
/// pixel when the selection changes; a conditional `Rectangle` — or a `.overlay` on the selected tab
/// alone — makes the whole block below it jump on every tap.
///
/// ## Non-generic, and that is a language constraint rather than a preference
///
/// `titles` is `[String]` and `selectedIndex` is an `Int`, so a caller hands over its own enum's titles
/// rather than the component knowing about any tab type. That keeps `Tab.allCases.map(\.title)` — the
/// list the suite asserts — at the call site where it can be read. It also has to be this way:
/// **a generic type cannot hold a static stored property**, which is the same constraint that forced
/// `StrapGlyph`'s `discSize`/`signSize` onto the concrete sibling `StrapBadge`, and the layout
/// constants below have to live somewhere a reader can find them.
///
/// ## What a caller still owns
///
/// `.listRowBackground(Color.clear)` and `.listRowInsets(…)` — the two modifiers that make this row sit
/// flush on a `Form`'s own background rather than inside a card. They are **trait-writing** modifiers,
/// and whether a trait written inside a nested view propagates to the `List` row that contains it is
/// not something this repo can verify: the runner has no renderer, and a wrong answer draws a card
/// rather than raising anything. So each call site applies `UnderlinedTabRow.insets` itself, which is
/// one definition of the padding and two places it is attached.
public struct UnderlinedTabRow: View {

    /// The gap between two tabs.
    public static let spacing: CGFloat = 24

    /// The gap between a tab's word and its rule.
    public static let ruleGap: CGFloat = 7

    /// The rule's thickness — the same on a selected tab and an unselected one.
    public static let ruleHeight: CGFloat = 2

    /// The letter-spacing on every tab's word, selected or not.
    public static let tracking: CGFloat = 0.9

    /// The row's insets inside a `Form`'s section, applied by the caller. See the type's note.
    public static let insets = EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16)

    public let titles: [String]
    public let selectedIndex: Int
    public let onSelect: (Int) -> Void

    public init(titles: [String], selectedIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button {
                    onSelect(index)
                } label: {
                    VStack(spacing: Self.ruleGap) {
                        Text(title)
                            .font(.footnote.weight(.bold))
                            .tracking(Self.tracking)
                            .foregroundStyle(index == selectedIndex ? Theme.textPrimary : Theme.textMuted)
                        Rectangle()
                            .fill(index == selectedIndex ? Theme.textPrimary : Color.clear)
                            .frame(height: Self.ruleHeight)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])
            }

            Spacer(minLength: 0)
        }
    }
}
