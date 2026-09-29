import MapKit
import SwiftUI

/// The route a session recorded, drawn on a map with its two figures laid over the bottom of it.
///
/// ## What is left for a view to do here
///
/// Almost nothing, and that is `ActivityRoute`'s design rather than this file's modesty. That type has
/// already dropped the implausible fixes, ordered what is left, decided the path's great-circle length,
/// fitted the box it is drawn in and composed both figures — so everything below is construction:
/// four `Double`s into an `MKCoordinateRegion`, a `[WorkoutRoutePoint]` into an
/// `[CLLocationCoordinate2D]`, and two strings into two `Text`s. The runner has no renderer, so a rule
/// written here would be a rule nothing could assert; there is no rule here to write.
///
/// **MapKit is imported by a `Presentation` file and that is legal**, as it is for `CoreLocation` in
/// `CoreLocationTrackingService`: the ban is on `Domain` and on `Presentation` reaching into `GRDB` or
/// `CoreBluetooth`. Both `Map` and `MapPolyline` were typechecked against the macOS and the iOS
/// targets before this file was written, so no `#if os(iOS)` guards it and the host build links it —
/// which `make build` would have caught loudly if it were otherwise.
public struct ActivityRouteMapView: View {

    /// The path, its frame and its two figures. Never `nil`: this view is constructed only on the
    /// branch where the page has a route, and `ActivityRoute` itself is the absence.
    public let route: ActivityRoute

    /// Which units the caption prints, resolved once at construction rather than read inside the
    /// `body`. See `ActivityRoute.Unit.forLocale`.
    public let unit: ActivityRoute.Unit

    /// The map **surface** — the picture above the caption — when it is not this module's to draw.
    ///
    /// `nil` on every build that has an iOS map, which is every build this package compiles: the
    /// surface is then the `MapKit` map below and this file is exactly what it always was.
    ///
    /// It is non-`nil` only for the **offline** card, whose map is the Mapbox SDK in `App/Map/` — a
    /// module this package never compiles and therefore cannot name. See the initialiser that sets it.
    private let mapSurface: AnyView?

    /// - Parameter unit: defaults to the device's own measurement system. It is a parameter at all so
    ///   that a preview or a future caller can state one, and so that this view holds no locale read.
    public init(route: ActivityRoute, unit: ActivityRoute.Unit = .forLocale(.current)) {
        self.route = route
        self.unit = unit
        self.mapSurface = nil
    }

    /// The same card, drawing a map supplied from outside this module.
    ///
    /// ## Why the *card* takes the surface rather than the offline implementation taking the card
    ///
    /// The offline card has to be this card: the user's ask is that a route reads the same whether the
    /// phone has signal or not, and the caption, the corner radius, the height split, the accessibility
    /// sentence and the two figures underneath are what "the same" means. A second card in `App/Map/`
    /// would restate all of them — and `App/Map/` is the one module in this repo that **neither build
    /// path here compiles**, so every one of those restated constants would be checked by nothing until
    /// it was wrong on a phone. So the seam is at the picture: `Presentation` keeps the card, and the
    /// unverifiable module supplies one `AnyView` that draws inside a frame the card has already fixed.
    ///
    /// **The surface is handed a height, not asked for one.** `map` applies
    /// `mapHeight - captionHeight` to whatever comes back, so an implementation has no size to state and
    /// no way to disagree with the card about the split. `ActivityRouteMapView`'s own `Map` takes its
    /// size the same way.
    ///
    /// **The caption is drawn from `route` and `unit` and never from the surface**, so the two cards'
    /// figures are one computation rather than two that agree today.
    ///
    /// - Parameter mapSurface: the map, already configured. `AnyView` for the reason
    ///   `OfflineMapRendering.map(route:unit:regionID:)` returns one — the concrete type is not nameable
    ///   here.
    public init(
        route: ActivityRoute,
        unit: ActivityRoute.Unit = .forLocale(.current),
        mapSurface: AnyView
    ) {
        self.route = route
        self.unit = unit
        self.mapSurface = mapSurface
    }

    /// The label above the map, and the heading the page's other blocks already use — the row above it
    /// is labelled `Typical range` the same way.
    public nonisolated static let title = "Route"

    /// The **card's** height — the map and the caption under it together. A `Map` has no intrinsic size,
    /// so something has to state one.
    ///
    /// The reference's own map is roughly a third of its screen; at this page's 16 pt gutter and a
    /// phone's width that lands near 220 pt, which is tall enough to read a route's shape in.
    ///
    /// **The caption is drawn below the map rather than laid over it, and that is a measured correction
    /// rather than a preference.** An overlay claims a fixed slice of a fixed height, while the path's
    /// own bottom margin is `spanPadding`'s share of a frame whose span the map is free to widen — so
    /// the two are set against each other and the flag loses. Measured on the iOS 26.5 simulator against
    /// a real recorded route: the polyline's lowest drawn pixel sat at 171.3 pt of the card's 220 and
    /// the caption's top edge at 172.0, so the finish marker — centred on that point and 19 pt tall —
    /// was drawn *under* an 86%-opaque bar, its title with it. Dividing the height instead makes the two
    /// independent: the map draws into its own box, and the figures sit below it rather than on it.
    private static let mapHeight: CGFloat = 220

