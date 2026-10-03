import SwiftUI

/// The typical-range band mark, drawn small enough to sit in a line of text as its key.
///
/// **It is a legend, not decoration.** The mark it stands for is a filled region with a dashed rule
/// down each of its sides, drawn by `TypicalRangeBar` — a band's edges bounding one span. A key has to
/// describe the mark it unlocks, so this is the same two ingredients at 16 pt: the fill and the two
/// rules, with `BandEdges` doing the stroking. It is deliberately **not** a tiny bar with the mark
/// drawn on it, which would be a picture of the chart rather than of the mark.
///
/// **The baseline guide is load-bearing.** Callers place it in an `HStack(alignment: .firstTextBaseline)`
/// beside a label, and a 16 pt square has no text baseline of its own — so without the guide the
/// glyph's own box bottom would be aligned and it would sit high against the words. Reporting
/// `[.bottom]` as the first-text-baseline puts its foot on the text's foot, which is where a bullet or
/// a symbol belongs.
///
/// **The size is a parameter because two screens draw it at one size each.** `SleepTypicalRangeCard`
/// draws it as the key to its bar's header and the activity page's `TYPICAL RANGE` row draws it as its
/// section icon; both want the same 16 pt, and the parameter exists so that neither has to reach for a
/// second copy of the drawing to get it.
public struct BandMarkGlyph: View {
    private let size: CGFloat

    public init(size: CGFloat = 16) {
        self.size = size
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.bandMarkFill)

            BandEdges(inset: 0.75)
                .stroke(
                    Theme.bandMarkEdge,
                    style: StrokeStyle(lineWidth: 1.5, dash: TypicalRangeBar.markDash))
        }
        .frame(width: size, height: size)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityHidden(true)
    }
}
