import SwiftUI

/// An activity's mark, drawn — the one renderer of `ActivityGlyph.Drawing`.
///
/// **It exists so four sites cannot drift.** The mark is drawn on Home's `ACTIVITIES` row, on the
/// activity detail header, on the picker's every row and on the edit sheet's activity row, and each
/// of those frames it differently. Four copies of "one image, or two at `compositeScale` with
/// `compositeSpacingRatio` between them" is four places for the spacing to be got wrong, and a wrong
/// spacing draws a plausible pair that nothing in this repo can see — the same argument that puts the
/// table itself on `ActivityGlyph` rather than inline in a `body`.
///
/// ## It takes no colour
///
/// `BandMarkGlyph`'s rule: the caller applies its own `.foregroundStyle`, which is what keeps the four
/// sites' colours exactly as they were — a tinted chip on Home, `textPrimary` on the detail header, and
/// `textSecondary` in the two list rows. A colour parameter here would be a fifth opinion about what an
/// activity's mark looks like.
///
/// ## Two details are copied from `BandMarkGlyph`, which solved both
///
/// **The baseline guide is load-bearing.** Every caller places this beside a label in an `HStack`, and
/// an image box has no text baseline of its own — so without the guide the mark's own box bottom is
/// aligned and it sits high against the words. Reporting `[.bottom]` as the first-text-baseline puts
/// the mark's foot on the text's foot, which is where a symbol belongs.
///
/// **It is `.accessibilityHidden(true)`.** On Home specifically, an explicit `accessibilityLabel` on the
/// activity row would *replace* the composed announcement and drop the strain figure out of it — so the
/// mark contributes nothing to the label, and the composed announcement is what it was before.
public struct ActivityGlyphLabel: View {

    private let drawing: ActivityGlyph.Drawing
    private let size: CGFloat
    private let weight: Font.Weight

    /// - Parameters:
    ///   - drawing: what to draw, from `ActivityGlyph.mark(for:)`.
    ///   - size: the point size a **single** symbol is drawn at. A composite's two symbols are each
    ///     drawn at `size × ActivityGlyph.compositeScale`, so a pair reads as one mark rather than as
    ///     two — see `ActivityGlyph.drawnWidth(of:atPointSize:)` for the width that produces.
    ///   - weight: the caller's own weight, unchanged for either kind of mark.
    public init(_ drawing: ActivityGlyph.Drawing, size: CGFloat, weight: Font.Weight = .regular) {
        self.drawing = drawing
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        HStack(spacing: size * ActivityGlyph.compositeSpacingRatio) {
            // `id: \.self` is safe here and is not a guess: `Drawing` holds a `primary` and an optional
            // `secondary`, so two identical symbols in one mark are unrepresentable and the ids cannot
            // collide. That is the reason the type has this shape rather than a `symbols: [String]`.
            ForEach(drawing.symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: weight))
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityHidden(true)
    }

    /// Full size for a single symbol, `compositeScale` of it for each half of a pair.
    private var symbolSize: CGFloat {
        drawing.isComposite ? size * ActivityGlyph.compositeScale : size
    }
}
