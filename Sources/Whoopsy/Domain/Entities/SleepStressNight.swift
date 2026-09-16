import Foundation

/// One night's within-sleep physiological activation: the trace, the aggregate, and how the scored
/// span divided across WHOOP's three bands.
///
/// ## Why this exists beside `StressDay`
///
/// The Stress Monitor is a **daytime** metric. `StressMath.wakingWindow` bounds it to 06:00–22:00 for a
/// reason its own doc comment gives: scoring the whole day would fold sleep in — where HRV is high and
/// heart rate low, correctly scoring as calm — and pull the day's average down. This type scores the
/// window the daytime model throws away, with the same model and the same bands, so the two are
/// commensurable rather than two different scales wearing the same colour.
///
/// It is **not** a `StressDay` narrowed to a night. A `StressDay`'s span is a calendar day's waking
/// hours; this one's is a sleep period, which crosses midnight and has no fixed clock bounds at all.
/// `StressDay` also carries no band breakdown, and that breakdown is most of what this card prints.
///
/// ## Nothing is stored
///
/// Derived on read from `biometric_samples` and nothing else, exactly as `StressScore` documents:
/// persisting it would create a second copy that can disagree with the samples it came from. There is
/// therefore no column, no migration and no placeholder — and it can be resolved for any night,
/// including one the export imported.
///
/// ## The bands divide the *scored* span, not the night
///
/// `percent` is a share of the time this model could score, which is not the same as elapsed sleep
/// period. The two differ by every window the strap was moving through or the R-R series could not
/// support, and on a real night that is a large fraction. `scoredSeconds` carries the denominator so a
/// reader can see which of the two they are looking at; the card prints the durations beside the
/// percentages, and the identity `Σ durations == scoredSeconds` holds on screen.
public struct SleepStressNight: Equatable, Sendable {

    /// The day this describes, snapped to its start — the morning the night ended on, which is this
    /// app's day key for a night everywhere else.
    public let date: Date

    /// The night's in-bed span: the **x axis this night is drawn against**.
    ///
    /// Carried on the entity rather than left for the chart to find, and that is the point of it. A
    /// chart handed bare `[StressWindow]` and a `Date` would be one line away from plotting a night
    /// against the day's 24-hour axis — which compiles, and draws a midnight-crossing night as two
    /// disconnected fragments at opposite ends of the calendar. The span travels with the windows it
    /// describes so the two cannot be separated.
    ///
    /// It is the session's `startTime ..< endTime`, bounded by
    /// `AnalyzeSleepStressUseCase.maximumNightSpanSeconds`, and it is **not** the sleep period: the
    /// in-bed span runs longer than the sleep it contains. Both the shares' denominator and the axis
    /// come from the scored windows instead; this is the frame they sit in.
    public let span: Range<Date>

    /// The night's scored windows, earliest first.
    public let windows: [StressWindow]

    /// The night's aggregate figure, computed from `windows`.
    ///
    /// No `init` parameter for it, for `StressDay`'s reason: a caller holding a `StressScore` to hand
    /// in would be a caller able to hand in the wrong one, and the point of this type is that the
    /// night's number and the night's line are one evaluation.
    public let score: StressScore

    /// How the scored span divided across the three bands, **high first** — the order the card prints
    /// them in, and the order the reference lists them.
    ///
    /// Always all three, including a band the night never entered. That is the one place in this app
    /// where a `0` is the reading rather than a reserved placeholder: a night with no high-stress
    /// window really did spend none of it high, and the card's headline is that same figure. The
    /// absence rule bites one level up — a night with no scored window has no `SleepStressNight` at
    /// all, so there is no card to draw three zeroes on.
    public let bands: [BandSummary]

    /// How many prior nights the baseline was drawn from.
    ///
    /// Carried for `StressScore.windowCount`'s reason: an aggregate of `0%` read against three nights
    /// and the same `0%` read against fourteen are different claims, and only this says which one is
    /// on screen.
    public let baselineNightCount: Int

    /// One band's share of the night.
    public struct BandSummary: Equatable, Sendable {
        /// Which band.
        public let band: StressMath.Band

        /// How many scored windows fell in it.
        public let windowCount: Int

        /// Its share of the scored span, in whole percent.
        public let percent: Int

        /// Its duration, being `windowCount × StressMath.windowSeconds`.
        ///
        /// **The model's own unit rather than a measured span.** WHOOP's own figures for this card —
        /// `1:34`, `6:24` — are not multiples of the five-minute window this model scores in, so its
        /// windowing is not this one's and its durations cannot be reproduced by it. Counting the
        /// windows it actually scored is the honest quantity; the alternative is a duration reverse
        /// -engineered to match a number this model never computed.
        public let durationSeconds: TimeInterval
    }

    /// The night's high-band share — the card's headline figure.
    ///
    /// `nil` only if `bands` were emptied by hand; `init` always writes all three, so through the
    /// throwing initialiser this is the high band's own percent.
    public var highPercent: Int? {
        bands.first { $0.band == .high }?.percent
    }

    /// The scored span those shares are of, in seconds.
    public var scoredSeconds: TimeInterval {
        windows.count > 0 ? Double(windows.count) * StressMath.windowSeconds : 0
    }

    /// A night's result, or `nil` when there is no scored window to describe.
    ///
    /// **Failable rather than documented-unreachable**, which is where this differs from `StressDay`.
    /// That type is non-failable and says an empty series cannot arrive; here the shares are a
    /// division, and a division by an empty span has no answer — so the rule that a night with nothing
    /// scored has no card is enforced by the type instead of restated at every call site. Three `0%`
    /// rows over an unnamed total would be a drawn picture of a night that was never measured, which
    /// is the strongest possible claim of calm.
    public init?(
        date: Date,
        span: Range<Date>,
        windows: [StressWindow],
        baselineNightCount: Int
    ) {
        guard !windows.isEmpty else { return nil }
        guard span.upperBound > span.lowerBound else { return nil }

        self.date = date
        self.span = span
        self.windows = windows
        self.baselineNightCount = baselineNightCount
        self.score = StressScore(
            date: date,
            averageScore: Self.mean(windows.map(\.score)),
            peakScore: windows.map(\.score).max() ?? 0,
            windowCount: windows.count)

        // Counted per band first, then converted to shares in one call, so the three percentages are
        // largest-remainder over the same total and cannot fail to sum to 100. `Counting` is a local
        // type rather than a dictionary keyed by `Band` so the printed order is fixed here rather than
        // depending on how a dictionary happened to enumerate.
        let ordered: [StressMath.Band] = [.high, .medium, .low]
        let counts = ordered.map { band in
            windows.filter { $0.band == band }.count
        }
        let durations = counts.map { Double($0) * StressMath.windowSeconds }

        // Unreachable: `windows` is non-empty, so the total is at least one window and is positive.
        // Falling back to equal zeroes rather than trapping keeps a malformed input from taking the
        // app down, and the fallback is still a set of real readings — a band with no window is `0%`.
        let percents = WholePercentMath.wholePercents(ofSeconds: durations)
            ?? ordered.map { _ in 0 }

        self.bands = zip(ordered, zip(counts, zip(percents, durations))).map { band, parts in
            BandSummary(
                band: band,
                windowCount: parts.0,
                percent: parts.1.0,
                durationSeconds: parts.1.1)
        }
    }

    /// `0` for an empty series, which `init` refuses before it can be reached.
    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
