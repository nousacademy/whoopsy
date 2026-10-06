import Foundation

/// The two conversions between a stored session and the shape a sync moves — for the parent *and* for
/// both of its children, because on this resource the row is an aggregate.
///
/// **This is `RecoveryRecord+SyncRow.swift`'s file, and it is three times the size for the schema's
/// reason rather than a mapping's.** A recovery is one row keyed on its day, so one extension and two
/// initialisers cover it. A workout is three tables keyed on `(user_id, id)`, the API requires a route
/// and a split list on every write body, and nothing about a route has an identity outside the session
/// that owns it — so the conversions have to carry the children or the row could not be written at all.
///
/// **The record property names are copied field for field, exactly as the flat one's are.** A workout
/// reading goes by three names on its way from SQLite to the wire — `offline_region_id` /
/// `offlineRegionID` / `offlineRegionID` — and the middle one is deliberately not a fourth spelling:
/// `WorkoutSyncRow` takes the *record's* property names, so `WorkoutWireMapper` stays the single place
/// in this app where a wire name is written down.
///
/// **Hand-written and not reflective**, on the same bargain `RecoveryRecord+SyncRow` documents: a
/// `Mirror`-based copy would silently stop covering a field the day someone adds one to `WorkoutRecord`,
/// dropping the new column on every synced row with a green build and no log line. Written out, a
/// fourteenth property is a compile error here.
extension WorkoutRecord {

    /// The row a sync sends for this record and its children, or `nil` when the stored id will not parse.
    ///
    /// **`nil` rather than a fresh `UUID`, and `GRDBWorkoutRepository.makeSessions` is where that rule
    /// already lives.** A session's id is the thing the API addresses it by and the thing every keyed
    /// read matches on, so inventing an identity for a row nobody can address would hand the sync a
    /// session that corresponds to nothing stored — and it would be *sent* under an id no screen of this
    /// app would ever find again. A route point's id is not part of any lookup, which is why the children
    /// below are treated the other way round; the two policies differ because the two ids are used
    /// differently, and neither is a preference.
    func syncRow(route: [WorkoutRoutePointRecord], splits: [WorkoutSplitRecord]) -> WorkoutSyncRow? {
        guard let id = UUID(uuidString: id) else { return nil }

        return WorkoutSyncRow(
            id: id,
            date: date,
            startedAt: startedAt,
            endedAt: endedAt,
            strain: strain,
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            source: source,
            activityName: activityName,
            hrZonePercents: hrZonePercents,
            steps: steps,
            offlineRegionID: offlineRegionID,
            // **In read order, never re-sorted.** The child table has no `seq` column and order is
            // recovered by the manager's `ORDER BY timestamp`, so this array's order is the only record
            // of the sequence the fixes were taken in — and the wire binds its own `seq` from this
            // array's index. Sorting here would be a second ordering rule that agrees with the first
            // today and need not tomorrow.
            route: route.map(\.routePoint),
            splits: splits.map(\.workoutSplit)
        )
    }

    /// The record a row arriving from a sync is stored as.
    ///
    /// Nothing is defaulted and nothing is filled in, on the flat one's argument: a row that arrives
    /// without a strain stores a NULL, which is this schema's word for *nobody measured one* and a
    /// different answer from `0`. The `date` is left as the mapper handed it over — already
    /// `startOfDay` in the device's own zone — and `saveWorkout` snaps it again on the way in, because
    /// that is where every other writer in this app snaps it.
    ///
    /// The id is spelled here and nowhere else: `WorkoutSyncRow.id` is a `UUID` and this column is a
    /// `String`, so this initialiser and `syncRow(route:splits:)` above are the pair that carries the
    /// conversion across the boundary — which is what `WorkoutSyncStore`'s doc comment means by saying
    /// it happens once.
    init(_ row: WorkoutSyncRow) {
        self.init(
            id: row.id.uuidString,
            date: row.date,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            strain: row.strain,
            averageHeartRate: row.averageHeartRate,
            maxHeartRate: row.maxHeartRate,
            source: row.source,
            activityName: row.activityName,
            hrZonePercents: row.hrZonePercents,
            steps: row.steps,
            offlineRegionID: row.offlineRegionID
        )
    }
}

extension WorkoutRoutePointRecord {

    /// The entity a screen would draw this fix as.
    ///
    /// **A point whose stored id will not parse keeps its place and takes a fresh identity**, and that is
    /// `makeSessions`' documented rule rather than a convenience: the fix is at a real place at a real
    /// moment, and its id is not part of any lookup — unlike the session's, which is why a session with
    /// an unreadable id is dropped instead. Dropping the point would leave a hole in a recorded path,
    /// which is a drawing of a route the user did not take, and the ids it is compared against are only
    /// ever this array's own ordering.
    var routePoint: WorkoutRoutePoint {
        WorkoutRoutePoint(
            id: UUID(uuidString: id) ?? UUID(),
            latitude: latitude,
            longitude: longitude,
            timestamp: timestamp,
            heartRate: heartRate
        )
    }

    /// The child row a synced fix is stored as, taking its owner from the parent's own id.
    ///
    /// **The back-pointer is the one field the wire has no equivalent for**, which is why it is a
    /// parameter here rather than a field on the entity: a route has no identity outside the session
    /// that owns it, so the parent's id is the only honest source for `workout_id` and passing it in is
    /// what keeps that visible at the call site.
    init(_ point: WorkoutRoutePoint, workoutId: String) {
        self.init(
            id: point.id.uuidString,
            workoutId: workoutId,
            latitude: point.latitude,
            longitude: point.longitude,
            timestamp: point.timestamp,
            heartRate: point.heartRate
        )
    }
}

extension WorkoutSplitRecord {

    /// The entity a screen would draw this split as — the point's id rule and its reason, verbatim.
    var workoutSplit: WorkoutSplit {
        WorkoutSplit(id: UUID(uuidString: id) ?? UUID(), elapsed: elapsed, strain: strain)
    }

    init(_ split: WorkoutSplit, workoutId: String) {
        self.init(
            id: split.id.uuidString,
            workoutId: workoutId,
            elapsed: split.elapsed,
            strain: split.strain
        )
    }
}
