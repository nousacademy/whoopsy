import Foundation

/// Scores a day's daytime physiological activation — see `StressMath` for the model's provenance.
///
/// Reads `biometric_samples` and nothing else: a window's RMSSD comes from the R-R intervals the
/// strap recorded, its heart rate from the same rows, and its stillness from their accelerometer
/// magnitudes. Nothing is written, so unlike the calculate use cases this one cannot damage a stored
/// day — it is a pure read whose only output is the value it returns.
public final class AnalyzeStressUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let calendar: Calendar

    public init(
        biometricRepository: any BiometricRepository,
        calendar: Calendar = .current
    ) {
        self.biometricRepository = biometricRepository
        self.calendar = calendar
    }

    /// The day's activation — the aggregate and the windows behind it — or `nil` when it has none.
    ///
    /// `nil` covers three situations this model cannot tell apart from the data it holds, and reports
    /// the same way on purpose:
    ///
    /// - the day has no samples at all — the common case on an imported day, and always on a
    ///   strap-less install, because the WHOOP export carries no R-R series;
    /// - its samples contain no still window with enough beats;
    /// - there is not enough history to build a personal baseline.
    ///
    /// Each of those is "no measurement", not a low score, and `StressScore` has no zero that could
    /// be mistaken for one. `nil` rather than a `StressDay` with an empty series is what lets a chart
    /// tell "nothing was measured" from "everything measured was calm" — the two draw the same empty
    /// plot, and only one of them should be drawn at all.
    ///
    /// One pass over the samples, and every value in the result comes out of it. `execute(for:)` is a
    /// forwarder to this method rather than a second implementation, so the aggregate cannot come to
    /// disagree with the series it is the mean of.
    public func executeDay(for date: Date) async throws -> StressDay? {
        guard let windows = try await evaluate(date: date) else { return nil }
        return StressDay(date: date.startOfDay, windows: windows)
    }

    /// The day's aggregate, or `nil` when it has none to report. See `executeDay(for:)`.
    public func execute(for date: Date) async throws -> StressScore? {
        try await executeDay(for: date)?.score
    }

    /// The day's scored windows, or `nil` when the day has no measurement to report.
    ///
    /// Every early return below is the aggregate's absence rule as well, which is the point of
    /// splitting it here: a caller that needs the series and a caller that needs the number cannot
    /// come to different conclusions about whether the day has anything on it.
    private func evaluate(date: Date) async throws -> [StressWindow]? {
        let dayStart = date.startOfDay
        guard let today = StressMath.wakingWindow(on: dayStart, calendar: calendar) else { return nil }

        // The baseline window: the same waking hours, `baselineDays` days back, ending where today
        // begins so the day being scored is never part of the baseline it is scored against.
        guard let baselineStart = calendar.date(
            byAdding: .day, value: -StressMath.baselineDays, to: today.lowerBound)
        else { return nil }

        guard let lastBaselineDay = calendar.date(
            byAdding: .day, value: -1, to: dayStart)
        else { return nil }

        // One read for the whole span rather than fifteen. This is the expensive part of the use case:
        // a fortnight of samples, which on a strap worn all day is a large array. Should it prove slow
        // in practice the fix is a per-day aggregate table, not a shorter window — the model needs the
        // history it is given here.
        let samples = try await biometricRepository.getSamples(
            from: baselineStart, to: today.upperBound)

        // Each baseline day is reduced to one point, so the baseline is a series of *days* rather than
        // of windows. Weighting by windows instead would let one heavily-worn day outvote a fortnight.
        var baselinePoints: [BaselinePoint] = []
        var day = lastBaselineDay
        while day >= baselineStart.startOfDay {
            if let window = StressMath.wakingWindow(on: day, calendar: calendar) {
                let points = eligibleWindows(
                    in: samples.filter { window.contains($0.timestamp) })
                if !points.isEmpty {
                    baselinePoints.append(
                        BaselinePoint(
                            meanRmssdMs: Self.mean(points.map(\.meanRmssdMs)),
                            meanHeartRate: Self.mean(points.map(\.meanHeartRate))))
                }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        // Below this there is no personal baseline, and the model is defined *relative* to one. A score
        // against a default would be a different quantity wearing this one's name.
        guard baselinePoints.count >= StressMath.minimumBaselineDays else { return nil }

        let rmssdBaseline = BaselineStatisticsMath.baseline(
            baselinePoints.map(\.meanRmssdMs), fallbackMean: 0, fallbackStdDev: 0)
        let heartRateBaseline = BaselineStatisticsMath.baseline(
            baselinePoints.map(\.meanHeartRate), fallbackMean: 0, fallbackStdDev: 0)

        let windows = eligibleWindows(in: samples.filter { today.contains($0.timestamp) })
        guard !windows.isEmpty else { return nil }

        return windows.map { window in
            StressWindow(
                start: window.start,
                score: StressMath.score(
                    fromActivation: StressMath.activation(
                        rmssdMs: window.meanRmssdMs,
                        meanHeartRate: window.meanHeartRate,
                        rmssdBaseline: rmssdBaseline,
                        heartRateBaseline: heartRateBaseline)))
        }
    }

    // MARK: - Windowing

    /// One window's features — the third, motion, has already done its job by qualifying it.
    private struct WindowFeatures {
        /// The bucket's anchor, carried through to `StressWindow.start` so the series can be plotted.
        let start: Date
        let meanRmssdMs: Double
        let meanHeartRate: Double
    }

    /// One baseline day, collapsed.
    private struct BaselinePoint {
        let meanRmssdMs: Double
        let meanHeartRate: Double
    }

    /// Splits samples into consecutive `windowSeconds` buckets and keeps the ones worth scoring.
    ///
    /// A window is kept only when the strap was still **and** it holds enough R-R intervals for an
    /// RMSSD that means something — see `StressMath.minimumRRIntervals` for why the second gate is not
    /// merely tidy.
    private func eligibleWindows(in samples: [BiometricSample]) -> [WindowFeatures] {
        var features: [WindowFeatures] = []

        for bucket in Self.windows(of: samples) {
            let samples = bucket.samples
            let rrIntervals = samples.compactMap(\.rrIntervalMs)
            guard rrIntervals.count >= StressMath.minimumRRIntervals else { continue }

            // The strap must have been still, and **shown** to have been. `magnitudes:` refuses a
            // whole window in which no sample carries an accelerometer — which is every window the
            // live `0x2A37` path produces, since nothing in the BLE layer decodes a motion payload
            // yet. The day then has no eligible windows and the tile is `—`. That is the honest
            // answer: exertion is the one thing this model separates from stress, and without motion
            // it cannot tell a workout from an argument.
            guard StressMath.isResting(magnitudes: samples.map(\.accelerationMagnitude)) else {
                continue
            }

            // A zero heart rate is an absent reading, not a stopped heart: the decoder yields 0 for
            // samples carrying no pulse value, and letting one into the mean would drag it down.
            let rates = samples.map(\.heartRate).filter { $0 > 0 }
            guard !rates.isEmpty else { continue }

            features.append(
                WindowFeatures(
                    start: bucket.start,
                    meanRmssdMs: HeartRateVariabilityMath.calculateRMSSD(from: rrIntervals),
                    meanHeartRate: Double(rates.reduce(0, +)) / Double(rates.count)))
        }
        return features
    }

    /// One `windowSeconds` bucket and the instant it begins at.
    private struct WindowBucket {
        let start: Date
        let samples: [BiometricSample]
    }

    /// Groups samples into consecutive `windowSeconds` buckets, anchored on the first sample so a
    /// window is never split because of where the clock happens to sit.
    ///
    /// The grouping expression is unchanged from when this returned bare arrays — only the returned
    /// tuple grew. It matters: the bucket index is what decides which samples are scored together, so
    /// any change to it would silently re-cut every window and move every score.
    ///
    /// Each bucket's `start` is that anchor plus whole window steps, which is what the chart plots. It
    /// is therefore *not* clock-aligned: a day whose first in-window sample lands at 09:03 has windows
    /// at :03, :08, :13. Rounding those to the hour for display would move a measurement to a time
    /// nobody took it at, so the chart draws the anchor it was given.
    private static func windows(of samples: [BiometricSample]) -> [WindowBucket] {
        guard let first = samples.first?.timestamp else { return [] }
        let buckets = Dictionary(grouping: samples) { sample in
            Int(sample.timestamp.timeIntervalSince(first) / StressMath.windowSeconds)
        }
        return buckets.keys.sorted().compactMap { index in
            guard let bucket = buckets[index] else { return nil }
            return WindowBucket(
                start: first.addingTimeInterval(Double(index) * StressMath.windowSeconds),
                samples: bucket)
        }
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
