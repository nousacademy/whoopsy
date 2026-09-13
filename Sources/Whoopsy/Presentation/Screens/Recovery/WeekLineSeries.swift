import Foundation

/// A week line chart's series: which slots plot, and how they group into line segments.
///
/// It is a type rather than logic in `WeekLineChartView`'s body for the reason `DayBarRules` is one
/// rather than logic in `DayNavigationBar`'s: the test runner has no renderer, so a rule written into
/// a `View` is a rule nothing can assert. Both rules below are ones this app has already got wrong
/// somewhere else, and neither is visible in a screenshot of a week where they happen not to bite.
///
/// **Which slots plot is the initialiser's business, and the three line charts on the Recovery detail
/// page answer it differently.** `init?(restingHeartRateWeek:)` and `init?(respiratoryRateWeek:)` take
/// every day carrying a reading, since each of those is one quantity in one unit. The HRV one cannot:
/// SDNN and RMSSD are different quantities on different scales, so it narrows to one of them first —
/// that is the never-mix rule, and its own comment below is where it is applied to a drawing.
///
/// **A quantity's resolution belongs here too, not at the call site.** `valueDecimals` is the number
/// of places the quantity is read to, and it is a property of the quantity rather than a styling
/// choice — a week of respiratory rates spans about two breaths per minute, so printing it the way a
/// week of milliseconds is printed would render seven labels of `15` and destroy the reading the
/// labels exist to carry. It sits beside the selection rule for the same reason that rule does: both
/// are answers about *this quantity*, and a caller free to pass the wrong one would be a caller free
/// to make a chart that states the wrong number.
///
/// ## A gap breaks the line
///
/// `runs` splits the points wherever two consecutive ones are not adjacent slots, and the chart draws
/// one segment per run. A day with no reading, and — for HRV — a day measured in the *other* quantity,
/// both end a run; a segment drawn across either would span days this line has no value for and would
/// be read as a value for them. This is the rule `StrainRecoveryChartView` and `StressMonitorChartView`
/// already follow.
public struct WeekLineSeries: Equatable, Sendable {

    /// One plotted day: which column it belongs to, and the reading in it.
    ///
    /// The value is a `Double` whatever the quantity, because a `MetricDay` carries an `Int` rate and a
    /// `Double` HRV and there is one drawing and one `FittedAxis` behind all three. It is rounded for
    /// display and never arithmetically combined, so nothing here turns a whole bpm into a fraction.
    public struct Point: Equatable, Sendable {
        public let slot: Int
        public let value: Double

        public init(slot: Int, value: Double) {
            self.slot = slot
            self.value = value
        }
    }

    /// The plotted days, in slot order.
    public let points: [Point]

    /// `points` split into consecutive runs. The chart strokes one segment per run of two or more;
    /// a run of one draws its dot and no segment, and is not joined to a neighbour to make a line.
    public let runs: [[Point]]

    /// How many decimal places this quantity is read to — the chart's point labels and the card's
    /// spoken sentence both round to it, so the two cannot state the same day differently.
    ///
    /// Set by each initialiser and never by a caller, so a quantity cannot be drawn at a resolution
    /// that does not belong to it. See the type's own comment for why the two whole-number quantities
    /// and the fractional one differ.
    public let valueDecimals: Int

    /// The week's resting heart rates, one point per day that has one.
    ///
    /// **No narrowing here, and that is the difference from the HRV series rather than an oversight.**
    /// A resting heart rate is one quantity in one unit, so every measured day in the week plots. Nil
    /// means *no chart at all* rather than an empty one: seven labelled columns with nothing in them is
    /// a week of zeros drawn once per column, the same fabrication a point at zero would be.
    ///
    /// The absence is already decided upstream — `MetricDay.restingHeartRate` is nil for a day with no
    /// row and for one an older build wrote as a reserved zero — so the optional is the whole rule and
    /// there is no second gate here to disagree with it.
    public init?(restingHeartRateWeek week: MetricWeek) {
        let points = week.days.enumerated().compactMap { slot, day -> Point? in
            guard let rate = day.restingHeartRate else { return nil }
            return Point(slot: slot, value: Double(rate))
        }
        guard !points.isEmpty else { return nil }

        self.points = points
        self.runs = Self.runs(points)
        // A stored rate is a whole bpm, and the slot's own type says so — an `Int?`. A label reading
        // `52.0` would claim a resolution the measurement does not have.
        self.valueDecimals = 0
    }

