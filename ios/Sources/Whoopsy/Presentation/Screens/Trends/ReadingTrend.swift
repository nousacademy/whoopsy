import Foundation

/// One **per-day physiological reading** over a window: which days plot, the average, the comparison
/// with the window before it, and the band those priors describe.
///
/// **One type for both trend pages, because the two differ only in what a row's figure is.** HRV and
/// resting heart rate are the same shape — a daily reading that a `recoveries` row may or may not
/// carry, a mean, a prior-window comparison and a typical band — and the difference between them is a
/// unit, a direction of "better", and one extraction. Writing the page twice would be two definitions
/// of the same window arithmetic, which is the drift this repo extracts types to prevent. The
/// extraction and the wording live on `Kind`; everything else is here.
///
/// ## HRV narrows to one metric before anything is averaged
///
/// SDNN and RMSSD are different quantities and never share a baseline (`docs/ALGORITHMS.md`). A
/// `recoveries` table holds both — the strap computes RMSSD, the HealthKit import stores SDNN — so an
/// HRV trend drawn from the rows without narrowing would put two distributions on one axis, where a
/// normal SDNN day looks like a collapse. `make` therefore picks **one** metric and filters to it
/// before plotting: the one the newest measured row in the read window carries, which is
/// `RecoveryViewModel.displayedHrvMetric`'s rule. A caller may pass one explicitly. Resting heart rate
/// has no such split — it is one quantity from every producer — so that narrowing is HRV's alone.
///
/// ## What the "typical range" is, and what it is not
///
/// It is **this app's own derivation**: the mean ± one sample standard deviation of the prior window's
/// measured days, withheld below `RecoveryScoring.minimumBaselineDays` observations. It is not WHOOP's
/// band — theirs is anchored to physiological events this app cannot measure — and the page's legend
/// says `TYPICAL RANGE` over a band whose definition is stated in its footnote rather than implied to
/// be WHOOP's.
///
/// ## Gaps
///
/// A day with no measured reading is `nil`, and the chart breaks the line across it. A missing day is
/// not a zero and not a straight interpolation between its neighbours: both would draw a reading the
/// app never took.
public struct ReadingTrend: Equatable, Sendable {

    /// Which quantity a page plots. The raw value is not drawn; the computed names are.
    public enum Kind: String, CaseIterable, Sendable {
        case hrv
        case restingHeartRate
        /// **An estimate, not a measurement** — see `vo2Max`'s note on `isEstimate`.
        case vo2Max

        /// The page's title and the panel it is reached from.
        public var title: String {
            switch self {
            case .hrv: return "HRV"
            case .restingHeartRate: return "RHR"
            case .vo2Max: return "VO₂ MAX"
            }
        }

        /// The unit every figure on the page is in.
        public var unit: String {
            switch self {
            case .hrv: return "ms"
            case .restingHeartRate: return "bpm"
            case .vo2Max: return "mL/kg/min"
            }
        }

        /// Which direction is the good one. An HRV rise is good; a resting-rate rise is not; a VO₂ max
        /// rise is — the same direction/verdict split `MetricChange` makes for the panels.
        public var higherIsBetter: Bool {
            switch self {
            case .hrv, .vo2Max: return true
            case .restingHeartRate: return false
            }
        }

        /// The words a sentence uses: *"your average **resting heart rate** this month"*.
        public var spokenName: String {
            switch self {
            case .hrv: return "HRV"
            case .restingHeartRate: return "resting heart rate"
            case .vo2Max: return "VO₂ max"
            }
        }

        /// Whether the quantity is derived rather than read off a row.
        ///
        /// **VO₂ max is this app's estimate**, `Vo2MaxMath.heartRateRatioEstimate` — the profile's
        /// assumed maximum over the day's resting rate. It is not stored, it is not measured, and the
        /// page must say so: the panel it is reached from carries `(EST.)` for the same reason, and
        /// the footnote here repeats the derivation and the model's error bar. The other two are
        /// readings.
        public var isEstimate: Bool { self == .vo2Max }
    }

    /// The three spans the page offers. The raw values are the drawn titles.
    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case week = "W"
        case month = "M"
        case sixMonths = "6M"

        public var id: String { rawValue }

