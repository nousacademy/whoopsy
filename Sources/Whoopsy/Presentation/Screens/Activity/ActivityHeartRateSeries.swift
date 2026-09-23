import Foundation

/// The vertical scale a session's heart rate is drawn on: `bpm`.
///
/// **A sibling of `HoursOfSleepChartAxis` rather than a reuse of it, and the difference is the axis'
/// shape rather than its rules.** Those rules are copied here deliberately and restated by value: fixed
/// bounds rather than an auto-fit, widening in `wideningStep`-sized steps rather than clamping, and
/// gridlines derived from the bounds rather than listed. What differs is what the two are scales *of*.
///
/// The sleep chart's standard axis is `30...110`, sized for a night: eight hours of a body at rest,
/// where the interesting band is the low forties to the low sixties and 30 bpm of headroom above the top
/// label is free. A workout is minutes long and its whole point is the excursion — a 15-minute basketball
/// session sits in the 90s and 100s, so a trace drawn on `30...110` is a line pinned against the top of
/// the frame with half the plot below it empty. This scale's standard is therefore `60...180`, which
/// holds an ordinary session at its centre and leaves room above for a maximal one.
///
/// **The two bounds are the profile's own heart rates made round, not an invented band**: 60 is this
/// app's cold-start resting rate (`GRDBUserProfileRepository`) and 180 is under the cold-start 190
/// maximum, so the standard scale spans about what a real session spans on a fresh install. It is not
/// fitted per session — a session that stayed in the 70s must not be drawn as a dramatic climb — which
/// is the same argument `StressMonitorChartView` makes for pinning 0–3.
public struct ActivityHeartRateAxis: Equatable, Sendable {

    public let lowerBound: Double
    public let upperBound: Double

    /// The labelled lines, ascending. **Derived from the bounds, never listed**, and the upper bound is
    /// excluded because its line would land on the frame's own top edge.
    public let gridLines: [Double]

    private static let gridStep: Double = 30
    private static let wideningStep: Double = 15

    /// Where the scale starts when nothing argues otherwise: `60...180`, ruled at `60`, `90`, `120` and
    /// `150`.
    ///
    /// `30`-spaced rather than the sleep chart's `20`, because this scale is half again as wide: four
    /// labels on a wider range keeps the same visual density, and a 20 bpm grid on `60...180` would draw
    /// seven lines across a plot a few centimetres tall.
    public static let standard = ActivityHeartRateAxis(
        lowerBound: 60, upperBound: 180, gridLines: lines(from: 60, to: 180))

    public init(lowerBound: Double, upperBound: Double, gridLines: [Double]) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.gridLines = gridLines
    }

    /// How far up the scale a rate sits, as a fraction of the plot's height.
    ///
    /// Clamped, and as in `HoursOfSleepChartAxis` that is not a fabrication: the bounds are widened to
    /// contain the data before this is ever asked, so a value outside them is reachable only through a
    /// hand-built axis. `NaN` collapses to the floor rather than propagating, since every comparison
    /// against a `NaN` is false and the clamp could not catch it.
    public func fraction(_ bpm: Double) -> Double {
        guard bpm.isFinite, upperBound > lowerBound else { return 0 }
        return min(1, max(0, (bpm - lowerBound) / (upperBound - lowerBound)))
    }

    /// The standard axis widened until it contains every finite value it is handed.
    ///
    /// A strap reports heart rate in a byte, so this cannot run away in production; the finiteness guard
    /// on the result is for a hand-built input, and it falls back to the standard axis rather than to an
    /// infinite one.
    public static func fit(_ values: [Double]) -> ActivityHeartRateAxis {
        let finite = values.filter(\.isFinite)
        guard let lowest = finite.min(), let highest = finite.max() else { return .standard }

        let below = max(0, ((standard.lowerBound - lowest) / wideningStep).rounded(.up))
        let above = max(0, ((highest - standard.upperBound) / wideningStep).rounded(.up))
        guard below > 0 || above > 0 else { return .standard }

        let lower = standard.lowerBound - below * wideningStep
        let upper = standard.upperBound + above * wideningStep
        guard lower.isFinite, upper.isFinite, upper > lower else { return .standard }

        return ActivityHeartRateAxis(
            lowerBound: lower, upperBound: upper, gridLines: lines(from: lower, to: upper))
    }

    /// Lines anchored at `lowerBound`, ascending, excluding `upperBound`. See `gridLines` for why.
    private static func lines(from lower: Double, to upper: Double) -> [Double] {
        guard upper > lower else { return [] }
        var lines: [Double] = []
        var value = lower
        // Bounded by the same guard the loop condition carries: `gridStep` is a positive constant, so
        // `value` strictly increases and the loop cannot spin.
        while value < upper {
            lines.append(value)
            value += gridStep
        }
        return lines
    }
}

