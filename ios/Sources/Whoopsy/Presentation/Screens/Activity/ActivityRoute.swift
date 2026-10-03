import Foundation

/// One session's recorded path: the polyline, the frame it is drawn in, and the two figures its caption
/// prints.
///
/// ## The rules live here and not in the map's `body`
///
/// This repo's standing arrangement, and the reason `ActivityZoneRow`, `ActivityHeartRateSeries` and
/// `ActivityDurationBarLayout` are values rather than views: the test runner has no renderer, so a rule
/// written into a `body` is a rule nothing can assert. The map draws a polyline and two markers, and
/// everything that decides *whether* there is a drawing at all — the plausibility filter, the two-point
/// floor, the ordering — and everything that decides *what the caption says* — a great-circle length, an
/// average speed, which unit — is resolved here first. What is left for `ActivityRouteMapView` is an
/// `MKCoordinateRegion` built from four numbers and a `MapPolyline` built from two coordinates, and
/// neither of those carries a rule.
///
/// ## The three absences collapse into one, and the section draws no note for it
///
/// A route is `nil` when the session recorded fewer than two plausible positions, and **that is every
/// session this app can currently show**: the `RECORD ROUTE` toggle is the only producer of
/// `workout_route_points`, it is off by default, and no session has ever been recorded on this machine.
/// The page's section is therefore **absent with no note**, which is `zoneSection`'s precedent — the
/// page's own block that is simply not drawn — and not `noHeartRateNote`'s, where the slot is always
/// drawn and the sentence explains why it is empty. A note here would be a permanent fixture on every
/// session rather than a response to a state, and it would have to name a toggle most readers never see.
///
/// ## ELEVATION is not on the caption, and it is not an oversight
///
/// The reference's overlay carries three figures: distance, speed and elevation. `WorkoutRoutePoint` has
/// no altitude field, `workout_route_points` has no column, and nothing in this app reads
/// `CLLocation.altitude` — so the third cell has **no producer at any layer**. It is dropped rather
/// than drawn as a dash: a `—` beside two real figures claims this app has an altimeter and that it
/// failed, which is the fabrication the absence rule forbids everywhere else. The reference's third cell
/// is the one field on it this app cannot populate, and the caption is two cells rather than three.
public struct ActivityRoute: Equatable, Sendable {

    /// Which units the caption is printed in.
    ///
    /// **A parameter and never a read of `Locale.current` inside the text builders**, and that is the
    /// rule `scripts/test.sh`'s own docs state: a hardcoded figure that only holds in one zone is a test
    /// that fails on someone else's machine. Resolving the unit is the view's job — it is the only layer
    /// that knows what device it is on — and the value takes it as an argument so every assertion below
    /// can drive both systems explicitly.
    public enum Unit: Sendable {
        case metric
        case imperial

        /// The system a locale measures in, with **metric as the one named case** and everything else
        /// falling to imperial.
        ///
        /// `Locale.MeasurementSystem` declares three constants — `.us`, `.metric` and `.uk` — and only
        /// one of them is metric. A `switch` cannot be exhaustive over it (the type is a `struct` with
        /// static members, not an `enum`), so testing for `.metric` positively is the form that stays
        /// correct if a fourth system appears: an unknown system gets miles, which is what both of the
        /// imperial ones use for road distance anyway.
        public static func forLocale(_ locale: Locale) -> Unit {
            locale.measurementSystem == .metric ? .metric : .imperial
        }

        /// The order the profile page's `UNITS` control draws the two in, which is **not** the
        /// declaration order.
        ///
        /// `case metric` is declared first because `forLocale` names it as the one non-imperial answer,
        /// and that says nothing about how a control lays them out: the reference draws `IMPERIAL` on the
        /// left, so a `CaseIterable` conformance would have put `METRIC` there instead and flipped the
        /// selected segment to the other side of the track. The drawing order is therefore written down
        /// once, here, and the page's index mapping reads it — a `[.imperial, .metric]` written at that
        /// call site would be a second copy of the order and would not move if the enum were reordered.
        public static let displayOrder: [Unit] = [.imperial, .metric]

        /// The word on a segment of the `UNITS` control.
        ///
        /// Uppercase in the value rather than by a `.textCase` on the view, because the two abbreviations
        /// beside it (`distanceLabel`, `speedLabel`) are lowercase and a reader comparing the two sets
        /// should see both spellings where they are decided.
        public var title: String { self == .metric ? "METRIC" : "IMPERIAL" }

        /// The suffix the caption prints after the distance — `21.2 km`, `13.2 mi`.
        var distanceLabel: String { self == .metric ? "km" : "mi" }

        /// The suffix after the speed — `16.0 km/h`, `9.9 mph`.
        var speedLabel: String { self == .metric ? "km/h" : "mph" }

