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

    /// Whether this fix is worth storing, as opposed to a coordinate the phone never measured.
    ///
    /// It lives here rather than in the CoreLocation-touching service for the reason every extracted
    /// rule in this repo does: the runner has no `CLLocationManager` and must not build one, so a test
    /// written inside `didUpdateLocations` would be a rule nothing can check. `LiveSessionUseCase`
    /// applies it to every point it receives.
    ///
    /// **Two checks, and they are not the same kind of thing.** The range test is definitional — a
    /// latitude outside ±90 is not a place, and `NaN` fails it by construction, which is what catches
    /// a fix built from arithmetic that went wrong. Rejecting exactly `(0, 0)` is a **heuristic**, and
    /// the honest statement of it is that Null Island is the coordinate CoreLocation hands back for a
    /// fix it has not resolved yet; it is also a real point in the Gulf of Guinea, so a route genuinely
    /// recorded there would lose its points. That trade is taken deliberately, because the cost of the
    /// false positive is a missing dot in one place on earth and the cost of the false negative is a
    /// polyline striking across the map from the user's actual position to `0, 0`.
    ///
    /// The *primary* filter is `horizontalAccuracy < 0`, which is CoreLocation's own "this coordinate
    /// is not valid" signal; that one stays in the service, because it is a fact about a `CLLocation`
    /// and cannot be stated on a value type here.
    public var isPlausible: Bool {
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else { return false }
        return !(latitude == 0 && longitude == 0)
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
    /// same thing as a live session here — and because NULL is the honest value for a fact nobody
    /// recorded at the time. An imported session carries `WhoopExportImporter.sourceLabel`.
    ///
    /// **Nothing writes `nil` any more.** The app's own recording path was the workout HUD, which is
    /// deleted, so `nil` now describes only rows an older build left on disk; `whoopExportImporter`
    /// is the sole live producer and it labels everything. The meaning of the value is unchanged and a
    /// future recorder should still write `nil` — but do not read a `nil` row as evidence that this
    /// build recorded it.
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

    /// Steps the strap counted **during this session**, or `nil` when it counted none to report.
    ///
    /// **A session-scoped count and not the day's**, which is what separates it from `StepCount`: the
    /// day's row accumulates a whole day of motion across every session and every waking hour, while
    /// this is the slice of it that fell inside `startedAt`…`endedAt`. The producer is
    /// `LiveSessionUseCase`'s own `StepAccumulator` over the same `motionStream` `TrackStepsUseCase`
    /// reads — the two are independent instances over a multicast stream, which is what the registry
    /// exists for.
    ///
    /// **`nil` and `0` are different answers, and the writer is what keeps them apart.** `0` is a
    /// measured session of no walking; `nil` is a session whose motion was not measured at all — every
    /// imported row (the export carries no step counts, so all 673 of them), every row written before
    /// `v17`, and any session the strap saw no motion batch during. The writer stores `nil` when its
    /// accumulator's `hasMeasurement` is false, and the page draws a dash and withholds the badge there
    /// rather than printing a confident `0`. That is `StepCount.hasMeasurement`'s rule applied to one
    /// session instead of one day, and it is the same test on both sides of the write.
    public let steps: Int?

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
        hrZonePercents: [Double]? = nil,
        steps: Int? = nil
    ) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.strain = strain
        self.averageHeartRate = averageHeartRate; self.maxHeartRate = maxHeartRate
        self.route = route; self.splits = splits
        self.source = source; self.activityName = activityName; self.hrZonePercents = hrZonePercents
        self.steps = steps
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

    /// One band's time, in seconds, or `nil` when the workout carries no zone block.
    ///
    /// The activity detail page's five rows are the **second reader** of this derivation — the strain
    /// page's `zone1to3Seconds`/`zone4to5Seconds` pair is the first — and it needs the bands apart
    /// rather than summed. Rather than a second division at the call site, this forwards to the same
    /// private helper: a row printing `22%` beside `0:03:32` derived twice would be two figures free to
    /// disagree, which is the rule `MetricChange.between` applies to the pair it compares.
    ///
    /// **The whole-block guard is the same one**, so the two accessors can never come apart: a session
    /// with `nil` `hrZonePercents`, or an array that is not five long, answers `nil` for every band —
    /// not `0`, which would be a measured band of no time. The `0` case travels through unchanged and
    /// is the right answer for the 45 rows in the bundled export that never reached zone 1: those are
    /// a measured `0%` and `0:00`, and the page draws them as such.
    public func zoneSeconds(_ index: HeartRateZoneIndex) -> Double? {
        zoneSeconds((index.rawValue - 1)..<index.rawValue)
    }

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
