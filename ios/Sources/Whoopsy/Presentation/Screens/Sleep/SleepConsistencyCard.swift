import SwiftUI

/// The night's Sleep Consistency: the figure, and the five nights it was read against drawn on a
/// clock.
///
/// **It is the reference's `SLEEP CONSISTENCY` card, and the chart is the card's subject.** The
/// figure at the top is the same one the breakdown row prints two elements up the page; what this
/// card adds is *why* — the four nights the score was read against, the night itself in the accent
/// colour, and the two rules their average draws. That is the whole reason the window is five nights
/// and not a week: `SleepConsistencyMath` reads a night against its four predecessors, so these five
/// columns **are** the model's own window, and a reader can check the rule against the bars by eye in
/// a way no other arrangement of this chart allows. `SleepConsistencyScoring` carries the argument.
///
/// **The legend says `AVG` where the reference says `OPTIMAL`, and that is a correction rather than a
/// preference.** Nothing in this app produces a recommendation: there is no circadian-phase model and
/// no sleep-need-derived target in any column, so what the two rules are is the average of the same
/// four nights the score already reads. WHOOP's word for the pair is a claim about what the user
/// *should* do, and this app cannot make it — the same judgement that keeps the estimate on Home's
/// VO₂ panel labelled `(EST.)`. `SleepConsistencyMath.typicalBoundaries` is where the arithmetic and
/// the reasoning both live.
///
/// **The `i` button is not drawn.** It is the reference's, it has no destination here, and a control
/// that looks tappable and is not reads as broken — the same judgement that omits it beside the ring
/// at the top of this page and beside `HOURS OF SLEEP` above.
///
/// **The card is gated at the call site on `SleepViewModel.consistencySummary`, which is `nil` below
/// four prior nights.** That is `SleepConsistencyMath`'s own gate forwarded, and on this screen it
/// means a night with nothing to compare against draws no card at all rather than a chart with a
/// rule over four empty columns — the same absence rule the typical-range card takes one element up.
/// It costs nothing: the figure the card would have headed itself with is already on the breakdown row
/// above, so no reading is hidden by the card being absent.
public struct SleepConsistencyCard: View {
    /// The five nights, the two rules, the figure and its window mean.
    public let summary: SleepConsistencyScoring.Summary

    public init(summary: SleepConsistencyScoring.Summary) {
        self.summary = summary
    }

    /// The card's title, which is the reference's own and is also the name of the breakdown row above.
    ///
    /// The three statics in this block are `nonisolated` for the reason
    /// `SleepTypicalRangeCard.spokenStageRow` records: the `View` conformance puts the whole type on
    /// the main actor, and these are strings built from a `Sendable` value and read by nothing on
    /// screen. The suite calls them from a plain `Task`, and an assertion that had to hop to the main
    /// actor would be a test of the concurrency system rather than of the words on the card.
    public nonisolated static let title = "Sleep Consistency"

    /// What the two dashed rules are, under the chart that draws them.
    ///
    /// `AVG` and not the reference's `OPTIMAL` — see the type's doc comment. It is a `static` so the
    /// suite can assert the word rather than a screenshot, because the word is the correction.
    public nonisolated static let legendLabel = "Avg Bed/Waketime"

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(Self.title)

            headline

