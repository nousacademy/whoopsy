import SwiftUI

/// A card's headline figure, with the value it moved against on the line beneath it and the marker
/// that says which way it went.
///
/// **It was `SleepDetailView.hoursOfSleepHeadline` and is lifted here because a second card on the same
/// screen draws it.** The need card's `81%` over `80%` and the hours-of-sleep card's `7:33` over its
/// window mean are the same object twice — same sizes, same marker, same three-state comparison — and a
/// copy is two places for a font size or an arrow size to drift, on one screen, where a reader would
/// see the disagreement side by side.
///
/// **The comparison is passed in rather than built here**, because building it needs the `formatted`
/// closure that decides what "these two print alike" means — and that decision is per-quantity, not
/// per-card. `MetricChange.between` is the only thing that makes it, and each caller hands it the
/// formatter its own figure is drawn with.
///
/// `nil` prints the figure alone, and there are two reasons a caller passes it. The first is a **missing
/// side** and not a zero: `MetricChange.between` returns `nil` on a window too thin for a mean, so a card
/// cannot print one it does not have. The second is a **deliberate absence** — `SleepConsistencyCard`
/// passes `nil` on a card whose mean exists, because the comparison it would draw is a second figure
/// under a headline that already sits above a chart making the same point. `nil` is the only way to say
/// either, which is why this type takes the comparison rather than deciding for itself whether to draw
/// one.
public struct MetricHeadline: View {
    /// The figure, already formatted the way the card prints it.
    public let text: String

    /// The comparison, or `nil` when there is nothing to compare against.
    public let change: MetricChange?

    public init(text: String, change: MetricChange?) {
        self.text = text
        self.change = change
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()

                // Drawn whenever there is a comparison, including the `.same` verdict — that case is a
                // dot rather than an absent arrow, which is `MetricChange`'s own rule.
                if let change {
                    Image(systemName: change.symbolName)
                        .font(.system(size: change.direction == nil ? 7 : 11))
                        .foregroundStyle(change.color)
                }
            }

            if let change {
                Text(change.previousText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
        }
    }
}
