import SwiftUI

/// The three-segment band bar under the sleep-performance ring: Poor, Sufficient, Optimal, with the
/// segment the night fell in drawn solid and the other two in the neutral track.
///
/// **It shows position on the scale, not a proportion of it.** The three segments are equal on purpose
/// and no `GeometryReader` divides the width between them, which is where this differs from
/// `HeartRateZoneBar` and `HypnogramChartView` — those two draw a *distribution*, so their widths are
/// the reading. Here the reading is which segment is lit, and equal segments are what make that
/// legible: a bar whose lengths varied with the thresholds would imply a distance between Poor and
/// Sufficient that this scale does not define, and the night's own figure is already printed in the
/// ring above it.
///
/// It is drawn inside the ring rather than beside it — the caller overlays it — so its width is fixed
/// rather than proposed by a parent. That is also why the segments carry no labels: the legend under
/// the card names all three, and three words inside a 190pt circle would not fit at a size anyone
/// could read.
///
/// The two unlit segments are drawn in `Theme.ringTrack` rather than omitted. A single bar would state
/// the night's band and nothing about the scale it sits on, which is the whole of what the three
/// segments are for.
public struct SleepBandBar: View {
    /// The band to light. Non-optional: a night with no figure draws no bar at all, so the caller
    /// gates it rather than this view rendering a bar with nothing lit — which would be a picture of
    /// the scale with no reading on it.
    public let band: SleepBand

    public var segmentWidth: CGFloat
    public var segmentHeight: CGFloat
    public var spacing: CGFloat

    public init(
        band: SleepBand,
        segmentWidth: CGFloat = 18,
        segmentHeight: CGFloat = 5,
        spacing: CGFloat = 4
    ) {
        self.band = band
        self.segmentWidth = segmentWidth
        self.segmentHeight = segmentHeight
        self.spacing = spacing
    }

    public var body: some View {
        HStack(spacing: spacing) {
            // `SleepBand.allCases` is declaration order — poor, sufficient, optimal — which is the
            // scale's order and the legend's below it. Reading the cases rather than listing them
            // means a fourth band would appear here without this file being edited twice.
            ForEach(SleepBand.allCases) { candidate in
                RoundedRectangle(cornerRadius: segmentHeight / 2, style: .continuous)
                    .fill(candidate == band ? candidate.color : Theme.ringTrack)
                    .frame(width: segmentWidth, height: segmentHeight)
            }
        }
        // Decoration, and the ring it sits in already announces the figure the band was read from.
        // A spoken "Poor, Sufficient, Optimal" beside it would name all three on every night.
        .accessibilityHidden(true)
    }
}
