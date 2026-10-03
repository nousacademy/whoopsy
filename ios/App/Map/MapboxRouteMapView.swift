import CoreLocation
import MapboxMaps
import SwiftUI
import Whoopsy

/// The route's polyline, drawn by Mapbox from tiles that are on disk.
///
/// ## What this is, and what it deliberately is not
///
/// **This is the picture and not the card.** `ActivityRouteMapView` owns the card — its height split,
/// its corner radius, its caption, its accessibility sentence and its two figures — and hands whatever
/// comes back from here a frame it has already fixed. So there is no `.frame(height:)` below, no
/// caption, and no `Theme.routeOverlayFill`: the caption is `Presentation`'s and the offline card draws
/// the same one, from the same `ActivityRoute`, as the `MapKit` card does.
///
/// That split is not tidiness. `App/Map/` is the one module in this repository that **neither
/// `make build` nor `make test` compiles** — it is excluded from the SwiftPM target and exists only in
/// the Xcode app target, because Mapbox is an iOS-only binary artifact this package cannot depend on.
/// Every constant restated here would be checked by nothing until it was wrong on a phone, so the rule
/// is that this file restates as little as it possibly can: it takes the four surface constants from
/// `ActivityRouteMapView` as `public static let`s rather than copying their values, and it states
/// nothing else about the card.
///
/// ## The map is not interactive, and here that costs a paragraph rather than a parameter
///
/// `ActivityRouteMapView.liveMap` settles this with `interactionModes: []` — one argument, whole
/// gesture set gone. Mapbox has no equivalent, so every gesture is turned off **by name** in
/// `GestureOptions`, and the failure mode of forgetting one is a map that pans inside a page that also
/// scrolls: the same swipe moves the map on one part of the screen and the page on another.
///
/// **`GestureOptions` and not `.allowsHitTesting(false)`, and the difference is an obligation.**
/// Mapbox's logo and its attribution button are drawn as ornaments *inside* the map view, and
/// "Improve this map" is a link the licence requires to be reachable. Disabling hit testing would leave
/// it drawn but inert — the attribution present and the link dead — so the gestures are disabled
/// individually and the ornaments are left alone. They are visible by default, which is why nothing
/// below configures `OrnamentOptions`: the default arrangement already satisfies the attribution
/// requirement, and a `scaleBar` or `compass` added "for completeness" would be a change made blind.
///
/// **One consequence, recorded rather than fixed.** The card applies
/// `.accessibilityElement(children: .ignore)` so that a screen reader hears `ActivityRoute`'s own
/// sentence rather than a list of place names, and that also swallows the attribution button from the
/// accessibility tree. The obligation Mapbox's terms state is that the mark be *displayed*, which it
/// still is; a screen-reader user loses the link. Worth knowing before someone reports it as a bug.
struct MapboxRouteMapView: View {

    /// Built by `ActivityRoute` — already filtered, ordered and framed. This view adds no rule to it.
    let route: ActivityRoute

    var body: some View {
        Map(initialViewport: .overview(geometry: frameGeometry, maxZoom: MapboxSetup.maximumZoom)) {
            // **The group is here for `lineCap` and for nothing else.** `PolylineAnnotation` carries
            // `lineJoin` but no `lineCap` — that member is declared on `PolylineAnnotationGroup` alone —
            // so a bare annotation can only ever draw Mapbox's default butt cap at the polyline's two
            // ends, where the `MapKit` card strokes `lineCap: .round`. Wrapping one annotation in a group
            // is what makes the two surfaces' strokes identical rather than nearly identical.
            //
            // The difference is invisible today: the line is `lineWidth` (4) wide and both its ends sit
            // underneath the 15 pt start dot and the 19 pt finish flag. It is written the faithful way
            // anyway, because "the marks cover it" is a fact that stops being true the moment either
            // marker is resized, and a cap is not a property anyone would think to re-check then.
            PolylineAnnotationGroup {
                PolylineAnnotation(lineCoordinates: coordinates)
                    .lineColor(UIColor(Theme.routeLine))
                    .lineWidth(Double(ActivityRouteMapView.lineWidth))
            }
            .lineCap(.round)
            .lineJoin(.round)

            // The same two marks the `MapKit` card draws, at the same sizes, for the reason the card's
            // own comment gives: where a route *began* and where it *ended* are different facts, and a
            // reader who has seen one of these cards should be able to read the other. `MapViewAnnotation`
            // anchors its content at the coordinate's centre by default, which is where `MapKit`'s
            // `Annotation` puts it too.
            MapViewAnnotation(coordinate: startCoordinate) {
                Circle()
                    .fill(Theme.routeLine)
                    .frame(
                        width: ActivityRouteMapView.startMarkerSize,
                        height: ActivityRouteMapView.startMarkerSize)
                    .overlay(
                        Circle().strokeBorder(
                            Theme.routeMarker, lineWidth: ActivityRouteMapView.startMarkerRingWidth))
            }

            MapViewAnnotation(coordinate: finishCoordinate) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: ActivityRouteMapView.finishMarkerSize, weight: .bold))
                    .foregroundStyle(Theme.routeMarker)
                    // The card's own rule, and the same reasoning: a white flag on a pale patch of map is
                    // a flag nobody sees, and one shadow is what makes one ink work over every ground the
                    // style can draw.
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            }
        }
        .mapStyle(.outdoors)
        .gestureOptions(
            GestureOptions(
                panEnabled: false,
                pinchEnabled: false,
                rotateEnabled: false,
                simultaneousRotateAndPinchZoomEnabled: false,
                pinchZoomEnabled: false,
                pinchPanEnabled: false,
                pitchEnabled: false,
                doubleTapToZoomInEnabled: false,
                doubleTouchToZoomOutEnabled: false,
                quickZoomEnabled: false))
    }

    // MARK: - Construction

    /// The route's padded box, as the two-point line `Viewport.overview` measures.
    ///
    /// ## Why the framing is derived from `route.region` rather than from the path
    ///
    /// `.overview(geometry:)` frames whatever geometry it is handed, with padding of its own. Handing it
    /// the polyline would therefore frame the *path* — while the `MapKit` card frames
    /// `ActivityRoute.region`, which is the path's box widened by `spanPadding` (1.4) and floored at
    /// `minimumSpanDegrees` (0.004°). Two cards framing the same route by two different rules is how the
    /// offline card comes to show a visibly tighter crop of the same run.
    ///
    /// A two-point line between the box's corners has exactly that box as its bounding box, so both
    /// surfaces are framed by the same four numbers — and the padding `overview` would add is left at
    /// its default of zero, because the padding is already *in* `route.region`. This line is never drawn;
    /// only `PolylineAnnotation` above is.
    private var frameGeometry: Geometry {
        let region = route.region
        let halfLatitude = region.latitudeSpan / 2
        let halfLongitude = region.longitudeSpan / 2

        // `Turf.LineString`'s only array initialiser is unlabelled — `init(_ coordinates:)` — which is
        // why this reads `LineString([...])` rather than the `coordinates:` form the property on the
        // type would suggest.
        return .lineString(
            LineString([
                CLLocationCoordinate2D(
                    latitude: region.centerLatitude - halfLatitude,
                    longitude: region.centerLongitude - halfLongitude),
                CLLocationCoordinate2D(
                    latitude: region.centerLatitude + halfLatitude,
                    longitude: region.centerLongitude + halfLongitude),
            ]))
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
