import Foundation

/// How much time this app spends in each zone on a *typical* session of one activity — the grey mark
/// the activity detail page draws on each zone row.
///
/// **It is built from measured samples and from nothing else.** A prior session's WHOOP
/// `hrZonePercents` block is a different producer of the same quantity, and averaging a
/// percentage-derived time with a sample-derived one would be the two-producer mean this repo treats
/// as a defect — the same reason `SleepSession` refuses to mix a computed need with an imported one.
/// The type therefore accepts only `ZoneTimeMath.Totals`, which can only come from samples; a prior
/// with a block and no samples simply contributes nothing.
///
/// **Who it is taken over is `ActivityBaseline`'s answer, not this type's.** `ActivityBaseline.window`
/// is the one definition of "the prior sessions of this activity" — the last ten, strictly before the
/// session being described — and the caller is expected to have taken it. This type only turns the
/// totals behind that window into a mean.
///
/// The floor is `RecoveryScoring.minimumBaselineDays` (3) measured priors, forwarded rather than
/// restated, so the activity page and the Recovery screen cannot come to disagree about how much
/// history a baseline needs.
public struct ActivityZoneBaseline: Equatable, Sendable {

    /// Mean seconds in each band, five entries in `HeartRateZoneIndex` order.
    public let averageSeconds: [Double]

    /// How many measured prior sessions the mean was taken over. Always at least the floor.
    public let sessionCount: Int

    public init(averageSeconds: [Double], sessionCount: Int) {
        self.averageSeconds = averageSeconds
        self.sessionCount = sessionCount
    }

    /// The baseline for a set of prior sessions' folds, or `nil` below the floor.
    ///
    /// `nil` also for a fold whose five bands are not all present, because a mean over a partial
    /// table would print a band this app never measured. `totals` already guarantees five entries,
    /// so that guard is a statement about the input rather than a case that occurs.
    public static func make(priorTotals: [ZoneTimeMath.Totals]) -> ActivityZoneBaseline? {
        guard priorTotals.count >= RecoveryScoring.minimumBaselineDays else { return nil }
        guard priorTotals.allSatisfy({
            $0.zoneSeconds.count == HeartRateZoneIndex.allCases.count
        }) else { return nil }

        let averages = HeartRateZoneIndex.allCases.map { zone in
            BaselineStatisticsMath.mean(priorTotals.map { $0.seconds(in: zone) })
        }
        return ActivityZoneBaseline(averageSeconds: averages, sessionCount: priorTotals.count)
    }

    /// Mean seconds in one band, by index rather than by array position.
    public func seconds(in zone: HeartRateZoneIndex) -> Double {
        let index = zone.rawValue - 1
        guard averageSeconds.indices.contains(index) else { return 0 }
        return averageSeconds[index]
    }
}
