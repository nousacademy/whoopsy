import SwiftUI

/// The one place the *strap* is named and drawn, so Home's badge and the device page's header cannot
/// disagree about what a strap looks like.
///
/// **This rule existed as a comment before it existed as a definition, and it had already drifted.**
/// Home's badge drew `capsule.portrait` and the device page's header drew
/// `sensor.tag.radiowaves.forward.fill`, while that header's own comment asserted it drew *"the same
/// glyph Home's badge draws"*. Nothing caught it and nothing could: a wrong symbol draws a different
/// picture rather than an error, and no build, test or screenshot of the other screen can see it. The
/// user then asked for the capsule on the device page too, which is what turned the claim into a
/// component.
///
/// The constants live here rather than on `StrapGlyph` because **a generic type cannot hold a static
/// stored property** — *"static stored properties not supported in generic types"*, which is a compile
/// error rather than a warning. The badge has to be generic: Home badges a connection dot, the device
/// page badges a plus, and everything *around* the badge is what the two share.
public enum StrapMark {
    /// The symbol that means *strap* across this app.
    public static let symbol = "capsule.portrait"

    /// The thickness of the ring that knocks a hole in whatever the badge overlaps.
    public static let ringWidth: CGFloat = 1.5
}

/// The strap's mark, with a badge sitting *over* its upper-right corner.
///
/// **The badge is placed by the alignment alone and must not carry an `offset`** — that is measured
/// rather than preferred, and the user is the one who corrected it on Home. An offset is applied
/// against the glyph's *frame*, and the frame is not the drawing: for this symbol the ink sits inside
/// it on both the right and the top, so a `offset(x: 3, y: -3)` that looks like "the corner" in the
/// arithmetic puts the badge's centre outside the ink's right edge and above its top, and what the
/// reader sees is a mark attached to the outside of the capsule's shoulder rather than one on it.
/// Measured at Home's 12 pt badge, the ink sits **1.5 pt inside the frame on both edges**; without the
/// offset the badge's centre falls inside both, and a 7 pt dot covers the corner and reaches past it on
/// either side.
///
/// The badge is ringed in `surface` — the colour *behind* the mark — so it knocks a hole in the outline
/// it crosses instead of merging with it. An unringed badge drawn onto the stroke is a blob at the
/// sizes this is read at.
public struct StrapGlyph<Badge: View>: View {
    private let size: CGFloat
    private let surface: Color
    private let badge: Badge

    /// - Parameters:
    ///   - size: the glyph's point size, which is the whole of its geometry.
    ///   - surface: the colour behind the mark, used for the badge's knockout ring. It must be the
    ///     surface the glyph is drawn *on*, not the glyph's own ink.
    ///   - badge: what sits on the upper-right corner, at whatever size it declares for itself. The
    ///     mark does not size it: a dot and a plus disc are different things and a shared size would
    ///     make one of them wrong.
    public init(size: CGFloat, surface: Color, @ViewBuilder badge: () -> Badge) {
        self.size = size
        self.surface = surface
        self.badge = badge()
    }

    public var body: some View {
        Image(systemName: StrapMark.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .overlay(alignment: .topTrailing) {
                badge.overlay(Circle().strokeBorder(surface, lineWidth: StrapMark.ringWidth))
            }
    }
}
