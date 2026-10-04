import Foundation
import SwiftUI
import Whoopsy

// MARK: - 19. The activity detail page

/// §19 — the activity detail page, reached by tapping an activity row on Home.
///
/// **Nothing here is evidence about a strap**, on §16's, §17's and §18's terms verbatim:
/// `biometric_samples` holds 0 rows in every database on this machine, so the heart-rate trace the
/// page draws is `No Data` on every session this app can show, and the blocks below prove arithmetic,
/// storage, screens and the two readers of one multicast stream — not whether a strap answers.
///
/// It opens on values with no database behind them — `ActivityDelta`, `ActivityZoneRow`, the
/// window/band pair, `ActivityEditDraft`, `WhoopActivityCatalog` with `ActivityGlyph`, the
/// "reading in force" rule, and `ActivityRoute` — so those blocks still assert if a database block
/// below throws. What each block is for, in the order they run:
///
/// 1. **The delta carries no verdict.** `ActivityDelta` is deliberately a sibling of `MetricChange`
///    rather than a fourth verdict on it: strain rising against the last ten basketball sessions is
///    neither good news nor bad, and `MetricChange.Verdict`'s three cases are all mapped to a colour.
/// 2. **The five zone rows**, which is what the user asked to sit below the chart. The property that
///    matters is that a row's percent and its time are **one share of one duration**, so they cannot
///    contradict each other — and the reference's `0% · 0:00:12` is therefore unreachable here.
/// 3. **The window and the band**, on a fixture whose quartiles are exact in binary.
/// 4. **The edit sheet's draft**, which is the one value both of the sheet's time controls write
///    through: a drag handle at each end of the chart and a compact `DatePicker` under `Start Time`
///    and `End Time`. Its rules are the whole of what an edit *is* — narrow-never-widen, the
///    `min(60, the session's own length)` floor, the minute-write guard that keeps a merely-drawn
///    picker from rewriting an untouched row, and the clamp that makes the day key invariant.
/// 5. **The picker's vocabulary** — `WhoopActivityCatalog`'s two sections, and the glyph sweep over
///    all 189 names. A wrong SF Symbol draws an empty chip rather than erroring, so a typo is invisible
///    to the compiler and to any screenshot of a different row; §17 covers the file's 21 names and this
///    is the other producer, whose vocabulary is neither a superset nor a subset of that one.
/// 6. **The reading in force at a trim handle** — the bpm a handle's label prints is the sample at or
///    before that instant and never an interpolation between two, on a synthetic series, because
///    `biometric_samples` holds no rows here and every session this app can show draws the dash.
/// 7. **`workout.steps`** through `v17`'s column, which is the one thing on this page with no
///    producer on any imported session.
/// 8. **The edit through the database**, which is where the save is proven to be an *update*: a
///    fixture carrying a route, splits, zones, steps and a provenance label is edited and read back,
///    and the day's session count must not move — an imported row's id is a function of its own two
///    instants, so an edit that minted a new one would draw the session twice.
/// 9. **Two readers on one motion stream** — the assertion that fails if anyone replaces the
///    multicast registry with a single continuation.
/// 10. **The export as a property**, over all 673 rows.
/// 11. **The route**, which is the map the user asked to sit below the heart-rate panels: the
///     two-point floor, the plausibility filter applied on the read as well as at the write, the
///     chronological order and the stable-sort tie-break, the great-circle length pinned against a
///     degree of latitude, the frame's padding and its floor, both unit systems driven explicitly, the
///     speed divided by the path's own span rather than the session's, and the two figures the
///     reference's overlay carries that this app **drops rather than fakes** — `ELEVATION`, which has
///     no producer at any layer, and a speed on a route with no time in it.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum ActivityDetailTests {
    // Every literal below is a duration or an offset from this instant rather than from `Date()`, so
    // the blocks that need no database cannot move with the day the suite runs.
    static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// A session at a known offset, carrying only what the block needs.
    ///
    /// **`strain` is optional and not `Double`**, which is the one change the fasting blocks needed from
    /// this helper. `WorkoutSession`'s own initialiser deliberately has no default on that parameter —
    /// see its comment — so a helper whose default is a number cannot express a fast at all, and a fast
    /// is precisely a session that measured no strain. Every existing call site still passes a `Double`
    /// and is unmoved; a fasting fixture passes `nil` and says so at its own call site.
    static func session(
        _ name: String?,
        startOffset: TimeInterval,
        durationSeconds: TimeInterval,
        strain: Double? = 5,
        steps: Int? = nil,
        zones: [Double]? = nil,
        region: String? = nil
    ) -> WorkoutSession {
        WorkoutSession(
            startedAt: anchor.addingTimeInterval(startOffset),
            endedAt: anchor.addingTimeInterval(startOffset + durationSeconds),
            strain: strain,
            averageHeartRate: 121,
            maxHeartRate: 164,
            route: [],
            splits: [],
            activityName: name,
            hrZonePercents: zones,
            steps: steps,
            offlineRegionID: region)
    }

    // The profile's table, off the cold-start 190/60 pair `GRDBUserProfileRepository` answers a fresh
    // install with. It is the same table `CalculateStrainUseCase` builds its zones from and the same
    // one the live session's band scale reads, so this page introduces no third edge.
    static let zones = StrainAccumulatorMath.computeZones(maxHR: 190, restHR: 60)

    // The fasting blocks' own calendar, and it must be `Calendar.current` for the reason the
    // importer's day keys are: a fast's enclosure rule compares **calendar days**, and a day built in
    // another zone does not shift a day key, it splits one. `dayCalendar` is the same calendar
    // `Date.startOfDay` uses inside the app, so a fixture's days are the days the app would key.
    static let dayCalendar = Calendar.current
    static let baseDay = dayCalendar.startOfDay(for: anchor)

    /// A calendar day at a wall-clock hour, built with `date(byAdding:)` rather than by adding seconds
    /// so a spring-forward day does not move the fixture — §13's consistency block records the same
    /// trap for the same reason.
    static func day(_ offset: Int, hour: Int = 0) -> Date {
        let start = dayCalendar.date(byAdding: .day, value: offset, to: baseDay) ?? baseDay
        return dayCalendar.date(byAdding: .hour, value: hour, to: start) ?? start
    }

    /// A recovery night on the day `offset`, keyed at `startOfDay` the way both producers key theirs.
    ///
    /// **This section's first `RecoveryMetric` fixture.** The spread a block hands it matters more than
    /// it looks: `BaselineStatisticsMath.baseline` floors a window's spread at
    /// `minimumCoefficientOfVariation × |mean|`, so a literal z-score is only reproducible on a window
    /// that clears that floor — a resting-rate window of 58/60/62 has the floor as its denominator (3,
    /// not 2) and every z downstream moves. The fasting blocks below pick spreads that clear it.
    static func night(
        _ offset: Int,
        score: Int,
        hrv: Double,
        rhr: Int,
        rr: Double? = nil,
        metric: HRVMetric = .rmssd
    ) -> RecoveryMetric {
        RecoveryMetric(
            date: dayCalendar.date(byAdding: .day, value: offset, to: baseDay) ?? baseDay,
            score: score,
            hrvValueMs: hrv,
            hrvMetric: metric,
            restingHeartRate: rhr,
            respiratoryRate: rr)
    }

    /// A fast between two instants.
    ///
    /// **It states the trio's absence at this one site rather than defaulting it**, which is the whole
    /// reason it is not folded into `session(...)`: a Zero fast measures no strain, no average heart
    /// rate and no maximum heart rate, and `WorkoutSession`'s initialiser has no default on any of the
    /// three so that a construction site has to say which answer it means. A fixture builder with a
    /// `nil` default would be that same trap one level down.
    static func fast(from start: Date, to end: Date) -> WorkoutSession {
        WorkoutSession(
            startedAt: start,
            endedAt: end,
            strain: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            route: [],
            splits: [],
            activityName: WhoopActivityCatalog.fastingName,
            hrZonePercents: nil)
    }

    static func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.0001 }

    // An optional printed into an assertion message. `Int?` has no `description` of its own —
    // `description` belongs to `Int`, and the compiler will not reach through the optional for it —
    // so a message that wants to show what it actually got goes through here. Without it a `nil` and
    // a wrong figure print alike, which is the one thing a failure message must not do.
    static func shown<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "nil" }

    /// A chart point from hand-picked z-scores, on a fixed day.
    static func point(_ zScores: [FastingMetric: Double]) -> FastingRecoveryChartSeries.Point {
        FastingRecoveryChartSeries.Point(date: day(1), zScores: zScores)
    }

    static func run() async throws {
        try await ActivityZoneRowTests.run()
        try await FastingRecoveryChartTests.run()
        try await ActivityEditDraftTests.run()
        try await ActivityOverflowAndDeleteTests.run()
        try await ActivityRouteAndOfflineMapTests.run()
    }
}
