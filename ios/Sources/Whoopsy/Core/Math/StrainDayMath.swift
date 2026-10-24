import Foundation

/// One calendar day's Strain, computed from the strap's two records of it: heart rate and motion.
///
/// This is the day computation `CalculateStrainUseCase` performs — extracted so the arithmetic can be
/// asserted without a database, a profile repository or a write, and so the one place the heart-rate
/// and motion terms are combined is a file with no I/O in it.
///
/// ## The combination is a partition, not a sum
///
/// Heart-rate load and motion load both use weighted seconds, and adding them would charge the same
/// minute twice: a run raises the heart rate *and* moves the wrist, so `hr + motion` would score a
/// vigorous hour as though it were two. The model instead takes, over each 30-second window,
///
/// ```
/// dayLoad = Σ over every window:
///             a motion epoch exists ? max(hrLoad[window], motionLoad[window]) : hrLoad[window]
/// ```
///
/// **The maximum rather than the sum, and the window rather than the day.** Taking the day-level
/// maximum would let a hard hour of running cover a whole afternoon of low-HR manual work, because the
/// run's load total exceeds the bench work's — the two are different periods, and the union of what
/// happened is not a single figure. Per-window, an elevated heart rate wins its own window (exercise is
/// measured better by HR) and a still heart rate loses to a moving wrist (manual work is measured only
/// by motion).
///
/// ## The heart-rate guard stays
///
/// A day with **no HR samples** returns `nil` and writes no row, however much motion it holds. Motion
/// modulates a day that has a heart-rate record; it never invents one. A station-only row would have
/// to carry `averageHeartRate: 0`, and `0 bpm` is not an absence — it is a reading no worn strap can
/// produce.
///
/// ## What has no epochs must be what the old code produced
///
/// The no-epoch branch returns `totalAccumulatedLoad` accumulated in sample order, which is bit-for-bit
/// the value `CalculateStrainUseCase` wrote before this file existed. §4's pin asserts it: the refactor
/// that introduced the motion term must not move a single stored score on a day with no motion rows,
/// and a partition sum that re-associates floats is enough to move one. §16 pins the same property
/// through the use case.
public enum StrainDayMath {

    /// The day's resolved figures — everything a `StrainScore` needs except its identity and the
    /// provenance columns.
    public struct Day: Sendable, Equatable {
        /// The 0–21 score on the day curve.
        public let score: Double
        /// The combined weighted-seconds load the score was computed from. HR-only on a day with no
        /// motion epochs, and the partition sum when there were any.
        public let rawAccumulatedLoad: Double
        /// The motion term's own contribution, summed over its windows. Local-only, stored for audit.
        public let motionLoad: Double
        public let averageHeartRate: Int
        public let maxHeartRate: Int
        public let zones: [HeartRateZone]
        /// The newest instant of input this result included. See `RefreshStrainUseCase`.
        public let scoredThrough: Date
    }

