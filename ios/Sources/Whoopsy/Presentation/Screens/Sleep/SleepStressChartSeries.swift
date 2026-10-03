import Foundation

/// A night's stress trace resolved into the shape the chart draws: the night's own axis, and the
/// windows split wherever the record is not continuous.
///
/// ## Why this is a value rather than logic in the chart's `body`
///
/// `HoursOfSleepChartSeries`' reason, one card along. The drawing has rules — where a gap breaks the
/// line, what fraction of the axis a window sits at — and the runner that tests this app has **no
/// renderer**, so a rule left inside a `GeometryReader` is a rule nothing can assert. Resolving the
/// geometry here means the arithmetic the picture is made of is asserted as a value, which is the same
/// bargain `TypicalRangeBarLayout` and `DayBarRules` strike.
///
/// ## The axis is the night, and it cannot be anything else
///
/// `timeFraction` is `0` at the night's in-bed start and `1` at its wake. That is the whole difference
/// from `StressMonitorChartView`, whose fraction is of a fixed 24-hour day: this night crosses
/// midnight, so there is no clock position to place a window at. The series takes a
/// `SleepStressNight`, which carries its own span, so a caller cannot hand the windows and a day's
/// axis to the same chart — see `SleepStressNight.span`.
public struct SleepStressChartSeries: Equatable, Sendable {

    /// The night's in-bed start, the axis origin.
    public let start: Date

    /// The night's wake, the axis end.
    public let end: Date

    /// The trace, in order, split at every gap. Empty runs never appear.
    public let runs: [Run]

    /// One plotted window.
    ///
    /// In the data's own terms rather than screen points: `timeFraction` is 0 at `start` and 1 at
    /// `end`, and `score` is on the 0–3 scale. Data terms because a `Shape` must lay itself out in
    /// whatever rect it is handed, which is what keeps the geometry right when the card's width
    /// changes and the gradient stops on the scale.
    public struct Point: Equatable, Sendable {
        public let timeFraction: Double
        public let score: Double

        public init(timeFraction: Double, score: Double) {
            self.timeFraction = timeFraction
            self.score = score
        }
    }

    /// A stretch of consecutive scored windows.
    ///
    /// A run of one is kept and drawn as a dot: a polyline through a single point draws nothing, and
    /// that point *was* measured — the same reasoning as the day chart's `DotPath`.
    public struct Run: Equatable, Sendable {
        public let points: [Point]

        public init(points: [Point]) {
            self.points = points
        }
    }

    /// The gap that ends a run, in seconds.
    ///
    /// One and a half windows, which is `StressMonitorChartView`'s figure — the two charts break on the
    /// same condition because they break for the same reason. A window is scored every
    /// `StressMath.windowSeconds`, so consecutive windows sit exactly one window apart and anything
    /// past one and a half is a window that is *missing* rather than late. Ineligible windows — the
    /// strap moving, or too few beats — are unmeasured, and joining across one would draw a reading
    /// nobody took. A break is the honest rendering of a hole.
    ///
    /// **Not a shared constant with the day chart**, because the day chart states it inline: promoting
    /// it would mean editing `StressMonitorChartView`, and the rule is two tokens of arithmetic whose
    /// meaning is `StressMath.windowSeconds` — the thing that actually must not drift, and which both
    /// read from the model.
    public static let maximumGapSeconds = StressMath.windowSeconds * 1.5

    /// A night's trace, or `nil` when there is nothing to draw.
    ///
    /// `nil` for an empty series and for a zero-length span — the two guards that keep the fractions
    /// from dividing by nothing. Both are unreachable through `SleepStressNight`, which refuses an
    /// empty window list and a reversed span in its own initialiser; they are restated here because
    /// this type is constructible on its own and a `NaN` fraction is not a mark in the wrong place, it
    /// is a mark that takes the whole chart with it.
    public init?(night: SleepStressNight) {
        let length = night.span.upperBound.timeIntervalSince(night.span.lowerBound)
        guard length > 0 else { return nil }

        let ordered = night.windows.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return nil }

        self.start = night.span.lowerBound
        self.end = night.span.upperBound

        var runs: [Run] = []
        var current: [StressWindow] = []

        for window in ordered {
            if let last = current.last,
                window.start.timeIntervalSince(last.start) > Self.maximumGapSeconds
            {
                runs.append(Run(points: current.map { Self.point($0, from: night.span.lowerBound, length: length) }))
                current = []
            }
            current.append(window)
        }
        if !current.isEmpty {
            runs.append(Run(points: current.map { Self.point($0, from: night.span.lowerBound, length: length) }))
        }

        self.runs = runs
    }

    /// Clamped to `0...1`, because a window outside the axis is a mark outside the scale, and a mark
    /// outside the scale reads as a different scale rather than as a wrong reading. The use case
    /// buckets inside the span so this cannot bite; it is here so a hand-built series cannot draw off
    /// the end of the card.
    private static func point(_ window: StressWindow, from origin: Date, length: TimeInterval) -> Point {
        let fraction = window.start.timeIntervalSince(origin) / length
        guard fraction.isFinite else { return Point(timeFraction: 0, score: window.score) }
        return Point(timeFraction: min(1, max(0, fraction)), score: window.score)
    }
}
