import Foundation

/// The formula that produced a stored Strain row.
///
/// **A metric row without its algorithm is a number nobody can re-derive.** `strains` holds a score
/// with no record of how it was computed, so a row written before the motion term existed and one
/// written after are indistinguishable — and if the model is tuned again, a reader cannot tell which
/// figures would move and which are measurements from another source. This type is the name that goes
/// on the row, `strainAlgorithms` is the table that documents each name, and `docs/ALGORITHMS.md` §2 is
/// the prose copy.
///
/// **A parameter change is a new case.** The zone weights, the low-intensity band's weight, the day
/// curve's `k`, the five-second gap clamp and the motion weight table are all part of what a version
/// string names. Editing any of them without adding a case leaves old and new rows saying the same
/// thing, which is the one failure this type exists to prevent. The rule is stated in three places —
/// here, the seed rows in migration `v35`, and the docs — and a suite assertion pins the current
/// constant against the newest catalogue row so they cannot drift.
public enum StrainAlgorithm: String, CaseIterable, Sendable, Codable {

    /// Everything this app computed before the motion term: the five HR-reserve zones, the
    /// weight-1 low-intensity band, `k_day = 1.085e-5` and the five-second gap clamp.
    case hrZoneV1 = "hr-zone-v1"

    /// The current model: the v1 heart-rate integral combined per 30-second window with the wrist's
    /// motion load, `max(hrLoad, motionLoad)`, summed over the day.
    case hrMotionV2 = "hr-motion-v2"

    /// WHOOP's own `Day Strain`, read from the bundled export and stored verbatim.
    ///
    /// **Not this app's computation and never to be recomputed.** The export carries no R-R series, so
    /// feeding it to this app's integrator would produce a different quantity wearing the same name.
    case whoopExport = "whoop-export"

    /// The version every writer of a computed row uses.
    public static let current: StrainAlgorithm = .hrMotionV2

    /// Whether this app computed the row, as opposed to reading it from another source.
    public var isAppComputed: Bool { self != .whoopExport }
}
