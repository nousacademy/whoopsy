import Foundation

/// The vertical scale a fast's nights are drawn on: **standard deviations of the user's own window,
/// measured up from the baseline**.
///
/// ## Why this axis is fixed and not fitted
///
/// `FittedAxis` exists because HRV, resting heart rate and respiratory rate have no definition to fix
/// a scale to — a night's 62 ms means nothing without knowing whose 62 ms it is. **A z-score has that
/// definition built in**: the unit is one σ of the user's own baseline window, `0` is that window's
/// mean, and the quantity is already dimensionless. So the standard scale is `0...4` for every fast
/// this app will ever draw, and a column reaching +2σ is the same height on one user's chart as on
/// another's — which is the entire point of normalising, and the one property a fitted axis would
/// destroy while looking more careful.
///
/// ## The floor is the baseline, and there is no lower bound to store
///
/// This axis used to be symmetric about `0` with the rule drawn across the middle, because a z-score
/// has a sign and a bar had to be able to grow downward. **It no longer does.** A quantity that fell
/// below its baseline draws a *shorter* segment rather than one below the rule — the user's own
/// *"if they go negative just shrink it"* — so every segment on the chart grows up from the baseline
/// and the baseline is the frame's foot. A lower bound would be a number nothing can reach.
///
/// The cost is recorded rather than hidden: with no downward direction on the drawing, a night whose
/// three readings all fell draws an **empty column**, and the sentence under the chart is the only
/// place a fall is legible. That is a real loss of information and it is the one the user asked for;
/// `FastingRecoveryChartView`'s type comment carries it in full.
///
/// ## What it copies from `ActivityHeartRateAxis`
///
/// The rules, restated by value: fixed bounds rather than an auto-fit, widening in `wideningStep`-sized
/// steps rather than clamping, and gridlines derived from the bounds rather than listed. That type is
/// this one's sibling and its doc comment carries the argument for the first two.
///
/// ## What it is fitted to, which changed when the bars merged
///
/// It used to be handed the individual z-scores, and since each of those has already been clamped to
/// `±maximumAbsoluteZScore` (4.0) by `BaselineStatisticsMath.zScore`, `4` was the last rung the ladder
/// could reach. **The chart now plots one column per night with the quantities stacked inside it**, so
/// what a column actually reaches is the *sum* of the excursions above the baseline — up to `3 × 4σ`.
/// The axis follows what is drawn, which is the only honest thing for it to do: a segment's length is
/// its own excursion read against this scale, so the scale has to contain the tallest column or the
/// picture is measured against a ruler too short for it.
public struct FastingRecoveryAxis: Equatable, Sendable {

    /// The top of the scale, in σ of **stacked** excursion above the baseline.
    public let upperBound: Double

    /// The labelled lines, ascending — **with the baseline removed**.
    ///
    /// The chart strokes `0` itself, as the rule across the frame's foot that the whole drawing is
    /// measured from, and a scale that also listed it would stroke that line twice — a visible seam on
    /// the one line every segment stands on. `baselineLine` is the single definition of where it goes,
    /// and §19 asserts the two never overlap.
    public let gridLines: [Double]

    /// Where the baseline mean is drawn. A constant, and deliberately not a stored bound.
    public static let baselineLine: Double = 0

    private static let wideningStep: Double = 1

    /// The most lines one margin may carry, which is what sets the grid's spacing.
    ///
    /// Nine, because the margin is `barAreaHeight` (132 pt) tall and a tick label is 10 pt type: nine
    /// lines are 14.7 pt apart, which is the closest two rows of labels can sit without touching. The
    /// step coarsens at the first bound that would exceed it.
    private static let maximumLinesPerMargin = 9

    /// Where the scale starts when nothing argues otherwise: `0...4`, ruled at `1`, `2`, `3`.
    ///
    /// Four σ of **stacked** excursion, i.e. roughly three quarters of the way up for a night whose
    /// three readings each moved about a σ — the ordinary shape on this chart — and room to spare for
    /// a night that moved further. `gridLines` excludes both ends, so the scale is ruled three times.
    public static let standard = FastingRecoveryAxis(upperBound: 4, gridLines: lines(upTo: 4))

    public init(upperBound: Double, gridLines: [Double]) {
        self.upperBound = upperBound
        self.gridLines = gridLines
    }

