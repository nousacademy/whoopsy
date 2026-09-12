import SwiftUI

/// A flat progress ring with its value centred inside it and its label beneath.
///
/// Deliberately a sibling to `GaugeRingView` rather than a variant of it. That component draws an
/// angular gradient, an outer glow, and its label *inside* the ring, and four screens depend on that
/// look — Strain, Sleep, Recovery and the workout HUD. Home's mockup wants the opposite of all three,
/// so bending `GaugeRingView` to fit would move four screens to restyle one.
///
/// **No chevron, and no tap target.** The rings have nowhere to go — the one thing on Home that
/// navigates is the day bar's title, which opens the month calendar — and an affordance with no
/// destination is the same defect the dashboard's `CUSTOMIZE` control is left out for.
public struct MetricRingView: View {
    /// The figure to show, already formatted by the caller — or `nil` for a day with no measurement.
    ///
    /// Optional rather than a pre-formatted `"–"` string so the ring cannot contradict itself: a
    /// caller that passes a dash cannot also pass a fill, because there is no fill to pass. Deciding
    /// *whether* the day has a value is the caller's, since only the caller knows which of the three
    /// metrics' absence rules applies.
    public let value: String?

    public let label: String

    /// 0...1. Ignored when `value` is `nil`.
    public let progress: Double

    public let color: Color
    public var size: CGFloat = 92
    public var lineWidth: CGFloat = 10

    /// Whether the label is drawn beneath the ring.
    ///
    /// Added for Home's collapsed header, which draws the same three rings at `size: 40`. The label's
    /// font is fixed at 10pt rather than scaled from `size`, so at that size the words would be wider
    /// than the rings they sit under and would set the row's height — a sticky header two-thirds
    /// label. Defaulted to `true`, so nothing that already draws a ring moves.
    public var showsLabel: Bool = true

    public init(
        value: String?,
        label: String,
        progress: Double,
        color: Color,
        size: CGFloat = 92,
        lineWidth: CGFloat = 10,
        showsLabel: Bool = true
    ) {
        self.value = value
        self.label = label
        self.progress = progress
        self.color = color
        self.size = size
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    public var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Theme.ringTrack, lineWidth: lineWidth)

                if let value {
                    Circle()
                        .trim(from: 0, to: max(0, min(1, progress)))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.45), value: progress)

                    Text(value)
                        .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, lineWidth)
                } else {
                    Text("—")
                        .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(width: size, height: size)

            if showsLabel {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// One reading, not two. Without this VoiceOver reaches the figure and the label as separate
    /// elements, which announces "95%" and then "SLEEP" with no relation between them.
    private var accessibilityDescription: String {
        guard let value else { return "\(label), no measurement" }
        return "\(label), \(value)"
    }
}
