import Foundation

/// The two activity figures the strain page's card reads that are not a stored row of their own:
/// **the day's time in zones 1–3 and 4–5**, and **the day's strength activity time**.
///
/// ## Why this is a value and not logic in the view model
///
/// The runner has no renderer, so a rule written into a `body` — or into an `await` sequence inside a
/// load — is a rule nothing can assert. Three things here are worth asserting and none of them is
/// visible in a screenshot: which producer a day's zone time came from, whether a baseline may be
/// printed beside it, and the difference between a measured zero and an absence.
///
/// ## The zone rows: one producer per figure, and a baseline that matches it
///
/// A session's time in a band comes from exactly one of two producers, the rule `ActivityZoneRow`
/// states for the activity page and reuses here:
///
/// - **measured** — `ZoneTimeMath.totals` over the session's own heart-rate samples. Every session
///   this app recorded has this.
/// - **imported** — WHOOP's `HR Zone n %` block scaled by the session's span, through
///   `WorkoutSession.zoneSeconds(_:)`.
///
/// Measured wins. The consequence for the *comparison* is the part that is a rule rather than a
/// convenience: the strain page's baseline is a mean over the last thirty days **whose zone totals
/// come from WHOOP blocks** (that history is read as rows; folding thirty days of samples per page
/// open is not affordable, and `ActivityZoneBaseline` refuses the mixture for the same reason). So a
/// day whose own figure is measured must not be printed against that mean — the two would be different
/// quantities under one comparison. `ZoneTime.isMeasuredOnly` is what withholds the marker.
///
/// ## Strength: the app's own definition, and a real zero
///
/// `WhoopActivityCatalog.strengthActivities` is this app's list of resistance activities, because
/// WHOOP's `^` membership is not published in a form this repo can reproduce. A day's figure is the
/// sum of the session spans whose activity is in that set. **An empty sum is `0`, not a dash**: on a
/// day with workouts the card is drawn, and "no strength session today" is a measured zero under any
/// definition. Only a day with no workouts at all is `nil` — which is the same day the card is absent
/// on, so the value and the card's gate agree.
public enum StrainDayActivity {

    /// A day's zone time, and whether every contributing figure was this app's own measurement.
    public struct ZoneTime: Equatable, Sendable {
        /// `nil` when no session on the day carries either producer — the ordinary state of a day
        /// whose sessions were recorded before this build, and of any session with no usable samples.
        public let value: WorkoutZoneTime?

        /// True only when the day has a value and **every** session behind it was folded from samples.
        /// A day mixing a measured session and an imported one is not measured-only: a mean built on
        /// one producer cannot be printed beside a figure built on both.
        public let isMeasuredOnly: Bool

        public init(value: WorkoutZoneTime?, isMeasuredOnly: Bool) {
            self.value = value
            self.isMeasuredOnly = isMeasuredOnly
        }

        public static let none = ZoneTime(value: nil, isMeasuredOnly: false)
    }

    /// Sums the day's sessions into the two bands the card draws.
    ///
    /// - Parameter measured: each session's own fold, by id. A session absent from the map falls back
    ///   to its WHOOP block; a session with neither contributes nothing.
    public static func zoneTime(
        for sessions: [WorkoutSession],
        measured: [UUID: ZoneTimeMath.Totals]
    ) -> ZoneTime {
        guard let date = sessions.first?.startedAt.startOfDay else { return .none }

        var zone1to3: Double = 0
        var zone4to5: Double = 0
        var contributing = 0
        var allMeasured = true

        for session in sessions {
            if let totals = measured[session.id] {
                zone1to3 += (0..<3).reduce(0) { $0 + totals.seconds(in: HeartRateZoneIndex(rawValue: 1 + $1) ?? .zone1) }
                zone4to5 += (3..<5).reduce(0) { $0 + totals.seconds(in: HeartRateZoneIndex(rawValue: 1 + $1) ?? .zone1) }
                contributing += 1
            } else if let block1to3 = session.zone1to3Seconds, let block4to5 = session.zone4to5Seconds {
                zone1to3 += block1to3
                zone4to5 += block4to5
                contributing += 1
                allMeasured = false
            }
        }

        guard contributing > 0 else { return .none }
        return ZoneTime(
            value: WorkoutZoneTime(
                date: date, zone1to3Seconds: zone1to3, zone4to5Seconds: zone4to5),
            isMeasuredOnly: allMeasured)
    }

    /// The day's strength activity time in seconds, or `nil` on a day with no workouts.
    ///
    /// **A zero is a measurement here**, which is the difference between this row and the zone rows: a
    /// day with a workout and no strength session really did spend no time doing strength work, while
    /// a day with no zone data has no reading at all.
    public static func strengthSeconds(for sessions: [WorkoutSession]) -> Double? {
        guard !sessions.isEmpty else { return nil }
        return sessions
            .filter { WhoopActivityCatalog.isStrength($0.activityName) }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// The trailing window's mean strength seconds, or `nil` below the shared baseline floor.
    ///
    /// One day is one observation: a day's sessions are summed first, so several short sessions do not
    /// count as several observations. The window is `RecoveryScoring.window` — strictly before the day,
    /// then the trailing thirty — and its floor is `minimumBaselineDays`, the same constant the zone and
    /// step means use, so the card's three comparisons cannot disagree about how much history a mean
    /// needs. **Days with no workouts are absent from the series**, which is the card's own frame: the
    /// rows describe activity, and a rest day is already absent from it.
    ///
    /// A day that had workouts but no strength session contributes a real `0` — the same reading the
    /// row would show on that day.
    public static func strengthBaseline(
        from history: [WorkoutSession], before date: Date
    ) -> Double? {
        let byDay = Dictionary(grouping: history) { $0.startedAt.startOfDay }
        let series = byDay.map { day, sessions in
            DayStrength(date: day, seconds: strengthSeconds(for: sessions) ?? 0)
        }
        .sorted { $0.date < $1.date }

        let window = RecoveryScoring.window(before: date, in: series, dated: \.date)
        guard window.count >= RecoveryScoring.minimumBaselineDays else { return nil }
        return window.reduce(0) { $0 + $1.seconds } / Double(window.count)
    }

    /// One day in the strength series — a date and a figure, which is all the window needs.
    public struct DayStrength: Equatable, Sendable {
        public let date: Date
        public let seconds: Double

        public init(date: Date, seconds: Double) {
            self.date = date
            self.seconds = seconds
        }
    }
}
