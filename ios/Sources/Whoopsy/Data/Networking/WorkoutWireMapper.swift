import Foundation

/// The workouts resource as the API spells it, and the conversions between that spelling and
/// `WorkoutSyncRow`.
///
/// **Three names, and this file is where they meet.** A field is `hr_zone_percents` in D1,
/// `hrZonePercents` on the wire and `hrZonePercents` on the app's record, and only the first of those
/// is this app's to choose — the wire's names are the ones the server publishes and the record's are
/// the ones `WorkoutRecord` already carries, which happen to be the same word. So the mapping is
/// written down once, here, exactly as `RecoveryWireMapper` writes down the flat resource's.
///
/// **What this resource has that the flat one does not is three things, and each is a place
/// `recoveries` had nothing to say.**
///
/// *An aggregate.* A session is one row and two child tables on this side and in D1, and one object
/// with two nested arrays on the wire. The children therefore ride inside `WorkoutDTO` rather than
/// beside it — the API's own contract says so, since `route` and `splits` are required on every write
/// body and never defaulted, so a body that omitted them would wipe a stored route rather than leave
/// it alone.
///
/// *A second instant format.* `recoveries` is addressed and keyed entirely by a day, so `YYYY-MM-DD`
/// was the only spelling it needed. A session carries two instants of its own and each of its route
/// points carries a third, and `workouts.started_at` is a TEXT column that is **ordered
/// lexicographically**, so the instants have to be one fixed-width UTC spelling or the database sorts
/// a chronology as a string and gets a different answer. `instantKey(for:)` is that spelling and
/// nothing else is.
///
/// *An addressing id.* A recovery is `/v1/recoveries/{date}`; a session is `/v1/workouts/{id}`,
/// because a day holds several. The id is a field on the body as well as in the path, and the two are
/// the same value by construction.
///
/// **The types the HTTP layer sends are split across two files, on `recoveries`' own precedent**:
/// `WorkoutDTO` and its two child DTOs live here with the conversions, while `WorkoutWriteDTO`,
/// `WorkoutBatchBody` and `WorkoutBatchResult` live at the bottom of `WhoopsyAPIClient.swift` beside
/// their `Recovery` siblings, because they describe payload *shapes* rather than mappings and the
/// client is the only thing that builds them.

// MARK: - The children

/// One GPS fix, as the API spells it.
///
/// **Nothing here is nullable, so the synthesised `Codable` is correct and this type deliberately
/// does not carry the hand-written `encode(to:)` its parent does.** That asymmetry is the wire's
/// rather than an oversight: `WorkoutRoutePointSchema` marks `heartRate` as `int().positive()` and
/// required, with the argument that the app stamps every fix it records from the session's own
/// accumulator, so there is no fix in this system that has no rate and one must not be expressible.
/// A type with no optionals has no key to omit and therefore no `encodeIfPresent` trap to avoid.
///
/// `timestamp` is a `String` here and a `Date` on `WorkoutRoutePoint`, converted by
/// `WorkoutWireMapper`'s canonical-instant pair — the same spelling `startedAt` and `endedAt` take,
/// which is what makes a stored route sort by the order it was recorded in.
///
/// `id` is a `String` here and a `UUID` on the entity, for `WorkoutIdSchema`'s own reason: the app
/// reads every stored id through `UUID(uuidString:)`, so a non-UUID id is a row that would be stored
/// and never shown.
public struct WorkoutRoutePointDTO: Codable, Equatable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let timestamp: String
    public let heartRate: Int

    public init(
        id: String,
        latitude: Double,
        longitude: Double,
        timestamp: String,
        heartRate: Int
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.heartRate = heartRate
    }
}

/// One lap, as the API spells it — the same shape `WorkoutRoutePointDTO` has and for the same reason.
///
/// **This type describes a shape nothing writes yet.** `workout_splits` has no producer in this app,
/// because there is no lap model; the table, the entity and this DTO all exist so that a session
/// carrying splits could sync them rather than so that any screen can make one. That is why
/// `isSendable` validates a split's bounds and the use case's chunking still has to count them: the
/// wire refuses what it refuses whether or not this build can produce it.
///
/// `elapsed` is a `TimeInterval` in the app and a `REAL` column in D1, so it is a `Double` at every
/// layer and is never rounded to a count — a lap's length in seconds is a measurement.
public struct WorkoutSplitDTO: Codable, Equatable, Sendable {
    public let id: String
    public let elapsed: Double
    public let strain: Double

