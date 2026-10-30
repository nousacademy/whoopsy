import Foundation

/// Scores a day's daytime physiological activation — see `StressMath` for the model's provenance.
///
/// Reads `biometric_samples` and nothing else: a window's RMSSD comes from the R-R intervals the
/// strap recorded, its heart rate from the same rows, and its stillness from their accelerometer
/// magnitudes. Nothing is written, so unlike the calculate use cases this one cannot damage a stored
/// day — it is a pure read whose only output is the value it returns.
public final class AnalyzeStressUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    /// The stillness **fallback**, and optional so every existing fixture keeps working. The live
    /// heart-rate record carries no motion lane, so without it a window built from live samples can
    /// never be shown to be still — see `StressWindowEvaluator.features`.
    private let motionRepository: (any MotionEpochRepository)?
    private let calendar: Calendar

    public init(
        biometricRepository: any BiometricRepository,
        motionRepository: (any MotionEpochRepository)? = nil,
        calendar: Calendar = .current
    ) {
        self.biometricRepository = biometricRepository
        self.motionRepository = motionRepository
        self.calendar = calendar
    }

    /// The day's activation — the aggregate and the windows behind it — or `nil` when it has none.
    ///
    /// `nil` covers two situations this model cannot tell apart from the data it holds, and reports
    /// the same way on purpose:
    ///
    /// - the day has no samples at all — the common case on an imported day, and always on a
    ///   strap-less install, because the WHOOP export carries no R-R series;
    /// - its samples contain no still window with enough beats.
    ///
    /// **A missing personal baseline is no longer one of them.** A day with no three-day history is
    /// scored against its own preceding hours instead (`StressWindowEvaluator.recentBaseline`), so a
    /// day is only absent when nothing measurable happened on it. The day's `baseline` is `nil` in
    /// that case, which is how the live page knows to build the same relative reference itself.
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
        guard let evaluated = try await evaluate(date: date) else { return nil }
        return StressDay(
            date: date.startOfDay, windows: evaluated.windows, baseline: evaluated.baseline)
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
    private func evaluate(
        date: Date
    ) async throws -> (windows: [StressWindow], baseline: StressBaseline?)? {
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
        // The fallback stillness source, read over the same span. Optional: a fixture with none
        // simply has no fallback, which is the pre-existing behaviour.
        let motionEpochs = (try? await motionRepository?.getMotionEpochs(
            from: baselineStart, to: today.upperBound)) ?? []

        // Each baseline day is reduced to one point, so the baseline is a series of *days* rather than
        // of windows. Weighting by windows instead would let one heavily-worn day outvote a fortnight.
        var baselinePoints: [BaselinePoint] = []
        // **Per-day window counts, for the capture.** "The stress tile is a dash" has four possible
        // causes and three of them look identical on the glass: no daytime samples at all (the strap
        // is only worn at night), samples with no still window, still windows with too few beats, and
        // too few such days for a baseline. This array separates them in one line.
        var baselineWindowsPerDay: [Int] = []
        var day = lastBaselineDay
        while day >= baselineStart.startOfDay {
            if let window = StressMath.wakingWindow(on: day, calendar: calendar) {
                let scan = eligibleWindows(
                    in: samples.filter { window.contains($0.timestamp) },
                    epochs: motionEpochs)
                baselineWindowsPerDay.append(scan.features.count)
                if !scan.features.isEmpty {
                    baselinePoints.append(
                        BaselinePoint(
                            meanRmssdMs: Self.mean(scan.features.map(\.meanRmssdMs)),
                            meanHeartRate: Self.mean(scan.features.map(\.meanHeartRate))))
                }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        let perDay = baselineWindowsPerDay.reversed().map(String.init).joined(separator: ",")

        // Today's windows come first now, because whether they can be scored no longer depends on
        // the personal baseline. A day with no three-day history is still a measured day.
        let scan = eligibleWindows(
            in: samples.filter { today.contains($0.timestamp) }, epochs: motionEpochs)
        let todayFeatures = scan.features
        // **The scan, whether it found windows or not.** `buckets=` is how many five-minute slices
        // the day held, and the three counters say which gate dropped the rest: `short=` windows with
        // fewer than 20 R-R intervals, `moved=` windows with no accelerometer or a mean above the
        // stillness ceiling, `noHR=` without a heart rate. `withAccel=`/`withRR=` are per-sample
        // densities, which separate "the samples were sparse" from "the samples carried no motion".
        let shape = "buckets=\(scan.buckets) short=\(scan.shortOfIntervals) "
            + "moved=\(scan.notResting) noHR=\(scan.noHeartRate) "
            + "withAccel=\(scan.samplesWithAcceleration) withRR=\(scan.samplesWithIntervals) "
            + "intervals=\(scan.intervalCount)"
        guard !todayFeatures.isEmpty else {
            CaptureLog.shared.append(
                "STRESS absent day=\(dayStart.ISO8601Format()) reason=windows "
                    + "\(shape) samples=\(samples.count) baselineDays=\(baselinePoints.count) "
                    + "perDay=\(perDay) today=\(today.lowerBound.ISO8601Format())"
                    + "..\(today.upperBound.ISO8601Format())")
            return nil
        }

        // **The personal baseline is preferred, and the recent one is what a fresh install stands
        // on.** The model is defined *relative* to a personal baseline, so when three prior days
        // carry still windows the whole day is scored against that one — the same rule it has always
        // had. Below three days there is no personal baseline to have, and the honest alternatives
        // were "no score" (which reported an absence of *history* as an absence of stress, and left
        // the live monitor dead for its first three days) or a score against a population default
        // (which is a different quantity wearing this one's name). The third option is the day's own
        // preceding hours: each window scored against the windows before it inside
        // `StressMath.recentBaselineSpan`. See `StressWindowEvaluator.recentBaseline`.
        let personal: StressBaseline? = baselinePoints.count >= StressMath.minimumBaselineDays
            ? StressBaseline(
                rmssd: BaselineStatisticsMath.baseline(
                    baselinePoints.map(\.meanRmssdMs), fallbackMean: 0, fallbackStdDev: 0),
                heartRate: BaselineStatisticsMath.baseline(
                    baselinePoints.map(\.meanHeartRate), fallbackMean: 0, fallbackStdDev: 0),
                scope: .personal)
            : nil

        let scored: [StressWindow]
        if let personal {
            scored = todayFeatures.map { window in
                StressWindow(
                    start: window.start,
                    score: StressWindowEvaluator.score(
                        StressWindowFeatures(
                            meanRmssdMs: window.meanRmssdMs,
                            meanHeartRate: window.meanHeartRate),
                        baseline: personal),
                    features: StressWindowFeatures(
                        meanRmssdMs: window.meanRmssdMs,
                        meanHeartRate: window.meanHeartRate))
            }
        } else {
            var priors: [StressWindow] = []
            var relative: [StressWindow] = []
            for window in todayFeatures {
                let features = StressWindowFeatures(
                    meanRmssdMs: window.meanRmssdMs, meanHeartRate: window.meanHeartRate)
                let candidate = StressWindow(start: window.start, score: 0, features: features)
                // The candidate is offered to its own baseline calculation and excluded by
                // `recentBaseline`'s strict `start <` test — passing it keeps that exclusion in the
                // one place that states it, rather than in a second loop here.
                let baseline = StressWindowEvaluator.recentBaseline(
                    before: window.start, windows: priors + [candidate])
                if let baseline {
                    relative.append(
                        StressWindow(
                            start: window.start,
                            score: StressWindowEvaluator.score(features, baseline: baseline),
                            features: features))
                }
                // A window with too few priors behind it is not scored — but its features are real
                // measurements, so it still counts toward the baselines of the windows after it.
                // Its placeholder score is never read: `recentBaseline` reads `start` and `features`.
                priors.append(candidate)
            }
            scored = relative
        }

        guard !scored.isEmpty else {
            CaptureLog.shared.append(
                "STRESS absent day=\(dayStart.ISO8601Format()) reason=baseline "
                    + "\(shape) baselineDays=\(baselinePoints.count) "
                    + "recentNeeds=\(StressMath.minimumRecentWindows) today=\(todayFeatures.count) "
                    + "perDay=\(perDay)")
            return nil
        }

        CaptureLog.shared.append(
            "STRESS day=\(dayStart.ISO8601Format()) windows=\(scored.count) \(shape) "
                + "baseline=\(personal == nil ? "recent" : "personal") "
                + "baselineDays=\(baselinePoints.count) samples=\(samples.count) perDay=\(perDay)")
        return (scored, personal)
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

    /// What one scan found: the windows worth scoring, and **why the others were dropped**.
    ///
    /// The counters exist because a dash on the tile has four causes that look identical on the glass,
    /// and the three gates below reject a window for different reasons. This is read by the capture
    /// line and by nothing else.
    private struct WindowScan {
        var features: [WindowFeatures] = []
        var buckets = 0
        /// Windows dropped for fewer than `minimumRRIntervals` intervals.
        var shortOfIntervals = 0
        /// Windows whose samples carried no accelerometer at all, or whose mean was above the ceiling.
        var notResting = 0
        var noHeartRate = 0
        /// How many samples carried an accelerometer / any R-R interval, and how many intervals the
        /// window held in total — the density figures behind the counters.
        var samplesWithAcceleration = 0
        var samplesWithIntervals = 0
        var intervalCount = 0
    }

    /// Splits samples into consecutive `windowSeconds` buckets and keeps the ones worth scoring.
    ///
    /// A window is kept only when the strap was still **and** it holds enough R-R intervals for an
    /// RMSSD that means something — see `StressMath.minimumRRIntervals` for why the second gate is not
    /// merely tidy.
    private func eligibleWindows(
        in samples: [BiometricSample],
        epochs: [MotionEpoch]
    ) -> WindowScan {
        var scan = WindowScan()
        scan.samplesWithAcceleration = samples.filter { $0.accelerationMagnitude != nil }.count
        scan.samplesWithIntervals = samples.filter { $0.rrIntervalMs != nil }.count

        for bucket in Self.windows(of: samples) {
            scan.buckets += 1
            scan.intervalCount += bucket.samples.compactMap(\.rrIntervalMs).count

            // The fallback's magnitudes: epochs overlapping this bucket. A window whose samples carry
            // no accelerometer is judged still or moving by these instead — the live record has no
            // motion lane, which is why the monitor could never populate while the phone was connected.
            let bucketEnd = bucket.start.addingTimeInterval(StressMath.windowSeconds)
            let magnitudes = epochs
                .filter { $0.start < bucketEnd && $0.end > bucket.start }
                .map(\.meanMagnitudeG)

            // **One gate implementation for the stored day and the live monitor.** The verdict is the
            // evaluator's, and this switch only counts it for the capture.
            switch StressWindowEvaluator.features(
                samples: bucket.samples, motionMagnitudes: magnitudes)
            {
            case let .features(features):
                scan.features.append(
                    WindowFeatures(
                        start: bucket.start,
                        meanRmssdMs: features.meanRmssdMs,
                        meanHeartRate: features.meanHeartRate))
            case .refused(.shortOfIntervals):
                scan.shortOfIntervals += 1
            case .refused(.notResting):
                scan.notResting += 1
            case .refused(.noHeartRate):
                scan.noHeartRate += 1
            }
        }
        return scan
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
