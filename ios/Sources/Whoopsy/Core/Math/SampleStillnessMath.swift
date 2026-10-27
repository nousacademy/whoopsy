import Foundation

/// 30-second **stillness** windows derived from the samples a drain already delivers.
///
/// ## Why this exists
///
/// The sleep classifier's independent signal is the accelerometer being *quiet*, not the wearer
/// moving: a motionless wrist still reads ≈1 g, because gravity is inside the magnitude, and an epoch
/// whose magnitude stays near 1 g is what "asleep" rests on. That signal has always been expected from
/// `R21` motion records — and the strap does **not** bank those in flash. Measured 2026-10-26, on a
/// phone-away night: every drained burst carried layouts 18 and 26, never 21, so the night had 54,869
/// heart-rate samples and no epoch at all.
///
/// **`R18` carries the accelerometer anyway.** Body 24 is three `f32` in g — mean acceleration X/Y/Z
/// for that second — and `HeartRatePayloadDecoder` now reads it into `BiometricSample`. This type
/// folds those per-second means into the same 30-second grid the motion recorder uses, so a drained
/// night becomes classifiable without a second record type existing.
///
/// ## The statistic, and why it is on the motion scale
///
/// The per-second signal used is the **change** between consecutive samples, `|Δa|`: zero when still,
/// rising when the wrist turns. Each window reports `1 + mean |Δa|`, which is the same shape as
/// `MotionBatch.meanMagnitudeG` — ≈1.0 at rest — so `AnalyzeSleepUseCase.motionQuietCeiling` (1.05)
/// and `StressMath.motionCeiling` (1.25) apply unchanged rather than being duplicated at a second
/// scale. `quietDeltaG` is therefore the mapping, not a second threshold.
///
/// A window with fewer than `minimumDeltasPerWindow` deltas is **absent rather than zero**: a gap in
/// the drain is missing evidence, and a zero here would read as perfect stillness.
public enum SampleStillnessMath {

    /// One 30-second window, in the shape the classifier consumes.
    public struct Epoch: Sendable, Equatable {
        public let start: Date
        public let end: Date
        /// `1 + mean |Δa|`, on the motion recorder's scale (≈1.0 G at rest).
        public let meanMagnitudeG: Double

        public init(start: Date, end: Date, meanMagnitudeG: Double) {
            self.start = start
            self.end = end
            self.meanMagnitudeG = meanMagnitudeG
        }
    }

    public static let windowSeconds: TimeInterval = 30

    /// How many second-to-second deltas a window needs before it is allowed to mean anything.
    public static let minimumDeltasPerWindow = 10

    /// The `mean |Δa|` that corresponds to `AnalyzeSleepUseCase.motionQuietCeiling`'s 1.05.
    ///
    /// **App-calibrated, and deliberately one number in one place**: it is the mapping from this
    /// statistic onto the motion magnitudes the classifier was written against. A re-calibration is
    /// this constant, and nothing else.
    public static let quietDeltaG = 0.05

    /// The stillness windows covering `samples`, newest-last and on an absolute 30-second grid.
    ///
    /// Samples without acceleration are skipped, and the previous *accelerometer* sample is what a
    /// delta is taken against — so a heart-rate-only gap neither invents a delta nor resets the
    /// window. Empty for a stream with no acceleration at all.
    public static func epochs(from samples: [BiometricSample]) -> [Epoch] {
        var sums: [Int: (total: Double, count: Int)] = [:]
        var previous: (time: Date, x: Double, y: Double, z: Double)?

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let x = sample.accelerometerX,
                  let y = sample.accelerometerY,
                  let z = sample.accelerometerZ
            else { continue }

            if let last = previous {
                let dx = x - last.x
                let dy = y - last.y
                let dz = z - last.z
                let delta = (dx * dx + dy * dy + dz * dz).squareRoot()
                if delta.isFinite {
                    let key = windowKey(for: sample.timestamp)
                    var bucket = sums[key] ?? (0, 0)
                    bucket.total += delta
                    bucket.count += 1
                    sums[key] = bucket
                }
            }
            previous = (sample.timestamp, x, y, z)
        }

        return sums.keys.sorted().compactMap { key in
            guard let bucket = sums[key], bucket.count >= minimumDeltasPerWindow else { return nil }
            let start = MotionEpochGrid.date(forIndex: key)
            return Epoch(
                start: start,
                end: start.addingTimeInterval(windowSeconds),
                meanMagnitudeG: 1 + bucket.total / Double(bucket.count))
        }
    }

    /// The absolute window index for an instant.
    ///
    /// **`MotionEpochGrid`'s index, not a second floor.** The two grids agree arithmetically — the
    /// reference date is itself a multiple of 30 seconds — but they agreed only by coincidence of
    /// origin, and the caller merges these windows with the recorder's by index. One definition is
    /// what makes the merge a lookup rather than a tolerance.
    static func windowKey(for date: Date) -> Int {
        MotionEpochGrid.index(for: date)
    }
}