    public init(id: String, elapsed: Double, strain: Double) {
        self.id = id
        self.elapsed = elapsed
        self.strain = strain
    }
}

// MARK: - The session

/// One stored session and its children, as the API returns them.
///
/// The field names and their order are the record's, verbatim, which is what keeps `dto(for:)` and
/// `row(for:)` below a field-for-field copy with no naming decision in them.
///
/// **`encode(to:)` is hand-written and every field goes through `container.encode`, never
/// `encodeIfPresent`, on `RecoveryDTO`'s argument and one that is sharper here.** Synthesised
/// `Codable` omits the key entirely for a `nil` optional, while every nullable field in
/// `WorkoutSchema` is `.nullable()` and **not** `.optional()` — so an absent key is a `400` naming a
/// missing field rather than a `null`. The eight nullables below are not a corner case on this
/// resource either: a Zero fast carries no strain, no heart rates, no zone block and no steps, its
/// route and split lists are empty, and it is 170 of the rows this app can hold. A synthesised
/// encoder would refuse every one of them, and the refusal would name a field the app had simply
/// never measured.
///
/// **`route` and `splits` are non-optional arrays with no default**, mirroring the server's own two
/// required fields: a body that could leave `route` out would delete a stored path rather than leave
/// it alone, so an empty route is an affirmative claim that the session has none.
public struct WorkoutDTO: Codable, Equatable, Sendable {
    public let id: String

    /// The day the session is filed under, as `YYYY-MM-DD`.
    ///
    /// **Sent by the client and never derived by the server**, which is this resource's structural
    /// difference from `recoveries`. The day is `startOfDay(startedAt)` in the *device's* calendar,
    /// and a UTC Worker cannot compute it: the same instant is a different day on two phones, and a
    /// server-side derivation would file a session on a day no screen of the app that recorded it
    /// reads.
    public let date: String

    /// The session's two instants, in the canonical fixed-width UTC form.
    public let startedAt: String
    public let endedAt: String

    /// The eight absences. `nil` is "nothing was measured", and it is never a zero.
    public let strain: Double?
    public let averageHeartRate: Int?
    public let maxHeartRate: Int?
    public let source: String?
    public let activityName: String?
    public let hrZonePercents: [Double]?
    public let steps: Int?
    public let offlineRegionID: String?

    /// The children, **in the order they were recorded** — see `WorkoutSyncRow.route`.
    public let route: [WorkoutRoutePointDTO]
    public let splits: [WorkoutSplitDTO]

    public init(
        id: String,
        date: String,
        startedAt: String,
        endedAt: String,
        strain: Double?,
        averageHeartRate: Int?,
        maxHeartRate: Int?,
        source: String?,
        activityName: String?,
        hrZonePercents: [Double]?,
        steps: Int?,
        offlineRegionID: String?,
        route: [WorkoutRoutePointDTO],
        splits: [WorkoutSplitDTO]
    ) {
        self.id = id
        self.date = date
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.strain = strain
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.source = source
        self.activityName = activityName
        self.hrZonePercents = hrZonePercents
        self.steps = steps
        self.offlineRegionID = offlineRegionID
        self.route = route
        self.splits = splits
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case startedAt
        case endedAt
        case strain
        case averageHeartRate
        case maxHeartRate
        case source
        case activityName
        case hrZonePercents
        case steps
        case offlineRegionID
        case route
        case splits
    }

    /// Written out rather than synthesised, so every key is present whether or not its value is.
    ///
    /// This is the one place on this resource where the encoder and the schema have to be read
    /// together: `container.encode` on an optional writes an explicit `null`, which is what
    /// `.nullable()` accepts, while the synthesised `encodeIfPresent` would write nothing at all,
    /// which `.strict()` refuses as a missing field.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(strain, forKey: .strain)
        try container.encode(averageHeartRate, forKey: .averageHeartRate)
        try container.encode(maxHeartRate, forKey: .maxHeartRate)
        try container.encode(source, forKey: .source)
        try container.encode(activityName, forKey: .activityName)
        try container.encode(hrZonePercents, forKey: .hrZonePercents)
        try container.encode(steps, forKey: .steps)
        try container.encode(offlineRegionID, forKey: .offlineRegionID)
        try container.encode(route, forKey: .route)
        try container.encode(splits, forKey: .splits)
    }
}

// MARK: - The window

