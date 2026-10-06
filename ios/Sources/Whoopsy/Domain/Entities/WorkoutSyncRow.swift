import Foundation

/// One `workouts` row and everything filed under it, carried between the layers a sync has to cross.
///
/// **The sync moves records, not entities, on `RecoverySyncRow`'s own argument** — and this resource
/// needs it for a second reason that the flat one does not have. A `WorkoutSession` is what a screen
/// draws, and a session read back through `GRDBWorkoutRepository` has already been through
/// `makeSessions`, which **silently drops any row whose id will not parse as a `UUID`** and which
/// builds a fresh `UUID` for the session it did keep. So a push written against the entity would be a
/// push of something the database does not quite hold, and the id it sent would be one nothing on
/// disk has ever had.
///
/// The names are therefore the record's, verbatim, exactly as `RecoverySyncRow`'s are — which is what
/// keeps the row ↔ record conversion a field-for-field copy with no naming decision in it, and leaves
/// `WorkoutWireMapper` the single place in this app where a wire name is written down.
///
/// **The children ride inside the row rather than beside it, and that is the aggregate's shape rather
/// than a convenience.** A recovery is one row keyed on its day; a workout is three tables keyed on
/// `(user_id, id)`, and the API's own contract says so — `route` and `splits` are required fields on
/// every write body, never defaulted, so a body that omitted them would silently wipe a stored route.
/// A row that could not carry them could not be written.
///
/// **The children are domain entities and not records, which is the one place this type departs from
/// the record's names.** `WorkoutRoutePointRecord` carries a `workoutId` the wire has no field for —
/// the parent's own id already states it — and a `String` id where the wire validates a UUID. The
/// entities carry `UUID` and no back-pointer, so the wire mapper's three-level `toWire` is a
/// field-for-field copy at every level. The `String`/`UUID` conversion happens once, at the store's
/// own boundary, and is argued on `WorkoutSyncStore`.
public struct WorkoutSyncRow: Equatable, Sendable {

    /// The session's id, and the thing the API addresses it by: `/v1/workouts/{id}`, never `{date}`.
    ///
    /// **`UUID` rather than the record's `String`, and the refusal is the reason.** `WorkoutIdSchema`
    /// validates a UUID with the message *"the app reads every stored id through `UUID(uuidString:)`"*,
    /// and `GRDBWorkoutRepository.makeSessions` does exactly that, skipping a row it cannot parse. A
    /// non-UUID id is therefore a row that would be stored on the server and never shown on any screen
    /// — so on this side of the boundary it is a **type** fact rather than a validation, and a row
    /// built from a session cannot be unsendable for this reason at all.
    public let id: UUID

    /// The day the session is filed under, as an instant.
    ///
    /// **It is a `Date` here and a `YYYY-MM-DD` on the wire**, converted by the same mapper and by the
    /// same calendar as every other day key in this app. It stays a `Date` on this side because Domain
    /// may not know about the wire's spelling of a day, and because every span this app draws or walks
    /// is a pair of instants rather than a pair of strings.
    public let date: Date

    /// The session's own two instants. Both are stored as fixed-width UTC strings on the wire, which
    /// is what makes the server's `started_at` column sort chronologically as text.
    public let startedAt: Date
    public let endedAt: Date

    /// The session's cardiovascular load, and its two heart rates — all three `nil` for a session
    /// nothing measured them on, and none of them defaulted.
    ///
    /// The absence is the fasting import's: a fast is time held rather than work done, so a `0.0` here
    /// would claim *measured, and no strain at all* about a session with no sensor behind it.
    public let strain: Double?
    public let averageHeartRate: Int?
    public let maxHeartRate: Int?

    /// Which producer wrote the row, or `nil` for a session this app recorded live.
    ///
    /// **This is the field the whole type exists to preserve on the recoveries row, and it is the same
    /// field here** — a column, on the wire, and absent from nothing else that carries the session's
    /// measurements. It is also read rather than merely written: `WhoopExportImporter` excludes rows
    /// carrying a fast label from its day skip, so a sync that dropped the label would change which
    /// days an import writes to.
    public let source: String?