        /// Days in the window, and in the comparison window before it.
        public var dayCount: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .sixMonths: return 182
            }
        }

        /// The noun a sentence uses for the window: *"your average HRV this month"*.
        public var noun: String {
            switch self {
            case .week: return "week"
            case .month: return "month"
            case .sixMonths: return "six months"
            }
        }

        /// The same for the window before it: *"the previous month"*.
        public var priorNoun: String { "previous \(noun)" }
    }

    public struct Point: Equatable, Sendable, Identifiable {
        public let id: Int
        public let date: Date
        /// The day's reading, or `nil` when the day has no measured one in this quantity.
        public let value: Double?
    }

    public let kind: Kind
    public let period: Period

    /// The HRV quantity every figure is in, or `nil` for a kind that has only one.
    public let hrvMetric: HRVMetric?

    public let points: [Point]

    /// The mean of the window's measured days, or `nil` when it holds none.
    public let average: Double?

    /// The mean of the window immediately before, on the same rule, or `nil`.
    public let previousAverage: Double?

    /// The rounded percentage change between the two means, or `nil` when there is no comparison
    /// worth drawing (no previous mean, or a previous mean of zero).
    public let percentChange: Int?

    /// The prior window's mean ± one sample standard deviation, or `nil` below the count floor.
    public let typicalRange: ClosedRange<Double>?

    /// How many days in the window carried a reading — the denominator the average is taken over.
    public let measuredDays: Int

    /// The chart's axis, in whole units of `kind.unit`, covering the readings **and** the band.
    public let axisMinimum: Int
    public let axisMaximum: Int

    /// Five gridline values, lowest first, including both ends of the axis.
    public let axisTicks: [Int]

    /// Which points carry a date under them. Five, evenly spaced, first and last included.
    public let labelIndices: [Int]

    public let windowStart: Date
    public let windowEnd: Date

    /// The smallest span the axis is allowed to draw. A window of seven near-identical readings would
    /// otherwise fill the plot with a one-unit difference.
    public static let minimumAxisSpan = 10

    public static func make(
        rows: [RecoveryMetric],
        anchor: Date,
        period: Period,
        kind: Kind,
        hrvMetric: HRVMetric? = nil,
        /// The profile's assumed maximum heart rate — the VO₂ estimate's only non-daily input. `nil`
        /// for the two readings, and for a profile this app could not read.
        maxHeartRate: Int? = nil,
        calendar: Calendar = .current
    ) -> ReadingTrend {
        let end = calendar.startOfDay(for: anchor)
        let start = calendar.date(byAdding: .day, value: -(period.dayCount - 1), to: end) ?? end
        let priorEnd = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let priorStart = calendar.date(byAdding: .day, value: -period.dayCount, to: start) ?? start

        // One HRV metric, decided before anything is plotted or averaged. Resting rate has none.
        let chosenMetric: HRVMetric? = kind == .hrv
            ? (hrvMetric
                ?? rows.filter(\.hasMeasurement).max(by: { $0.date < $1.date })?.hrvMetric
                ?? .rmssd)
            : nil

        func reading(_ row: RecoveryMetric) -> Double? {
            guard row.hasMeasurement else { return nil }
            switch kind {
            case .hrv:
                guard row.hrvMetric == chosenMetric else { return nil }
                return row.hrvValueMs
            case .restingHeartRate:
                // A row's resting rate is non-optional, but a placeholder's `0` is not a reading.
                guard row.restingHeartRate > 0 else { return nil }
                return Double(row.restingHeartRate)
            case .vo2Max:
                // Derived exactly as `MetricWeek` derives the panel's figure, so the page and the
                // panel cannot disagree about a day: an absent rate, a zero rate and a `nil` maximum
                // all arrive as `nil`.
                return Vo2MaxMath.heartRateRatioEstimate(
                    maxHeartRate: maxHeartRate,
                    restingHeartRate: row.restingHeartRate > 0 ? row.restingHeartRate : nil)
            }
        }

        let eligible = rows.filter { reading($0) != nil }

        let byDay = Dictionary(
            uniqueKeysWithValues: eligible.compactMap { row in
                reading(row).map { (calendar.startOfDay(for: row.date), $0) }
            })

        var points: [Point] = []
        var day = start
        var slot = 0
        while day <= end {
            points.append(Point(id: slot, date: day, value: byDay[day]))
            slot += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let windowValues = points.compactMap(\.value)
        let average = windowValues.isEmpty ? nil : BaselineStatisticsMath.mean(windowValues)

        let priorValues = eligible
            .filter { $0.date.startOfDay >= priorStart && $0.date.startOfDay <= priorEnd }
            .compactMap(reading)
        let previousAverage = priorValues.isEmpty ? nil : BaselineStatisticsMath.mean(priorValues)

        let percentChange: Int? = {
            guard let average, let previousAverage, previousAverage > 0 else { return nil }
            return Int((((average - previousAverage) / previousAverage) * 100).rounded())
        }()

        let typicalRange: ClosedRange<Double>? = {
            guard priorValues.count >= RecoveryScoring.minimumBaselineDays else { return nil }
            let mean = BaselineStatisticsMath.mean(priorValues)
            let deviation = BaselineStatisticsMath.standardDeviation(priorValues)
            return (mean - deviation)...(mean + deviation)
        }()

        // The axis covers the readings *and* the band: a band clipped off the top of the plot is a
        // range the reader cannot see the readings against.
        let allValues = windowValues + [typicalRange?.lowerBound, typicalRange?.upperBound].compactMap { $0 }
        let rawLow = allValues.min() ?? 0
        let rawHigh = allValues.max() ?? Double(minimumAxisSpan)
        var low = Int(rawLow.rounded(.down))
        var high = Int(rawHigh.rounded(.up))
        if high - low < minimumAxisSpan {
            let midpoint = (high + low) / 2
            low = midpoint - minimumAxisSpan / 2
            high = low + minimumAxisSpan
        }
        low = max(0, low)

        let ticks = (0...4).map { step in
            Int((Double(low) + (Double(high - low) * Double(step) / 4.0)).rounded())
        }

        let count = points.count
        let labelIndices = count == 0
            ? []
            : Array(Set([0, count / 4, count / 2, (count * 3) / 4, count - 1])).sorted()

        return ReadingTrend(
            kind: kind,
            period: period,
            hrvMetric: chosenMetric,
            points: points,
            average: average,
            previousAverage: previousAverage,
            percentChange: percentChange,
            typicalRange: typicalRange,
            measuredDays: windowValues.count,
            axisMinimum: low,
            axisMaximum: high,
            axisTicks: ticks,
            labelIndices: labelIndices,
            windowStart: start,
            windowEnd: end)
    }
}