/// The `days`/`endingOn` pair the workouts window read takes.
///
/// **A typealias and not a second struct, because the two windows are genuinely one shape.** The API
/// declares two query schemas — one per resource — and they carry the same two fields with the same
/// bounds, both reading `MAX_WINDOW_DAYS` from `recoveryService.ts` rather than from a constant of
/// their own. Declaring `WorkoutWindow` afresh would be a second copy of `RecoveryWindow.init?`'s
/// arithmetic, which is the off-by-one that decides whether a ten-day range is `days: 9` or `days: 10`
/// — and two copies of that drift by exactly one day in a way no screen can see. This name exists so
/// that the workouts call sites read in workouts' vocabulary; the rule behind it is one rule.
public typealias WorkoutWindow = RecoveryWindow

// MARK: - The mapper

/// The conversions between `WorkoutSyncRow` and the wire, in both directions.
///
/// An enum with no cases because there is nothing here to instantiate — `RecoveryWireMapper`'s shape,
/// for its reason: every member is a pure function of a value the caller already holds, and there is
/// no state a mapper could hold that would not be a second copy of something the row already says.
public enum WorkoutWireMapper {

    // MARK: The published bounds

    /// The most GPS fixes one session may carry, mirroring `MAX_ROUTE_POINTS` (`workoutService.ts`).
    public static let maximumRoutePoints = 2000

    /// The most laps one session may carry, mirroring `MAX_SPLITS` (`workoutService.ts`).
    public static let maximumSplits = 200

    /// The number of zone shares a block must hold, mirroring `ZONE_COUNT` (`repositories/workout.ts`).
    public static let zoneCount = 5

    // MARK: The day key