            if let layout = SleepConsistencyChartLayout(summary: summary) {
                SleepConsistencyChartView(layout: layout)

                legend
            }
        }
        .glassCard()
        // The chart is a `Shape` and says nothing to VoiceOver, so the card is announced as one
        // element — the same treatment `SleepNeedCard` and `hoursOfSleepCard` take.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(for: summary)))
    }

    // MARK: - The figure

    /// The night's consistency, in `MetricHeadline`'s shape, with no comparison beneath it.
    ///
    /// **`nil` is passed rather than a `MetricChange`**, so the card prints the figure alone. What that
    /// withholds is the pair `MetricHeadline` draws for a comparison — a marker beside the figure and
    /// the value it moved against on the line below — not the mean itself, which is still computed.
    ///
    /// **The mean keeps a reader, and it is `spoken(for:)`.** That is the only place the window mean now
    /// reaches anyone, so removing that sentence too would leave `SleepConsistencyScoring.typicalScore`,
    /// `Summary.typicalScore` and the assertions the suite pins that function with all computed for
    /// nothing. A listener gets the comparison a sighted reader no longer does.
    ///
    /// **The mean is not the two dashed rules, and the difference matters if either is ever moved.**
    /// The rules are the four priors' average bedtime and waketime, taken over the model's own
    /// four-night window; the mean is an average of *stored percentages* over the 30-day comparison
    /// window. They are two different quantities answering two different questions, so a later reader
    /// restoring a figure to this card has to say which of them they mean — and a figure put back here
    /// as a second headline would be the mean, not the rules.
    private var headline: some View {
        MetricHeadline(text: "\(summary.score)%", change: nil)
    }

    // MARK: - The key to the rules

    /// A dashed swatch and the words for what the rules are.
    ///
    /// **The swatch is drawn with the rules' own colour and dash rather than a picture of them**, so
    /// the key and the thing it keys cannot drift: `TypicalRangeBar.markDash` and `Theme.bandMarkEdge`
    /// are the two values both read, and this legend is their third reader. It is a short rule and not
    /// a filled bar, because a bar is what the chart's five columns are and a key drawn as a sixth one
    /// would read as a night.
    private var legend: some View {
        HStack(spacing: 8) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 24, y: 1))
            }
            .stroke(
                Theme.bandMarkEdge,
                style: StrokeStyle(lineWidth: 1.5, dash: TypicalRangeBar.markDash))
            .frame(width: 24, height: 2)
            .accessibilityHidden(true)

            Text(Self.legendLabel.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - The card in one sentence

    /// The figure, what it moved against, the night's own two boundaries, then the rules.
    ///
    /// **The night's boundaries are spoken because the chart cannot be.** A listener hears five columns
    /// as one sentence or not at all, so the description gives the anchor — the column the card is
    /// about — and then the two averages, which are the comparison the chart exists to draw. Reading
    /// out all five nights would be a listener's version of counting the bars; naming the night and the
    /// rules is the listener's version of looking at them.
    ///
    /// **The times come back through `clockText`, not through arithmetic here**, so the spoken onset
    /// and the callout on the rule are the same conversion — a listener and a reader comparing notes
    /// would otherwise be comparing two frames.
    ///
    /// It is a `static` rather than a computed property on the view, on the rule the rest of this
    /// repo's cards follow: this suite has no renderer, so text built inside a `body` is text nothing
    /// can assert. `nonisolated` for the reason `title` above records.
    public nonisolated static func spoken(for summary: SleepConsistencyScoring.Summary) -> String {
        var spoken = "\(title), \(summary.score) percent"
        if let typical = summary.typicalScore {
            spoken += ", typical \(Int(typical.rounded())) percent"
        } else {
            spoken += ", no typical range yet"
        }

        if let anchor = summary.bars.last(where: \.isAnchor) {
            spoken += ". That night, "
                + "\(SleepConsistencyChartLayout.clockText(forNightClockMinutes: anchor.onsetMinutes))"
                + " to "
                + "\(SleepConsistencyChartLayout.clockText(forNightClockMinutes: anchor.wakeMinutes))"
        }

        let priorCount = max(0, summary.bars.count - 1)
        let nights = priorCount == 1 ? "1 night" : "\(priorCount) nights"
        return spoken + ". Average bedtime "
            + "\(SleepConsistencyChartLayout.clockText(forNightClockMinutes: summary.typicalOnsetMinutes))"
            + ", average waketime "
            + "\(SleepConsistencyChartLayout.clockText(forNightClockMinutes: summary.typicalWakeMinutes))"
            + ", over the \(nights) before it."
    }
}