        /// The noun the spoken sentence uses.
        ///
        /// **Plural, always, and the one-decimal formatter is the whole of why.** Every figure on this
        /// card is printed to one decimal, so the number in front of this noun is never a bare `1` — it
        /// is `1.0`, `0.5` or `21.2` — and *"1.0 kilometres"* is a sentence no reader would call broken
        /// while *"1 kilometres"* is the only form that would be. A singular arm here would therefore be
        /// a branch no input could reach: the test would have to be the raw value being exactly one, and
        /// a great-circle sum is a `Double` that lands on `1.0` only by accident of floating point.
        ///
        /// Spelled out because the caption's `mi` and `mph` are *abbreviations*, and VoiceOver reads an
        /// abbreviation letter by letter on some voices.
        var distanceNoun: String { self == .metric ? "kilometres" : "miles" }

        var speedNoun: String { self == .metric ? "kilometres per hour" : "miles per hour" }

        /// One statute mile, exactly, as the international definition fixes it.
        ///
        /// Internal and not `private`: Swift scopes a `private` member to the declaration that encloses
        /// it and its same-file extensions, and a member declared inside this nested `enum` is enclosed
        /// by `Unit` rather than by `ActivityRoute` — so `private` here is invisible to the outer type
        /// that does the dividing. It is not `public` either, because nothing outside this file has any
        /// business with a conversion factor.
        var metersPerDistanceUnit: Double { self == .metric ? 1_000 : 1_609.344 }

        /// Metres per second in one unit of speed — `1_000 / 3_600` for km/h, `1_609.344 / 3_600` for
        /// mph. Derived from the distance unit rather than written down twice, so the two cannot drift.
        var metersPerSecondPerSpeedUnit: Double { metersPerDistanceUnit / 3_600 }
    }

    /// Where the map should look, as a centre and two spans in plain degrees.
    ///
    /// **Four `Double`s and not an `MKCoordinateRegion`**, which is the same split the rest of this file
    /// makes: the framing rule is arithmetic and is asserted against literals, while the map type is a
    /// construction with no rule in it. It also keeps this file Foundation-only, like every other value
    /// in this folder.
    public struct Region: Equatable, Sendable {
        public let centerLatitude: Double
        public let centerLongitude: Double
        public let latitudeSpan: Double
        public let longitudeSpan: Double
    }

    /// The session's positions, in time order, with every implausible fix already dropped.
    public let points: [WorkoutRoutePoint]

    /// The frame the polyline is drawn in.
    public let region: Region

    /// The path's great-circle length, in metres.
    public let distanceMeters: Double

    /// The span the path itself covers: `finish.timestamp − start.timestamp`.
    ///
    /// **Not the session's duration, and the difference is the whole of the speed's honesty.** The
    /// route begins when the reader turned `RECORD ROUTE` on, which is not when the session started —
    /// so a run whose toggle was flipped two minutes in has a path covering eighteen of its twenty
    /// minutes. Dividing the path's own length by the session's own span would mix two producers and
    /// report an average over distance the app never measured, which is the same fault as counting a
    /// sample rate as a duration. This is the span the distance was actually covered over, and both
    /// figures come from the same array.
    ///
    /// The reference's own overlay divides by its session's duration; this app's arithmetic differs
    /// from it on purpose, and the two agree whenever the toggle was on from the start.
    public let durationSeconds: Double

    /// Where the path began.
    public var start: WorkoutRoutePoint { points[0] }

    /// Where it ended. Equal to `start` on a route of exactly two coincident fixes, which is a path of
    /// no length rather than a missing end.
    public var finish: WorkoutRoutePoint { points[points.count - 1] }

    /// How many positions a route needs before it is one.
    ///
    /// Two, because a polyline is drawn between positions and a single fix is a *place* rather than a
    /// path. Drawing one as a route would put a marker on the map and claim the session moved; the
    /// honest answer for one plausible fix is the same absence a session with none draws.
    public static let minimumPointCount = 2

    /// The IUGG mean earth radius, in metres — the `R₁` of the IUGG's mean-radius set, and the figure
    /// the haversine below is stated against.
    ///
    /// A single sphere rather than an ellipsoid: over a session's few kilometres the two differ by well
    /// under a tenth of a percent, which is far inside GPS's own error, and a great-circle sum is
    /// reproducible against a literal in a way an ellipsoidal one is not.
    public static let earthRadiusMeters: Double = 6_371_008.8

    /// The narrowest the frame is allowed to be, in degrees, on either axis.
    ///
    /// A route that went nowhere — a couple of fixes a few metres apart in a car park — would otherwise
    /// frame a box metres wide, and the map would draw the same street at a zoom where the polyline is a
    /// blob. `0.004°` is about 440 m of latitude, which is the scale the reference's own maps use for a
    /// short route.
    public static let minimumSpanDegrees: Double = 0.004