    /// The caption bar's height: two 8 pt paddings around a 17 pt figure and the 9 pt word under it.
    ///
    /// Stated rather than left to the layout because the *map's* height is the subtraction's result, and
    /// a `Map` with no intrinsic size will not negotiate for it. The bar is free to exceed this — the
    /// stack gives it its own height and the card grows by the difference — so a font metric that moves
    /// makes the card a little taller rather than clipping a figure.
    private static let captionHeight: CGFloat = 48

    private static let cornerRadius: CGFloat = 16

    /// The path's width. Wide enough to read over a map's own roads, which are drawn at about a third
    /// of this, and rounded at both ends so a route that doubles back does not draw a mitre.
    ///
    /// **The four constants from here to `finishMarkerSize` are `public`, and that is the one widening
    /// this card's surface seam needed.** The offline surface in `App/Map/` draws the same path over a
    /// different SDK, and a second copy of `4`/`15`/`3`/`19` there would be four numbers nothing in this
    /// package compiles — the drift `Theme` exists to prevent, moved to the one file that cannot be
    /// built here. They are the *surface's* constants rather than the card's: the height split, the
    /// corner radius and the caption stay `private` because the surface is handed a frame and never
    /// states one.
    public static let lineWidth: CGFloat = 4

    public static let startMarkerSize: CGFloat = 15

    /// The ring around the start dot, in `Theme.routeMarker` — the ink that separates a mark from the
    /// map under it.
    public static let startMarkerRingWidth: CGFloat = 3

    /// The finish flag's point size, extracted from the literal it used to be so the offline surface
    /// draws a flag the same size rather than one that merely looks close.
    public static let finishMarkerSize: CGFloat = 19

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(Self.title)

