import SwiftUI

/// The five heart-rate-reserve bands as one scale, with the live reading's position marked on it.
///
/// **This is a position scale and not a distribution.** Each of its five segments is one band of heart
/// rate reserve — `50-59%` … `90-100%` — drawn end to end, and the mark says *where the current heart
/// rate sits*. How much of a session was spent in each band is a different quantity with a different
/// shape (a stacked share bar) and a different reader; drawing the two with one picture is the
/// confusion this component exists to end.
///
/// **So the mark moves and the segments do not.** A segment's width is one band's share of the
/// *reserve*, which the profile fixes — never one band's share of anything measured — so the scale is
/// the same picture all session and only the mark travels across it. That is what makes it readable at
/// a glance: the reader learns the scale once.
///
/// The scale's two ends are zone 1's own floor and zone 5's ceiling, so it is the same table
/// `StrainAccumulatorMath.computeZones` builds. The five names come off
/// `StrainAccumulatorMath.zoneReserveBandLabels`, derived from the same `zoneReserveFractions` the
/// edges are — a label typed into a `View`'s `body` is a rule the test runner, which has no renderer,
/// cannot see.
public struct HeartRateBandScaleView: View {

    /// Where the current reading sits, as a `0…1` fraction across the scale — or `nil` when nothing
    /// has been measured, which draws the scale with **no mark at all**.
    ///
    /// **The absence is not a mark at zero.** A mark at the left edge is a real reading: a heart rate
    /// at or below zone 1's floor, which is what a worn strap at rest reports. A session that has heard
    /// from no strap has no reading to place, and parking its mark at the left edge would state the
    /// first as though it were the second — the fabrication class `WhoopDevice.batteryPercentage`
    /// already documents. The scale itself is drawn either way, because the scale is a set of band
    /// edges rather than a measurement.
    public let position: Double?

    public init(position: Double?) {
        self.position = position
    }

    /// The mark's diameter. Wider than the track, so the mark reads as a point *on* the scale rather
    /// than as one more segment of it.
    private static let markDiameter: CGFloat = 9
    private static let trackHeight: CGFloat = 3
    /// The gap between two bands — the tick that separates `50-59%` from `60-69%`. Drawn as a gap
    /// rather than as a stroked line, so it cannot be mistaken for a mark of any kind.
    private static let bandGap: CGFloat = 3

    /// `StrainAccumulatorMath.zoneReserveBandLabels`, held as a `static let` so the `body` does not
    /// rebuild the array on every redraw. It is a pure function of a `static let` in `Core/Math`, so
    /// there is nothing here that can drift from it.
    private static let bandLabels = StrainAccumulatorMath.zoneReserveBandLabels

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: Self.bandGap) {
                        ForEach(Self.bandLabels.indices, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                                .fill(Theme.bandMarkEdge)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: Self.trackHeight)
                    .frame(maxHeight: .infinity)

                    if let position {
                        Circle()
                            .fill(Theme.textPrimary)
                            .frame(width: Self.markDiameter, height: Self.markDiameter)
                            .offset(x: markOffset(for: position, in: geometry.size.width))
                    }
                }
                // Explicit, because the mark is placed by an `offset` and an alignment-only `ZStack`
                // would let the group sit wherever its own width put it instead of starting at the
                // scale's left edge. `SleepTimelineView`'s gotcha is this same mistake one container
                // over, where it was invisible until the lane's marks were measured.
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .frame(height: Self.markDiameter)

            HStack(spacing: Self.bandGap) {
                ForEach(Self.bandLabels.indices, id: \.self) { index in
                    Text(Self.bandLabels[index])
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        // Five columns on a phone leaves about 65 pt each and `90-100%` is the widest
                        // of the five. Shrinking beats wrapping, which would stagger the row and take
                        // each name off the band it belongs to.
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The mark's travel is the track **minus the mark's own width**, so a reading at either end of the
    /// scale keeps the whole mark inside it rather than hanging half of it off the edge — which is what
    /// a bare `position × width` does, and it reads as the scale being mis-drawn rather than as a
    /// reading at its limit.
    private func markOffset(for position: Double, in width: CGFloat) -> CGFloat {
        let clamped = min(1.0, max(0.0, position))
        return clamped * max(0, width - Self.markDiameter)
    }

    /// The scale is five band names and, when there is a reading, the band it currently falls in. The
    /// mark's position along the track is the whole of the picture, and it is not legible aloud — so
    /// the band number is what is spoken instead.
    private var accessibilityDescription: String {
        let scale = Self.bandLabels.joined(separator: ", ")
        guard position != nil else {
            return "Heart rate reserve scale: \(scale). No reading."
        }
        return "Heart rate reserve scale: \(scale). Current reading is in band \(currentBandNumber)."
    }

    /// Which of the five segments the mark currently sits in, counting from one.
    ///
    /// `position × 5` rather than a comparison against each edge: the bands are equal widths of the
    /// reserve by construction (`zoneReserveFractions` is five ten-point spans), so the segment index
    /// *is* the fraction — and a second table of edges here is exactly the duplication this component
    /// avoids. A mark at the far right belongs to the last band rather than to a sixth one.
    private var currentBandNumber: Int {
        guard let position else { return 1 }
        let index = Int(min(1.0, max(0.0, position)) * Double(Self.bandLabels.count))
        return min(Self.bandLabels.count, index + 1)
    }
}
