import Foundation

/// The vertical scale a night's heart rate is drawn on.
///
/// The `HoursOfSleepChart` prefix is the card this axis belongs to rather than the quantity on it —
/// `HoursOfSleepChartSeries`' doc comment carries that argument in full. The bounds are `bpm`.
///
/// **Fixed, and that is the whole of its design.** Auto-scaling to the night's own range would draw a
/// calm night and a restless one as the same picture — the argument `StressMonitorChartView` makes for
/// pinning its 0–3 scale, and it holds here night to night rather than within one day. `FittedAxis` is
/// this repo's other answer to a y axis and it is deliberately not used: its own doc comment records
/// that a fitted axis is honest only because `WeekLineChartView` prints a number over *every* point,
/// and a night's trace carries far too many points to label.
///
/// **It widens rather than clamps.** A sample outside the standard bounds raises them in
/// `wideningStep`-sized steps until it is inside. Clamping would draw a peak at a height the value did
/// not reach, which is the fabrication `TypicalRangeBarLayout.fraction`'s comment already refuses for
/// a mark off the end of a track — a mark in the wrong place reads as a different scale rather than as
/// a wrong reading. The cost is accepted knowingly: a night that widens is no longer pixel-comparable
/// with one that did not, and that is visible on the screen rather than hidden in it.
public struct HoursOfSleepChartAxis: Equatable, Sendable {

    public let lowerBound: Double
    public let upperBound: Double

    /// The labelled lines, ascending. **Derived from the bounds, never listed.**
    ///
    /// Spaced `gridStep` apart and anchored at `lowerBound`, so the standard axis carries exactly the
    /// four labels the reference draws — `30, 50, 70, 90` — and a widened one re-anchors rather than
    /// labelling a scale it is no longer on. The upper bound is excluded because its line would land on
    /// the frame's own top edge and say nothing the frame does not.
    public let gridLines: [Double]

    private static let gridStep: Double = 20
    private static let wideningStep: Double = 10

    /// Where the scale starts when nothing argues otherwise: `30...110`, with the reference's four
    /// labels and 20 bpm of headroom above the top one so a spike is not flush against the frame.
    public static let standard = HoursOfSleepChartAxis(
        lowerBound: 30, upperBound: 110, gridLines: lines(from: 30, to: 110))