/// One session's heart rate, as a series the chart can draw.
///
/// ## Why this is not `HoursOfSleepChartSeries`
///
/// That type's doc comment is explicit that its name is deliberate — it is the series the
/// *hours-of-sleep card* draws, and reaching for either half of the pair re-creates the mistake its name
/// exists to prevent. This is the same quantity read by a **different card on a different screen**: an
/// activity page, whose x axis is the session's own ten or fifteen minutes rather than a night, and
/// whose y axis is `ActivityHeartRateAxis` — a different scale with different bounds, for the reason
/// that type's comment gives. Reusing the sleep series would have forced the sleep axis onto a workout
/// and put a night's `No Data` caption on a session's card.
///
/// **The gap rule is restated by value rather than extracted**, which is the same deliberate
/// duplication `SleepStressShareBar` already makes against `TypicalRangeBar` — and the same warning
/// applies: `maximumGapSeconds` is now written down in two files, so re-measuring it moves **both**.
/// The alternative was an extraction into a shared series the sleep card's own assertions cannot see.
///
/// ## One point per notification, and the arrival-instant caveat
///
/// `CLAUDE.md` requires a *per-beat* series built from `rrIntervalsMs` to reconstruct beat times by
/// cumulative sum and never to trust `timestamp`. **This series is not that**, on
/// `HoursOfSleepChartSeries`' argument verbatim: one point per persisted *notification*, plotting the
/// `heartRate` the strap measured in it rather than an interval this app derived. Across a fifteen
/// minute session, a notification's arrival is sub-pixel from the beats it carried. Anything wanting
/// beat-to-beat resolution must go through `rrIntervalsMs` and the cumulative-sum rule instead.
///
/// ## Empty is `nil`, and `nil` is the screen's `No Data`
///
/// **This series is `nil` on every session this app can currently show.** `biometric_samples` holds 0
/// rows in every database on this machine, and the bundled export carries no heart-rate series at all —
/// only a per-cycle daily average — so all 673 of its sessions have none permanently. The page draws
/// `No Data` there, which is the correct output and not a bug: it is `HOURS OF SLEEP`'s precedent
/// exactly, and a dash rather than a flat line. What makes it absent is that no strap has ever been
/// connected here, not that the strap cannot produce one.
public struct ActivityHeartRateSeries: Equatable, Sendable {

    /// One measured instant: when the app heard it, and what the strap reported.
    ///
    /// The value is a `Double` because the axis is one — it is mapped to a fraction and never
    /// arithmetically combined, so nothing here turns a whole bpm into a fraction.
    public struct Point: Equatable, Sendable {
        public let time: Date
        public let bpm: Double

        public init(time: Date, bpm: Double) {
            self.time = time
            self.bpm = bpm
        }
    }

    /// The session's own bounds, and the x axis' origin and end.
    public let start: Date
    public let end: Date

    /// The plotted readings, sorted by time. Never empty — see the type's own comment.
    public let points: [Point]

    /// `points` split into consecutive runs. The chart strokes one segment per run of two or more; a run
    /// of one draws its dot and no segment, and is not joined to a neighbour to make a line.
    public let runs: [[Point]]

    /// The vertical scale, widened to contain `points` and to nothing else.
    public let axis: ActivityHeartRateAxis

    /// How long a silence has to be before it is a hole rather than a sampling interval.
    ///
    /// Five minutes, restated from `HoursOfSleepChartSeries.maximumGapSeconds` — see this type's comment
    /// for why it is a copy rather than an extraction, and move both files if it is ever re-measured.
    /// The live path notifies about once a second, so anything approaching this is the app not running,
    /// the strap off the wrist, or the two out of range; the cost of splitting too eagerly is a trace
    /// broken into more pieces than the session really had.
    public static let maximumGapSeconds: TimeInterval = 300

    /// The session's readings, or `nil` when it has none to plot.
    ///
    /// Two absences are collapsed deliberately, because the page renders both as `No Data`: a session
    /// with no samples in its window, and a window that is not a window at all (`end <= start`), which
    /// would make the x axis a division by zero.
    ///
    /// A `heartRate` of `0` is dropped rather than plotted at the floor — the absence rule
    /// `RecoveryMetric.hasMeasurement` and `StrainScore.hasMeasurement` enforce, and the same one the
    /// sleep series applies: a value with no measurement behind it is not a reading, and a point at the
    /// bottom of the scale is a strong claim about a session rather than an admission about a sample.
    public init?(samples: [BiometricSample], start: Date, end: Date) {
        guard end > start else { return nil }

        let points = samples
            .filter { $0.heartRate > 0 && $0.timestamp >= start && $0.timestamp <= end }
            .map { Point(time: $0.timestamp, bpm: Double($0.heartRate)) }
            .sorted { $0.time < $1.time }

        guard !points.isEmpty else { return nil }

        self.start = start
        self.end = end
        self.points = points
        self.runs = Self.runs(points)
        self.axis = ActivityHeartRateAxis.fit(points.map(\.bpm))
    }

    /// `points` split into consecutive runs.
    ///
    /// Internal rather than private so the suite can drive the split directly, which is the one rule
    /// here whose failure is invisible on screen: a segment drawn across a dropout looks exactly like a
    /// segment drawn across a session the strap really did record continuously, and the runner has no
    /// renderer to notice either.
    static func runs(_ points: [Point]) -> [[Point]] {
        var runs: [[Point]] = []
        var current: [Point] = []

        for point in points {
            if let last = current.last,
               point.time.timeIntervalSince(last.time) > maximumGapSeconds {
                runs.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