            map
        }
    }

    // MARK: - The drawing

    private var map: some View {
        VStack(spacing: 0) {
            surface
                .frame(height: Self.mapHeight - Self.captionHeight)

            caption
        }
        // The clip wraps both halves, so the caption's bottom corners are rounded to the map's top
        // ones by one shape rather than by two that have to be kept in step — and it wraps whichever
        // surface is drawn, which is what keeps the offline card's corners from being a second shape
        // that has to be kept in step with this one.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // The map is a drawing, and a `Map`'s own accessibility tree is a set of place names that say
        // nothing about this session. The card's whole accessible content is the sentence, which
        // `ActivityRoute` composes so the runner can assert it.
        //
        // It is applied to the card rather than to the `MapKit` map alone so that the offline surface
        // is described by the same sentence — a route is a route either way, and which SDK drew it is
        // not something a screen reader should have to say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.spokenSummary(in: unit))
    }

    /// The picture above the caption: this module's `MapKit` map, or the one handed in.
    ///
    /// The height is applied outside this property and not inside either branch, so neither surface
    /// gets to state its own and the card's split is one number in one place.
    @ViewBuilder
    private var surface: some View {
        if let mapSurface {
            mapSurface
        } else {
            liveMap
        }
    }

    /// **The map is not interactive, and that is a decision rather than an omission.** Panning or
    /// zooming inside a card inside a `ScrollView` is a gesture conflict — the drag that means *move
    /// the map* to one view means *scroll the page* to the other, and SwiftUI resolves it by whichever
    /// recogniser wins, so the same swipe moves the map on one part of the screen and the page on
    /// another. The reference's own map is static too, and this app has no full-screen map page for a
    /// tap to open, so there is nothing an interactive card would lead to. A control with no
    /// destination is the thing this repo's no-control-without-a-destination rule forbids, and an
    /// interactive map with no destination is that same fault with a gesture instead of a tap.
    ///
    /// **The style excludes points of interest** so the polyline is the only thing competing for
    /// attention in a 220 pt window. The map is drawn dark because the page sets
    /// `.preferredColorScheme(.dark)` and `Map` reads the environment — the app's own
    /// near-black rather than a light map inside a dark card, which is what the reference has for the
    /// same reason.
    ///
    /// **There is no share button**, although the reference has one. It is Apple Maps' own control and
    /// it has no destination here: this app shares nothing, and a button that opened a share sheet for
    /// a map of the user's own run would be the first thing on this page that leaves the app.
    ///
    /// **The offline surface owes this rule too, and it is the surface's own file that states it.**
    /// `MapKit` settles it with `interactionModes: []`; Mapbox has no equivalent parameter and turns
    /// each gesture off by name. That difference is why the rule is repeated rather than inherited —
    /// see `MapboxRouteMapView` in `App/Map/`, which is the one place it can be broken without anything
    /// in this package noticing.
    private var liveMap: some View {
        Map(initialPosition: position, interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(
                    Theme.routeLine,
                    style: StrokeStyle(
                        lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))

            // Two marks and not a mark at each end of one kind: where a route *began* and where it
            // *ended* are different facts, and the reference draws them differently — a dot and a
            // checkered flag — so a reader who has seen one of these cards can read another.
            // `annotationTitles` is a **`MapContent`** modifier and not a `Map` view one — it is
            // declared on `MapContent` in the `_MapKit_SwiftUI` overlay — so there is no way to
            // apply it once to the whole builder's product and it goes on each annotation. A
            // `MapContent` builder has no `Group` to hang it on either.
            Annotation(Self.startLabel, coordinate: startCoordinate) {
                Circle()
                    .fill(Theme.routeLine)
                    .frame(width: Self.startMarkerSize, height: Self.startMarkerSize)
                    .overlay(
                        Circle().strokeBorder(
                            Theme.routeMarker, lineWidth: Self.startMarkerRingWidth))
            }
            .annotationTitles(.hidden)

            Annotation(Self.finishLabel, coordinate: finishCoordinate) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: Self.finishMarkerSize, weight: .bold))
                    .foregroundStyle(Theme.routeMarker)
                    // A white flag on a pale patch of map is a flag nobody sees. The shadow is what
                    // makes one ink work over every kind of ground the style can draw.
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    // MARK: - The two figures

    /// The bar under the map, at the card's foot: `13.2 mi DISTANCE`, `9.9 mph SPEED`.
    ///
    /// **Two cells, and the reference has three.** The third is `ELEVATION`, and this app cannot
    /// populate it at any layer — `WorkoutRoutePoint` has no altitude, `workout_route_points` has no
    /// column, and nothing here reads `CLLocation.altitude`. It is **dropped rather than drawn as a
    /// `—`**, because a dash beside two real figures claims this app has an altimeter and that it
    /// failed. `ActivityRoute`'s own comment carries the argument in full.
    ///
    /// **The speed cell is dropped when there is none**, on the same rule: a route whose every fix
    /// carries one instant has no span to divide by, so the distance cell takes the bar alone.
    private var caption: some View {
        HStack(spacing: 0) {
            captionCell(value: route.distanceText(in: unit), label: Self.distanceLabel)

            if let speed = route.averageSpeedText(in: unit) {
                captionCell(value: speed, label: Self.speedLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.routeOverlayFill)
    }

    /// One figure of the caption: the number, then the word for what it is.
    ///
    /// `frame(maxWidth: .infinity)` on each cell is what divides the bar evenly however many cells
    /// there are, so a route with no speed draws one figure over the whole width rather than one
    /// figure over half of it with an empty half beside it.
    private func captionCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()

            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The two words under the figures, emphasised the way this page's every other caption is — the
    /// `DURATION` pair on the `TYPICAL RANGE` row above is set in the same style. They are constants
    /// rather than literals in the `body` for the reason the page's other strings are.
    private nonisolated static let distanceLabel = "DISTANCE"
    private nonisolated static let speedLabel = "SPEED"

    /// The two annotations' titles — **and neither is drawn.**
    ///
    /// `.annotationTitles(.hidden)` on the map is what suppresses the drawing, and the reason is the
    /// reference: it marks a route with a dot and a checkered flag and sets no word beside either.
    /// Measured before that modifier went on, both words were on the map, and `Finish` — the marker it
    /// belongs to being the path's southern extreme — was drawn inside the caption bar and showed
    /// through its 86% fill over the caption's own figures.
    ///
    /// They are kept as words rather than deleted or emptied because `Visibility.hidden` is a
    /// *display* modifier: it stops the drawing while leaving each annotation described by a name, and
    /// an empty string would leave the two marks anonymous in the view tree for no gain.
    private nonisolated static let startLabel = "Start"
    private nonisolated static let finishLabel = "Finish"

    // MARK: - Construction

    /// `ActivityRoute.region`'s four numbers as MapKit's own type. This is the one place the two meet,
    /// and it is the reason that type is four `Double`s: the framing rule is arithmetic the suite
    /// asserts against literals, while this line is a construction with no rule in it.
    private var position: MapCameraPosition {
        let region = route.region
        return .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: region.centerLatitude, longitude: region.centerLongitude),
                span: MKCoordinateSpan(
                    latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)))
    }

    private var coordinates: [CLLocationCoordinate2D] {
        route.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private var startCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: route.start.latitude, longitude: route.start.longitude)
    }

    private var finishCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: route.finish.latitude, longitude: route.finish.longitude)
    }
}
