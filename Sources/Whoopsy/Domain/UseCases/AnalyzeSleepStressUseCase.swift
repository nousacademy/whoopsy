import Foundation

/// Scores a night's within-sleep physiological activation — see `StressMath` for the model.
///
/// `AnalyzeStressUseCase`'s counterpart for the window that model throws away. It reuses the same
/// activation, the same bands and the same stillness gate, and differs in exactly three places, each
/// recorded below: the span it scores, the baseline it scores against, and how it gathers R-R
/// intervals.
///
/// Reads `biometric_samples` and writes nothing, so unlike the calculate use cases it cannot damage a
/// stored night. Its only output is the value it returns.
public final class AnalyzeSleepStressUseCase: Sendable {

    /// The longest in-bed span this model will describe, in seconds.
    ///
    /// A guard on **reads**, not a physiological claim. `SleepSession`'s in-bed span is not bounded by
    /// anything: the importer only checks `end > start`, and `docs/ALGORITHMS.md` records that one export
    /// row's `Sleep onset` is literally `00:00:00`, which stretches a night's span by up to six hours
    /// past the sleep it contains. A span that long is an artefact of the source row rather than a
    /// night, and left unchecked it is also the size of the read: at the strap's ~1 Hz this is 57,600
    /// rows, and an unbounded span is however many the artefact says.
    ///
    /// A night past it is **skipped**, not clamped. Clamping would silently describe the first sixteen
    /// hours of something that is not a night and print the result as one; skipping is this app's
    /// ordinary absence. Sixteen rather than twelve because the gate is meant to catch artefacts, not
    /// to have an opinion about long sleepers.
    public static let maximumNightSpanSeconds: TimeInterval = 16 * 60 * 60

    private let biometricRepository: any BiometricRepository
    private let calendar: Calendar

    public init(
        biometricRepository: any BiometricRepository,
        calendar: Calendar = .current
    ) {
        self.biometricRepository = biometricRepository
        self.calendar = calendar
    }

