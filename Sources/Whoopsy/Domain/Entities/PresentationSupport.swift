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

    /// Which producer this session came from, or `nil` for one this app recorded live.
    ///
    /// `nil` rather than a `"strap"` label because a row written before the column existed is the
    /// same thing as a live session here — the app's own recording path is the only other writer —
    /// and because NULL is the honest value for a fact nobody recorded at the time. An imported
    /// session carries `WhoopExportImporter.sourceLabel`.
    public let source: String?

    /// WHOOP's own name for the session — `Walking`, `Yoga`, `Activity` — when it came out of
    /// `workouts.csv`.
    ///
    /// A **name**, not a measurement, which is why it is optional without being an absence marker:
    /// `nil` here means the file did not say, and it is the value on every session this app recorded
    /// itself and on every row written before `v15`. The screen draws WHOOP's own word for an
    /// uncategorised activity — `ACTIVITY` — for that case, rather than a dash. A dash would say
    /// *not measured* about the one field on the row that was never a measurement, and `ACTIVITY` is
    /// not a placeholder: it is the literal name on 197 of the file's own 673 rows.
    ///
    /// The string is the file's own, in the file's own casing. Only the drawing uppercases it.
    public let activityName: String?

    /// WHOOP's own `HR Zone 1 %`…`HR Zone 5 %` for the workout, when it came out of `workouts.csv`.
    ///
    /// **Percentages, not seconds**, so the file's own resolution is preserved and no derived
    /// duration is baked into a row: the span is already in `startedAt`/`endedAt`, and
    /// `zone1to3Seconds` is the one place the two are combined.
    ///
    /// `nil` on every session this app recorded itself and on every row written before `v14`. That is
    /// not the same as `[0, 0, 0, 0, 0]`, which is a measured workout that never reached zone 1 — the
    /// bundled file holds 45 of those, and the strain page draws one as a real `0:00` and the other
    /// as a dash.
    public let hrZonePercents: [Double]?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        strain: Double,
        averageHeartRate: Int,
        maxHeartRate: Int,
        route: [WorkoutRoutePoint],
        splits: [WorkoutSplit],
        source: String? = nil,
        activityName: String? = nil,
        hrZonePercents: [Double]? = nil
    ) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.strain = strain
        self.averageHeartRate = averageHeartRate; self.maxHeartRate = maxHeartRate
        self.route = route; self.splits = splits
        self.source = source; self.activityName = activityName; self.hrZonePercents = hrZonePercents
    }

    /// The workout's own length, in seconds — the scale every zone figure is a share of.
    public var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }

    /// Time in zones 1–3 and 4–5, in seconds, or `nil` when the workout carries no zone block.
    ///
    /// **The five percentages do not sum to 100**, so these two do not sum to the workout either. The
    /// remainder is time below zone 1, which WHOOP publishes no column for. `nil` in, `nil` out: an
    /// absent block must not become a measured `0`.
    public var zone1to3Seconds: Double? { zoneSeconds(0..<3) }
    public var zone4to5Seconds: Double? { zoneSeconds(3..<5) }

    private func zoneSeconds(_ range: Range<Int>) -> Double? {
        guard let percents = hrZonePercents, percents.count == 5 else { return nil }
        let share = range.reduce(0.0) { $0 + percents[$1] } / 100
        return share * durationSeconds
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
