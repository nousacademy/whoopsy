import Foundation

/// One day's Stress Monitor result: the aggregate and the windows behind it, evaluated together.
///
/// This exists so the two cannot be read from separate evaluations. A tile that showed an average of
/// 1.4 above a chart of a different day's windows would be one number describing one measurement and
/// a line describing another, with nothing on screen to say so. `AnalyzeStressUseCase.executeDay(for:)`
/// is the only producer, and it makes exactly one pass over the samples.
///
/// The aggregate is built here rather than passed in, which is what makes the invariant structural:
/// `windows.count == score.windowCount` holds by construction, because the count *is* the window
/// count. A value type that took both would let a caller pair a score with someone else's series.
public struct StressDay: Equatable, Sendable {
    /// The day this describes, snapped to its start.
    public let date: Date

    /// The day's scored windows, earliest first.
    public let windows: [StressWindow]

    /// The day's aggregate figure, computed from `windows`.
    ///
    /// No `init` parameter for it: a caller holding a `StressScore` to hand in would be a caller able
    /// to hand in the wrong one, and the whole point of this type is that the day's number and the
    /// day's line are one evaluation.
    public let score: StressScore

    /// The **personal** baseline every window above was scored against, or `nil`.
    ///
    /// `nil` means one of two things, and the second is the common one on a young install: the day
    /// was scored relative to its own preceding hours, because fewer than three prior days carried
    /// still windows. There is no single baseline to carry in that case — each window has its own,
    /// drawn from the windows before it inside `StressMath.recentBaselineSpan` — so a live monitor
    /// rebuilds them from the windows' own features rather than from a value here.
    ///
    /// A non-`nil` value is the four numbers a live tick scores against, which is what stops it
    /// re-reading a fortnight of samples per tick. See `StressBaseline`.
    public let baseline: StressBaseline?

    public init(date: Date, windows: [StressWindow], baseline: StressBaseline? = nil) {
        self.date = date
        self.windows = windows
        self.baseline = baseline
        self.score = StressScore(
            date: date,
            averageScore: Self.mean(windows.map(\.score)),
            peakScore: windows.map(\.score).max() ?? 0,
            windowCount: windows.count)
    }

    /// The time the day spent in one band, in seconds.
    ///
    /// **A window's score is a claim about its own five minutes**, so the duration behind a band is a
    /// count of windows times `StressMath.windowSeconds` — not a difference between two instants. The
    /// windows need not be contiguous (each is only kept when the strap was still and held enough
    /// beats), so summing their spans is the only honest total: a gap between two windows belongs to
    /// no band, and is measured by subtracting this from the waking window rather than by inventing a
    /// band for it. `StressDetailView`'s sentence is the reader of this.
    public func seconds(in band: StressMath.Band) -> TimeInterval {
        Double(windows.filter { $0.band == band }.count) * StressMath.windowSeconds
    }

    /// `0` for an empty series, which is unreachable from the use case: a day with no eligible window
    /// has no `StressDay` at all, rather than one with an empty line and a `0.0` average — the same
    /// rule `StressScore` documents for its own zero.
    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
