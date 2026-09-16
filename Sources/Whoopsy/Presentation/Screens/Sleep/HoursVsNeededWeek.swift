import Foundation

/// A week's two sleep durations — what was slept and what was needed — as one drawing.
///
/// It is a type rather than logic in `HoursVsNeededChartView`'s body for the reason `WeekLineSeries`
/// and `WeekBarSeries` are types: the test runner has no renderer, so a rule written into a `View` is
/// a rule nothing can assert. Three rules live here, and the first is the one this card could get
/// wrong invisibly.
///
/// ## One axis, fitted to both lanes
///
/// `StrainRecoveryChartView` draws two series on **two** axes, and it has to: strain is 0–21 and
/// recovery is 0–100%, so a shared scale would flatten one of them. This card is the opposite case and
/// must not copy it. Asleep and needed are the same quantity in the same unit and their *difference*
/// is the reading — that gap is the night's shortfall — so the two lines have to be measured against
/// one scale or the picture says nothing. Two axes here would draw a 4:38 night level with a 9:17
/// need.
///
/// That is why the axis is fitted **here** and not in the view. `WeekLineChartView` fits its own
/// inside `body` from the one series it was handed, which is correct for a one-series chart; a
/// two-series chart doing the same thing would fit to whichever lane it reached for first and draw the
/// other against the wrong bounds. Fitting to the concatenation makes "the two lines share a scale"
/// structural, and puts it somewhere the runner can assert it.
///
/// ## Both lanes or no card
///
/// The card is a comparison, so one line is not half of it — it is the absence of the thing the card
/// is named for. A nil here draws no card rather than a single line, on the rule every other chart in
/// this app follows: an empty or one-sided frame is a drawing of something that was not measured.
///
/// The two lanes are still built independently, and can in principle hold different slots. They come
/// off one `sleeps` row, so in practice they do not — but the need is gated on being positive and the
/// asleep total is not, so a stored row with no need would plot a sleep point with no need point
/// beside it, which is the honest picture of that row.
public struct HoursVsNeededWeek: Equatable, Sendable {

    /// One plotted night: which column it belongs to, and the duration in it.
    ///
    /// **The value is the stored `TimeInterval`, not a converted `Double` of hours.** The chart needs
    /// hours — the axis has to be fitted in the unit a reader names, and a range of 16 000 seconds
    /// would put `FittedAxis`'s step ladder at 10 000 and its gridlines on figures like `50000` — but
    /// the *label* is a clock reading and `formattedCompactHoursMinutes()` is defined on seconds. So
    /// the seconds are carried and the division happens twice, at the two places that want it, rather
    /// than once at construction where it would round a duration before the label could read it back.
    public struct Point: Equatable, Sendable {
        public let slot: Int
        public let seconds: TimeInterval

        /// The same duration in hours, which is the unit the axis is fitted and drawn in.
        public var hours: Double { seconds / 3600 }

        public init(slot: Int, seconds: TimeInterval) {
            self.slot = slot
            self.seconds = seconds
        }
    }

    /// The nights' time asleep, in slot order.
    public let asleep: [Point]

    /// The nights' sleep need, in slot order.
    public let need: [Point]

    /// The scale both lanes are drawn against, fitted to the union of their values.
    public let axis: FittedAxis

    /// The week's two durations, or nil when it does not hold both of them.
    ///
    /// Both absences are already decided upstream — `MetricDay.asleepSeconds` and
    /// `.sleepNeedSeconds` are nil for a day with no classified night — so the optionals are the whole
    /// rule and there is no second gate here to disagree with them.
    public init?(week: MetricWeek) {
        let asleep = week.days.enumerated().compactMap { slot, day -> Point? in
            guard let seconds = day.asleepSeconds else { return nil }
            return Point(slot: slot, seconds: seconds)
        }
        let need = week.days.enumerated().compactMap { slot, day -> Point? in
            guard let seconds = day.sleepNeedSeconds else { return nil }
            return Point(slot: slot, seconds: seconds)
        }
        // One lane alone is not a comparison. See the type's own comment.
        guard !asleep.isEmpty, !need.isEmpty else { return nil }

        // The union, and this is the line that makes the two lines comparable. See above.
        guard let axis = FittedAxis(values: (asleep + need).map(\.hours)) else { return nil }

        self.asleep = asleep
        self.need = need
        self.axis = axis
    }

    /// The sleep lane split into runs of adjacent slots, so a gap breaks its line.
    public var asleepRuns: [[Point]] { Self.runs(asleep) }

    /// The need lane, split the same way.
    public var needRuns: [[Point]] { Self.runs(need) }

    /// Splits points into runs of adjacent slots.
    ///
    /// Adjacency is on the slot index rather than on the date, which is `WeekLineSeries.runs`' rule
    /// and for its reason: `MetricWeek`'s slots are one calendar day apart by construction, so a gap
    /// in the indices is a gap in the days. A segment drawn across one would span nights this lane has
    /// no value for and be read as a value for them.
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

    /// The week in one sentence: how many nights carry both durations, and the span they cover.
    ///
    /// **It is stated against the nights that carry both**, because a night carrying one lane and not
    /// the other is a column this drawing shows only half of — and the sentence exists so a listener
    /// who cannot see the picture is told how complete it is. The span is the same two figures the
    /// axis is fitted between, read off the points rather than off the axis' rounded bounds, so the
    /// sentence describes the week and not the frame it was drawn in.
    ///
    /// The durations are spoken through `formattedHoursMinutes()` and not the compact form the labels
    /// print, on `SleepTypicalRangeCard.spokenStageRow`'s rule: `7:33` on screen is a clock reading to
    /// a listener, and `7h 33m` is a duration.
    public var spokenSentence: String {
        let paired = Set(asleep.map(\.slot)).intersection(need.map(\.slot))
        let values = (asleep + need).map(\.seconds)
        guard let lowest = values.min(), let highest = values.max() else {
            return "Hours versus needed for the last seven days, no measurement"
        }
        return "Hours versus needed for the last seven days, "
            + "\(paired.count) of \(MetricWeek.dayCount) nights measured, "
            + "from \(lowest.formattedHoursMinutes()) to \(highest.formattedHoursMinutes())"
    }
}