    /// The night's activation — the trace, the aggregate and the band breakdown — or `nil` when it has
    /// none to report.
    ///
    /// ## `nil` is one answer for three situations
    ///
    /// On `AnalyzeStressUseCase`'s reasoning, and deliberately not distinguished: the night has no
    /// samples; its samples contain no still window with enough beats; or there are too few prior
    /// nights to build a personal baseline. Each is *no measurement* rather than a low score, and
    /// `StressScore` has no zero that could be mistaken for one.
    ///
    /// **The third case makes this card unreachable for a new user, and that is the honest state.** A
    /// window's *band* needs a score, a score is a z-score, and a z-score needs the baseline — so
    /// unlike `SleepStageRangeScoring.summary`, which draws shares without bands on a thin window,
    /// there is nothing here to draw below the floor. It takes `StressMath.minimumBaselineNights`
    /// nights of overnight wear before this returns anything at all, and `StressMath.baselineDays` to
    /// fill its window. The floor is forwarded from `StressMath` rather than restated for that reason:
    /// the two models share one judgement about when a personal baseline exists.
    ///
    /// ## The prior nights are handed in, and that is a decision
    ///
    /// `priorNights` is the same array the page's typical-range and consistency cards were built from,
    /// so every figure on this screen describes one set of nights. A use case that fetched its own
    /// history could select a different set and print two "typical" numbers that disagree with nothing
    /// on screen to say so — which is the failure `SleepViewModel.resolveWindow` exists to prevent.
    /// It also keeps the window rule in one place: this type does not re-derive what "before" means.
    ///
    /// - Parameters:
    ///   - session: the night to score.
    ///   - priorNights: the nights to draw the baseline from, in any order. Only the
    ///     `StressMath.baselineDays` most recent are used.
    public func execute(
        for session: SleepSession,
        priorNights: [SleepSession]
    ) async throws -> SleepStressNight? {
        // The night's own windows first, and before any baseline read: a night this model cannot score
        // needs no baseline, and on this machine that is every night — so the early return here is
        // what keeps an unscoreable night from costing fifteen repository reads.
        guard let span = Self.span(of: session) else { return nil }
        let scored = try await windows(in: span)
        guard !scored.isEmpty else { return nil }

        // Newest first, and stopped once the window is full. Ordering is what makes the early exit
        // take the *nearest* nights rather than an arbitrary fourteen, and it bounds the work at
        // `baselineDays` reads in the worst case rather than walking a year of history to fill up.
        var points: [BaselinePoint] = []
        for night in priorNights.sorted(by: { $0.date > $1.date }) {
            guard points.count < StressMath.baselineDays else { break }
            guard let nightSpan = Self.span(of: night) else { continue }

            let features = try await windows(in: nightSpan)
            // A baseline night with no eligible window is skipped rather than counted as a zero. It
            // carries no reading, and a zero would be a real RMSSD of nothing and a heart rate of
            // nothing — both of which would move the mean.
            guard !features.isEmpty else { continue }

            points.append(
                BaselinePoint(
                    meanRmssdMs: BaselineStatisticsMath.mean(features.map(\.meanRmssdMs)),
                    meanHeartRate: BaselineStatisticsMath.mean(features.map(\.meanHeartRate))))
        }

        guard points.count >= StressMath.minimumBaselineDays else { return nil }

        let rmssdBaseline = BaselineStatisticsMath.baseline(
            points.map(\.meanRmssdMs), fallbackMean: 0, fallbackStdDev: 0)
        let heartRateBaseline = BaselineStatisticsMath.baseline(
            points.map(\.meanHeartRate), fallbackMean: 0, fallbackStdDev: 0)

        let windows = scored.map { window in
            StressWindow(
                start: window.start,
                score: StressMath.score(
                    fromActivation: StressMath.activation(
                        rmssdMs: window.meanRmssdMs,
                        meanHeartRate: window.meanHeartRate,
                        rmssdBaseline: rmssdBaseline,
                        heartRateBaseline: heartRateBaseline)))
        }

        return SleepStressNight(
            date: session.date, span: span, windows: windows, baselineNightCount: points.count)
    }

    // MARK: - The span

    /// A night's in-bed span, or `nil` when it is not one this model will describe.
    ///
    /// **Not `StressMath.wakingWindow`.** That returns a range within one calendar day and cannot
    /// express a night at all — a sleep period crosses midnight, so its bounds are the session's and
    /// never a day's. This is the night model's one genuinely new span rule.
    ///
    /// `nil` for a night that ends before it begins, and for one past
    /// `maximumNightSpanSeconds` — see that constant for why the second is a read guard rather than a
    /// view about sleep.
    static func span(of session: SleepSession) -> Range<Date>? {
        let start = session.startTime
        let end = session.endTime
        guard end > start else { return nil }
        guard end.timeIntervalSince(start) <= maximumNightSpanSeconds else { return nil }
        return start..<end
    }

    // MARK: - Windowing

    /// One window's features — the third, motion, has already done its job by qualifying it.
    struct WindowFeatures {
        /// The bucket's anchor, carried through to `StressWindow.start` so the series can be plotted.
        let start: Date
        let meanRmssdMs: Double
        let meanHeartRate: Double
    }

    /// One baseline night, collapsed.
    private struct BaselinePoint {
        let meanRmssdMs: Double
        let meanHeartRate: Double
    }

    /// Reads a span and returns its eligible windows.
    private func windows(in span: Range<Date>) async throws -> [WindowFeatures] {
        let samples = try await biometricRepository.getSamples(
            from: span.lowerBound, to: span.upperBound)
        return Self.eligibleWindows(in: samples, span: span)
    }

