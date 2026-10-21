import Foundation

/// The point an offline map region was downloaded around: one plausible GPS fix, in plain degrees.
///
/// ## Why the row needs a coordinate when it already names a region
///
/// `WorkoutSession.offlineRegionID` is a join key into Mapbox's tile store, and a key is all the store
/// needs to *find* the tiles. It is not enough to *frame* them: Mapbox's `TileRegion` exposes no
/// geometry, so a page holding only an id can say *tiles exist* and cannot say *where they are*.
///
/// A session that recorded a route does not need this — `ActivityRoute` frames the path. The case this
/// type exists for is the one the two switches make ordinary: `USE OFFLINE MAP` is mutually exclusive
/// with `RECORD ROUTE`, so a session can download a map and store no route at all. Its detail page then
/// has tiles on disk and nothing to point the camera at.
///
/// ## Why it is persisted rather than re-derived
///
/// The download's centre is the first fix the session took after the switch went on. Nothing later in
/// the app knows it: the fix is not in `workout_route_points` when route recording is off, and Mapbox
/// does not publish a region's geometry. So it is written beside the region id at the same moment, in
/// the two nullable `workouts` columns `v23` adds.
///
/// `nil` on every session recorded with the switch off, and on every row written before `v23`.
public struct OfflineMapCenter: Equatable, Hashable, Sendable {

    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Whether a downloaded region could actually have been centred here.
    ///
    /// The same test `WorkoutRoutePoint.isPlausible` applies to a recorded fix, forwarded rather than
    /// restated: these values are read back off two columns with no constraint behind them, so a
    /// hand-run probe or an older build could put a `(0, 0)` — CoreLocation's "not resolved yet"
    /// placeholder — in front of the map, and a card framed on the Gulf of Guinea is the same fault
    /// the route's own filter exists to stop. A `NaN` is refused by the range comparisons themselves,
    /// on that type's own reasoning.
    public var isPlausible: Bool {
        WorkoutRoutePoint.isPlausibleCoordinate(latitude: latitude, longitude: longitude)
    }
}

/// The shape every offline region is downloaded in, in the one place a non-map caller can read it.
///
/// **The radius is the downloader's number and the card's frame is derived from it**, so the two cannot
/// drift: `MapboxOfflineMaps` builds its polygon with `radiusMeters`, and `ActivityOfflineArea` frames a
/// box that fits inside the circle that number describes. A card framing ground the download never
/// covered would be blank offline at its edges — the failure the whole feature exists to remove,
/// reintroduced by a constant.
///
/// It lives in `Domain` rather than beside the SDK because the card is `Presentation` and cannot name
/// `App/Map/`, which the package never compiles. The number itself is the user's own — *"can we
/// download 10 mile radius for offline version"* — and is kept as a radius rather than a bounding box
/// because that is the shape `Polygon(center:radius:)` takes.
public enum OfflineMapCoverage {

    /// Ten miles, in metres.
    public static let radiusMeters: Double = 16_093
}