    /// The week's respiratory rates, one point per day that has one.
    ///
    /// **No narrowing and no gate**, for two different reasons. There is one quantity here — breaths
    /// per minute — so there is nothing to narrow to. And the column has no reserved zero: it is
    /// optional on both the row and the slot, so the optional is the whole rule and this initialiser
    /// is the only one of the three with no absence test beyond it. Nil means *no chart at all*, the
    /// same as the other two.
    ///
    /// **One decimal place, and that is not a preference.** Measured over the bundled export, this
    /// quantity runs 13.5–20.2 rpm and a week of it typically spans under two — the reference week is
    /// 14.8, 15.4, 14.9, 14.9, 14.9, 16.5, 14.9. Rounded to whole numbers that week reads
    /// `15 15 15 15 15 17 15`, which is not a coarser version of the reading, it is a different and
    /// wrong one: it hides the 16.5 that is the whole point of the week and flattens six distinct
    /// days into a single number. The other two charts are printed whole because their stored
    /// resolutions are whole; this one is stored to a tenth and is read to a tenth.
    public init?(respiratoryRateWeek week: MetricWeek) {
        let points = week.days.enumerated().compactMap { slot, day -> Point? in
            guard let rate = day.respiratoryRate else { return nil }
            return Point(slot: slot, value: rate)
        }
        guard !points.isEmpty else { return nil }

        self.points = points
        self.runs = Self.runs(points)
        self.valueDecimals = 1
    }

    /// The week's HRV, narrowed to a single quantity.
    ///
    /// ## The never-mix rule, applied to a chart
    ///
    /// `RecoveryScoring` filters history to one metric before every baseline, and the week's own
    /// baseline does the same — so this narrows to `MetricWeek.hrvBaselineMetric`, the newest measured
    /// slot's quantity, rather than plotting whatever the slots happen to hold.
    ///
    /// The consequence is that a mixed week plots **fewer than seven points**, and the ones it drops
    /// were measured. That is the correct handling and not a gap to explain away, but it is why the
    /// count of points is not the count of measured days and nothing here should be asked to make it
    /// so. The same narrowing can leave a single point in a week full of readings — the minority case
    /// `MetricWeek` documents — which draws as one dot and no line, which is what one day of data is.
    ///
    /// Nil covers a week with no reading at all, and in principle a week whose readings are all in a
    /// quantity no slot names — which `MetricDay` makes unreachable, since `hrvMetric` is non-nil
    /// exactly when `hrvValueMs` is, so the pair can never disagree.
    public init?(hrvWeek week: MetricWeek) {
        guard let metric = week.hrvBaselineMetric else { return nil }

        let points = week.days.enumerated().compactMap { slot, day -> Point? in
            guard day.hrvMetric == metric, let value = day.hrvValueMs else { return nil }
            return Point(slot: slot, value: value)
        }
        guard !points.isEmpty else { return nil }

        self.points = points
        self.runs = Self.runs(points)
        // A stored HRV is a mean over a night's beats and the slot's type is a `Double`, but no reader
        // reads a week at a fraction of a millisecond.
        self.valueDecimals = 0
    }

    /// Splits points into runs of adjacent slots.
    ///
    /// Adjacency is on the slot index and not on the date: `MetricWeek`'s slots are one calendar day
    /// apart by construction, so a gap in the indices is a gap in the days, and re-deriving it from
    /// `Date` arithmetic would only give the calendar a second opinion it does not need.
    static func runs(_ points: [Point]) -> [[Point]] {
        var runs: [[Point]] = []
        var current: [Point] = []
        var previousSlot: Int?

        for point in points {
            if let previousSlot, point.slot != previousSlot + 1 {
                runs.append(current)
                current = []
            }
            current.append(point)
            previousSlot = point.slot
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
