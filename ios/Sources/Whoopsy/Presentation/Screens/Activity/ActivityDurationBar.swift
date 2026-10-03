import SwiftUI

/// Where everything on a duration bar is drawn, as fractions of the track's width.
///
/// **It exists for `TypicalRangeBarLayout`'s reason**, which is worth restating because it is the reason
/// this file is not a few lines inside a `View`: the runner that tests this app has no renderer, so a
/// rule written into a `body` — a clamp inside a `GeometryReader` — is a rule nothing can assert.
/// Resolving the fractions here means the arithmetic the bar's picture is made of, including the case a
/// session runs past the scale it is drawn on, is assertable as a value.
///
/// Fractions rather than points, on the same argument: the bar's width belongs to whatever proposes it,
/// and the one thing this type promises is where along it a mark lands.
public struct ActivityDurationBarLayout: Equatable, Sendable {

    /// This session's length as a fraction of the scale. Always `0...1`.
    public let filledFraction: Double

    /// The lower edge of what is typical for this activity, as a fraction of the scale.
    public let lowFraction: Double

    /// The upper edge of what is typical, as a fraction of the scale. Never less than `lowFraction`.
    public let highFraction: Double

    /// The share of the track that is *not* this session, which is the region the hatch fills.
    public var unfilledFraction: Double { 1 - filledFraction }

    /// The session's length, and the band it is read against.
    ///
    /// ## The scale is the band's own upper edge, and that is the one decision here
    ///
    /// The sleep bar next door is drawn on a scale that is fixed for every night — 0–100% of the period
    /// — because a stage's share of a night is a percentage by construction and needs no anchor. **A
    /// duration is not**, and has to be given one: a track that ran 0 to the session's own length would
    /// draw every session as a full bar, saying nothing. So the anchor is the band's own `high`, which
    /// makes the question the bar answers *"how does this session sit against what is typical for this
    /// activity"* — the session's share lands inside the band when its duration is typical, short of it
    /// when the session was brief, and past the scale's right edge when it was long.
    ///
    /// **A session longer than the band's top widens the scale rather than being clamped.** Clamping
    /// would draw a session an hour past typical exactly level with one that just reached it, which is
    /// the fabrication `HoursOfSleepChartAxis`'s widening and `TypicalRangeBarLayout.fraction`'s clamp
    /// both exist to refuse — a mark in the wrong place reads as a different scale rather than as a
    /// wrong reading. The widen-and-recompute runs before the fractions are resolved, so every fraction
    /// below is still inside `0...1` by construction and the clamps are a guard rather than a rule.
    ///
    /// - Parameters:
    ///   - durationSeconds: this session's own length.
    ///   - typical: the activity's duration band, or `nil` when the window was too thin to produce one.
    ///     **`nil` produces no layout at all** — see `make` — because the band *is* the scale.
    public init(durationSeconds: Double, low: Double, high: Double) {
        let bandHigh = max(high, 1)
        // Widened in whole steps of the band's own top edge until the session fits, so a session twice
        // typical lands at exactly 1 (and one hair past it lands at 2 steps). Bounded by the
        // `filledFraction` clamp below, which is what stops a pathological duration spinning here.
        let scale = durationSeconds > bandHigh ? durationSeconds : bandHigh

        self.filledFraction = Self.fraction(durationSeconds / scale)
        self.lowFraction = Self.fraction(min(low, high) / scale)
        self.highFraction = Self.fraction(max(low, high) / scale)
    }

    /// A layout, or `nil` when there is no band to draw the session against.
    ///
    /// **No band, no bar.** The alternative was to draw the session's length on some other scale — its
    /// own, or a fixed number of minutes — and both would put a length on the screen with nothing to
    /// read it against: a bar whose whole meaning is a comparison, drawn without the thing it compares
    /// to. The row prints its duration either way, so the absence costs the page a picture and no
    /// figure, which is the same bargain `TypicalRangeBar` makes when it draws a share and withholds
    /// the band mark.
    public static func make(
        durationSeconds: Double,
        typical: ActivityBaseline.Typical?
    ) -> ActivityDurationBarLayout? {
        guard let typical else { return nil }
        return ActivityDurationBarLayout(
            durationSeconds: durationSeconds, low: typical.low, high: typical.high)
    }