    /// The day key, forwarded to the one place this app writes that rule down.
    ///
    /// `RecoveryWireMapper` owns the arithmetic because `recoveries` reached the wire first, and the
    /// day key is **one wire concept rather than two** — the API declares a single `DayKeySchema` and
    /// this resource's `date` field is a reference to that same shape. A second copy here would be a
    /// second answer to a question that has one, and the failure would be invisible in the worst way:
    /// both spellings would keep parsing, so nothing would throw, and only one of them would keep
    /// agreeing with the calendar about which day a session is filed on.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        RecoveryWireMapper.dayKey(for: day, in: calendar)
    }

    /// The inverse, forwarded for `dayKey(for:in:)`'s reason.
    ///
    /// It is the stricter half and the strictness is the calendar's rather than a pattern's:
    /// `2026-02-31` is four digits, a dash and two digits in exactly the right places, and what
    /// refuses it is re-snapping through `startOfDay` and checking the calendar's fields came back
    /// unchanged. See `RecoveryWireMapper.day(fromDayKey:in:)`.
    public static func day(fromDayKey key: String, in calendar: Calendar = .current) -> Date? {
        RecoveryWireMapper.day(fromDayKey: key, in: calendar)
    }

    // MARK: The instant

    /// The wire's one canonical instant: `2026-08-22T13:45:00.000Z`, to the character.
    ///
    /// **Built from `Calendar` components and never from a `DateFormatter`**, which is `dayKey`'s
    /// argument arriving at a second address. A formatter is lenient in ways that are undocumented
    /// and version-dependent — it will render a zone offset, or a fraction of another width, and be
    /// right about the instant while being wrong about the *string* — and the string is what the
    /// column holds. `workouts.started_at` is TEXT and `SELECT_WINDOW` orders a day's sessions by it,
    /// so two spellings of one instant is a column whose order is a guess.
    ///
    /// **No `calendar` parameter, and the absence is the point.** A day key needs a calendar because
    /// a day is a zone-dependent thing; an instant is not, so this takes UTC and says so rather than
    /// offering a parameter that would only ever have one correct value.
    ///
    /// The millisecond is computed by subtraction rather than read off `.nanosecond`, because
    /// `Date` holds a `Double` and a component read truncates where the arithmetic rounds: an instant
    /// at `.0006` would render `.000` through the component and `.001` through this, and the two
    /// disagree precisely at the values a live session produces.
    public static func instantKey(for instant: Date) -> String {
        let total = instant.timeIntervalSince1970
        let floored = total.rounded(.down)
        var millis = Int(((total - floored) * 1000).rounded())
        var whole = floored

        // A fraction of .9995 or more rounds up into the next second. Carrying it here rather than
        // letting it render is what keeps the string at three digits: `.1000` would be 25 characters
        // and would fail this function's own reader.
        if millis == 1000 {
            millis = 0
            whole += 1
        }

        let parts = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: whole)
        )

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            millis
        )
    }

    /// The instant `key` names, or `nil` for any spelling but the canonical one.
    ///
    /// **The round trip at the end is the load-bearing half, and it is there for
    /// `parseInstant`'s reason.** The shape check below admits `2026-02-31T00:00:00.000Z`, which is
    /// four digits, a dash and two digits in exactly the right places, and so does any pattern of
    /// digits a reader could write; `24:00:00`, `13:60:00` and month `13` are the same case. What
    /// refuses all four is the calendar — `Calendar.date(from:)` normalises an out-of-range component
    /// by rolling forward, so `2026-02-31` parses to the 3rd of March and re-rendering it does not
    /// give back what came in. That is the same three-step structure the server's own parser uses,
    /// and it cannot be wrong about February, because the calendar doing the checking is the
    /// platform's rather than one written here.
    public static func instant(fromInstantKey key: String) -> Date? {
        // `Array(key.utf8)` before the count, never `key.count`: a 24-Character string holding any
        // multi-byte character would pass a count check and then read past the end of its bytes.
        let bytes = Array(key.utf8)
        guard bytes.count == 24 else { return nil }

        // The seven fixed characters. Checked before any digit is read, so a field can never be
        // sliced out of a string whose shape is wrong.
        for (index, expected) in [(4, 0x2D), (7, 0x2D), (10, 0x54), (13, 0x3A), (16, 0x3A), (19, 0x2E), (23, 0x5A)] as [(Int, UInt8)]
        where bytes[index] != expected {
            return nil
        }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard
            let year = number(0 ..< 4),
            let month = number(5 ..< 7),
            let day = number(8 ..< 10),
            let hour = number(11 ..< 13),
            let minute = number(14 ..< 16),
            let second = number(17 ..< 19),
            let millis = number(20 ..< 23)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = millis * 1_000_000

        guard let parsed = utc.date(from: components) else { return nil }
        guard instantKey(for: parsed) == key else { return nil }

        return parsed
    }

    /// The calendar the two functions above read and write through: Gregorian, in UTC, and no other.
    ///
    /// Computed rather than stored. `Calendar` is a value type but a `static let` of one is a
    /// concurrency question this file has no reason to take a position on, and constructing it is
    /// cheaper than the formatter it replaces by orders of magnitude — which matters here, because a
    /// session's route is up to two thousand instants and a batch may hold two hundred sessions.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    // MARK: Row ↔ wire

    /// The body a `PUT` or a batch row sends for `row`.
    ///
    /// A field-for-field copy with three conversions in it: the day key, the two instants, and the
    /// children's own ids and timestamps. The `route` and `splits` arrays are carried **in the order
    /// the row holds them and are never sorted** — that order is the server's `seq`, bound from the
    /// array index on the way in and read back by it on the way out, so a mapper that re-sorted would
    /// be inventing a second ordering rule that agrees with the first today and need not tomorrow.
    public static func dto(for row: WorkoutSyncRow, in calendar: Calendar = .current) -> WorkoutDTO {
        WorkoutDTO(
            id: row.id.uuidString,
            date: dayKey(for: row.date, in: calendar),
            startedAt: instantKey(for: row.startedAt),
            endedAt: instantKey(for: row.endedAt),
            strain: row.strain,
            averageHeartRate: row.averageHeartRate,
            maxHeartRate: row.maxHeartRate,
            source: row.source,
            activityName: row.activityName,
            hrZonePercents: row.hrZonePercents,
            steps: row.steps,
            offlineRegionID: row.offlineRegionID,
            route: row.route.map { routePointDTO(for: $0) },
            splits: row.splits.map { splitDTO(for: $0) }
        )
    }

    /// The row a body describes.
    ///
    /// **This direction throws and the other does not**, which is the asymmetry `RecoveryWireMapper`
    /// records and it holds here for the same reason: a row this app holds is a row the database
    /// accepts by construction, while an answer has crossed a network and may hold anything. The four
    /// values that are strings on the wire and structured types here — the id, the day and the two
    /// instants — are each checked rather than force-unwrapped, and each names itself in the refusal
    /// so the sentence a caller logs says which field was unreadable rather than that something was.
    ///
    /// **`.malformed` and never `.unreachable`**, because this is a server that answered: the request
    /// got through and came back with something this app cannot read. A caller may degrade to local
    /// storage over an unreachable cloud and must not over this one, since the two mean opposite
    /// things about whether the data is safe.
    public static func row(for dto: WorkoutDTO, in calendar: Calendar = .current) throws -> WorkoutSyncRow {
        guard let id = UUID(uuidString: dto.id) else {
            throw CloudSyncError.malformed(message: "the answer carried an id this app cannot read: \(dto.id)")
        }

        guard let day = day(fromDayKey: dto.date, in: calendar) else {
            throw CloudSyncError.malformed(message: "the answer carried a day this app cannot read: \(dto.date)")
        }

        guard let startedAt = instant(fromInstantKey: dto.startedAt) else {
            throw CloudSyncError.malformed(
                message: "the answer carried a start this app cannot read: \(dto.startedAt)"
            )
        }

        guard let endedAt = instant(fromInstantKey: dto.endedAt) else {
            throw CloudSyncError.malformed(
                message: "the answer carried an end this app cannot read: \(dto.endedAt)"
            )
        }

        return WorkoutSyncRow(
            id: id,
            date: day,
            startedAt: startedAt,
            endedAt: endedAt,
            strain: dto.strain,
            averageHeartRate: dto.averageHeartRate,
            maxHeartRate: dto.maxHeartRate,
            source: dto.source,
            activityName: dto.activityName,
            hrZonePercents: dto.hrZonePercents,
            steps: dto.steps,
            offlineRegionID: dto.offlineRegionID,
            route: try dto.route.map { try routePoint(for: $0) },
            splits: dto.splits.map { split(for: $0) }
        )
    }

    private static func routePointDTO(for point: WorkoutRoutePoint) -> WorkoutRoutePointDTO {
        WorkoutRoutePointDTO(
            id: point.id.uuidString,
            latitude: point.latitude,
            longitude: point.longitude,
            timestamp: instantKey(for: point.timestamp),
            heartRate: point.heartRate
        )
    }

    private static func routePoint(for dto: WorkoutRoutePointDTO) throws -> WorkoutRoutePoint {
        guard let id = UUID(uuidString: dto.id) else {
            throw CloudSyncError.malformed(message: "the answer carried a route point id this app cannot read: \(dto.id)")
        }

        guard let timestamp = instant(fromInstantKey: dto.timestamp) else {
            throw CloudSyncError.malformed(
                message: "the answer carried a route point time this app cannot read: \(dto.timestamp)"
            )
        }

        return WorkoutRoutePoint(
            id: id,
            latitude: dto.latitude,
            longitude: dto.longitude,
            timestamp: timestamp,
            heartRate: dto.heartRate
        )
    }

    private static func splitDTO(for split: WorkoutSplit) -> WorkoutSplitDTO {
        WorkoutSplitDTO(id: split.id.uuidString, elapsed: split.elapsed, strain: split.strain)
    }

    private static func split(for dto: WorkoutSplitDTO) -> WorkoutSplit {
        // No throw, because there is nothing here to refuse: `id` is the only string and
        // `WorkoutSplit`'s initialiser defaults it, so an id this app cannot read costs the split its
        // identity rather than the whole answer its meaning. `routePoint(for:)` throws on the same
        // field because a route point carries a timestamp that has to be parsed either way, and
        // splitting the two policies would be a difference nobody could see.
        WorkoutSplit(
            id: UUID(uuidString: dto.id) ?? UUID(),
            elapsed: dto.elapsed,
            strain: dto.strain
        )
    }

    // MARK: What the database will accept

    /// Whether `row` is a session `POST /v1/workouts` will store.
    ///
    /// **The wire's question and not the app's**, which is the distinction `recoveries` drew between
    /// `isSendable` and `hasMeasurement`: this asks *will the database take it*, and it is stricter
    /// than anything a screen asks. `POST /batch` is one all-or-nothing transaction, so a single row
    /// the server refuses fails a whole chunk — which is why the use case filters on this **before**
    /// chunking rather than inside the chunk loop.
    ///
    /// The rules are `WorkoutSchema`'s and `checkSession`'s, restated in the layer that has to decide:
    ///
    /// - `endedAt` strictly after `startedAt`, **compared on the strings that will be sent and not on
    ///   the `Date`s**. The server compares `parseInstant`'s two answers, so two instants that render
    ///   to the same millisecond are one instant as far as the request is concerned — a sub-
    ///   millisecond session would otherwise be sent and refused with `endedAt must be after
    ///   startedAt`, naming a field whose values look plainly ordered to whoever reads the log.
    /// - `strain` finite and at least zero; `steps` at least zero; both heart rates **positive**,
    ///   never zero — a rate of nought is not a rate, and the schema's `.positive()` says so.
    /// - `source`, `activityName` and `offlineRegionID` non-empty when present. The server's
    ///   `.min(1)` is what makes an empty string a different answer from `nil`, and this app has no
    ///   producer for one, so a row carrying it is a row from somewhere else.
    /// - `hrZonePercents`, when present, is exactly five whole percents in 0…100 summing to **at most**
    ///   100. At most and never exactly: the five bands do not cover a session, because time below
    ///   zone 1 belongs to no band, so a block summing to 100 would be shares of something other than
    ///   the span the app prints beside it. `nil` is not `[0, 0, 0, 0, 0]` and both are sendable —
    ///   the first is a session with no block, the second is a measured workout that never reached
    ///   zone 1, which is 45 of the bundled export's 673 rows.
    /// - every route point's latitude within ±90, longitude within ±180, both finite, and
    ///   `heartRate` positive; every split's `elapsed` and `strain` finite and non-negative.
    /// - `route.count <= 2000` and `splits.count <= 200`, the per-session caps the schema publishes
    ///   as array bounds.
    ///
    /// **The route-point heart rate is the rule that bites, and the answer to it is to skip the row
    /// and never to trim the array.** A live session with `RECORD ROUTE` on can collect its first GPS
    /// fixes before the accumulator has seen a heart-rate sample, and those fixes are stamped with the
    /// documented `0` sentinel — so a row this app produced can hold route points the API will not
    /// take. Dropping those points would send a *different route* from the one on disk, which is
    /// inventing a path the user did not run; so the whole session is skipped, and the caller counts
    /// it and says why. The same reasoning covers every other refusal here: this function answers one
    /// question about the row as a whole, and the caller's remedy is a counted skip rather than an
    /// edit.
    public static func isSendable(_ row: WorkoutSyncRow) -> Bool {
        guard instantKey(for: row.endedAt) > instantKey(for: row.startedAt) else { return false }

        if let strain = row.strain, !(strain.isFinite && strain >= 0) { return false }
        if let average = row.averageHeartRate, average <= 0 { return false }
        if let max = row.maxHeartRate, max <= 0 { return false }
        if let source = row.source, source.isEmpty { return false }
        if let name = row.activityName, name.isEmpty { return false }
        if let region = row.offlineRegionID, region.isEmpty { return false }
        if let steps = row.steps, steps < 0 { return false }
        if let zones = row.hrZonePercents, !isSendable(zones) { return false }

        guard row.route.count <= maximumRoutePoints else { return false }
        guard row.splits.count <= maximumSplits else { return false }

        return row.route.allSatisfy { isSendable($0) } && row.splits.allSatisfy { isSendable($0) }
    }

    /// Whether a zone block is one the wire will take.
    ///
    /// Whole percents and not merely numbers in range: `z.number().int()` is the schema's own bound,
    /// and a fractional share is a value from some other producer — the export's cells are whole, and
    /// the activity detail page refuses a fraction rather than rounding it, because rounding would
    /// invent a reading instead of losing one. `percent == percent.rounded()` is `isInteger`'s test
    /// and it is true for a negative fraction too, which is why the range check is beside it.
    private static func isSendable(_ zones: [Double]) -> Bool {
        guard zones.count == zoneCount else { return false }

        var total: Double = 0
        for share in zones {
            guard share.isFinite, share >= 0, share <= 100 else { return false }
            guard share == share.rounded() else { return false }
            total += share
        }

        return total <= 100
    }

    private static func isSendable(_ point: WorkoutRoutePoint) -> Bool {
        guard point.latitude.isFinite, (-90 ... 90).contains(point.latitude) else { return false }
        guard point.longitude.isFinite, (-180 ... 180).contains(point.longitude) else { return false }
        guard point.heartRate > 0 else { return false }
        return true
    }

    private static func isSendable(_ split: WorkoutSplit) -> Bool {
        guard split.elapsed.isFinite, split.elapsed >= 0 else { return false }
        guard split.strain.isFinite, split.strain >= 0 else { return false }
        return true
    }
}
