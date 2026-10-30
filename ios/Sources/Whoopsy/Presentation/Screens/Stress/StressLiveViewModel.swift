import Foundation
import SwiftUI

/// The Stress Monitor page's live half: it extends the day's already-scored windows as new
/// five-minute buckets complete, without ever re-reading the fourteen-day baseline.
///
/// ## Why it polls rather than consumes the live streams
///
/// The live heart-rate record carries R-R intervals and a heart rate but **no accelerometer**, while
/// the stillness gate needs motion — from the samples when they measured it, or from the
/// `motionEpochs` the recorder writes from R1 otherwise. Polling the **unscored tail** of both tables
/// is the shape that works for either source: a drain writes samples the live stream never saw, a
/// connected strap writes epochs the drained samples do not carry, and a minute's tail is a handful
/// of rows rather than the 1.2 M a full evaluation reads.
///
/// ## What a tick may and may not do
///
/// It scores only buckets that are **complete** — a five-minute span whose end has passed — and only
/// those after the last stored window. The anchor is the day's first stored window's start, which is
/// the same anchor `AnalyzeStressUseCase` used, so a live window lands on the grid the stored ones
/// are on. It never rescales or replaces a stored window, and a refused bucket is skipped rather than
/// invented: a gap in the line is a window the model could not read.
///
/// ## Which baseline a live window is scored against
///
/// The day's carried baseline when there is one — the personal, fortnight reference, which also
/// stops a tick re-reading days of samples. When the day has none (fewer than three prior days with
/// stillness), the day was scored **relative to its own preceding hours**, so each live window gets
/// the same treatment: `StressWindowEvaluator.recentBaseline(before:windows:)` over the windows the
/// page already holds, whose features it carries. That is why a new window is appended with its
/// features — they are the next window's priors.
@MainActor @Observable public final class StressLiveViewModel {

    /// The day's windows as the page draws them: the stored ones, then any completed live ones.
    public private(set) var windows: [StressWindow] = []

    /// The most recent scored window, or `nil` on a day with none — the gauge's figure and time.
    public private(set) var latest: StressWindow?

    /// Whether the day's baseline is available, which is what live scoring stands on.
    public private(set) var canScoreLive = false

    /// What the windows on screen are scored against, so the page can name it.
    ///
    /// `.personal` on a day with three prior days of stillness; `.recent(span:)` otherwise, and the
    /// page says "your last 6 hours" rather than "your fortnight" because those are two different
    /// claims. `nil` before the first window is scored.
    public private(set) var baselineScope: StressBaselineScope?

    public private(set) var isTicking = false

    /// The day being shown, for the header and the chart's calendar bounds.
    public private(set) var date: Date = Date()

    private let biometricRepository: any BiometricRepository
    private let motionRepository: (any MotionEpochRepository)?
    private let calendar: Calendar
    private let tickInterval: Duration

    private var baseline: StressBaseline?
    private var anchor: Date?

    /// Every window the gates let through, scored or not — the priors a recent baseline is built
    /// from.
    ///
    /// **Not the same array as `windows`**, and the difference is the point: a window with too few
    /// priors is not scored, so it is not drawn, but its features are real measurements and behind
    /// them sits another window. The analyzer keeps the same distinction (its `priors` grows by one
    /// per gate-passing bucket), which is what makes the live extension agree with a later full
    /// evaluation of the same day. The placeholders' scores are never read — `recentBaseline` reads
    /// `start` and `features`.
    private var priors: [StressWindow] = []

    public init(
        biometricRepository: any BiometricRepository,
        motionEpochRepository: (any MotionEpochRepository)? = nil,
        calendar: Calendar = .current,
        tickInterval: Duration = .seconds(60)
    ) {
        self.biometricRepository = biometricRepository
        self.motionRepository = motionEpochRepository
        self.calendar = calendar
        self.tickInterval = tickInterval
    }