    /// A fraction clamped into the track. Non-finite collapses to zero rather than propagating: a `NaN`
    /// width is not a mark drawn at the wrong place, it is a mark that takes the whole bar with it,
    /// since every comparison against a `NaN` is false and the clamp cannot catch it.
    private static func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// One session's length, drawn solid over the band that length is normally in — this page's sibling of
/// the sleep detail screen's `TypicalRangeBar`.
///
/// ## Why it is a sibling rather than a reuse
///
/// `TypicalRangeBarLayout` has exactly one initialiser, `init(percent:typical:)`, which takes whole
/// percent and a `SleepStageRangeScoring.Typical` — two types that belong to the sleep card's *share of
/// a night*. A duration band is neither: it is seconds against seconds, and the scale is derived rather
/// than fixed. Expressing this through that initialiser would mean converting a duration into a
/// percentage of something first, which is the invented scale `ActivityDurationBarLayout` exists to
/// avoid inventing.
///
/// **The three styling constants are restated here by value, and that is the same deliberate
/// duplication `SleepStressShareBar` already makes.** `TypicalRangeBar`'s `stripeSpacing` (10.9),
/// `stripeWidth` (3.85) and `trackCornerRadius` (4.5) are `private` to that type, and the alternative
/// to copying them was a refactor of a shipped component that the existing bar-layout assertions cannot
/// see. So they are now written down twice, and **changing one without the other is drift**: if the
/// reference's stripe is ever re-measured, both files move together. The shapes themselves —
/// `HatchShape` and `BandEdges` — are reused rather than copied, because they are already the app's one
/// definition of a hatched remainder and of a two-rule band, and `BandEdges` is public for exactly this.
public struct ActivityDurationBar: View {

    /// Where everything goes. Built by the page from the session's own length and the activity's band.
    public let layout: ActivityDurationBarLayout

    /// The track's thickness. A parameter because the page tunes it against the row above and the bar
    /// has no opinion about that. **The corner radius does not follow it** — see `trackCornerRadius`.
    public var height: CGFloat

    public init(layout: ActivityDurationBarLayout, height: CGFloat = 20) {
        self.layout = layout
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            track(width: width)
                .overlay(alignment: .leading) { band(width: width) }
        }
        .frame(height: height)
        // Decoration. The row above announces the duration and its band in one sentence, so a listener
        // has already been told everything the bar draws.
        .accessibilityHidden(true)
    }

    /// The bar itself: the scale, the hatched remainder, and this session's length.
    ///
    /// The stack is clipped to the track's shape, which is what gives the share a square trailing edge
    /// while its leading end takes the track's corner — `TypicalRangeBar.track`'s composition, and the
    /// measurement that settled it is recorded there.
    private func track(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.trackCornerRadius, style: .continuous)

        return ZStack(alignment: .leading) {
            // The scale, in the neutral track the sleep bars also use for the part of a scale a reading
            // did not reach.
            shape.fill(Theme.ringTrack)

            // The remainder, hatched. Masked rather than inset, so the stripes land at the same spacing
            // on every row rather than being redrawn per bar.
            HatchShape(spacing: Self.stripeSpacing)
                .stroke(Theme.hatchStripe, lineWidth: Self.stripeWidth)
                .clipShape(shape)
                .mask(alignment: .trailing) {
                    Rectangle().frame(width: max(0, width * layout.unfilledFraction))
                }

            Rectangle()
                .fill(Theme.strainRing)
                .frame(width: max(0, width * layout.filledFraction))
        }
        .frame(height: height)
        .clipShape(shape)
    }

    /// The band, drawn as one filled region with a dashed rule down each of its sides.
    ///
    /// A region with two edges rather than two marks, on `TypicalRangeBar.bandMark`'s argument: two
    /// lines say where a band's edges are, a region says the two edges bound *one span*, which is what a
    /// range is. Both bounds are always set here — `ActivityDurationBarLayout` computes them together
    /// from a non-optional `Typical` — so this is not a `ViewBuilder` with an absent branch the way its
    /// sibling's is.
    private func band(width: CGFloat) -> some View {
        let low = min(layout.lowFraction, layout.highFraction)
        let high = max(layout.lowFraction, layout.highFraction)
        let startX = min(max(0, width * low), width)
        let endX = min(max(0, width * high), width)
        // A floor on the width, because a region narrower than the two rules that bound it would draw
        // them on top of each other and read as a single line — a mark that says *here* rather than
        // *from here to here*.
        let markWidth = max(Self.markMinimumWidth, endX - startX)

        return ZStack(alignment: .leading) {
            Rectangle().fill(Theme.bandMarkFill)

            BandEdges(inset: Self.markLineWidth / 2)
                .stroke(
                    Theme.bandMarkEdge,
                    style: StrokeStyle(lineWidth: Self.markLineWidth, dash: TypicalRangeBar.markDash))
        }
        .frame(width: markWidth, height: height + Self.markOverhang * 2)
        .offset(x: min(startX, max(0, width - markWidth)))
    }

    // MARK: - The shared constants, restated

    /// The hatch's period and one stripe's width, **restated by value from `TypicalRangeBar`.** See
    /// this type's comment: the two files move together or the two bars drift.
    private static let stripeSpacing: CGFloat = 10.9
    private static let stripeWidth: CGFloat = 3.85

    /// How round the track's ends are, restated from `TypicalRangeBar` on the same terms — nearly
    /// square rather than a capsule, solved for against the reference at `4.5` pt.
    private static let trackCornerRadius: CGFloat = 4.5

    private static let markLineWidth: CGFloat = 1.5
    private static let markMinimumWidth: CGFloat = 6
    private static let markOverhang: CGFloat = 5
}
