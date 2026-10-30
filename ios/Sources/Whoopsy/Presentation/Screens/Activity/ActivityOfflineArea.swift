import Foundation

/// The ground an offline map download covered, framed so a card can draw it when the session recorded
/// no route.
///
/// ## Why this value exists at all
///
/// `ActivityRoute` is the page's map for a session that recorded positions — and every session this app
/// whose route has fewer than two plausible fixes has none.
/// Such a session holds uploaded tiles in Mapbox's store and a centre on its row (`v23`), and nothing
/// that turns those into a frame. This type is that turn: a centre plus the box a card draws around it.
///
/// ## The frame is a square in metres, fitted inside the downloaded circle
///
/// The region is downloaded as a circle of `OfflineMapCoverage.radiusMeters` around its centre — that is
/// the polygon `MapboxOfflineMaps` builds — so the honest frame is one that stays inside that circle at
/// every point, or the card's corners would be blank offline. A square of side
/// `visibleSpanFraction × radius` centred on the same point has a half-diagonal of
/// `√2/2 × 0.75 × radius ≈ 0.53 × radius`, leaving close to half the radius of margin — enough that the
/// extra longitude a wide card's aspect reveals (a card roughly 1.8:1 shows about 1.35 × the requested
/// width) still lands on downloaded ground.
///
/// **The square is sized in metres and converted, rather than a pair of degrees picked by eye.** One
/// degree of latitude is `ActivityRoute.earthRadiusMeters × π / 180` metres everywhere, while a degree of
/// longitude shrinks with `cos(latitude)` — so a box "square" in degrees is not square on the ground, and
/// a card framed that way draws a different amount of ground at different latitudes. The longitude span
/// is therefore the latitude span divided by the cosine, which is the standard equirectangular
/// conversion and is exact enough at a 10-mile scale.
///
/// ## It draws the same absence the route card draws
///
/// The page's map section is absent, with no note, when neither a route nor an area exists —
/// `ActivityRoute`'s own rule, carried because a card that only ever appears on one kind of session
/// should not be explained by a sentence that appears on all of them.
public struct ActivityOfflineArea: Equatable, Sendable {

    /// Where the region was downloaded around, in plain degrees.
    public let center: OfflineMapCenter

    /// The box the card draws: the centre, and the two spans a map takes its camera from.
    ///
    /// It is `ActivityRoute.Region` rather than a second four-`Double` type because it is the same
    /// question — where a map should look — and the card has one construction of it.
    public let region: ActivityRoute.Region

    /// One side of the frame, as a fraction of the downloaded circle's radius.
    ///
    /// **`0.75` and not `2`**: the frame is sized to stay inside the circle, and a side equal to the
    /// diameter would inscribe a square whose corners touch the circle — no margin for the aspect's
    /// revealed width, and no margin for a map that pads its camera. Three-quarters leaves a quarter of
    /// the radius around the frame's own edges. See the type comment for the diagonal arithmetic.
    public static let visibleSpanFraction: Double = 0.75

    /// Metres in one degree of latitude under the mean-radius sphere `ActivityRoute` uses, so the two
    /// maps' conversions cannot disagree. Internal so the suite can pin a span against it.
    static let metersPerDegreeLatitude: Double =
        ActivityRoute.earthRadiusMeters * Double.pi / 180

    /// A frame for `center`, or `nil` when no honest frame exists.
    ///
    /// The two refusals are the implausible centre — a `(0, 0)` from an old build or a hand-run probe,
    /// which would frame the Gulf of Guinea — and a center so close to a pole that the longitude
    /// conversion has no meaning. The latter is unreachable from this app's recorders and is refused
    /// rather than clamped: a clamped span would be a made-up number, which is the fabrication the
    /// absence rules forbid everywhere else.
    public init?(center: OfflineMapCenter) {
        guard center.isPlausible, let region = Self.region(around: center) else { return nil }
        self.center = center
        self.region = region
    }

    /// The sentence VoiceOver reads for the card, which is the whole of its accessible content — the
    /// map is a drawing and says nothing. `ActivityRoute.spokenSummary`'s shape, with no figures
    /// because there are none to speak: an area has no distance and no speed.
    public var spokenSummary: String {
        "Map of the area downloaded for this activity."
    }

    /// The arithmetic, kept off the initialiser so it can be exercised through a single centre and read
    /// as the three steps it is.
    static func region(around center: OfflineMapCenter) -> ActivityRoute.Region? {
        let sideMeters = OfflineMapCoverage.radiusMeters * visibleSpanFraction
        let latitudeSpan = sideMeters / metersPerDegreeLatitude
        let cosine = cos(center.latitude * Double.pi / 180)
        // `1e-6` is about a ten-thousandth of a degree from a pole. Below it the division would blow
        // the longitude span past any map's own limits rather than produce a frame.
        guard cosine > 1e-6 else { return nil }

        return ActivityRoute.Region(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeSpan: latitudeSpan,
            longitudeSpan: latitudeSpan / cosine)
    }
}