    /// The day's result, or `nil` when the strap recorded no heart rate for it.
    ///
    /// - Parameters:
    ///   - samples: the day's heart-rate samples, **ascending by timestamp** — the interval between
    ///     adjacent entries is the time each is credited with, so an unsorted array would credit
    ///     negative or wild spans. Every repository read returns them ascending.
    ///   - epochs: the day's motion windows, in any order. Windows whose `start` is off the 30-second
    ///     grid are bucketed by the grid's floor, which is where the writer puts them too.
    public static func compute(
        samples: [BiometricSample],
        epochs: [MotionEpoch],
        maxHeartRate: Int,
        restingHeartRate: Int
    ) -> Day? {
        guard !samples.isEmpty else { return nil }

        let zones = StrainAccumulatorMath.computeZones(
            maxHR: maxHeartRate, restHR: restingHeartRate)

        var zoneDurations: [HeartRateZoneIndex: TimeInterval] = [
            .zone1: 0, .zone2: 0, .zone3: 0, .zone4: 0, .zone5: 0
        ]
        var totalAccumulatedLoad = 0.0
        var hrLoadByWindow: [Int: Double] = [:]
        var hrSum = 0
        var maxObservedHR = 0
        var scoredThrough = samples[0].timestamp

        for i in 0..<samples.count {
            let sample = samples[i]
            let hr = sample.heartRate
            hrSum += hr
            if hr > maxObservedHR { maxObservedHR = hr }
            if sample.timestamp > scoredThrough { scoredThrough = sample.timestamp }

            // Estimate duration between samples (default 1 second if continuous)
            let duration: TimeInterval = (i > 0)
                ? min(5.0, sample.timestamp.timeIntervalSince(samples[i - 1].timestamp))
                : 1.0

            let (zoneIdx, load) = StrainAccumulatorMath.loadDelta(
                for: hr, zones: zones, restingHeartRate: restingHeartRate, durationSeconds: duration)
            // Load is added even when no zone matched: time above resting but below zone 1's floor is
            // credited at weight 1 by the low-intensity band. Zone *duration* is added only when a zone
            // matched, so the five percentages still sum to at most 100.
            totalAccumulatedLoad += load
            if let zoneIdx = zoneIdx {
                zoneDurations[zoneIdx, default: 0] += duration
            }

            // The interval is credited to the window it elapsed in — the earlier of its two samples.
            // For the first sample the interval is the fixed `1.0` above and there is no earlier
            // sample, so it belongs to its own window. A straddling interval is therefore off by at
            // most its own length and is never counted in two windows.
            let window = MotionEpochGrid.index(for: i > 0 ? samples[i - 1].timestamp : sample.timestamp)
            hrLoadByWindow[window, default: 0] += load
        }

        var motionLoadByWindow: [Int: Double] = [:]
        var motionLoad = 0.0
        for epoch in epochs {
            let covered = MotionLoadMath.coveredSeconds(sampleCount: epoch.sampleCount)
            guard covered > 0 else { continue }

            let load = MotionLoadMath.motionLoad(
                meanMagnitudeG: epoch.meanMagnitudeG, sampleCount: epoch.sampleCount)
            // One stored row per window, so this is a plain assignment in every path a repository can
            // produce. `max` rather than `+=` so a caller holding two rows for one window — a
            // duplicated read, a legacy row written off-grid — cannot credit the window twice.
            let window = MotionEpochGrid.index(for: epoch.start)
            motionLoadByWindow[window] = max(motionLoadByWindow[window] ?? 0, load)
            motionLoad += load

            // The window's **measured** edge, not its nominal end: a window that has only received a
            // second of batches covers one second, and saying it covered 30 would tell the refresh
            // watermark there is nothing left to recompute when the rest of the window arrives.
            let edge = epoch.start.addingTimeInterval(covered)
            if edge > scoredThrough { scoredThrough = edge }
        }

        // Bit-identical to the pre-motion algorithm when there is nothing to combine, including the
        // order the floats are summed in.
        let dayLoad: Double
        if motionLoadByWindow.isEmpty {
            dayLoad = totalAccumulatedLoad
        } else {
            var buckets = Set(hrLoadByWindow.keys)
            buckets.formUnion(motionLoadByWindow.keys)
            var combined = 0.0
            for window in buckets.sorted() {
                let hr = hrLoadByWindow[window] ?? 0
                if let motion = motionLoadByWindow[window] {
                    combined += max(hr, motion)
                } else {
                    combined += hr
                }
            }
            dayLoad = combined
        }

        let updatedZones = zones.map { zone in
            HeartRateZone(
                index: zone.index,
                lowerBpm: zone.lowerBpm,
                upperBpm: zone.upperBpm,
                durationSeconds: zoneDurations[zone.index] ?? 0
            )
        }

        return Day(
            score: StrainAccumulatorMath.calculateStrainScore(from: dayLoad),
            rawAccumulatedLoad: dayLoad,
            motionLoad: motionLoad,
            averageHeartRate: hrSum / samples.count,
            maxHeartRate: maxObservedHR,
            zones: updatedZones,
            scoredThrough: scoredThrough
        )
    }
}