    /// How far up the scale a value sits, as a fraction of the plot's height. **`0` is the floor.**
    ///
    /// Clamped, and — as in `ActivityHeartRateAxis.fraction` — that is not a fabrication: the bound is
    /// widened to contain every column before this is asked, so a value outside it is reachable only
    /// through a hand-built axis. `NaN` collapses to the floor rather than propagating, since every
    /// comparison against a `NaN` is false and the clamp could not catch it. And a **negative** value
    /// collapses to the floor as well, which is the shrink rather than a second direction — see the
    /// type comment.
    public func fraction(_ value: Double) -> Double {
        guard value.isFinite, upperBound > 0 else { return 0 }
        return min(1, max(0, value / upperBound))
    }

    /// The standard scale widened until it contains every finite value it is handed.
    ///
    /// Only the top moves: the foot is the baseline mean for every fast, so there is no second side to
    /// widen. Values at or below zero are ignored rather than pulling a bound down — they have no
    /// extent on this drawing. The finiteness guard on the result is for a hand-built input, and it
    /// falls back to the standard axis rather than to an infinite one.
    public static func fit(_ values: [Double]) -> FastingRecoveryAxis {
        let reached = values.filter { $0.isFinite && $0 > 0 }
        guard let highest = reached.max() else { return .standard }

        let steps = max(0, ((highest - standard.upperBound) / wideningStep).rounded(.up))
        guard steps > 0 else { return .standard }

        let bound = standard.upperBound + steps * wideningStep
        guard bound.isFinite, bound > 0 else { return .standard }

        return FastingRecoveryAxis(upperBound: bound, gridLines: lines(upTo: bound))
    }

    /// The spacing between ruled lines, chosen so the margin stays a scale rather than a grey block.
    ///
    /// The step used to be a constant, and it could be: every input was a clamped z-score, so the
    /// widest axis this type could build was seven lines. With the columns stacked, a bound of `12` is
    /// reachable and a unit step would rule eleven lines down a 132-point margin. So the step doubles
    /// until the margin is inside `maximumLinesPerMargin`.
    ///
    /// **Keyed to a count of lines and not to a bound**, which is the correction: the earlier rule
    /// doubled past `maximumAbsoluteZScore`, a threshold that says something true about a single
    /// z-score and nothing about how many labels fit on a margin. On the one-sided axis that fires at
    /// a bound of `5`, where a unit step draws four comfortable lines — so a fast whose nights moved
    /// about a σ would have been ruled at 2σ and left with no line anywhere near its segments.
    private static func gridStep(forBound bound: Double) -> Double {
        var step: Double = 1
        while lineCount(forBound: bound, step: step) > maximumLinesPerMargin { step *= 2 }
        return step
    }

    /// How many lines a margin of `bound` ruled at `step` would carry: the multiples of `step` strictly
    /// between the baseline and the bound, which is `ceil(bound / step) - 1`.
    private static func lineCount(forBound bound: Double, step: Double) -> Int {
        guard step > 0, bound > 0 else { return 0 }
        return max(0, Int((bound / step).rounded(.up)) - 1)
    }

    /// Lines stepping up from the baseline, ascending, excluding `upperBound` and excluding `0`.
    ///
    /// Two exclusions, for two different reasons: the upper bound's line would land on the frame's own
    /// top edge, and the baseline's is drawn by the chart as a rule. See `gridLines`.
    private static func lines(upTo upper: Double) -> [Double] {
        guard upper > 0 else { return [] }
        let step = gridStep(forBound: upper)
        var lines: [Double] = []
        var value = baselineLine
        // Bounded by the same guard the loop condition carries: `step` is positive, so `value` strictly
        // increases and the loop cannot spin.
        while value < upper {
            if value != baselineLine { lines.append(value) }
            value += step
        }
        return lines
    }
}

/// The nights a fast covered, as the columns a chart can draw.
///
/// ## Why this is a type and not the summary itself
///
/// The three sleep week charts' precedent (`HoursVsNeededWeek`, `RestorativeSleepWeek`,
/// `TimeInBedWeek`), and their reason: **the runner has no renderer**, so the axis, the legend's
/// entries and the sentence have to be values something can assert rather than expressions inside a
/// `body`. A `nil` return means **no chart at all** — not an empty frame, which would draw a fast that
/// measured nothing as a fast that measured flat.
///
/// ## The two absence states, which are different and must not be merged
///
/// - `FastingRecovery.summary(for:history:)` returning `nil` means the fast covered no measured night.
///   That is the common case on the bundled files and the reader's sentence is *no physiological
///   readings inside this fast*.
/// - A summary that exists but yields no series here means the fast covered nights and **the baseline
///   window behind them was too thin to draw a z-score against**. A different sentence, because
///   "nothing was measured" and "nothing to compare it to" are different answers and telling a user
///   with four nights of readings that there were none would be a lie about their own data.
public struct FastingRecoveryChartSeries: Equatable, Sendable {

