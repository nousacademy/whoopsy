import SwiftUI

/// The map cards' expansion control, and the surface it opens.
///
/// ## Expansion changes the frame and nothing else
///
/// The full-screen map draws **the same surface the card draws** — the card already holds it, as its
/// own `MapKit` `Map` or as the `AnyView` the `App/Map/` seam handed in — so there is no second map
/// implementation, no second framing rule and no second set of constants. What changes is the frame:
/// the card's 172 pt of picture becomes the screen.
///
/// **The gestures do change, and that is the second thing expansion is for.** The cards are inert
/// because a map panned inside a scrolling page steals the page's drag (see
/// `ActivityRouteMapView.liveMap`); the cover has no page behind it, so the same route is drawn on a
/// map that pans and zooms. **Those two and no others** — rotation and tilt stay off, because a map
/// turned by a drifting pinch draws the route at an angle and a route read at an angle is read wrong.
/// `MapKit` takes it as `interactionModes: [.pan, .zoom]`; the offline SDK's set is
/// `MapboxSetup.expandedGestures`, decided in `App/Map/` and handed in as the card's
/// `expandedMapSurface` — the two surfaces exist because that module's gesture options cannot be set
/// from this package.
///
/// **The close control is the only chrome.** The route's caption is not redrawn — it is a figure
/// under a card, and a full-screen map has no card — and the two maps' attribution stays the SDK's
/// own ornament inside the surface, which this view neither covers nor replaces.
public struct MapFullScreenView: View {

    /// The surface, already configured by the card that owns it. `AnyView` for the offline case's
    /// reason: `App/Map/`'s map is a type this package cannot name.
    private let content: AnyView

    /// The sentence a screen reader hears for the map — the card's own, threaded through rather than
    /// composed here, because the route and the area have different things to say and this view has
    /// no way to tell which it was handed.
    private let spoken: String

    @Environment(\.dismiss) private var dismiss

    public init(content: AnyView, spoken: String) {
        self.content = content
        self.spoken = spoken
    }

    /// The two-corner arrows the card draws, and the cross that closes the expanded map.
    ///
    /// **`arrow.up.left.and.arrow.down.right`, not `.expand`** — the latter is a chevron pair that
    /// reads as "open a list", and the user's own words for this control were "two corner arrows, that
    /// are used for expansion". Both symbols are old enough for this app's iOS 17 floor, which is the
    /// check `ActivityGlyph` documents and the one a name added here would need.
    public nonisolated static let expandSymbol = "arrow.up.left.and.arrow.down.right"

    public nonisolated static let closeSymbol = "xmark"

    /// The controls' spoken names. Kept here rather than inline so §19 can pin them, and so the two
    /// cards that draw the expand button cannot drift apart in what they call it.
    public nonisolated static let expandLabel = "Expand map"

    public nonisolated static let closeLabel = "Close map"

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // The app's own near-black behind the map, so a surface that has not drawn its first frame
            // — or a tile region that ended at the downloaded circle's edge — shows the page's
            // background rather than a white flash.
            Theme.homeBackground.ignoresSafeArea()

            content
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: Self.closeSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.routeMarker)
                    .frame(width: 34, height: 34)
                    .background(Theme.routeOverlayFill, in: Circle())
                    .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.closeLabel)
            .padding(16)
        }
        // The map itself is a drawing and says nothing; the sentence is the whole accessible content,
        // exactly as on the card. `.contain` so the close button stays reachable beside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }
}

/// The expand control the two map cards overlay on their picture.
///
/// A sibling of `MapFullScreenView` rather than a member, because it belongs to the **card** — it is
/// drawn inside the card's clipped frame and opens the cover — while the view above is what the cover
/// shows. The two share their constants through `MapFullScreenView`'s statics.
struct MapExpandButton: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: MapFullScreenView.expandSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.routeMarker)
                .frame(width: 30, height: 30)
                .background(Theme.routeOverlayFill, in: Circle())
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MapFullScreenView.expandLabel)
        .padding(8)
    }
}

extension View {

    /// Presents the expanded map, by the platform's own full-screen idiom.
    ///
    /// **`fullScreenCover` does not exist on macOS**, and these cards are built for both — `make build`
    /// compiles them, which is the same constraint that keeps `.toolbar(_:for: .tabBar)` out of
    /// `HomeDashboardView`. The Mac build takes a sheet: the control is reachable there, the "full
    /// screen" is a window-sized sheet, and nothing else about the card changes.
    @ViewBuilder
    func mapExpansion(isPresented: Binding<Bool>, content: @escaping () -> AnyView) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
