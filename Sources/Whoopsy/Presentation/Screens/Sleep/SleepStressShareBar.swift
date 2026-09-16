import SwiftUI

/// One stress band's share of a night: the part of the scored span it took, solid, over the hatched
/// remainder of the same 0–100% track.
///
/// ## Why this is not `TypicalRangeBar`
///
/// Those two bars are one card apart on the same screen and they are deliberately two types. That one
/// draws a **share against a range** — tonight's stage share, with the band that share is normally in
/// marked on the same track — and half of its code is the band mark. This one draws a **share alone**:
/// a night is divided into three bands, so the three rows are parts of one whole and there is no
/// external range for any of them to be read against. A `typical:` parameter that was always `nil`
/// would be the band mark's whole machinery carried unused, and the two bars would then be one type
/// whose doc comment answers two different questions.
///
/// What they *do* share is the drawing, and it is shared by **value rather than by reference**: the
/// hatch, its period and stripe width, and the track's corner radius are restated below with the
/// measurements they came from, which is the precedent `SleepTimelineView` set against this same type's
/// constants. Those constants are `private` there, and what keeps the two copies equal is that both are
/// stated against the same reference measurement rather than against each other. If either is
/// re-measured, re-measure the other.
///
/// ## The scale is the scored span, and the card prints what that is
///
/// A bar's length is a share of the time this model could score — `SleepStressNight.scoredSeconds` —
/// and not of the night. The two differ by every window the strap was moving through or the R-R series
/// could not support. The card's header names the denominator, so the three percentages under it are
/// read against a total a reader can see.
public struct SleepStressShareBar: View {

    /// The band, which is the bar's colour and nothing else. Read through `StressMath.Band.color` —
    /// the app's single band-to-token mapping — so this bar and the stress chart above it cannot come
    /// to draw one band in two colours.
    public let band: StressMath.Band

    /// The share of the scored span, in whole percent.
    public let percent: Int

    /// The track's thickness. A parameter because the caller tunes it against a stack of rows and the
    /// bar has no opinion about that.
    public var height: CGFloat

    public init(band: StressMath.Band, percent: Int, height: CGFloat = 20) {
        self.band = band
        self.percent = percent
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            track(width: proxy.size.width)
        }
        .frame(height: height)
        // Decoration. The row above this bar announces the band, its share and its duration in one
        // sentence, so a listener has already been told everything the bar draws — a second reading of
        // the same figures in a shape with no words would be noise.
        .accessibilityHidden(true)
    }

    /// The scale, the hatched remainder, and this band's share.
    ///
    /// **The share is a plain rectangle clipped to the track's shape**, which is what gives it a round
    /// leading end and a flat trailing one in a single move: the leading edge takes the track's corner
    /// from the clip while the trailing edge, an interior edge meeting the hatched remainder, stays
    /// straight. Drawn as a capsule instead it would end in a semicircular cap bulging into the middle
    /// of the bar. `TypicalRangeBar` carries the measurement this was read from.
    ///
    /// **The hatch is masked rather than inset**, on that bar's rule: the stripes are one texture over
    /// the whole track and the mask says which part of it is this band's. A hatch drawn only across the
    /// remainder would land its stripes at a different spacing on every row — a mask keeps one texture
    /// and moves the edge, which is what makes three rows look like one scale.
    private func track(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.trackCornerRadius, style: .continuous)

        return ZStack(alignment: .leading) {
            shape.fill(Theme.ringTrack)

            HatchShape(spacing: Self.stripeSpacing)
                .stroke(Theme.hatchStripe, lineWidth: Self.stripeWidth)
                .clipShape(shape)
                .mask(alignment: .trailing) {
                    Rectangle().frame(width: max(0, width * (1 - filledFraction)))
                }

            Rectangle()
                .fill(band.color)
                .frame(width: max(0, width * filledFraction))
        }
        .frame(height: height)
        .clipShape(shape)
    }

    /// This band's share, as a fraction of the track.
    ///
    /// A **guard, not a rule**. `SleepStressNight` derives every percent from `WholePercentMath` over a
    /// non-empty window list, so each is a whole number in `0...100` by construction and the clamp
    /// changes nothing. What it prevents is a hand-built bar drawing a mark off the end of its track,
    /// which is worse than a mark in the wrong place: it reads as a different scale. A non-finite value
    /// collapses to zero rather than propagating, because a `NaN` width is not a mark drawn at the
    /// wrong place but a mark that takes the whole bar with it — every comparison against a `NaN` is
    /// false, so the clamp cannot catch it.
    private var filledFraction: Double {
        let value = Double(percent) / 100
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// The hatch's period and one stripe's width, in the horizontal run this shape steps in.
    ///
    /// Restated by value from `TypicalRangeBar`, which carries the full measurement: the reference
    /// draws a `3.85` pt stripe on a `7.7` pt perpendicular period, a 1:1 duty cycle, and a 45° stripe
    /// crosses a horizontal scan at `√2` times its own thickness — hence `10.9` and `3.85` here.
    /// Absolute rather than a multiple of `height`, for the reason given there.
    private static let stripeSpacing: CGFloat = 10.9
    private static let stripeWidth: CGFloat = 3.85

    /// How round the track's ends are, restated by value from `TypicalRangeBar` — which solved for
    /// this against the reference's own anti-aliased corner profile rather than reading it off, and
    /// names the capsule it replaced. `4.5` pt, `continuous`, and the two bars on this screen agree
    /// because both are stated against that one measurement.
    private static let trackCornerRadius: CGFloat = 4.5
}
