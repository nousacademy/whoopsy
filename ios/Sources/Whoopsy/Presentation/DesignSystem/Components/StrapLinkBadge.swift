import SwiftUI

/// What Home's strap badge draws: the link dot, or a charging bolt.
///
/// **The bolt is a reading, not decoration.** `WhoopDevice.isCharging` is written by the strap's own
/// `CHARGING_ON`/`CHARGING_OFF` events (numbers 7 and 8, mapped in `StrapEventDecoder`), so the badge
/// changes when the strap says it is charging and not when the app guesses from a battery figure — the
/// level characteristic carries no charging flag, and the event's own layout is the only source.
///
/// **The bolt only replaces a *linked* strap's dot**, and that is the whole reason this is a function
/// rather than an `if` at the call site. A disconnected strap's dot is yellow and means "this link is
/// gone"; drawing a charging bolt in its place would hide the one fact the dot exists to carry. A
/// strap on the charger but out of range therefore reads disconnected — which is true — and the
/// charging state it last reported is still there, so it appears the moment the link returns.
///
/// **The bolt gets a disc of the surface colour behind it.** `StrapGlyph` knocks a hole in the mark
/// with a ring in the surface colour, and a transparent badge would let the capsule's own stroke show
/// between the bolt and that ring. The disc is the same surface the glyph is drawn on, so the badge
/// reads as one sticker rather than a symbol floating over an outline.
public struct StrapLinkBadge: View {

    /// The link dot's diameter. Unchanged from the dot Home has always drawn.
    public static let dotDiameter: CGFloat = 7

    /// The charging badge's diameter — the disc, not the bolt.
    ///
    /// Larger than the dot because a bolt needs a frame to sit in: at `dotDiameter` its tips would
    /// meet the `StrapGlyph` knockout ring, which is drawn inside the badge's own frame.
    public static let chargingDiameter: CGFloat = 11

    /// `bolt.fill` is iOS 13, so it clears the 17.0 deployment target — unlike the `figure.*` family
    /// `CLAUDE.md` warns about. §14 asserts the name is non-empty, which is the only thing that sees
    /// a typo.
    public static let chargingSymbol = "bolt.fill"

    /// The one colour a charging badge is drawn in.
    ///
    /// Borrowed from the verdict scale for `WhoopConnectionState.linkColor`'s reason: `Theme` has no
    /// link token, and a second name for one value is the drift the dedicated tokens exist to prevent.
    public static let chargingColor: Color = Theme.recoveryYellow

    public let state: WhoopConnectionState
    public let isCharging: Bool

    /// The colour behind the mark — `StrapGlyph`'s `surface`, passed on so the disc and the knockout
    /// ring are the same colour.
    public let surface: Color

    public init(state: WhoopConnectionState, isCharging: Bool, surface: Color) {
        self.state = state
        self.isCharging = isCharging
        self.surface = surface
    }

    /// Whether this pair draws the bolt. **A pure function so §14 can assert it without a renderer** —
    /// the runner has no `View` body, and this is the rule rather than the drawing.
    public static func showsCharging(isCharging: Bool, state: WhoopConnectionState) -> Bool {
        isCharging && state.isLinked
    }

    public var showsCharging: Bool {
        Self.showsCharging(isCharging: isCharging, state: state)
    }

    public var body: some View {
        if showsCharging {
            ZStack {
                Circle().fill(surface)
                Image(systemName: Self.chargingSymbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Self.chargingColor)
            }
            .frame(width: Self.chargingDiameter, height: Self.chargingDiameter)
            .accessibilityHidden(true)
        } else {
            Circle()
                .fill(state.linkColor)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
        }
    }
}
