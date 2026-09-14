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
    /// bar has no opinion about that — but its corner radius follows it rather than being fixed, so the
    /// bar is a capsule at any height.
    public var height: CGFloat

    public init(stage: SleepStageType, layout: TypicalRangeBarLayout, height: CGFloat = 10) {
        self.stage = stage
        self.layout = layout
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                // The scale, in the neutral track `SleepBandBar` also uses for its unlit segments: the
                // two are the same idea — the part of a scale a reading did not reach.
                Capsule(style: .continuous)
                    .fill(Theme.ringTrack)

                // The remainder, hatched. Masked rather than inset: the stripes are a texture over the
                // whole track and the mask is what says which part of it is tonight's. A hatch drawn
                // only across the remainder would have its stripes land at a different spacing on every
                // row — a Mask keeps one texture and moves the edge, which is what makes four rows look
                // like one scale.
                HatchShape(spacing: Self.stripeSpacing)
                    .stroke(Theme.hatchStripe, lineWidth: 1)
                    .clipShape(Capsule(style: .continuous))
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: max(0, width * layout.unfilledFraction))
                    }

                Capsule(style: .continuous)
                    .fill(stage.color)
                    .frame(width: max(0, width * layout.filledFraction))

                // No band, no markers. A dashed bound at an invented position would be the same
                // fabrication a `0` height bar would be, and worse for being explicit.
                if let low = layout.lowFraction {
                    marker(at: low, width: width)
                }
                if let high = layout.highFraction {
                    marker(at: high, width: width)
                }
            }
        }
        .frame(height: height)
        // Decoration. The row above this bar announces the stage, its share and its band in one
        // sentence, so a listener has already been told everything the bar draws — a second reading of
        // the same figures in a shape with no words would be noise.
        .accessibilityHidden(true)
    }

    /// One dashed bound, drawn full height across the track.
    ///
    /// The offset is clamped so a bound at either end sits inside the bar rather than half outside it.
    /// That is a pixel guard and not the fraction clamp in `TypicalRangeBarLayout`: a fraction of `1`
    /// is a legitimate reading — a stage that took the whole period — and the mark for it should touch
    /// the right edge, not hang past it.
    private func marker(at fraction: Double, width: CGFloat) -> some View {
        DashedMarker()
            .stroke(
                Theme.textPrimary.opacity(0.85),
                style: StrokeStyle(lineWidth: Self.markerWidth, dash: [3, 3]))
            .frame(width: Self.markerWidth, height: height)
            .offset(x: min(max(0, width * fraction - Self.markerWidth / 2),
                           max(0, width - Self.markerWidth)))
    }

    private static let stripeSpacing: CGFloat = 5
    private static let markerWidth: CGFloat = 1.5
}

/// A vertical line down the middle of its rect, dashed when stroked with a dash pattern.
///
/// A `Shape` rather than a `Rectangle` with a dash overlay, following `CardNotch`'s convention that
/// this app draws its small marks as shapes: the caller supplies the stroke, so a marker cannot come
/// to be filled in a colour the bar did not choose.
private struct DashedMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
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
