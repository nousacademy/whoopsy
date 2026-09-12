import Foundation

/// One day's daytime physiological activation.
///
/// Derived on read rather than stored. Unlike the day-keyed metric tables, this is a function of
/// `biometric_samples` and nothing else, so persisting it would only create a second copy that can
/// disagree with the samples it came from.
///
/// There is no placeholder instance and no zero value. A day whose samples yielded no eligible
/// window has no score — `AnalyzeStressUseCase` returns `nil` — because a `0.0` here would read as
/// "perfectly calm", which is a claim, and the absence of a measurement is not one.
public struct StressScore: Equatable, Sendable {
    /// The day this describes, snapped to its start.
    public let date: Date

    /// Mean activation across the day's eligible windows, on the 0–3 scale.
    ///
    /// The day's representative figure, and what `band` is derived from. `peakScore` is the day's
    /// worst moment instead.
    public let averageScore: Double

    /// The highest-scoring window of the day, on the 0–3 scale.
    ///
    /// Kept alongside the average because the two answer different questions, and the product
    /// behaviour WHOOP describes keys off the high-stress *moment* — that is when breathwork is
    /// offered. Neither is derived from the other.
    public let peakScore: Double

    /// How many eligible windows stood behind those numbers.
    ///
    /// Carried so the figure can be judged rather than merely read. A day with two windows and a day
    /// with two hundred both produce an average, and only this says which one you are looking at.
    public let windowCount: Int

    /// The band `averageScore` falls in, on WHOOP's published 0–3 edges.
    public let band: StressMath.Band

    public init(date: Date, averageScore: Double, peakScore: Double, windowCount: Int) {
        self.date = date
        self.averageScore = averageScore
        self.peakScore = peakScore
        self.windowCount = windowCount
        self.band = StressMath.band(forScore: averageScore)
    }
}
