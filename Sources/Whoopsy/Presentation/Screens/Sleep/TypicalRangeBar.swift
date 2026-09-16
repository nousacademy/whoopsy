import SwiftUI

/// Where everything on a typical-range bar is drawn, as fractions of the track's width.
///
/// **It exists because a rule written into a `View` is a rule nothing here can assert**, which is
/// `DayBarRules`' reason for being a type of its own and applies twice over to this bar: the runner
/// that tests this app has no renderer, so a clamp written inside a `GeometryReader` is a clamp
/// nothing can check. Resolving the fractions here means the arithmetic the card's picture is made of
/// — including the case a bound arrives outside the scale — is asserted as a value.
///
/// Fractions rather than points deliberately. The bar's width belongs to whatever proposes it, and the
/// one thing this type promises is where along it a mark lands; a type that resolved to points would
/// have to be handed a width and would be a drawing rather than a rule.
public struct TypicalRangeBarLayout: Equatable, Sendable {

    /// How much of the bar is tonight, as a fraction of the whole. Always `0...1`.
    public let filledFraction: Double

    /// The lower bound of what is typical, as a fraction of the scale, or `nil` when there is no band.
    ///
    /// **`nil` and not `0`.** A window too thin to produce a quartile has no lower bound, and drawing
    /// one at zero would put a mark on the bar that the data did not put there — the same fabrication
    /// as a `SleepBandBar` with nothing lit, in a smaller shape.
    public let lowFraction: Double?

    /// The upper bound, or `nil` for the same reason. Never less than `lowFraction` when both are set.
    public let highFraction: Double?

    /// The share of the bar that is *not* tonight, which is the region the hatch fills.
    public var unfilledFraction: Double { 1 - filledFraction }

    /// Tonight's share, and the band it is read against.
    ///
    /// The clamping here is a **guard, not a rule**, and it is worth saying which because the two look
    /// alike. A share of a sleep period is within `0...100` by construction, and
    /// `SleepStageRangeScoring` has already ordered each band so `lowPercent <= highPercent`; every
    /// input this receives is therefore in range and in order, and the clamps change nothing. What they
    /// prevent is a future call site handing a fraction the bar would draw off the end of its track —
    /// a mark outside the scale is worse than a mark in the wrong place, because it reads as a
    /// different scale rather than as a wrong reading.
    ///
    /// - Parameters:
    ///   - percent: tonight's share of the night, in whole percent.
    ///   - typical: the band for this stage, or `nil` when the window was too thin for one.
    public init(percent: Int, typical: SleepStageRangeScoring.Typical?) {
        self.filledFraction = Self.fraction(Double(percent) / 100)
        self.lowFraction = typical.map { Self.fraction($0.lowPercent / 100) }
        self.highFraction = typical.map { Self.fraction($0.highPercent / 100) }
    }

    /// A fraction clamped into the track. Non-finite collapses to zero rather than propagating: a
    /// `NaN` width is not a mark drawn at the wrong place, it is a mark that takes the whole bar with
    /// it, since every comparison against a `NaN` is false and the clamp cannot catch it.
    private static func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// One sleep stage's night: the share it took, drawn solid, over the band that share is normally in.
///
/// It is the bar under each of the typical-range card's four rows, and it is `SleepBandBar`'s opposite
/// number. That bar shows **position** on a scale of three equal segments and no proportion at all;
/// this one shows a **proportion** — tonight's share, as a length — with the typical range marked on
/// the same scale so the two can be read against each other. Neither could be bent into the other, and
/// the reason they are two types rather than one with a flag is that their doc comments answer
/// different questions.
///
/// **The scale is 0–100% of the night, and it is the same scale on all four rows.** That is what makes
/// the four bars comparable with each other and it is why the band is drawn in percentage points: a
/// band in minutes could not be drawn on this track at all. It also means a bar's length is a share
/// and not a duration, so the REM row's bar is not shorter than the Deep row's because REM was shorter
/// — the durations are printed beside them, in the row above.
public struct TypicalRangeBar: View {

    /// The stage, which is the bar's colour and nothing else. Read through `SleepStageType.color`, the
    /// app's single stage-to-token mapping, so this bar and the hypnogram above it cannot come to draw
    /// one stage in two colours.
    public let stage: SleepStageType