    /// One night: a column, with the segments it stacks and the day it is labelled with.
    public struct Point: Equatable, Sendable, Identifiable {
        /// The day key — the morning this night ended on.
        public let date: Date

        /// The z-scores this column draws, keyed by quantity. A quantity missing from the dictionary
        /// is one this night has no segment for, either because it has no reading or because the
        /// baseline behind it was too thin — the two are the same answer on the chart and are
        /// distinguished in the legend, which lists only the quantities that appear at all.
        public let zScores: [FastingMetric: Double]

        public var id: Date { date }

        /// A point from a day and its z-scores.
        ///
        /// Explicit and `public` for the reason `WorkoutRoutePoint`'s initialiser is: the runner is a
        /// separate module that `import Whoopsy`s, so the synthesised memberwise initialiser — which is
        /// `internal` — is out of its reach. The chart's geometry is asserted against these directly,
        /// where every z is a literal a reader can check, rather than against whatever a fixture
        /// history happens to produce.
        public init(date: Date, zScores: [FastingMetric: Double]) {
            self.date = date
            self.zScores = zScores
        }

        /// How far this column reaches **up from the baseline**, in σ — the sum of the excursions that
        /// rose above it.
        ///
        /// The one quantity a merged column has that a grouped one did not. Three bars side by side
        /// each stood on their own; three segments in one column add up, so the column's own extent is
        /// a number the axis has to be fitted to and the drawing has to be built from. It is a sum of
        /// z-scores and **is not itself a z-score** — which is why it is never printed, never spoken,
        /// and appears only as geometry.
        ///
        /// **Only the excursions above the baseline count**, because those are the only ones the chart
        /// draws: a quantity that fell contributes no length, so it must not stretch the axis either.
        public var stackTotal: Double { Self.stackTotal(of: zScores) }

        /// `stackTotal` as a pure function, so the runner can drive it without a `Point`.
        public static func stackTotal(of zScores: [FastingMetric: Double]) -> Double {
            zScores.values.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        }
    }

    /// One column per covered night, **oldest first**, which is the order they are drawn in.
    public let points: [Point]

    /// The scale every column shares. One axis, widened to hold every bar on the chart.
    public let axis: FastingRecoveryAxis

    /// The quantities that appear on at least one column, in `FastingMetric.allCases` order.
    ///
    /// Derived rather than fixed at three, because a legend entry with no bar anywhere is a key to
    /// nothing: on a fast whose window carried no respiratory readings the third swatch would sit
    /// under a chart that never draws it.
    public let metrics: [FastingMetric]

    /// Which HRV quantity the window and the nights were narrowed to, for the legend's label.
    public let hrvMetric: HRVMetric?

    /// The footer sentence, composed from these same z-scores. See `sentence(for:)`.
    public let sentence: String

    /// The chart for a fast's summary, or `nil` when no night carries a drawable z-score.
    public init?(summary: FastingRecoverySummary) {
        let points = summary.nights.map { Point(date: $0.date, zScores: $0.zScores) }
        guard !points.flatMap({ $0.zScores.values }).isEmpty else { return nil }

        self.points = points
        // **Fitted to the columns, not to the z-scores inside them.** A night with HRV half a σ above
        // its baseline and resting heart rate half a σ above it reaches one σ up the frame, not half —
        // and an axis fitted to the individual values would draw that column straight off the top edge
        // of a scale it is supposed to be measured against. A night that drew nothing — every reading
        // on or below its baseline — contributes a total of zero and is dropped by `fit` itself, so a
        // fast whose readings all sat at or under their baselines falls back to the standard scale
        // rather than widening for nothing.
        self.axis = FastingRecoveryAxis.fit(points.map(\.stackTotal))
        self.metrics = FastingMetric.allCases.filter { metric in
            points.contains { $0.zScores[metric] != nil }
        }
        self.hrvMetric = summary.hrvMetric
        self.sentence = Self.sentence(for: points, metrics: metrics, hrvMetric: hrvMetric)
    }

    // MARK: - The footer sentence

    /// How far from the baseline counts as *at* it rather than above or below.
    ///
    /// Half a σ. A z-score is already a normalised quantity, so any threshold here is a choice rather
    /// than a measurement — and the honest place to put it is where a night's own noise stops being
    /// distinguishable from a move: below half a σ the two are the same picture on this chart, since
    /// a bar that short is a bar that reads as sitting on the rule.
    public static let flatThreshold: Double = 0.5