    /// WHOOP's own name for the session, when it came out of `workouts.csv`.
    ///
    /// Not an absence marker: `nil` means the file did not say, and a name is not a measurement. The
    /// wire treats it as a plain nullable string for the same reason.
    public let activityName: String?

    /// WHOOP's own five zone percentages, in the order the wire's `hrZonePercents` requires.
    ///
    /// `nil` is not `[0, 0, 0, 0, 0]`: the latter is a measured workout that never reached zone 1, and
    /// the bundled export holds 45 of those. The wire's rule is subtly weaker than the column's —
    /// the five shares must be whole numbers in 0…100 summing to **at most** 100, because time below
    /// zone 1 belongs to no band — and `WorkoutWireMapper.isSendable` is where that is spelled.
    public let hrZonePercents: [Double]?

    /// Steps the strap counted during this session, or `nil` when it counted none to report.
    public let steps: Int?

    /// The offline map region this session downloaded, when the user turned `USE OFFLINE MAP` on.
    ///
    /// A join key into Mapbox's own tile store rather than an absence a screen draws, which is why its
    /// only reader gates on the region being `.ready` rather than on this being non-`nil`. On the wire
    /// it is an ordinary nullable string; nothing validates its shape, because only the device that
    /// wrote it has a store to look it up in.
    public let offlineRegionID: String?

    /// The session's GPS fixes, **in the order they were recorded**.
    ///
    /// The order is the field. The local child table has no `seq` column and recovers order by sorting
    /// on `timestamp`; the wire's `WorkoutRoutePoint` has no `seq` either, because a JSON array is
    /// already ordered — and the server's `workout_route_points` binds its `seq` from the array index.
    /// So this array's order *is* the round trip, and a mapper that re-sorted it would be inventing a
    /// second ordering rule that agrees today and need not tomorrow.
    public let route: [WorkoutRoutePoint]

    /// The session's splits, **in the order they were taken** — the same rule as `route`.
    public let splits: [WorkoutSplit]

    public init(
        id: UUID,
        date: Date,
        startedAt: Date,
        endedAt: Date,
        strain: Double?,
        averageHeartRate: Int?,
        maxHeartRate: Int?,
        source: String? = nil,
        activityName: String? = nil,
        hrZonePercents: [Double]? = nil,
        steps: Int? = nil,
        offlineRegionID: String? = nil,
        route: [WorkoutRoutePoint] = [],
        splits: [WorkoutSplit] = []
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

    /// The entity a screen would draw, rebuilt from the row's own fields.
    ///
    /// A field-for-field copy in the other direction, since `WorkoutSession` carries the same
    /// measurements under the same names — and unlike `RecoverySyncRow.metric` this one loses nothing
    /// at all: `source`, `steps` and `offlineRegionID` are all fields on the entity, so a screen
    /// reached through this row sees the same session the database holds.
    public var session: WorkoutSession {
        WorkoutSession(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            strain: strain,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            route: route,
            splits: splits,
            source: source,
            activityName: activityName,
            hrZonePercents: hrZonePercents,
            steps: steps,
            offlineRegionID: offlineRegionID
        )
    }

    /// The row a session would be stored as.
    ///
    /// **The day is snapped here rather than taken from the session's start**, because that is what
    /// the column holds: `LocalDatabaseManager.saveWorkout` snaps `date` centrally and
    /// `getWorkouts(for:)` matches on the snapped key, so a row built with a raw instant would be
    /// filed on a day nothing reads. The session has no `date` field to copy — it is a derived column
    /// and this is the derivation.
    public init(_ session: WorkoutSession, calendar: Calendar = .current) {
        self.init(
            id: session.id,
            date: calendar.startOfDay(for: session.startedAt),
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            strain: session.strain,
            averageHeartRate: session.averageHeartRate,
            maxHeartRate: session.maxHeartRate,
            source: session.source,
            activityName: session.activityName,
            hrZonePercents: session.hrZonePercents,
            steps: session.steps,
            offlineRegionID: session.offlineRegionID,
            route: session.route,
            splits: session.splits
        )
    }
}