    /// Where everything goes. Built by the card from the row's own figure and band.
    public let layout: TypicalRangeBarLayout

    /// The track's thickness. A parameter because the card tunes it against four rows of type and the
    /// bar has no opinion about that. **The corner radius does not follow it** — see
    /// `trackCornerRadius` for why the ends are nearly square rather than a capsule.
    public var height: CGFloat

    public init(stage: SleepStageType, layout: TypicalRangeBarLayout, height: CGFloat = 20) {
        self.stage = stage
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
        // Decoration. The row above this bar announces the stage, its share and its band in one
        // sentence, so a listener has already been told everything the bar draws — a second reading of
        // the same figures in a shape with no words would be noise.
        .accessibilityHidden(true)
    }

    /// The bar itself: the scale, the hatched remainder, and tonight's share.
    ///
    /// **It is a view of its own, and the explicit height on it is load-bearing.** The band mark is
    /// taller than the bar, and while the two were children of one `ZStack` that stack sized itself to
    /// the taller of them — so the track, the hatch and the share, none of which carries a height of
    /// its own, all stretched to the mark's height. The bar came out at `height + 2 × markOverhang`
    /// with the mark lying exactly on top of it, which is a bar half again as thick as this one with no
    /// overhang at all: measured off a screenshot, 30 pt of bar and a mark that began and ended on the
    /// bar's own edges. Giving the bar its own frame and drawing the mark as an `overlay` is what makes
    /// `height` mean the bar's height and `markOverhang` mean an overhang.
    ///
    /// **The whole stack is clipped to the track's shape, and that is what gives the share a square
    /// trailing edge.** The share is a plain rectangle rather than a shape of its own, so its leading
    /// end takes the track's corner from this clip while its trailing end stays a straight vertical
    /// line — which is where it meets the hatched remainder, an interior edge with nothing to round.
    /// Drawn as its own capsule instead, the share ended in a semicircular cap bulging into the middle
    /// of the bar where the reference has a flat edge, and a share of `1` would have been the only
    /// share that looked right. Measured off the reference's first row, the share's right edge is flat
    /// to within one source pixel over the bar's whole height.
    private func track(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.trackCornerRadius, style: .continuous)

        return ZStack(alignment: .leading) {
            // The scale, in the neutral track `SleepBandBar` also uses for its unlit segments: the two
            // are the same idea — the part of a scale a reading did not reach.
            shape.fill(Theme.ringTrack)

            // The remainder, hatched. Masked rather than inset: the stripes are a texture over the
            // whole track and the mask is what says which part of it is tonight's. A hatch drawn only
            // across the remainder would have its stripes land at a different spacing on every row — a
            // Mask keeps one texture and moves the edge, which is what makes four rows look like one
            // scale.
            HatchShape(spacing: Self.stripeSpacing)
                .stroke(Theme.hatchStripe, lineWidth: Self.stripeWidth)
                .clipShape(shape)
                .mask(alignment: .trailing) {
                    Rectangle().frame(width: max(0, width * layout.unfilledFraction))
                }

            Rectangle()
                .fill(stage.color)
                .frame(width: max(0, width * layout.filledFraction))
        }
        .frame(height: height)
        .clipShape(shape)
    }

    /// The band, or nothing.
    ///
    /// **No band, no mark.** A mark at an invented position would be the same fabrication a `0` height
    /// bar would be, and worse for being explicit.
    ///
    /// **Both bounds are required, and that is not a shortcut.** A band is a *range*, and one edge of a
    /// range is not a narrower range — so a half-band has nothing to draw rather than something smaller
    /// to draw. `init(percent:typical:)` is this type's only constructor and it sets the two together,
    /// so a half-band is unreachable through it; the `min`/`max` in `bandMark` are there so the shape
    /// is well-formed for a hand-built layout too.
    @ViewBuilder
    private func band(width: CGFloat) -> some View {
        if let low = layout.lowFraction, let high = layout.highFraction {
            bandMark(from: min(low, high), to: max(low, high), width: width)
        }
    }