    public init(lowerBound: Double, upperBound: Double, gridLines: [Double]) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.gridLines = gridLines
    }

    /// How far up the scale a rate sits, as a fraction of the plot's height.
    ///
    /// Clamped, and unlike the widening above that is not a fabrication: the bounds are fitted to the
    /// data before this is ever asked, so a value outside them is reachable only through a caller that
    /// built one of these by hand. `NaN` collapses to the floor rather than propagating, since every
    /// comparison against a `NaN` is false and the clamp could not catch it.
    public func fraction(_ bpm: Double) -> Double {
        guard bpm.isFinite, upperBound > lowerBound else { return 0 }
        return min(1, max(0, (bpm - lowerBound) / (upperBound - lowerBound)))
    }

    /// The standard axis widened until it contains every finite value it is handed.
    ///
    /// The step count is computed rather than looped, so a value far outside the standard bounds costs
    /// one division instead of one iteration per ten bpm. A strap reports heart rate in a byte, so this
    /// cannot run away in production; the finiteness guard on the result is for a hand-built input,
    /// and it falls back to the standard axis rather than to an infinite one.
    public static func fit(_ values: [Double]) -> HoursOfSleepChartAxis {
        let finite = values.filter(\.isFinite)
        guard let lowest = finite.min(), let highest = finite.max() else { return .standard }

        let below = max(0, ((standard.lowerBound - lowest) / wideningStep).rounded(.up))
        let above = max(0, ((highest - standard.upperBound) / wideningStep).rounded(.up))
        guard below > 0 || above > 0 else { return .standard }

        let lower = standard.lowerBound - below * wideningStep
        let upper = standard.upperBound + above * wideningStep
        guard lower.isFinite, upper.isFinite, upper > lower else { return .standard }

        return HoursOfSleepChartAxis(lowerBound: lower, upperBound: upper, gridLines: lines(from: lower, to: upper))
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

/// One night's heart rate, as a series the chart can draw.
///
/// ## Named for the card it is drawn in, and its points are still `bpm`
///
/// The name says **hours of sleep** and the payload says **beats per minute**, and that is deliberate
/// on both sides rather than a rename that stopped halfway. The card is `HOURS OF SLEEP` — that is its
/// title in the reference, and the night's asleep total is its headline figure — so a type called
/// `SleepHeartRateSeries`, read at the call site inside that card, named the wrong thing about the
/// screen: it invited a reader to conclude the card was *about* heart rate, which is exactly the
/// mistake the card's title and its headline exist to prevent. The trace is what the card carries
/// below its figure, so the type is named for its place.
///
/// **The unit is not renamed with it.** The points really are `bpm`, the axis really is labelled
/// `30/50/70/90`, and calling `Point.bpm` anything else would be a name that lies about a quantity —
/// the failure `CLAUDE.md`'s absence rules exist to catch, one layer up in the type system. So the
/// answer to "why is the hours-of-sleep series full of heart rates" is in the first sentence of this
/// comment and not in a puzzle a reader has to solve: this is the series the *hours-of-sleep card*
/// draws.
///
/// It is a type rather than logic in `HoursOfSleepChartView`'s body for the reason `WeekLineSeries`
/// and `DayBarRules` are types rather than logic in a body: the test runner that tests this app has no
/// renderer, so a rule written into a `View` is a rule nothing can assert.
///
/// ## One point per notification, and why that is not the beat-time defect
///
/// `CLAUDE.md` requires a *per-beat* series built from `rrIntervalsMs` to reconstruct beat times by
/// cumulative sum and never to trust `timestamp`, because an arrival instant records when the app heard
/// about the beats rather than when they happened. **This series is not that**, and the distinction is
/// the whole reason the rule does not bite here: it has one point per persisted *notification*, not one
/// per beat, and it plots the `heartRate` the strap itself measured in that notification rather than an
/// interval it derived. At roughly seven hours across a few hundred points a notification's arrival is
/// sub-pixel from the beats it carried. Anything that wants beat-to-beat resolution — a tachogram, an
/// RMSSD — must go through `rrIntervalsMs` and the cumulative-sum rule instead.
///
/// ## A gap breaks the line
///
/// `runs` splits the points wherever two consecutive ones are further apart than `maximumGapSeconds`,
/// and the chart strokes one segment per run. This is the rule `WeekLineSeries.runs` and
/// `StressMonitorChartView.runs` already follow: the app receives nothing while it is not running, the
/// strap is off the wrist, or the two are out of range, and a segment drawn across one of those
/// stretches is a curve through a period nothing measured.
///
/// ## Empty is `nil`, and `nil` is the screen's `No Data`
///
/// `nil` means *this night holds no heart rate*, which is exactly the state the sleep detail screen
/// draws as `No Data` rather than as an empty frame. There is no minimum point count on top of that: a
/// night the app heard from three times **was** measured, and the repo's other two series return `nil`
/// on emptiness and nothing more. Refusing to draw it would be the same fabrication as a dash over a
/// stored reading.
public struct HoursOfSleepChartSeries: Equatable, Sendable {

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

    /// The night's in-bed bounds, and the x axis' origin and end.
    public let start: Date
    public let end: Date

    /// The plotted readings, sorted by time. Never empty — see the type's own comment.
    public let points: [Point]

    /// `points` split into consecutive runs. The chart strokes one segment per run of two or more; a
    /// run of one draws its dot and no segment, and is not joined to a neighbour to make a line.
    public let runs: [[Point]]

    /// The vertical scale, fitted to `points` and to nothing else.
    public let axis: HoursOfSleepChartAxis

    /// How long a silence has to be before it is a hole rather than a sampling interval.
    ///
    /// Five minutes, and the number is a judgement stated so it can be argued with. The live path
    /// notifies about once a second, so anything approaching this is the app not running or the strap
    /// not on the wrist; and it is deliberately looser than `StressMonitorChartView`'s one-and-a-half
    /// five-minute windows, because a heart-rate notification is far more frequent than a stress
    /// window and the cost of splitting too eagerly is a trace broken into more pieces than the
    /// night really had.
    public static let maximumGapSeconds: TimeInterval = 300

    /// The night's readings, or `nil` when it has none to plot.
    ///
    /// Two absences are collapsed deliberately, because the screen renders both as `No Data`: a night
    /// with no samples in its window, and a window that is not a window at all (`end <= start`), which
    /// would make the x axis a division by zero.
    ///
    /// A `heartRate` of `0` is dropped rather than plotted at the floor. That is the same absence rule
    /// `RecoveryMetric.hasMeasurement` and `StrainScore.hasMeasurement` enforce — a value with no
    /// measurement behind it is not a reading, and a point at the bottom of the scale is a strong claim
    /// about a night rather than an admission about a sample.
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
        self.axis = HoursOfSleepChartAxis.fit(points.map(\.bpm))
    }

    /// `points` split into consecutive runs.
    ///
    /// Internal rather than private so the suite can drive the split directly, which is the one rule
    /// here whose failure is invisible on screen: a segment drawn across a dropout looks exactly like a
    /// segment drawn across a night the strap really did record continuously, and the runner has no
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
