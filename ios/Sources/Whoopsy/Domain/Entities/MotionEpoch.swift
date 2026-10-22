import Foundation

/// One 30-second window of the strap's motion, reduced to the numbers an onset detector needs.
///
/// **This exists so sleep onset can be decided by movement rather than by the heart-rate stager.**
/// A heart rate alone cannot separate "asleep" from "lying still awake", and the stager's own
/// documentation says so: a still, wakeful person classifies as asleep, so a night that never
/// happened would still produce a session. Motion is the independent signal — a night with no
/// sustained quiet run is reported as no night, however low the heart rate sat.
///
/// The magnitude is `|a|` in Gs, so gravity is inside it: a motionless strap reads ≈1.0, not 0.
/// `meanMagnitudeG` is what the onset detector thresholds, and `maxMagnitudeG` is what distinguishes
/// a still epoch from one that merely averaged still.
public struct MotionEpoch: Identifiable, Equatable, Sendable {
    public let id: UUID

    /// The day key, snapped to `startOfDay(start)` — the same rule every other day-keyed table holds.
    public let date: Date
    public let start: Date
    public let end: Date
    public let meanMagnitudeG: Double
    public let maxMagnitudeG: Double
    public let sampleCount: Int

    public init(
        id: UUID = UUID(),
        start: Date,
        end: Date,
        meanMagnitudeG: Double,
        maxMagnitudeG: Double,
        sampleCount: Int
    ) {
        self.id = id
        self.date = start.startOfDay
        self.start = start
        self.end = end
        self.meanMagnitudeG = meanMagnitudeG
        self.maxMagnitudeG = maxMagnitudeG
        self.sampleCount = sampleCount
    }
}