    /// The typical range, drawn as one filled region with a dashed rule down each of its sides.
    ///
    /// **A region with two edges rather than two marks, and the difference is not decoration.** Two
    /// lines say where a band's edges are; a region says the two edges bound *one span*, which is what
    /// a range is. The reference draws it this way, and the card's header carries a miniature of the
    /// same mark as the key to it — so this is something a reader is expected to look up, not a pair of
    /// rules.
    ///
    /// Three things about the geometry are guards rather than rules, named because each is a place the
    /// mark could come to lie about the data:
    ///
    /// - **The rules are inset by half a stroke's width**, so each sits inside the span it describes. A
    ///   stroked path is centred on its geometry, so an un-inset rule at `low` would paint half a
    ///   line-width to the left of the band's real lower edge.
    /// - **The width has a floor** (`markMinimumWidth`), because a region narrower than the two rules
    ///   that bound it would draw them on top of each other and read as a single line — a mark that
    ///   says *here* rather than *from here to here*. It bites only below a band a couple of points
    ///   wide, and moves neither edge by more than that; refusing to draw instead would hide a real
    ///   band on a real night.
    /// - **The x offset is clamped to the track**, so a band at either end sits inside the bar rather
    ///   than half outside it. That is `min`/`max` on the offset and not the fraction clamp in
    ///   `TypicalRangeBarLayout`: a fraction of `1` is a legitimate reading — a stage that took the
    ///   whole period — and its mark should touch the right edge, not hang past it.
    ///
    /// It is **taller than the track, and centred on it**, overhanging by `markOverhang` at each end.
    /// That is the reference's proportion and it is what makes the mark read as a span of the scale
    /// rather than as a segment of the bar — a range that extends past the reading it was drawn beside
    /// is saying it is a property of the *scale*, not of tonight. The centring comes from the
    /// `overlay`'s `.leading` alignment, which is `.center` vertically and so hangs half the overhang
    /// off each side of the bar; there is deliberately no y offset here, which is what an earlier
    /// version of this mark had and what put it off-centre. Nothing on the path clips — not the
    /// `overlay`, not the `GeometryReader`, not the card's stack — so the mark draws outside the frame
    /// the bar was given, which is the whole point of it.
    private func bandMark(from low: Double, to high: Double, width: CGFloat) -> some View {
        let startX = min(max(0, width * low), width)
        let endX = min(max(0, width * high), width)
        let markWidth = max(Self.markMinimumWidth, endX - startX)

        return ZStack(alignment: .leading) {
            Rectangle().fill(Theme.bandMarkFill)

            BandEdges(inset: Self.markLineWidth / 2)
                .stroke(
                    Theme.bandMarkEdge,
                    style: StrokeStyle(lineWidth: Self.markLineWidth, dash: Self.markDash))
        }
        .frame(width: markWidth, height: height + Self.markOverhang * 2)
        .offset(x: min(startX, max(0, width - markWidth)))
    }

    /// The hatch's period, and the width of one stripe across it.
    ///
    /// Both are measured off the reference and both are **perpendicular** measurements quoted as the
    /// horizontal run this shape steps in, because that is the axis `HatchShape` walks: a 45° stripe
    /// crosses a horizontal scan at `√2` times its own thickness, so a stripe the reference draws
    /// `3.85` pt thick reads as `5.45` pt of the scan and its `7.7` pt perpendicular period reads as
    /// `10.9` pt of it. The pair is a **1:1 duty cycle** — the reference's stripe and its gap are the
    /// same width — which is what makes the remainder read as a texture rather than as a set of lines
    /// ruled across a surface.
    ///
    /// The first version of these was a `5` pt period with a `1` pt stroke: a fine dense shimmer, and
    /// measurably a different figure from the reference's chunky, sparse stripes, which cross a 20 pt
    /// bar about twice. The period is absolute rather than a multiple of `height` because a bar height
    /// is not something the reference varies, so there is nothing to derive the ratio from.
    private static let stripeSpacing: CGFloat = 10.9
    private static let stripeWidth: CGFloat = 3.85

