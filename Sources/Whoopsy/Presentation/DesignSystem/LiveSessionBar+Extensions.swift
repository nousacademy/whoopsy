import SwiftUI

/// The clock-dependent half of the recording bar: which zone a fast is in, and the two colours that
/// follow from it.
///
/// Split out of `LiveSessionBar` for a reason that is about the drawing rather than about tidiness.
/// `LiveSessionBar.subject(...)` is read in Home's `body` and must stay there, because that read is
/// what registers the `@Observable` dependency on the use case — while everything below needs `now`,
/// which only exists inside a `TimelineView`. One file for the rule and one for the colour is what
/// keeps those two evaluations apart.
///
/// It follows the four existing value-into-colour files (`RecoveryState+Extensions`,
/// `SleepStageType+Extensions`, `ActivityGlyph`, `FastingZone+Extensions`) and **picks no colour of its
/// own**: the five fills and the two inks are `FastingZone`'s, and the activity's red is
/// `Theme.recoveryRed`, which is the colour the bar has always been.
extension LiveSessionBar.Subject {

    /// The fasting zone this session has reached, or `nil` for an activity.
    ///
    /// **`nil` for an activity is the honest answer and not a missing one.** An activity is not in a
    /// fasting zone; there is no duration at which a run becomes `ketosis`. The bar draws its red and
    /// asks nothing further, which is why the colour methods below branch on this and not on the case.
    ///
    /// **The zone is read over the whole fast, and that is deliberately not the reading Home's
    /// `ACTIVITIES` row draws.** `ActivityFigure.fastingZone(for:on:)` is day-clamped, because a stored
    /// row is *about* a day and an 86-hour fast walks down the week one zone at a time. The bar is
    /// about the fast itself — it is the live indicator, and it exists on every day alike — so it
    /// counts from `startedAt` with nothing clamped. The two answer different questions and **must not
    /// be reconciled**: making the bar day-scoped would freeze it at `anabolic` on the day a fast
    /// began, and making the row whole-span would draw `deep ketosis` on day 1 above `ketosis` on
    /// day 2, a zone moving backwards down the week.
    ///
    /// `now` is a parameter rather than a `Date()` read inside, for `DayBarRules`' reason: an assertion
    /// about a zone must not say something different tomorrow.
    public func zone(at now: Date) -> FastingZone? {
        guard case .fast = self else { return nil }
        return Self.zone(since: anchor, at: now)
    }

    /// The same reading for a fast that is already known to be one, so the two colours below can take
    /// it without inventing a fallback zone for the `nil` that only an activity can produce.
    private static func zone(since startedAt: Date, at now: Date) -> FastingZone {
        FastingZone.zone(forDurationSeconds: max(0, now.timeIntervalSince(startedAt)))
    }

    /// The bar's fill.
    ///
    /// The activity's red is unchanged from before a fast could be recorded — the user's *"a regular
    /// activity will have that red timer on home page"* — and a fast takes the fill of the zone it is
    /// in, which is the whole of the request this file exists to serve.
    ///
    /// **The colour is up to a minute late at each boundary** (4 h / 16 h / 24 h / 72 h), because the
    /// caller is a `TimelineView(.everyMinute)`. A per-second timer for a colour that changes four
    /// times in three days would re-render the bar sixty times as often to be wrong ninety-nine
    /// percent of the time; the clock beside it is the system's and ticks on its own regardless.
    ///
    /// **`catabolic`'s fill is orange, which this repo's own theme doc records as knowingly below AA
    /// contrast, and the bar promotes it to a full-width band.** Stated rather than hidden: the zone's
    /// fill is the user's choice and the bar is the one place it is drawn at that size.
    public func fill(at now: Date) -> Color {
        switch self {
        case .activity: return Theme.recoveryRed
        case .fast: return Self.zone(since: anchor, at: now).color
        }
    }

    /// The colour of the clock on that fill.
    ///
    /// **A second answer rather than `.white` throughout, and the fast is the reason.** White is
    /// invisible on the `ketosis` fill — measured at 1.0:1 — and only 1.5:1 on `fatBurning`'s, so two
    /// of the five zones would draw a clock the reader cannot see. `FastingZone.inkDepth` is the one
    /// statement of which fills are pale, and this forwards to it rather than restating the split.
    ///
    /// An activity's red takes white, which is what the bar has always drawn and what the red's own
    /// contrast was chosen for.
    public func ink(at now: Date) -> Color {
        switch self {
        case .activity: return .white
        case .fast: return Self.zone(since: anchor, at: now).inkColor
        }
    }
}
