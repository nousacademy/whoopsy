import SwiftUI

/// Animated circular gauge ring with custom color gradient, glow, and central label.
public struct GaugeRingView: View {
    public let progress: Double // 0.0 to 1.0
    public let scoreText: String
    public let label: String
    public let ringColor: Color
    public var lineWidth: CGFloat = 14
    public var size: CGFloat = 140

    public init(
        progress: Double,
        scoreText: String,
        label: String,
        ringColor: Color,
        lineWidth: CGFloat = 14,
        size: CGFloat = 140
    ) {
        self.progress = max(0.0, min(1.0, progress))
        self.scoreText = scoreText
        self.label = label
        self.ringColor = ringColor
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
                    .foregroundColor(Theme.textSecondary)
                    .tracking(1.2)
            }
        }
        .frame(width: size, height: size)
    }
}
