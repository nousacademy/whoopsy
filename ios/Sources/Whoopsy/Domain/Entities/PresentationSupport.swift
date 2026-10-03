import Foundation

public struct WorkoutRoutePoint: Identifiable, Equatable, Hashable, Sendable {
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

public struct WorkoutSplit: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let elapsed: TimeInterval
    public let strain: Double
    public init(id: UUID = UUID(), elapsed: TimeInterval, strain: Double) { self.id = id; self.elapsed = elapsed; self.strain = strain }
}

/// `Hashable` is spelled out for one call site and is not incidental: `HomeDashboardView` pushes this
/// page through `navigationDestination(item:)`, whose item binding requires it. The three types
/// involved are all plain values over `UUID`, `Date`, `Double`, `Int` and `String`, so the conformance
/// is synthesised and carries no equality of its own — `==` still means what `Equatable` meant here
/// before it, which matters because `HomeViewModel.workouts` is replaced wholesale on every day change.
public struct WorkoutSession: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    /// The session's cardiovascular load on WHOOP's 0–21 scale, and `nil` for a session nothing
    /// measured one on.
    ///
    /// **`nil` and `0.0` are different answers**, and the distinction is the one every absence rule in
    /// this app turns on. `0.0` is a measured session that never left zone 1 — `LiveSessionAccumulator`
    /// produces exactly that for a session it watched at rest — while `nil` is a session with no sensor
    /// behind it at all. The Zero fasting import is the producer that needs the second: a fasting window
    /// is time held rather than work done, so there is no strain to report and a `0.0` would claim
    /// *measured, and no strain at all*.
    ///
    /// It is optional on the same reasoning as `steps` below — optional on the entity, nullable in the
    /// column (`v18`), `nil` written by the producer that measured nothing, a dash drawn by the reader
    /// (`ActivityFigure.strainText`). What it is **not** is an invitation to default it: the parameter
    /// has no default, so every construction site has to state which of the two answers it means.
    public let strain: Double?

    /// The session's mean and peak heart rate, in bpm, or `nil` for a session nothing measured them on.
    ///
    /// Two separate fields with two separate absences — a session can carry one and not the other, and
    /// nothing here couples them. `nil` is not `0`: a heart rate of zero is not a measurement of a
    /// still heart but the absence of one, which is why neither is defaulted at the initialiser.
    ///
    /// The three of them were non-optional until `v18`, with a doc comment recording that the fix
    /// would be to make them optional once a producer without a sensor needed to say so. That producer
    /// is `ZeroFastingImporter`, and this is that fix.
    public let averageHeartRate: Int?
    public let maxHeartRate: Int?
    public let route: [WorkoutRoutePoint]
    public let splits: [WorkoutSplit]

    /// Which producer this session came from, or `nil` for one this app recorded live.
    ///
    /// `nil` rather than a `"strap"` label because a row written before the column existed is the
    /// same thing as a live session here — and because NULL is the honest value for a fact nobody
    /// recorded at the time. An imported session carries its own importer's label:
    /// `WhoopExportImporter.sourceLabel` for a row out of `workouts.csv`, `ZeroFastingImporter`
    /// `.sourceLabel` for one out of the Zero export.
    ///
    /// **`LiveSessionUseCase` is the writer of `nil`.** Its `end()` is the app's own recording path and
    /// stores `nil` for a session this app recorded live, so a `nil` row is that rather than only a
    /// leftover from an older build. The two importers are the other producers and both label
    /// everything. **One further value exists for one case**: `ActiveFast.sourceLabel`, written by
    /// `LiveSessionUseCase.endFast()`. A hand-recorded fast is neither a measured live session nor an
    /// import — it is a row this app recorded that carries no measurement at all — so it is a fourth
    /// thing and says so. `ActiveFast.fastSourceValues` is the set of values meaning *this row is a
    /// fast*, and it is the one place that set is written down, because `recordedWorkoutDays()` below
    /// needs both members and the importer is `Data` while `ActiveFast` is `Domain`.
    ///
    /// **It is read, not just written.** `WhoopExportImporter.recordedWorkoutDays()` excludes rows
    /// carrying a fast label, so the export's own day skip does not mistake a fast for a workout this
    /// app already imported — which is why the label is a compared value rather than a note.
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

    /// The name of the offline map region this session downloaded, when `USE OFFLINE MAP` was on.
    ///
    /// **Defaulted, unlike the three measured fields above, and the difference is the point.** Those
    /// have no default precisely so a construction site cannot silently let a measurement degrade to
    /// `nil`. This is not a measurement — it is a join key into Mapbox's tile store — so a default
    /// cannot turn a reading into an absence, and requiring every one of the app's construction sites
    /// to pass it would be noise for a feature most sessions do not use.
    ///
    /// `nil` on every session recorded with the switch off and on every row written before `v19`. Its
    /// only reader is `RouteMapRenderer.resolve(session:state:)`, and a `nil` there resolves to the
    /// MapKit card rather than to a blank one.
    public let offlineRegionID: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        strain: Double?,
        averageHeartRate: Int?,
        maxHeartRate: Int?,
        route: [WorkoutRoutePoint],
        splits: [WorkoutSplit],
        source: String? = nil,
        activityName: String? = nil,
        hrZonePercents: [Double]? = nil,
        steps: Int? = nil,
        offlineRegionID: String? = nil
    ) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.strain = strain
        self.averageHeartRate = averageHeartRate; self.maxHeartRate = maxHeartRate
        self.route = route; self.splits = splits
        self.source = source; self.activityName = activityName; self.hrZonePercents = hrZonePercents
        self.steps = steps
        self.offlineRegionID = offlineRegionID
    }

    /// The workout's own length, in seconds — the scale every zone figure is a share of.
    public var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }

    /// How much of this session had elapsed by the end of `day`, clamped to the session's own end.
    ///
    /// This is what makes a fast's pill a function of the day rather than of the fast: an 86-hour fast
    /// draws `KETOSIS` on its second day and `DEEP KETOSIS` on its fourth, because a zone is a claim
    /// about how long the body has been fasting and on a day the fast merely passes through only part of
    /// it has happened yet.
    ///
    /// **It snaps `day` itself**, which `Date.startOfNextDay` does and this depends on — see that
    /// property for why a caller's `today at 14:23` must not become the day's end. The `max(0, …)` floor
    /// is the other half: on a day entirely before the session started the subtraction is negative, and a
    /// negative elapsed would run `FastingZone.zone(forDurationSeconds:)` backwards past `ANABOLIC` into
    /// no zone at all. The `min` is the clamp — on a day after the session ended, the day's own end is
    /// later than `endedAt`, and without it a long-finished fast would keep climbing zones forever.
    ///
    /// Lives on the entity and not inside `ActivityFigure` for this repo's standing reason: the runner
    /// has no renderer, so a rule written into a `body` is a rule nothing can assert — and this
    /// arithmetic *is* the feature. `Calendar.current` is required rather than merely acceptable,
    /// because the day keys it must agree with are the ones `LocalDatabaseManager.saveWorkout` snapped
    /// with the same calendar; a caller passing another zone's calendar would not shift a day key, it
    /// would split it.
    public func elapsedSeconds(byEndOf day: Date) -> TimeInterval {
        max(0, min(endedAt, day.startOfNextDay).timeIntervalSince(startedAt))
    }

    /// Whether this session was underway at any point during `day`, by the half-open rule.
    ///
    /// `getWorkouts(covering:)`'s SQL predicate is this rule's index-friendly twin — it tests the same
    /// thing against the snapped `date` column instead of `startedAt`, which are the same answer because
    /// `saveWorkout` snaps. It exists as a value for the reason `FastingZone.zone(forDurationSeconds:)`
    /// does: the boundary belongs somewhere a test can pin it, and this end of it is a comparison rather
    /// than a query string.
    ///
    /// **Half-open is the whole of it.** `startedAt` at exactly the day's own end belongs to the *next*
    /// day and not this one, and `endedAt` at exactly midnight belongs to the day it ended on and not
    /// the one it ended at — a 23:00 → 00:00 session covers one day, not two. An inclusive test at
    /// either end would draw a session on a day it was not running, which is the same over-claim as a
    /// fabricated reading.
    public func covers(_ day: Date) -> Bool {
        startedAt < day.startOfNextDay && endedAt > day.startOfDay
    }

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

    /// Whether the profile form shows and accepts metric units, or `nil` when nobody has chosen.
    ///
    /// **The three-state is the whole point, and it is the `—`-not-`0` rule applied to a preference.**
    /// `UserDefaults.bool(forKey:)` answers `false` for a key that was never written, so a plain `Bool`
    /// would draw an imperial profile for a user whose phone measures in metric — a choice they never
    /// made, presented as theirs. `nil` means *nobody has chosen*, and the form resolves it through
    /// `ActivityRoute.Unit.forLocale(.current)`, the same answer the activity route card derives. The
    /// two therefore agree on a fresh install by construction rather than by a second guess.
    ///
    /// **This governs the four BIOMETRICS fields and nothing else** — not the activity route card, which
    /// keeps following the phone's locale. With the preference unset the two agree, so the mismatch is
    /// only reachable by a user who picks a unit their phone disagrees with.
    ///
    /// **A `UserDefaults` key rather than a `user_profiles` column**, on the argument already written
    /// against `UserDefaultsStrapModelRepository` below: a migration is frozen once shipped and a
    /// failing one `fatalError`s the app at launch, so a schema version is a permanent cost paid for data
    /// that is a *preference*, not a measurement. Nothing stored changes when this changes; only how a
    /// stored value is presented and accepted.
    public var usesMetricUnits: Bool?

    public init(
        analyticsEnabled: Bool = false,
        healthKitSyncEnabled: Bool = false,
        liveHeartRateBroadcastEnabled: Bool = false,
        usesMetricUnits: Bool? = nil
    ) {
        self.analyticsEnabled = analyticsEnabled; self.healthKitSyncEnabled = healthKitSyncEnabled; self.liveHeartRateBroadcastEnabled = liveHeartRateBroadcastEnabled; self.usesMetricUnits = usesMetricUnits
    }
}
