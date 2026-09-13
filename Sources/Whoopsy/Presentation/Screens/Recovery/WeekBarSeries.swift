import Foundation

/// A week bar chart's series: which slots plot, and how each bar is coloured.
///
/// It is a type rather than logic in `WeekBarChartView`'s body for the reason `WeekLineSeries` is one
/// rather than logic in `WeekLineChartView`'s: the test runner has no renderer, so a rule written into
/// a `View` is a rule nothing can assert. Which slots plot is exactly such a rule — a bar drawn for a
/// day with no score would be the strongest possible claim about that day — and so is the palette.
///
/// **Two charts on the Recovery detail page are bars, and this is the one drawing they share.**
/// Recovery scores and sleep performance are both whole percentages on the same fixed 0–100 scale, so
/// they are one chart with two answers to "which slots" and "what colour", which is the same shape
/// `WeekLineSeries` gives the three line charts. What each bar *means* is not shared and does not
/// belong here: the card's own label says which quantity is plotted, exactly as it does for the lines.
///
/// The value is an `Int` and the label is a percentage, unlike `WeekLineSeries`'s `Double` and its
/// per-quantity `valueDecimals`. That is not a simplification: a percent is a whole number on every
/// path this app has, so there is no resolution for a caller to get wrong.
public struct WeekBarSeries: Equatable, Sendable {

    /// One plotted day: which column it belongs to, and the percentage in it.
    public struct Point: Equatable, Sendable {
        public let slot: Int
        public let value: Int

        public init(slot: Int, value: Int) {
            self.slot = slot
            self.value = value
        }
    }

    /// What colour a bar is drawn in.
    ///
    /// Deliberately **no `Color`**, so this type stays free of SwiftUI and the tokens stay in the view
    /// layer where `Theme` lives. The cases name the question; `WeekBarChartView` answers it.
    public enum Palette: Equatable, Sendable {
        /// Each bar in the colour of the recovery tier its own value falls in. The colour *is* the
        /// reading here, which is why the gridlines below it are the tier edges.
        case recoveryTier
        /// Every bar in one colour, for a quantity this app has no bands for. Distinguishing bars by
        /// colour where nothing distinguishes them would be an invitation to read a band that is not
        /// there.
        case sleepPerformance
    }

    /// The plotted days, in slot order.
    public let points: [Point]

    /// How each bar is coloured.
    public let palette: Palette

    /// The interior horizontal lines, as fractions of the 0–100 scale.
    ///
    /// **Empty for a quantity with no bands, and that is a decision rather than an omission.** The
    /// recovery chart grids at 34% and 67% because those are the numbers `RecoveryState.init(score:)`
    /// bands on, so a reader can see the boundaries the colours come from. This app has no sleep
    /// performance bands, so round quarters drawn under those bars would be lines at meaningful-
    /// looking places that mean nothing — the thing the recovery chart's own gridlines are the
    /// opposite of. A quantity without thresholds gets a chart without lines.
    public let gridEdges: [Double]

    /// The week's recovery scores, one bar per day that has one.
    ///
    /// Nil means *no chart at all* rather than an empty one: seven labelled columns with nothing in
    /// them is a week of zeros drawn once per column, which is the same fabrication a bar at zero
    /// would be. That test lives here and not in the view, so the card and the chart cannot disagree
    /// about whether there is anything to draw.
    ///
    /// The absence is already decided upstream — `MetricDay.recoveryScore` is nil for a day with no
    /// row and for one an older build wrote as a reserved zero — so the optional is the whole rule and
    /// there is no second gate here to disagree with it. A day with no score draws no bar *and no
    /// value label*; a bar of height zero would be a total collapse, which is a claim about the day.
    public init?(recoveryWeek week: MetricWeek) {
        let points = week.days.enumerated().compactMap { slot, day -> Point? in
            guard let score = day.recoveryScore else { return nil }
            return Point(slot: slot, value: score)
        }
        guard !points.isEmpty else { return nil }

        self.points = points
        self.palette = .recoveryTier
        self.gridEdges = Self.recoveryTierEdges
    }

    /// The week's sleep performance, one bar per night that has one.
    ///
    /// **No gate on the value, and the difference matters.** A night can carry a performance with no
    /// other measurement on the day — the strap path records nights and recoveries independently — so
    /// this is a series that can exist on a week with no recovery scores in it at all. The two bar
    /// charts are therefore omitted independently, exactly as the three line charts are: one can be
    /// drawn while the other is absent.
    ///
    /// Nil covers a week with no classified night in it. It does **not** cover a night whose need was
    /// zero, which `SleepSession.sleepPerformancePercentage` answers with a hard `100` — see
    /// `MetricDay.sleepPerformance` for why that path is unreachable on stored nights and why the
    /// honest handling is to leave it ungated rather than to drop a bar the row above prints.
    public init?(sleepPerformanceWeek week: MetricWeek) {
        let points = week.days.enumerated().compactMap { slot, day -> Point? in
            guard let performance = day.sleepPerformance else { return nil }
            return Point(slot: slot, value: performance)
        }
        guard !points.isEmpty else { return nil }

        self.points = points
        self.palette = .sleepPerformance
        // A quantity with no thresholds gets no lines. See `gridEdges`.
        self.gridEdges = []
    }

    /// The recovery chart's two interior lines: the red/yellow and yellow/green boundaries.
    ///
    /// Read through `RecoveryState`'s own ranges rather than typed as `0.34` and `0.67`, so a bar
    /// cannot be coloured by one boundary and measured against another.
    static let recoveryTierEdges: [Double] = [
        Double(RecoveryMetric.RecoveryState.yellowRange.lowerBound) / 100,
        Double(RecoveryMetric.RecoveryState.greenRange.lowerBound) / 100,
    ]
}
