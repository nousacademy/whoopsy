import Foundation

/// One day's heart-rate zone time, summed over that day's workouts — the quantity the strain page's
/// two `HEART RATE ZONES` rows are read against.
///
/// ## Where the numbers come from, and what that makes them
///
/// **On an imported day these are WHOOP's own measurements, not this app's.** They are recovered from
/// the `HR Zone n %` columns of `workouts.csv` and scaled by the workout's own span, which is the only
/// producer of zone time this app has: the export carries no heart-rate series for
/// `StrainAccumulatorMath` to integrate, `biometric_samples` holds no rows on any database here, and
/// the drain's type-24 heart-rate record has no reader. So nothing on this screen is a zone this app
/// computed from a heart rate it measured — see `ALGORITHMS.md` §2, and do not describe it as such.
///
/// ## Why this is two fields and not five
///
/// The card draws two rows, zones 1–3 and 4–5, so that is what is carried. The five percentages
/// themselves stay on `WorkoutSession.hrZonePercents`, where the file's own resolution lives; this
/// type is the *day's* aggregate of them, in seconds.
///
/// ## Why they do not sum to the day
///
/// The five percentages sum to at most 100 and often well below it — the remainder is time below zone
/// 1, which WHOOP publishes no column for. So `zone1to3Seconds + zone4to5Seconds` is deliberately
/// **not** the day's workout time, and anything printing a total must take it from the sessions rather
/// than from these two.
public struct WorkoutZoneTime: Equatable, Sendable {
    /// The day, snapped to `startOfDay`.
    public let date: Date

    public let zone1to3Seconds: Double
    public let zone4to5Seconds: Double

    public init(date: Date, zone1to3Seconds: Double, zone4to5Seconds: Double) {
        self.date = date
        self.zone1to3Seconds = zone1to3Seconds
        self.zone4to5Seconds = zone4to5Seconds
    }

    /// The day's workouts summed into one aggregate, or `nil` when none of them carries a zone block.
    ///
    /// **`nil` is the answer for a day with no zone data, and it is not the same as a zero.** A day
    /// whose workouts all carry a block that reads `0%` in every band is a measured day with a real
    /// `0:00`; a day whose workouts have no block at all is unmeasured and must draw a dash. Summing
    /// over an empty set would produce the first where the second is true — the fabricated zero every
    /// absence rule in this app exists to prevent.
    ///
    /// Sessions this app recorded itself carry no zone block, so a day can hold workouts and still
    /// produce `nil`. That is the intended reading of the user's rule: fill a row from a CSV where the
    /// field exists, draw a dash where it does not.
    public static func aggregate(_ workouts: [WorkoutSession]) -> WorkoutZoneTime? {
        guard let date = workouts.first?.startedAt.startOfDay else { return nil }
        let zoned = workouts.filter { $0.hrZonePercents != nil }
        guard !zoned.isEmpty else { return nil }

        return WorkoutZoneTime(
            date: date,
            zone1to3Seconds: zoned.reduce(0) { $0 + ($1.zone1to3Seconds ?? 0) },
            zone4to5Seconds: zoned.reduce(0) { $0 + ($1.zone4to5Seconds ?? 0) })
    }
}
