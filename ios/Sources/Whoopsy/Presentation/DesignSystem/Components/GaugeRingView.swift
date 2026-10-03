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
    /// The label's font size as a fraction of `size`. **`0.09` is what five of the six call sites
    /// draw**, and the default is not to be moved: a new default would restyle all of them to suit
    /// one, which is `MetricRingView`'s origin story.
    ///
    /// It is a parameter for `labelColor`'s reason, and reachable the same way — the exception is made
    /// possible without being made compulsory. The one caller that passes one is `LiveSessionView`,
    /// whose label is the longest any of them prints.
    ///
    /// **The constraint it exists for is measured, because nothing else can see it.** A ring is a
    /// circle around a rectangle of text, and a label wider than the chord it sits on crosses the
    /// stroke. On a 190 pt ring with an 18 pt line the inner edge is at radius 86; `ACTIVITY STRAIN`
    /// at the default scale is 159.9 pt wide where the chord at its own lower edge is 151.8 pt, so the
    /// word runs into the ring by 4.1 pt at each end. Every caller's build, and the whole suite, are
    /// green while that is true. Short labels are nowhere near it — `STRAIN` is 76 pt — so this is
    /// about the length of the word and not about the ring.
    ///
    /// **Measure a change here rather than looking at it.** The width is the font's, the chord is
    /// `sqrt(innerRadius² − dy²)` where `dy` is the label box's own lower edge below the ring's
    /// centre, and the two are within a few points of each other at the sizes this app uses — which is
    /// exactly why a picture is not enough to decide it.
    public var labelScale: CGFloat = 0.09
    /// Whether the label is drawn **above** the score rather than below it. The default is below,
    /// which is what five of the six call sites draw.
    ///
    /// It exists for `LiveSessionView`, whose reference puts the quantity's name over its figure —
    /// `ACTIVITY STRAIN` above `0.0` — where every other ring here puts the figure first. That is an
    /// *ordering* difference and not a different ring, so it is a parameter on this type rather than a
    /// seventh component; the alternative, reordering the `VStack` for everyone, would move the five
    /// screens that are already right.
    ///
    /// **Ordering is not only cosmetic here.** The label sits on the chord `sqrt(innerRadius² − dy²)`
    /// where `dy` is its own lower edge below the ring's centre, so moving it *up* widens the chord it
    /// has to fit and can only relieve the overflow `labelScale` documents — it cannot introduce one.
    /// For a caller that has already narrowed its label, this is free clearance.
    public var labelFirst: Bool = false
    public var lineWidth: CGFloat = 14
    public var size: CGFloat = 140

    public init(
        progress: Double,
        scoreText: String,
        label: String,
        ringColor: Color,
        labelColor: Color = Theme.textSecondary,
        labelScale: CGFloat = 0.09,
        labelFirst: Bool = false,
        lineWidth: CGFloat = 14,
        size: CGFloat = 140
    ) {
        self.progress = max(0.0, min(1.0, progress))
        self.scoreText = scoreText
        self.label = label
        self.ringColor = ringColor
        self.labelColor = labelColor
        self.labelScale = labelScale
        self.labelFirst = labelFirst
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
                if labelFirst { labelText }

                Text(scoreText)
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)

                if !labelFirst { labelText }
            }
        }
        .frame(width: size, height: size)
    }

    /// The label, drawn either above or below the score — see `labelFirst`. One definition rather
    /// than two branches of the `VStack`, so the two positions cannot drift apart in type, tracking
    /// or colour.
    private var labelText: some View {
        Text(label.uppercased())
            .font(.system(size: size * labelScale, weight: .semibold, design: .rounded))
            .foregroundColor(labelColor)
            .tracking(1.2)
            // A label long enough to carry its own line break — the sleep detail page's
            // `SLEEP` over `PERFORMANCE` — would otherwise centre the block and left-align
            // the lines inside it, which reads as a mistake rather than as two lines.
            .multilineTextAlignment(.center)
    }
}