    /// How much of the frame's margin is left around the path.
    ///
    /// Applied **before** the floor above, so a path that exactly fills the minimum frame still gets its
    /// margin. `1.4` leaves a fifth of the frame clear on each side, which is about where a marker stops
    /// colliding with the frame's own edge.
    public static let spanPadding: Double = 1.4

    /// The session's positions as a route, or `nil` when they do not make one.
    ///
    /// ## The plausibility filter is applied on the read as well as at the write
    ///
    /// `WorkoutRoutePoint.isPlausible` is the same test the recording path drops fixes with — §18 asserts
    /// that a `(0, 0)` yielded into a live session never reaches storage. Applying it again here is the
    /// "same test on both sides of the write" rule this repo states for every gate: the column has no
    /// constraint behind it, so a row written by an older build, by a hand-run SQL probe, or by a future
    /// producer that forgets the filter would otherwise be drawn as a path to the Gulf of Guinea.
    ///
    /// ## The sort is by `timestamp`, and `sorted(by:)` is guaranteed stable
    ///
    /// `LocalDatabaseManager.getRoutePoints(for:)` already returns these ordered by timestamp ascending,
    /// so on the ordinary path this sort is a no-op. It is here because the *definition* of a polyline is
    /// an ordered sequence and this type should not depend on a caller having ordered it — and because a
    /// stable sort (SE-0372, Swift 5.8) keeps the repository's own arrival order for two fixes sharing an
    /// instant, which is the only tie-break available: `id` is a fresh `UUID` and would order the same
    /// rows differently on every launch.
    ///
    /// A path that crosses the antimeridian is framed on raw longitudes and therefore gets a
    /// world-wide box rather than a wrapped one. Recorded rather than fixed: `isPlausible` admits ±180,
    /// but no session this app can record crosses it, and wrapping arithmetic nothing can produce is
    /// arithmetic nothing can check.
    public init?(points: [WorkoutRoutePoint]) {
        let ordered = points
            .filter(\.isPlausible)
            .sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= Self.minimumPointCount else { return nil }

        self.points = ordered
        self.distanceMeters = Self.distance(along: ordered)
        self.durationSeconds = max(
            0, ordered[ordered.count - 1].timestamp.timeIntervalSince(ordered[0].timestamp))
        self.region = Self.region(around: ordered)
    }

    // MARK: - The path's length

    /// The sum of consecutive great-circle distances, in metres.
    static func distance(along points: [WorkoutRoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + distance(from: pair.0, to: pair.1)
        }
    }

    /// The haversine distance between two fixes, in metres.
    ///
    /// Hand-rolled rather than `CLLocation.distance(from:)`, and the reason is the one
    /// `LocationTracking.swift` records for `Domain` not naming `CoreLocation`: this type is asserted
    /// against literals in a runner that must not construct a `CLLocationManager`, and a distance that
    /// can only be obtained by asking the framework is a distance the suite cannot pin. The formula is
    /// the standard one over the mean radius above; at 1° of latitude it returns 111 195 m, which is what
    /// §19 pins it at.
    ///
    /// **The `min(1, …)` is not decoration.** Two exactly antipodal points give `h` a hair above 1 in
    /// floating point, and `asin` of that is `NaN` — a route whose length is not a number, printed as
    /// such. No session this app can record is 20 000 km long, but a `NaN` reaching a formatted string is
    /// the kind of fault that has no local symptom.
    static func distance(from a: WorkoutRoutePoint, to b: WorkoutRoutePoint) -> Double {
        let radians = Double.pi / 180
        let latitude1 = a.latitude * radians
        let latitude2 = b.latitude * radians
        let deltaLatitude = (b.latitude - a.latitude) * radians
        let deltaLongitude = (b.longitude - a.longitude) * radians

        let halfLatitude = sin(deltaLatitude / 2)
        let halfLongitude = sin(deltaLongitude / 2)
        let h = halfLatitude * halfLatitude
            + cos(latitude1) * cos(latitude2) * halfLongitude * halfLongitude

        return 2 * earthRadiusMeters * asin(min(1, h.squareRoot()))
    }

    // MARK: - The frame

