import SwiftUI

/// One night's within-sleep stress: the share of it spent highly activated, the trace that share was
/// taken from, and how the scored span divided across the three bands.
///
/// ## Where this sits, and why it is the page's last card
///
/// `SleepTypicalRangeCard`'s sibling one card down. That card divides the night by **sleep stage**;
/// this one divides the same night by **activation**, which is the second of the two questions WHOOP
/// asks of a night and the one the daytime Stress Monitor cannot answer — see `SleepStressNight` for
/// why `StressMath.wakingWindow` excludes sleep and what that leaves unmeasured.
///
/// ## The headline is the high band's share, and there is no comparison under it
///
/// The reference's own arithmetic settles the first half: its `MEDIUM + HIGH` would be `20%` where the
/// card shows `0%`, and its headline matches its `HIGH 0%` row exactly. So the figure the card leads
/// with is the high band's own percent, stated twice — once large, once as the first row — which is the
/// same doubling `SleepDetailView` already carries for sleep performance and for the same reason (the
/// reference composes a card around the figure it leads with).
///
/// **There is deliberately no "vs. your typical night" under it**, and the absence is the honest
/// answer rather than a missing feature. A share's baseline would have to be each prior night's own
/// high-band share, and a night's share needs *that* night's score, which needs its own fourteen-night
/// baseline — the recursion does not close. Scoring prior nights against tonight's baseline instead
/// would produce a number that looks plausible and means nothing, which is the fabrication this app's
/// absence rules exist to prevent. `baselineNightCount` is printed in words at the foot of the card
/// instead, so a reader can see how much history the score above it rests on.
///
/// ## Every word is decided outside the `body`
///
/// The spoken strings are `nonisolated` statics rather than text built in a `body`, for the reason
/// `Tests/WhoopsyTestRunner` §15 records: the runner that tests this app has no renderer, so a string
/// built inside a `body` is a string nothing can assert. The chart is a `Shape` and says nothing to
/// VoiceOver, and each row announces itself.
public struct SleepStressCard: View {

    /// The night to draw. Carries its own span, its windows and its band breakdown.
    public let night: SleepStressNight

    public init(night: SleepStressNight) {
        self.night = night
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading

            // Built from the night rather than handed in, so the chart and the figures above it cannot
            // come to describe two different window sets — the failure `SleepStressNight.span` exists
            // to make unrepresentable. `nil` is unreachable through `SleepStressNight.init`, which
            // refuses an empty window list and a reversed span; a night that somehow had neither would
            // draw its figures with no trace under them, which is the honest degradation rather than a
            // flat line at zero.
            if let series = SleepStressChartSeries(night: night) {
                SleepStressChartView(series: series)
                    .padding(.bottom, 16)
            }

            divider

            ForEach(night.bands, id: \.band) { bandRow($0) }

            footnote
        }
        .glassCard()
    }

    // MARK: - The heading

    /// `SLEEP STRESS`, the denominator the three shares below are of, and the headline figure.
    ///
    /// **The denominator is named and printed, and that is what makes the percentages readable.**
    /// `SleepStressNight`'s shares divide the time this model could *score* rather than the night, and
    /// on a real night the two differ by a large fraction — every window the strap was moving through
    /// or the R-R series could not support is in neither. `SCORED` over `formattedCompactHoursMinutes`
    /// is the same shape `SleepTypicalRangeCard` gives its own `DURATION`, and for the same reason: a
    /// column of percentages over a total nothing names is a column a reader has to guess the base of.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionLabel("Sleep stress")

                Text("SCORED")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)

                Text(night.scoredSeconds.formattedCompactHoursMinutes())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }

            if let highPercent = night.highPercent {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(highPercent)%")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(StressMath.Band.high.color)
                        .monospacedDigit()

                    Text("HIGH")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.top, 12)
            }
        }
        .padding(.bottom, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spokenHeading(night: night)))
    }

    // MARK: - One band

    /// A band's name, its share and its duration, and the bar that draws the share.
    ///
    /// The layout is `SleepTypicalRangeCard.stageRow`'s, deliberately: the name, then the share in the
    /// band's colour tying the figure to the bar beneath it, then the duration as the row's
    /// right-aligned figure. Two cards on one screen printing a share over a bar should be read the
    /// same way, and a second arrangement would make a reader learn the same row twice.
    ///
    /// **The name is `StressMath.Band.rawValue`** — `HIGH`, `MEDIUM`, `LOW` — and that vocabulary is
    /// not shared with anything else on this page. The band legend above keys `SleepBand`, whose three
    /// names are `Poor`/`Sufficient`/`Optimal` and whose colours are three other tokens; the two are
    /// told apart by their words first and their colours second, which is why a reader cannot carry a
    /// reading from one to the other by matching a green.
    private func bandRow(_ summary: SleepStressNight.BandSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Circle()
                    .fill(summary.band.color)
                    .frame(width: 10, height: 10)

                Text(summary.band.rawValue.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text("\(summary.percent)%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(summary.band.color)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Text(summary.durationSeconds.formattedCompactHoursMinutes())
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }

            SleepStressShareBar(band: summary.band, percent: summary.percent)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenBandRow(summary))
    }

    // MARK: - The footer

    /// The history the night's score was read against, in words.
    ///
    /// **A low band and not a comparison**, which is the one place this card's footer parts from
    /// `SleepTypicalRangeCard`'s: that one has a prior-window mean to print, and this one has none —
    /// see the type's doc comment for why a share cannot be baselined. `baselineNightCount` alone is
    /// still worth printing, because it is the difference between a `0%` read against three nights and
    /// the same `0%` read against fourteen.
    private var footnote: some View {
        Text(Self.baselineNote(baselineNightCount: night.baselineNightCount))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .padding(.top, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
    }

    // MARK: - The card's words

    /// The card's title, its denominator, and the headline figure — one statement.
    ///
    /// The duration is spoken through `formattedHoursMinutes()` and not the compact form the header
    /// prints, on `SleepTypicalRangeCard.spokenStageRow`'s rule: `0:30` read aloud is a colon, and the
    /// spoken form has to name its units.
    public nonisolated static func spokenHeading(night: SleepStressNight) -> String {
        let scored = night.scoredSeconds.formattedHoursMinutes()
        guard let highPercent = night.highPercent else {
            return "Sleep stress, \(scored) scored"
        }
        return "Sleep stress, \(highPercent) percent of the scored night in the high band, "
            + "\(scored) scored"
    }

    /// One band's row.
    ///
    /// **The share is spoken as a share of the scored night and not of the night**, which the visual
    /// row leaves to context. A listener has no bar to see and no header above them at the moment the
    /// row is read, so the denominator has to be in the sentence.
    public nonisolated static func spokenBandRow(_ summary: SleepStressNight.BandSummary) -> String {
        "\(summary.band.rawValue), \(summary.percent) percent of the scored night, "
            + summary.durationSeconds.formattedHoursMinutes()
    }

    /// How much history the score rests on.
    ///
    /// Singular at one, which is unreachable — the use case refuses a night below
    /// `StressMath.minimumBaselineDays` — and stated anyway so that a reader of this file does not have
    /// to hold that invariant to know what the sentence says at every input.
    public nonisolated static func baselineNote(baselineNightCount: Int) -> String {
        baselineNightCount == 1
            ? "Baseline: 1 prior night"
            : "Baseline: \(baselineNightCount) prior nights"
    }
}
