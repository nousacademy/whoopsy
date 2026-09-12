import Foundation

public struct WorkoutRoutePoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let heartRate: Int

    public init(id: UUID = UUID(), latitude: Double, longitude: Double, timestamp: Date = .now, heartRate: Int) {
        self.id = id; self.latitude = latitude; self.longitude = longitude; self.timestamp = timestamp; self.heartRate = heartRate
    }
}

public struct WorkoutSplit: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let elapsed: TimeInterval
    public let strain: Double
    public init(id: UUID = UUID(), elapsed: TimeInterval, strain: Double) { self.id = id; self.elapsed = elapsed; self.strain = strain }
}

public struct WorkoutSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let strain: Double
    public let averageHeartRate: Int
    public let maxHeartRate: Int
    public let route: [WorkoutRoutePoint]
    public let splits: [WorkoutSplit]
    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, strain: Double, averageHeartRate: Int, maxHeartRate: Int, route: [WorkoutRoutePoint], splits: [WorkoutSplit]) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.strain = strain; self.averageHeartRate = averageHeartRate; self.maxHeartRate = maxHeartRate; self.route = route; self.splits = splits
    }
}

public struct CoachInsight: Identifiable, Equatable, Sendable {
    public enum Tone: String, Sendable { case recovery, activity, sleep }
    public let id: UUID
    public let title: String
    public let message: String
    public let tone: Tone
    public init(id: UUID = UUID(), title: String, message: String, tone: Tone) { self.id = id; self.title = title; self.message = message; self.tone = tone }
}

public struct AppPreferences: Equatable, Sendable {
    public var analyticsEnabled: Bool
    public var healthKitSyncEnabled: Bool
    public var liveHeartRateBroadcastEnabled: Bool
    /// Whether the bundled WHOOP export has been imported at least once.
    ///
    /// This records that the *button was pressed*, not that the import succeeded — a failed import
    /// throws before it is set. Nothing in the app gates on it: the import is idempotent, so a second
    /// run is harmless. It exists so Settings can tell the user which of the two they are looking at.
    public var hasImportedWhoopExport: Bool
    public init(
        analyticsEnabled: Bool = false,
        healthKitSyncEnabled: Bool = false,
        liveHeartRateBroadcastEnabled: Bool = false,
        hasImportedWhoopExport: Bool = false
    ) {
        self.analyticsEnabled = analyticsEnabled; self.healthKitSyncEnabled = healthKitSyncEnabled; self.liveHeartRateBroadcastEnabled = liveHeartRateBroadcastEnabled; self.hasImportedWhoopExport = hasImportedWhoopExport
    }
}
