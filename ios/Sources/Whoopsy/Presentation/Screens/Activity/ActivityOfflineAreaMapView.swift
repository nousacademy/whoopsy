import MapKit
import SwiftUI

/// The downloaded area a session recorded no route over, drawn on a map with no figures beneath it.
///
/// ## The card is the route card minus the caption
///
/// The page's map card is `ActivityRouteMapView`, and this is its sibling for the one case that card
/// cannot serve: `USE OFFLINE MAP` on with `RECORD ROUTE` off. The same label, the same height, the same
/// corner radius and the same non-interactive rule — what is missing is the caption, because an area has
/// no distance and no speed to print, and a bar holding two dashes would claim two measurements this
/// session never took.
///
/// ## The surface seam is the route card's, unchanged
///
/// On a build with a map SDK the picture comes from `App/Map/` — a module this package never compiles —
/// and on every other build it is MapKit below. The card fixes the frame and clips it, so the two
/// implementations cannot disagree about height or corners. See
/// `ActivityRouteMapView.init(route:unit:mapSurface:)` for the full argument, which this card inherits
/// rather than restates.
public struct ActivityOfflineAreaMapView: View {

    /// The framed ground. Never `nil`: this view is constructed only on the branch where the page has
    /// an area, and `ActivityOfflineArea` itself is the absence.
    public let area: ActivityOfflineArea

    /// The map surface when it is not this module's to draw — `nil` on every build this package
    /// compiles, exactly as on the route card.
    private let mapSurface: AnyView?

    public init(area: ActivityOfflineArea) {
        self.area = area
        self.mapSurface = nil
    }

    /// The same card, drawing a map supplied from outside this module.
    public init(area: ActivityOfflineArea, mapSurface: AnyView) {
        self.area = area
        self.mapSurface = mapSurface
    }

    /// `ActivityRouteMapView.title` is `Route` because there is a route in it. Nothing is drawn on this
    /// map, so it is labelled for what it is.
    public nonisolated static let title = "Map"

    /// The route card's total height, and here it is all map: there is no caption to divide it with.
    ///
    /// **The number matches the route card's on purpose** — the two cards replace each other for
    /// sessions of the same kind, and a map that changed height when the route toggle was off would read
    /// as a different section rather than the same one.
    private static let mapHeight: CGFloat = 220

    private static let cornerRadius: CGFloat = 16

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(Self.title)

            surface
                .frame(height: Self.mapHeight)
                .clipShape(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                // The map is a drawing, so its own place names are suppressed for the same reason the
                // route card suppresses them: the sentence is the whole accessible content.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(area.spokenSummary)
        }
    }

    @ViewBuilder
    private var surface: some View {
        if let mapSurface {
            mapSurface
        } else {
            // The route card's live map minus its content: no polyline, no markers, no gesture. The
            // style excludes points of interest and the page's dark scheme darkens it, so this card and
            // the route card are the same surface with and without a path on it.
            Map(initialPosition: position, interactionModes: [])
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
        }
    }

    /// `ActivityOfflineArea.region`'s four numbers as MapKit's own type — the one construction, as on
    /// the route card, and the reason the framing rule lives in the value.
    private var position: MapCameraPosition {
        let region = area.region
        return .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: region.centerLatitude, longitude: region.centerLongitude),
                span: MKCoordinateSpan(
                    latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)))
    }
}