    /// The box the path's own extremes define, padded and floored.
    ///
    /// Each span is `padding × the path's extent` with `minimumSpanDegrees` as a floor underneath it, so
    /// a path that covered no ground is framed at the floor rather than at a zero-height box that a map
    /// cannot draw. The centre is the midpoint of the path's extremes and is **not** recomputed after the
    /// floor is applied — the floor grows the box around a centre that is already the path's, which is
    /// the same frame a reader would get from a hand-zoomed map.
    static func region(around points: [WorkoutRoutePoint]) -> Region {
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let lowestLatitude = latitudes.min() ?? 0
        let highestLatitude = latitudes.max() ?? 0
        let lowestLongitude = longitudes.min() ?? 0
        let highestLongitude = longitudes.max() ?? 0

        return Region(
            centerLatitude: (lowestLatitude + highestLatitude) / 2,
            centerLongitude: (lowestLongitude + highestLongitude) / 2,
            latitudeSpan: max(
                (highestLatitude - lowestLatitude) * spanPadding, minimumSpanDegrees),
            longitudeSpan: max(
                (highestLongitude - lowestLongitude) * spanPadding, minimumSpanDegrees))
    }

    // MARK: - What the caption prints

    /// The distance as the overlay prints it — `21.2 km`, `13.2 mi`.
    ///
    /// One decimal place, on the reference's own shape (`13.2 mi`), through the app's existing
    /// `formattedOneDecimal()` so this figure and every other one-decimal figure in the app share a
    /// formatter. That helper is `String(format:)` with no locale, so it prints a `.` in every region —
    /// which is what makes the assertions below region-independent, and is the same choice the rest of
    /// the app's formatted figures already make.
    public func distanceText(in unit: Unit) -> String {
        "\(Self.value(distanceMeters, per: unit).formattedOneDecimal()) \(unit.distanceLabel)"
    }

    /// The average speed as the overlay prints it — `16.0 km/h`, `9.9 mph` — or `nil` when there is no
    /// span to divide by.
    ///
    /// `nil` when `durationSeconds` is zero, which is a route whose every fix carries the same instant:
    /// a speed is a distance over a time, and with no time there is no answer rather than a fast one.
    /// The overlay then draws the distance cell alone rather than a `—`, on the same rule that keeps
    /// `ELEVATION` off it.
    public func averageSpeedText(in unit: Unit) -> String? {
        guard durationSeconds > 0 else { return nil }
        let speed = distanceMeters / durationSeconds / unit.metersPerSecondPerSpeedUnit
        guard speed.isFinite else { return nil }
        return "\(speed.formattedOneDecimal()) \(unit.speedLabel)"
    }

    /// The whole reading, for VoiceOver.
    ///
    /// **The map is a drawing and it carries nothing to a reader who cannot see it**, so this sentence is
    /// the entire accessible content of the card — it opens by saying what the drawing is, then gives the
    /// two figures the caption carries. `ActivityHeartRateChartView`'s labelling and
    /// `FastingRecoveryChartSeries.spokenSentence` are the precedents.
    ///
    /// **The duration is deliberately not spoken**, although the route has one: the page prints the
    /// *session's* `DURATION` a few inches above this card, and a sentence naming the route's own span
    /// would put two different durations for one session in a reader's ear with nothing to tell them
    /// apart. Distance and speed are the two figures this card owns.
    public func spokenSummary(in unit: Unit) -> String {
        let distance = Self.spoken(
            Self.value(distanceMeters, per: unit), unit.distanceNoun)
        guard let speed = averageSpeed(in: unit) else {
            return "Map of the recorded route. \(distance)."
        }
        return "Map of the recorded route. \(distance), averaging "
            + "\(Self.spoken(speed, unit.speedNoun))."
    }

    /// The raw length in the caller's unit — kilometres or miles — before it is formatted.
    ///
    /// Internal rather than private so the suite can pin the conversion without going through a string,
    /// which is the one rule here a formatting change could hide.
    func value(_ meters: Double, for unit: Unit) -> Double {
        Self.value(meters, per: unit)
    }

    /// The average speed in the caller's unit, unformatted — see `averageSpeedText`.
    func averageSpeed(in unit: Unit) -> Double? {
        guard durationSeconds > 0 else { return nil }
        let speed = distanceMeters / durationSeconds / unit.metersPerSecondPerSpeedUnit
        return speed.isFinite ? speed : nil
    }

    private static func value(_ meters: Double, per unit: Unit) -> Double {
        meters / (unit == .metric ? 1_000 : 1_609.344)
    }

    /// A value and its unit as one spoken phrase.
    ///
    /// **There is no singular arm, and its absence is the rule rather than an omission.** The figure is
    /// printed to one decimal, so the noun never follows a bare `1` — *"1.0 kilometres"* is correct and
    /// *"1 kilometres"* is unreachable — which is the argument `Unit.distanceNoun` carries in full.
    /// Keying a singular on the raw value being exactly one would be a branch no distance can take: a
    /// great-circle sum is a `Double` that reaches `1.0` only by floating-point accident.
    private static func spoken(_ value: Double, _ noun: String) -> String {
        "\(value.formattedOneDecimal()) \(noun)"
    }
}
