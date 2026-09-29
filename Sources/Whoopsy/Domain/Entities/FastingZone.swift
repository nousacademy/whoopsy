import Foundation

/// Which of the Zero fasting app's five metabolic zones a fast of a given length reached.
///
/// A fast is the one session in this app whose interesting property is not a measurement but a
/// *duration already in hand* — a `WorkoutSession` always has a span, and for an imported Zero fast
/// nothing else was ever recorded. So the zone is **derived on read from the stored span** and never
/// persisted: nothing here needs a column, a migration, or a backfill, and editing a fast's start or
/// end time moves its zone with it.
///
/// ## Why the boundaries are written down rather than derived
///
/// Zero publishes its zones as ranges — `0–4`, `4–16`, `16–24`, `24–72`, `72+` — and **the published
/// ranges overlap on their upper edge**: 4 h ends the first range and begins the second. That makes
/// `<` versus `<=` a real decision rather than an implementation detail, and it is load-bearing on
/// exactly one row of the bundled file, where a fast sits at precisely 16 h. The convention taken
/// here is: **the upper edge of a range belongs to the next zone.** Exactly 4 h is `catabolic`,
/// exactly 16 h is `fatBurning`, exactly 24 h is `ketosis`, exactly 72 h is `deepKetosis`.
///
/// This is a choice and not a derivation, so it is pinned by assertions at every edge in both
/// directions (§20) rather than left to whichever comparison operator was typed.
///
/// ## Why this is not in `Presentation`
///
/// It holds no `Color` and imports only `Foundation`, so it is a Domain value like `SleepStageType`
/// — a category with a published definition. Its colour mapping is a separate extension under
/// `Presentation/DesignSystem/`, which is where that layer's only `Color` vocabulary lives. Putting
/// this type in Presentation would make `ActivityFigure`'s gate reach across for it and leave the
/// zone's own definition stranded in the drawing layer.
public enum FastingZone: String, CaseIterable, Sendable {

    /// Roughly 0–4 h. The fed state: the body is still running on the meal it just absorbed.
    case anabolic

    /// Roughly 4–16 h. Glycogen is being drawn down; insulin has fallen.
    case catabolic

    /// Roughly 16–24 h. The zone most of the bundled fasts land in.
    case fatBurning

    /// Roughly 24–72 h. Ketone production is established.
    case ketosis

    /// 72 h and beyond.
    case deepKetosis

    /// The zone a fast of this length reached.
    ///
    /// **Non-optional, because every `WorkoutSession` has a span** — a duration always maps
    /// somewhere, and there is no such thing as a fast with no zone. The clamp at zero is for a
    /// negative or zero span, which no producer writes but which is the honest answer rather than a
    /// crash: a session of no length has not left the fed state, so it is `anabolic`.
    ///
    /// See the type comment for the edge convention — **each `upperBound` here is exclusive**, which
    /// is what puts a fast of exactly 4 h in `catabolic` and one of exactly 16 h in `fatBurning`.
    public static func zone(forDurationSeconds seconds: TimeInterval) -> FastingZone {
        let elapsed = max(0, seconds)
        if elapsed < 4 * 3600 { return .anabolic }
        if elapsed < 16 * 3600 { return .catabolic }
        if elapsed < 24 * 3600 { return .fatBurning }
        if elapsed < 72 * 3600 { return .ketosis }
        return .deepKetosis
    }

    /// What the pill draws.
    ///
    /// Uppercase literals rather than the raw value uppercased, because `fatBurning` → `FAT BURNING`
    /// is a *stated* string and not a camel-case transformation: a transformation would silently
    /// follow a future case rename onto the screen, where a literal fails to compile instead.
    public var label: String {
        switch self {
        case .anabolic: return "ANABOLIC"
        case .catabolic: return "CATABOLIC"
        case .fatBurning: return "FAT BURNING"
        case .ketosis: return "KETOSIS"
        case .deepKetosis: return "DEEP KETOSIS"
        }
    }

    /// The published range this zone covers, as Zero states it.
    ///
    /// Not drawn today — the pill carries the name alone — but it is the zone's definition and the
    /// half of it a name cannot state, so it lives beside the label rather than nowhere. The `+` on
    /// the last one is deliberate: 72 h is a floor and not an interval.
    public var hoursRange: String {
        switch self {
        case .anabolic: return "0-4H"
        case .catabolic: return "4-16H"
        case .fatBurning: return "16-24H"
        case .ketosis: return "24-72H"
        case .deepKetosis: return "72H+"
        }
    }
}