    /// Which side of the baseline a night's reading fell on.
    public enum Position: String, Sendable {
        case above
        case at
        case below

        /// Classifies a z-score, or `nil` for a night with no z to classify.
        public init?(zScore: Double?) {
            guard let zScore, zScore.isFinite else { return nil }
            if zScore > flatThreshold {
                self = .above
            } else if zScore < -flatThreshold {
                self = .below
            } else {
                self = .at
            }
        }

        /// The clause for a chart of **one** night: where it finished.
        ///
        /// "finished" rather than "rose" or "improved", because one reading has no direction — there is
        /// nothing for it to have moved from. The word states a position and claims no trend.
        func finishedClause(_ name: String) -> String {
            switch self {
            case .above: return "\(name) finished above your baseline"
            case .at: return "\(name) held at your baseline"
            case .below: return "\(name) finished below your baseline"
            }
        }

        /// The clause for a chart of **two or more** nights: where the last one ended up.
        ///
        /// The verb is the same for every night in between, on purpose: this sentence compares the
        /// last column with the first and says nothing about the shape of the path between them. A
        /// word like "steadily" would be a claim about four nights this arithmetic never looked at.
        func movedClause(_ name: String) -> String {
            switch self {
            case .above: return "\(name) climbed above your baseline"
            case .at: return "\(name) held at your baseline"
            case .below: return "\(name) fell below your baseline"
            }
        }
    }

    /// The sentence under the chart, composed from the same z-scores the bars are drawn from.
    ///
    /// ## It cannot describe a different set of nights than the bars
    ///
    /// That is the whole reason it is built here rather than in a view: the reference's
    /// `Normalized Trends (z-score basis): …` reads as a summary of the picture above it, and a
    /// sentence written independently would be free to disagree with it the first time either moved.
    /// Both come off `points`.
    ///
    /// ## One night states a position, several state a move
    ///
    /// With a single night there is no trend to report, so each quantity's clause says where it
    /// *finished*. With two or more, the comparison is **the last column against the first** — a
    /// two-point reading of the window, which is what the reference's own sentence is, and the only
    /// comparison a chart of one to four columns can support. `Position` carries both vocabularies.
    ///
    /// ## It reads z-scores and never physiology
    ///
    /// `HRV climbed above your baseline` is a statement about arithmetic on the user's own window and
    /// not about the fast having done anything. This app has no fasting mechanism to claim — no
    /// glucose, no ketones — so the sentence must not acquire a causal verb, and neither must a
    /// caller paraphrase it into one.
    ///
    /// A quantity with no z-score on either end is left out entirely rather than reported as
    /// unchanged: silence is the honest word for a quantity nothing measured.
    ///
    /// The clauses are joined as an ordinary list. The reference's connective is `while`, which reads
    /// well for exactly two clauses and has no form for three; a list reads correctly at one, two and
    /// three, and the states each clause reports are the same either way.
    static func sentence(
        for points: [Point],
        metrics: [FastingMetric],
        hrvMetric: HRVMetric?
    ) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let isSingleNight = points.count == 1

        let clauses: [String] = metrics.compactMap { metric in
            let position = isSingleNight
                ? Position(zScore: first.zScores[metric])
                : Position(zScore: last.zScores[metric])
            guard let position else { return nil }
            let name = metric.proseName(hrvMetric: hrvMetric)
            return isSingleNight
                ? position.finishedClause(name)
                : position.movedClause(name)
        }

        guard !clauses.isEmpty else { return "" }
        guard clauses.count > 1 else { return clauses[0] + "." }

        return clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1] + "."
    }

    /// What VoiceOver reads in place of the chart.
    ///
    /// A drawing is one element to a screen reader, so without this the entire chart is silence. It
    /// names the span and the count first — the two things the columns encode structurally — and then
    /// hands over to the sentence, which already speaks every quantity's direction. It does not recite
    /// the z-scores: `+1.4σ` is not a figure anyone reads aloud, and the raw figures are in
    /// `FastingRecoverySummary.Night.rawText(for:)`.
    public var spokenSentence: String {
        guard let first = points.first, let last = points.last else { return sentence }
        let nights = points.count == 1 ? "1 night" : "\(points.count) nights"
        let span = "\(first.date.formattedShortDate()) to \(last.date.formattedShortDate())"
        return "\(nights), \(span). \(sentence)"
    }
}
