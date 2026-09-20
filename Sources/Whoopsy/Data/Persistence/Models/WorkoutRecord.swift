import Foundation
import GRDB

/// A recorded workout session, its route, and its splits.
///
/// All three types live in one file because they are one aggregate: a route point or a split has no
/// meaning apart from the workout it belongs to, and both cascade with it. Splitting them across
/// three files would overstate their independence.
///
/// **This table is not day-keyed the way `recoveries`/`sleeps`/`strains` are.** Those three hold one
/// row per day and are primary-keyed on `date`, which is why every writer snaps to `startOfDay` and
/// why a raw timestamp there is silent data loss. A day can hold several workouts, so `id` is the
/// primary key and `date` is an ordinary indexed lookup column. The snap still matters here — it is
/// what `getWorkouts(for:)` matches on — but two workouts on one day are two rows, not a collision.
public struct WorkoutRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "workouts"

    public let id: String

    /// `startOfDay(startedAt)`, snapped by `LocalDatabaseManager.saveWorkout`. See the type comment.
    public var date: Date

    public let startedAt: Date
    public let endedAt: Date
    public let strain: Double
    public let averageHeartRate: Int
    public let maxHeartRate: Int

    /// Where the row came from, when that is worth recording — see `RecoveryRecord.source`. A
    /// workout recorded here carries no source; a row imported from the export's `workouts.csv`
    /// carries `WhoopExportImporter.sourceLabel`, which is what tells the two apart.
    public let source: String?

    /// What WHOOP called the workout, out of `workouts.csv`'s `Activity name` column — the file's own
    /// string in the file's own casing.
    ///
    /// `nil` on every session this app recorded itself and on every row written before `v15`. Unlike
    /// `hrZonePercents` that `nil` is not an absence marker: a name is not a measurement, so `nil` and
    /// a stored `"Activity"` both reach the screen as a label rather than as a dash.
    public let activityName: String?

    /// WHOOP's own five zone percentages, JSON-encoded into a `.text` column — the `[Double]?` shape
    /// `biometric_samples.rrIntervalsMs` (`v8`) and `sleeps.sleep_stages` (`v12`) already use, because
    /// `Array` is not a `DatabaseValueConvertible` and can therefore only ever be a record property.
    ///
    /// `nil` on every session this app recorded itself and on every row written before `v14`. `nil` is
    /// not `[0, 0, 0, 0, 0]`: the latter is a workout that never reached zone 1.
    public let hrZonePercents: [Double]?

    public init(
        id: String,
        date: Date,
        startedAt: Date,
        endedAt: Date,
        strain: Double,
        averageHeartRate: Int,
        maxHeartRate: Int,
        source: String? = nil,
        activityName: String? = nil,
        hrZonePercents: [Double]? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case strain
        case averageHeartRate = "average_heart_rate"
        case maxHeartRate = "max_heart_rate"
        case source
        case activityName = "activity_name"
        case hrZonePercents = "hr_zone_percents"
    }
}

/// One GPS fix of a workout's route. `heart_rate` is the reading at the moment of the fix, which is
/// what colours the map polyline — a zero here means the strap had no reading then, not a pulse.
public struct WorkoutRoutePointRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "workout_route_points"

    public let id: String
    public let workoutId: String
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let heartRate: Int

    public init(
        id: String,
        workoutId: String,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        heartRate: Int
    ) {
        self.id = id
        self.workoutId = workoutId
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.heartRate = heartRate
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workoutId = "workout_id"
        case latitude
        case longitude
        case timestamp
        case heartRate = "heart_rate"
    }
}

/// A split the user tapped mid-workout: the elapsed time and the strain accumulated by then.
public struct WorkoutSplitRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "workout_splits"

    public let id: String
    public let workoutId: String
    public let elapsed: Double
    public let strain: Double

    public init(id: String, workoutId: String, elapsed: Double, strain: Double) {
        self.id = id
        self.workoutId = workoutId
        self.elapsed = elapsed
        self.strain = strain
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workoutId = "workout_id"
        case elapsed
        case strain
    }
}
