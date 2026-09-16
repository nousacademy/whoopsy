import SwiftUI

/// The night's Sleep Need: the hours slept drawn against it, and the need split into the parts the
/// stored data can source.
///
/// **It is the reference's `HOURS VS. NEEDED` card, and it draws two parts where the reference draws
/// three.** The reference's box under its need figure reads `Healthy Minimum`, `Recent Strain` and
/// `Sleep Debt`; the bundled export carries the debt and nothing else, so this card's box reads
/// `Healthy Minimum + Recent Strain` and `Sleep Debt`. `SleepNeedBreakdown` carries the whole argument
/// — including the measurement (`need = 427.5 + 4.05 × strain + 0.98 × debt`) that establishes the
/// stored debt as an additive component at face value — and it is the reason the first row is named for
/// two of WHOOP's terms rather than for one of them.
///
/// **The two bars share an origin and a scale, and they are the card's actual subject.** The sleep bar
/// spans `asleep / need` of the need bar, which is the same ratio as the percentage printed above them,
/// so the picture cannot contradict the figure. `SleepNeedBarLayout` holds that rule and documents why
/// the scale is the night's own rather than a fixed maximum.
///
/// **Three of the reference's elements are omitted or changed, each for a reason this app has recorded
/// elsewhere.** Its `i` button has no destination, and a control that looks tappable and is not reads as
/// broken — the same judgement that omits the `i` beside the ring. Its box's first row is split in two,
/// because the two figures are not in this data. And its `81%` is drawn over its own prior-30-day mean,
/// which the reference takes over a window it does not state; this card takes the mean over
/// `RecoveryScoring.baselineWindow(before:in:)`, the same window every other "typical" figure on this
/// screen uses, so this card and the typical-range card below it cannot come to disagree about how much
/// history a baseline needs.
///
/// **The card is gated on `hasNight` at the call site**, like the hours-of-sleep card and the heading.
/// A day with no night would otherwise draw a need of `—` over two empty bars, which is a picture of a
/// night rather than the absence of one.
public struct SleepNeedCard: View {
    /// The night's hours of sleep — `SleepSession.totalTimeAsleepSeconds`.
    public let asleepSeconds: TimeInterval

    /// The night's need, and the figure the parts below it are parts of.
    public let needSeconds: TimeInterval

    /// The split, or `nil` when the stored row supports none. See `SleepNeedBreakdown.breakdown`.
    public let breakdown: SleepNeedBreakdown.Breakdown?

    /// Asleep over need, the figure the ring and the breakdown row both print.
    public let performancePercent: Int

    /// The window's mean performance, or `nil` below `RecoveryScoring.minimumBaselineDays`.
    public let typicalPerformancePercent: Double?

    public init(
        asleepSeconds: TimeInterval,
        needSeconds: TimeInterval,
        breakdown: SleepNeedBreakdown.Breakdown?,
        performancePercent: Int,
        typicalPerformancePercent: Double?
    ) {
        self.asleepSeconds = asleepSeconds
        self.needSeconds = needSeconds
        self.breakdown = breakdown
        self.performancePercent = performancePercent
        self.typicalPerformancePercent = typicalPerformancePercent
    }

    /// The card's title, which is the reference's own and is the name of the comparison it draws.
    ///
    /// **The breakdown card has a row of the same name and the screen prints the figure twice**, on the
    /// user's instruction. That is not new to this screen: the ring and the breakdown row already print
    /// the same percentage, and the type's doc comment records why — this app has one sleep figure where
    /// the reference has a composite of four, and it prints the figure it has rather than inventing a
    /// second one to put under the same word.
    public static let title = "Hours vs. Needed"

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(Self.title)

            headline

            if let layout {
                VStack(alignment: .leading, spacing: 7) {
                    measureRow(label: Self.asleepLabel, value: asleepSeconds.formattedCompactHoursMinutes())

                    SleepNeedBar(fraction: layout.asleepFraction, color: Theme.sleepPerformance)

                    // Only when there is a split to draw. An unsplit need bar would need a colour
                    // meaning "the whole need", which is a third colour this card does not have — and
                    // drawing it in either component's colour would claim the need was made of that
                    // component alone.
                    if !layout.segments.isEmpty {
                        SleepNeedStackedBar(layout: layout)
                    }

                    measureRow(label: Self.needLabel, value: needSeconds.formattedCompactHoursMinutes())
                }
            }

