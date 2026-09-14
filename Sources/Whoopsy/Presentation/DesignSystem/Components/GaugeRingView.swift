import SwiftUI

/// Animated circular gauge ring with custom color gradient, glow, and central label.
public struct GaugeRingView: View {
    public let progress: Double // 0.0 to 1.0
    public let scoreText: String
    public let label: String
    public let ringColor: Color
    /// The label's colour, and a parameter rather than a constant for the same reason `ringColor` is
    /// one: the screens that draw this ring are not styled alike.
    ///
    /// It defaults to `Theme.textSecondary`, which is what every caller but `SleepDetailView` passes
    /// through by omission — the sleep detail page is the one that follows a reference in printing its
    /// label at full strength under the score. A caller that wanted a *different* label could not
    /// reach one before this existed, and the alternative to a defaulted parameter here is the one
    /// `MetricRingView`'s doc comment records: a fifth parameter on a shared component moves four
    /// screens, so the exception is made reachable without being made compulsory.
    public var labelColor: Color = Theme.textSecondary
    public var lineWidth: CGFloat = 14
    public var size: CGFloat = 140

    public init(
        progress: Double,
        scoreText: String,
        label: String,
        ringColor: Color,
        labelColor: Color = Theme.textSecondary,
        lineWidth: CGFloat = 14,
        size: CGFloat = 140
    ) {
        self.progress = max(0.0, min(1.0, progress))
        self.scoreText = scoreText
        self.label = label
        self.ringColor = ringColor
        self.labelColor = labelColor
        self.lineWidth = lineWidth
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Track background
            Circle()
                .stroke(ringColor.opacity(0.18), lineWidth: lineWidth)

            // Progress indicator
            Circle()
                .trim(from: 0.0, to: CGFloat(progress))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [ringColor.opacity(0.7), ringColor]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * progress)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: ringColor.opacity(0.6), radius: 6, x: 0, y: 0)
                .animation(.spring(response: 0.8, dampingFraction: 0.75), value: progress)

            // Inner content
            VStack(spacing: 2) {
                Text(scoreText)
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)

                Text(label.uppercased())
                    .font(.system(size: size * 0.09, weight: .semibold, design: .rounded))
                    .foregroundColor(labelColor)
                    .tracking(1.2)
                    // A label long enough to carry its own line break — the sleep detail page's
                    // `SLEEP` over `PERFORMANCE` — would otherwise centre the block and left-align
                    // the lines inside it, which reads as a mistake rather than as two lines.
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: size, height: size)
    }
}