    /// Splits a span's samples into whole `windowSeconds` buckets and keeps the ones worth scoring.
    ///
    /// ## Two rules differ from the day model, both deliberately
    ///
    /// **The buckets are anchored on the span's start, not on the first sample.** The day model
    /// anchors on its first in-window sample "so a window is never split because of where the clock
    /// happens to sit", which for a day is right. Here the span is the night's own in-bed bounds, so
    /// anchoring on it is what guarantees every bucket lies inside the night: a bucket cut from a
    /// sample anchor would run past `endTime` and score time the session does not cover.
    ///
    /// **Only whole buckets are scored.** `Int(span / windowSeconds)` truncates, so a trailing stub of
    /// the night is dropped rather than counted as a full five minutes. That is what makes
    /// `windowCount × windowSeconds` a true statement about the night — see
    /// `SleepStressNight.BandSummary.durationSeconds`, which is exactly that product.
    ///
    /// ## Why this is not shared with `AnalyzeStressUseCase`
    ///
    /// The two differ in both halves: the anchor above, and the R-R gathering below, which the day
    /// model does wrongly and this one must not. Extracting a common type that both could call would
    /// mean either teaching the night model the day model's defect or fixing the day model here —
    /// and fixing it here would move the Stress Monitor's existing numbers, which is a change with its
    /// own justification and its own evidence. The shared parts are referenced by name from
    /// `StressMath`, so the constants cannot drift even though the loop is not shared.
    static func eligibleWindows(in samples: [BiometricSample], span: Range<Date>) -> [WindowFeatures] {
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        let bucketCount = Int(length / StressMath.windowSeconds)
        guard bucketCount > 0 else { return [] }

        var buckets = [[BiometricSample]](repeating: [], count: bucketCount)
        for sample in samples {
            let offset = sample.timestamp.timeIntervalSince(span.lowerBound)
            guard offset >= 0, offset < length else { continue }
            buckets[Int(offset / StressMath.windowSeconds)].append(sample)
        }

        return buckets.enumerated().compactMap { index, bucket in
            guard !bucket.isEmpty else { return nil }

            // The beats, as one run per notification and **never concatenated** — see
            // `HeartRateVariabilityMath.calculateRMSSD(fromRuns:)` for why differencing across that
            // seam is the defect this call exists to avoid. The floor counts *intervals*, not
            // samples, because one notification can carry many.
            let runs = bucket.compactMap(\.rrIntervalsMs).filter { !$0.isEmpty }
            guard runs.reduce(0, { $0 + $1.count }) >= StressMath.minimumRRIntervals else {
                return nil
            }

            // Stillness, and never a substituted zero for it — `magnitudes:` refuses a bucket where
            // nothing measured motion, so a night with no accelerometer scores no windows rather
            // than scoring every one of them as resting. See `StressMath.isResting`.
            guard StressMath.isResting(magnitudes: bucket.map(\.accelerationMagnitude)) else {
                return nil
            }

            // A zero heart rate is an absent reading, not a stopped heart: the decoder yields 0 for
            // samples carrying no pulse value, and letting one into the mean would drag it down.
            let rates = bucket.map(\.heartRate).filter { $0 > 0 }
            guard !rates.isEmpty else { return nil }

            let rmssd = HeartRateVariabilityMath.calculateRMSSD(fromRuns: runs)
            // **A second gate, and the day model does not have it.** `calculateRMSSD` returns `0.0`
            // when the cleaning in `filterRRIntervals` leaves fewer than two beats, and the interval
            // count above is taken *before* that cleaning — so a bucket of out-of-range intervals
            // passes the floor and arrives at the scorer as a zero. `StressMath.minimumRRIntervals`
            // documents what a zero RMSSD means here: a perfectly metronomic heart, which this model
            // scores as maximum stress. No living heart produces one, so a zero is insufficient data
            // wearing a reading's name, and it is refused.
            guard rmssd > 0 else { return nil }

            return WindowFeatures(
                start: span.lowerBound.addingTimeInterval(
                    Double(index) * StressMath.windowSeconds),
                meanRmssdMs: rmssd,
                meanHeartRate: BaselineStatisticsMath.mean(rates.map(Double.init)))
        }
    }
}