    /// How round the track's ends are. **Nearly square, and it was a capsule.**
    ///
    /// The bar was built from `Capsule`s, whose radius is half the bar's height — `9.8` pt at the
    /// default `20`. The reference's ends are not that: its corner is small and its share ends flat.
    /// Both halves were measured rather than eyeballed, off the reference's first row, on the share's
    /// leading edge — the one edge on the bar with nothing hatched over it, so a luminance threshold
    /// finds it unambiguously where the same scan across the hatched remainder is confounded by the
    /// stripes.
    ///
    /// - **The share's trailing edge is square**, measured over the bar's whole height rather than at
    ///   one row: flat to within one source pixel, against this app's own fill tracing `503 → 541 →
    ///   524` across the same span — a semicircle.
    /// - **The radius is `4.5` pt, and it was solved for rather than read off.** The corner's own
    ///   extent is not its radius — an anti-aliased corner's last pixel or two fall below any
    ///   threshold — so the reference's profile was measured against this app's, which is drawn at a
    ///   radius this file names. Read down the share's leading edge, the reference insets `3.42`,
    ///   `1.71`, `0.85`, `0.85`, `0` pt at `0`, `0.85`, `1.71`, `2.56`, `3.42` pt below the bar's top;
    ///   the same scan of a `3.5` pt corner gives an inset of `0.76`, `0.38`, `0.19`, `0.09` of *its*
    ///   radius at `0`, `0.19`, `0.38`, `0.48` of its depth. Matching the two puts the reference at
    ///   `4.5`: that radius predicts `3.43`, `1.71`, `0.86` pt at the three depths where the reference
    ///   measures `3.42`, `1.71`, `0.85`. The capsule this replaced had half the bar's height for a
    ///   radius — `9.8` pt at the default `20` — which is over twice as round as what it is copying.
    ///
    /// It is **absolute rather than a fraction of `height`**, for the reason `stripeSpacing` above is:
    /// the reference draws this bar at one height, so there is no ratio to derive. A caller that made
    /// the bar much thicker would want to revisit it, and the reference has nothing to say about that
    /// case either way.
    ///
    /// **The style is `continuous` on the same calibration**, not on the image alone. Both styles fit
    /// the reference's coarse profile — its rows quantise to `0.85` pt, so half the curve is at the
    /// floor — but this is the style the rest of this app's rounded surfaces use, and at `4.5` pt a
    /// circular corner would put the share's leading edge within a third of a point of where this one
    /// puts it. The choice is consistency, and the arithmetic above is what keeps it from being a
    /// guess.
    private static let trackCornerRadius: CGFloat = 4.5

    private static let markLineWidth: CGFloat = 1.5
    private static let markMinimumWidth: CGFloat = 6
    private static let markOverhang: CGFloat = 5

    /// 12 px on, 6 px off in the reference, which is 2.34 px to the point.
    static let markDash: [CGFloat] = [5, 2.5]
}

/// The two vertical rules that bound a typical-range band, inset inside its own rect so that a stroke
/// of twice `inset` lands within it.
///
/// **Two lines and not a rectangle**, which is the whole of what this shape is. A band's top and
/// bottom are not edges of anything — the region between the rules is filled by the caller — and
/// stroking a closed path here would draw a box around the mark, which is the shape this replaced.
///
/// A `Shape` rather than a stroked `Path` built in the view so the caller supplies the stroke and the
/// shape cannot come to be drawn in a colour the bar did not choose — `CardNotch`'s convention for
/// this app's small marks, and `HatchShape`'s.
///
/// **Public because two views stroke it and the suite asserts its geometry.** `SleepTypicalRangeCard`'s
/// header draws the same edges as its key to the bars — a key drawn from a copy of the mark is a key
/// that goes stale the moment the mark moves — and the inset is the one part of the mark that is
/// arithmetic, so it is the one part a runner with no renderer can check. `HatchShape` is internal for
/// the same first reason and is untested for want of the second.
///
/// `inset` is a parameter rather than a derived value because a `Shape` is never told the stroke it
/// will be handed, and matching that stroke is the whole purpose of the inset. It is applied
/// horizontally only: the rules run the full height of the rect they are given, because the height is
/// already the caller's decision about how far past the bar the mark reaches.
public struct BandEdges: Shape {
    public var inset: CGFloat = 0.75

    public init(inset: CGFloat = 0.75) {
        self.inset = inset
    }

    public func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: 0)
        guard box.width > 0, box.height > 0 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        path.move(to: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        return path
    }
}

/// Diagonal stripes at 45°, filling whatever rect it is given.
///
/// The stripes start one bar-height to the left of the rect so the leading edge is covered at the angle
/// rather than beginning with a gap, and the loop is bounded by `spacing > 0` so a zero spacing cannot
/// spin forever drawing an infinite number of coincident lines.
struct HatchShape: Shape {
    var spacing: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return path }

        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
