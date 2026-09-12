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

    public init(date: Date, windows: [StressWindow]) {
        self.date = date
        self.windows = windows
        self.score = StressScore(
            date: date,
            averageScore: Self.mean(windows.map(\.score)),
            peakScore: windows.map(\.score).max() ?? 0,
            windowCount: windows.count)
    }

    /// `0` for an empty series, which is unreachable from the use case: a day with no eligible window
    /// has no `StressDay` at all, rather than one with an empty line and a `0.0` average — the same
    /// rule `StressScore` documents for its own zero.
    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