    /// Seeds the page from Home's already-computed day and, for today, ticks until cancelled.
    ///
    /// The loop is the `.task` the page attaches, so leaving the screen cancels it — there is no
    /// detached timer to stop.
    public func run(day: StressDay?, date: Date) async {
        self.date = date
        windows = day?.windows ?? []
        latest = windows.last
        priors = windows
        baseline = day?.baseline
        // A day exists and carries no baseline exactly when it was scored relative to its own
        // preceding hours — `StressDay`'s own rule — so the page can name that reference even though
        // there are four numbers nowhere to read it from.
        baselineScope = day.map { $0.baseline?.scope ?? .recent(span: StressMath.recentBaselineSpan) }
        anchor = windows.first?.start
        // A carried baseline makes a tick possible on its own; without one the day is
        // recent-relative and the windows' own features are the reference, so the anchor is what
        // matters. Either way the page has to know where the grid starts.
        canScoreLive = anchor != nil

        guard canScoreLive, calendar.isDateInToday(date) else { return }

        isTicking = true
        defer { isTicking = false }
        while !Task.isCancelled {
            await scoreNewWindows()
            do {
                try await Task.sleep(for: tickInterval)
            } catch {
                return
            }
        }
    }

    /// Scores every bucket that has completed since the last stored window.
    private func scoreNewWindows() async {
        guard let anchor else { return }
        // **The live half scores only the hours the model scores.** The analyzer filters to
        // `StressMath.wakingWindow` before it buckets anything, so a tick that ran past the window's
        // end would add a window the stored day could never hold — and the day average would drift
        // downwards through the evening for a reason nothing on screen would explain.
        guard let waking = StressMath.wakingWindow(on: date.startOfDay, calendar: calendar)
        else { return }
        let now = Date()
        let windowSeconds = StressMath.windowSeconds

        // The next bucket index the line does not hold. `windows.count` is not it: the analyzer omits
        // buckets its gates refused, so a day with one scored window can be three buckets in.
        let lastStart = windows.last?.start
        let nextIndex: Int
        if let lastStart {
            nextIndex = Int(((lastStart.timeIntervalSince(anchor)) / windowSeconds).rounded()) + 1
        } else {
            nextIndex = 0
        }

        let start = anchor.addingTimeInterval(Double(nextIndex) * windowSeconds)
        guard start.addingTimeInterval(windowSeconds) <= now, waking.contains(start) else { return }

        let samples = (try? await biometricRepository.getSamples(from: start, to: now)) ?? []
        let epochs = (try? await motionRepository?.getMotionEpochs(from: start, to: now)) ?? []
        guard !samples.isEmpty else { return }

        var index = nextIndex
        var bucketStart = start
        while bucketStart.addingTimeInterval(windowSeconds) <= now, waking.contains(bucketStart) {
            let bucketEnd = bucketStart.addingTimeInterval(windowSeconds)
            let bucketSamples = samples.filter { $0.timestamp >= bucketStart && $0.timestamp < bucketEnd }
            let magnitudes = epochs
                .filter { $0.start < bucketEnd && $0.end > bucketStart }
                .map(\.meanMagnitudeG)

            // The gate first, because the window's features are needed for the **next** window's
            // recent baseline whether or not this one scores.
            guard case let .features(features) = StressWindowEvaluator.features(
                samples: bucketSamples, motionMagnitudes: magnitudes)
            else {
                index += 1
                bucketStart = anchor.addingTimeInterval(Double(index) * windowSeconds)
                continue
            }

            // `baseline` is the personal one the day carried. Without it this day is
            // recent-relative, and the reference is the windows already seen — the same rule
            // `AnalyzeStressUseCase` applied to the stored ones. The candidate is offered to its own
            // baseline calculation and excluded by `recentBaseline`'s strict `start <` test.
            let candidate = StressWindow(start: bucketStart, score: 0, features: features)
            let reference = baseline ?? StressWindowEvaluator.recentBaseline(
                before: bucketStart, windows: priors + [candidate])
            priors.append(candidate)
            if let reference {
                let score = StressWindowEvaluator.score(features, baseline: reference)
                let window = StressWindow(start: bucketStart, score: score, features: features)
                windows.append(window)
                latest = window
                baselineScope = reference.scope
                CaptureLog.shared.append(
                    "STRESS live day=\(date.startOfDay.ISO8601Format()) "
                        + "start=\(bucketStart.ISO8601Format()) score="
                        + String(format: "%.1f", score)
                        + " baseline=\(reference.scope == .personal ? "personal" : "recent")")
            }
            index += 1
            bucketStart = anchor.addingTimeInterval(Double(index) * windowSeconds)
        }
    }
}
