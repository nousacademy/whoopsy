import CoreLocation
import MapboxMaps
import SwiftUI
import Whoopsy

/// The downloaded area, drawn by Mapbox from tiles that are on disk — the area card's picture.
///
/// ## The route surface minus the path
///
/// This is `MapboxRouteMapView` for a session that recorded no route: the same style, the same
/// viewport ceiling, the same shared gesture set, and the same two-point line used only to state the
/// frame `ActivityOfflineArea` fitted. What is gone is the polyline and the two marks, because there is
/// no path to draw — the card exists so the *ground* is visible, not a movement across it.
///
/// It is a separate file rather than a flag on the route surface because the two take different values
/// (`ActivityRoute` and `ActivityOfflineArea`) and share nothing but the framing trick; a single view
/// with an optional route would make the no-route case a mode of the route card rather than its own
/// card. The card itself — label, height, corners, accessibility sentence — stays in `Presentation`, as
/// on the route surface; see `ActivityOfflineAreaMapView.init(area:mapSurface:)`.
///
/// **`App/Map/` is compiled by neither `make build` nor `make test`**, so everything here is checked
/// only by the Xcode app target. That is the reason the constants worth sharing live in
/// `MapboxSetup` and `ActivityOfflineArea` rather than being restated: a number written here is a
/// number nothing on a development machine checks until it is wrong on a phone.
struct MapboxAreaMapView: View {

    /// Framed by `ActivityOfflineArea` — already plausible-checked and sized to fit inside the
    /// downloaded circle. This view adds no rule to it.
    let area: ActivityOfflineArea

    var body: some View {
        Map(initialViewport: .overview(geometry: frameGeometry, maxZoom: MapboxSetup.maximumZoom))
            .mapStyle(.outdoors)
            .gestureOptions(MapboxSetup.cardGestures)
    }

    // MARK: - Construction

    /// The area's box, as the two-point line `Viewport.overview` measures.
    ///
    /// `MapboxRouteMapView.frameGeometry`'s rule, one field changed: a two-point line between the box's
    /// corners has exactly that box as its bounding box, so this surface and the `MapKit` card are framed
    /// by the same four numbers rather than by two framings that agree today. The line is never drawn —
    /// this map has no `PolylineAnnotation`.
    private var frameGeometry: Geometry {
        let region = area.region
        let halfLatitude = region.latitudeSpan / 2
        let halfLongitude = region.longitudeSpan / 2

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
}