            if let breakdown {
                breakdownWell(breakdown)
            }
        }
        .glassCard()
        // The bars are `GeometryReader`s and say nothing to VoiceOver, so the card is announced as one
        // element — the same treatment the hours-of-sleep card takes, and for the same reason.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    // MARK: - The figure

    /// The night's performance over its own window mean, in `MetricHeadline`'s shape.
    ///
    /// **The comparison is made on the printed percentages and not on the durations**, which is
    /// `MetricChange`'s own rule and matters here: `81%` over a mean of `80.6%` prints as `81` over
    /// `81`, and a marker pointing between two figures a reader can see are equal is a row contradicting
    /// itself.
    ///
    /// **`higherIsBetter: true`**, the same judgement the hours-of-sleep headline makes one card below:
    /// a night that met more of its need is the better night.
    private var headline: some View {
        let change = MetricChange.between(
            current: Double(performancePercent),
            previous: typicalPerformancePercent,
            higherIsBetter: true,
            formatted: { "\(Int($0.rounded()))%" })

        return MetricHeadline(text: "\(performancePercent)%", change: change)
    }

    // MARK: - The two measures

    /// The label and figure pair the reference prints above and below its bars.
    ///
    /// The value is at the size the reference draws it — larger than the label beside it — and the label
    /// carries the same uppercase-and-tracked treatment `SectionLabel` uses, so a reader can tell the
    /// two rows apart from the card's own title without reading them.
    private func measureRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
    }

    // MARK: - The split

    /// The recessed box listing the need's parts, notched at its top edge toward the figure it explains.
    ///
    /// **Notched rather than plain**, because the box is below both bars and its subject is the *need*
    /// figure printed directly above it — the notch is the only thing on the card that says which of the
    /// two numbers the box is about. It is the same mark the breakdown card uses to point at the ring,
    /// drawn at the trailing edge instead of the centre because that is where the figure it points at
    /// sits.
    private func breakdownWell(_ breakdown: SleepNeedBreakdown.Breakdown) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(breakdown.parts.enumerated()), id: \.element.id) { index, part in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.textMuted.opacity(0.15))
                        .frame(height: 1)
                }
                partRow(part)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.sleepNeedWell)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            CardNotch()
                .fill(Theme.sleepNeedWell)
                .frame(width: 18, height: 8)
                .offset(x: -30, y: -8)
        }
    }

    /// One part: its swatch, its name, and its figure — signed when it is an increment.
    ///
    /// The swatch is the same colour its segment is drawn in, through
    /// `SleepNeedBreakdown.Component.color`, so the box is a key to the bar above it rather than a
    /// second colour scheme. It is a rounded square and not a bar segment, because the segments are
    /// drawn on the need's own scale and a zero-length part — a night in perfect sleep credit — would be
    /// an invisible key to a visible colour.
    private func partRow(_ part: SleepNeedBreakdown.Part) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(part.component.color)
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)

            Text(part.component.displayName)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Text(
                part.component.isIncrement
                    ? part.seconds.formattedSignedCompactHoursMinutes()
                    : part.seconds.formattedCompactHoursMinutes()
            )
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .monospacedDigit()
        }
        .padding(.vertical, 7)
    }

    // MARK: - The night's figures

    private var layout: SleepNeedBarLayout? {
        SleepNeedBarLayout(
            asleepSeconds: asleepSeconds,
            needSeconds: needSeconds,
            parts: breakdown?.parts ?? [])
    }

    private static let asleepLabel = "Hours of sleep"
    private static let needLabel = "Sleep needed"

    /// The card in one sentence: the figure, its comparison, the two durations, then the split.
    ///
    /// **The durations are spoken through `formattedHoursMinutes()` and not the compact form printed**,
    /// on `SleepTypicalRangeCard.spokenStageRow`'s rule: `7:33` on screen is a clock reading to a
    /// listener, and `7h 33m` is a duration. The split is read after the figure it is a split of, so a
    /// listener hears what the parts are parts of before hearing them.
    private var spoken: String {
        var spoken = "\(Self.title), \(performancePercent) percent"
        if let typical = typicalPerformancePercent {
            spoken += ", typical \(Int(typical.rounded())) percent"
        }

        spoken += ". \(Self.asleepLabel), \(asleepSeconds.formattedHoursMinutes())"
        spoken += ". \(Self.needLabel), \(needSeconds.formattedHoursMinutes())"

        guard let breakdown else {
            return spoken + ". The need's breakdown was not recorded for this night."
        }
        let parts = breakdown.parts.map { part -> String in
            let seconds = part.seconds.formattedHoursMinutes()
            return part.component.isIncrement
                ? "\(part.component.displayName), plus \(seconds)"
                : "\(part.component.displayName), \(seconds)"
        }
        return spoken + ". Need breakdown, " + parts.joined(separator: "; ")
    }
}
