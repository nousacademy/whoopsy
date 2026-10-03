import SwiftUI

/// One recessed track holding equal halves, with the selected half raised under a pill — the profile
/// page's `UNITS` control.
///
/// **It replaced SwiftUI's `.pickerStyle(.segmented)`, for the reason that replaced the device page's
/// tab `Picker` with `UnderlinedTabRow`.** The stock control draws the platform's own track, radius and
/// selection chrome at the platform's own 32 pt height, and the reference draws none of them: it draws a
/// well in the page with a raised pill inside it, a head taller than the stock control and rounder at
/// every corner. Nothing about the *behaviour* moved — the two titles, the tap-to-persist and the
/// binding the caller supplies are all unchanged, and the value behind it is still
/// `AppPreferences.usesMetricUnits` rather than anything this view knows about.
///
/// ## The pill is drawn on every segment and filled on one
///
/// That is `UnderlinedTabRow`'s rule and it is load-bearing here for a second reason on top of the first.
/// A cleared shape and a filled one are the same size, so nothing moves when the selection changes; and
/// because each segment is `.frame(maxWidth: .infinity)` whether or not it is selected, the two words
/// stay at the same x on both sides of a tap. The other way to build this — a `ZStack` with one pill
/// *moved* to the selection — has to know a segment's width to place it, which means a `GeometryReader`,
/// which means the track can no longer state its own height.
///
/// ## Non-generic, on `UnderlinedTabRow`'s language constraint
///
/// `titles` is `[String]` and `selectedIndex` is an `Int`, so a caller hands over its own enum's words
/// rather than the component knowing about any unit type — which keeps `Unit.displayOrder.map(\.title)`
/// at the call site where it can be read. It also has to be this way: **a generic type cannot hold a
/// static stored property**, and the four layout constants below have to live somewhere a reader can
/// find them. That is the same constraint that put `StrapGlyph`'s sizing on `StrapBadge`.
public struct SegmentedPillControl: View {

    /// The height of one segment, and so half the control: the track measures this plus two
    /// `trackInset`s.
    ///
    /// **Taller than the platform's own segmented control, and a touch taller than the field boxes
    /// around it.** The reference's control is the taller of the two, and clearing the 40 pt boxes on
    /// either side is what makes this read as *the* control on the pane rather than as a seventh field
    /// in the column — which matters because it is the only row on `BIOMETRICS` that is a preference rather
    /// than a fact about the body.
    public static let segmentHeight: CGFloat = 38

    /// The track's corner radius.
    public static let trackRadius: CGFloat = 10

    /// How far the two segments sit inside the track.
    public static let trackInset: CGFloat = 4

    /// **Concentric with the track rather than picked.** The pill sits `trackInset` inside the track, so
    /// a radius that is not `trackRadius − trackInset` is a radius the two shapes do not share — which
    /// leaves a sliver of track showing at each of the pill's corners and reads as a misalignment at
    /// every tap rather than as a radius that is slightly wrong.
    public static let pillRadius: CGFloat = trackRadius - trackInset

    /// The letter-spacing on both words, selected or not.
    ///
    /// The same number as `UnderlinedTabRow.tracking` and the page's own `eyebrow`, so the tabs, the
    /// field names and this control's two segments share one letter treatment rather than three that
    /// agree today.
    public static let tracking: CGFloat = 0.9

    public let titles: [String]
    public let selectedIndex: Int
    public let onSelect: (Int) -> Void

    public init(titles: [String], selectedIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button {
                    onSelect(index)
                } label: {
                    Text(title)
                        .font(.footnote.weight(.bold))
                        .tracking(Self.tracking)
                        .foregroundStyle(index == selectedIndex ? Theme.textPrimary : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.segmentHeight)
                        .background {
                            RoundedRectangle(cornerRadius: Self.pillRadius, style: .continuous)
                                .fill(index == selectedIndex ? Theme.segmentedPill : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])
            }
        }
        .padding(Self.trackInset)
        .background(
            Theme.segmentedTrack,
            in: RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous))
    }
}
