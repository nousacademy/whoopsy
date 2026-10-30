import Foundation

/// The length of a path over the earth — the one great-circle rule this app measures distance with.
///
/// **It lives in `Core` because two layers need the same number and neither may import the other's
/// owner.** `ActivityRoute` (Presentation) turns a session's fixes into the route card's distance and
/// speed; `LiveSessionUseCase` (Domain) pushes the live distance into the Live Activity. `Core` can
/// name neither `WorkoutRoutePoint` nor a SwiftUI view, so it takes plain coordinates and both callers
/// map theirs in — which is what keeps the card and the lock screen from disagreeing about how far a
/// run has gone by the width of a second haversine.
///
/// **A single sphere rather than an ellipsoid**: over a session's few kilometres the two differ by well
/// under a tenth of a percent, far inside GPS's own error, and a great-circle sum is reproducible
/// against a literal in a way an ellipsoidal one is not. `6_371_008.8` is the IUGG mean radius, which
/// is the figure `ActivityRoute` has always been asserted against.
public enum RouteDistance {

    /// The IUGG mean earth radius, in metres.
    public static let earthRadiusMeters: Double = 6_371_008.8

    /// How many fixes make a path. Two, and it is here rather than on `ActivityRoute` because the
    /// Live Activity's distance has the same floor and `Domain` may not reach a `Presentation` type
    /// for it — the compiler would allow it in one module, which is exactly why the rule is written
    /// where both layers can read it.
    public static let minimumPointCount = 2

    /// The haversine distance between two coordinates, in metres.
    ///
    /// Hand-rolled rather than `CLLocation.distance(from:)` for `ActivityRoute`'s recorded reason: a
    /// distance obtainable only from the framework is a distance the runner cannot pin, and this one
    /// is asserted against a literal at one degree of latitude (`111_195.08 m`).
    public static func meters(
        fromLatitude: Double, fromLongitude: Double,
        toLatitude: Double, toLongitude: Double
    ) -> Double {
        let phi1 = fromLatitude * .pi / 180
        let phi2 = toLatitude * .pi / 180
        let deltaPhi = (toLatitude - fromLatitude) * .pi / 180
        let deltaLambda = (toLongitude - fromLongitude) * .pi / 180

        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadiusMeters * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// The sum of consecutive great-circle distances, in metres — the path's own length rather than
    /// the span between its ends, because a route that doubles back is longer than its endpoints say.
    public static func meters(along coordinates: [(latitude: Double, longitude: Double)]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + meters(
                fromLatitude: pair.0.latitude, fromLongitude: pair.0.longitude,
                toLatitude: pair.1.latitude, toLongitude: pair.1.longitude)
        }
    }
}
