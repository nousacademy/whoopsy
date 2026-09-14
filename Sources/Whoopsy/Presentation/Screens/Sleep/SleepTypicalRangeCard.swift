import SwiftUI

/// The night's four stages against what is typical for this user, and the two restorative stages
/// summed against their own mean.
///
/// It is the last card on the sleep detail screen, below the band legend, and it answers the question
/// the three rows above it do not: not *how much* the user slept but *how* — the shape of the night,
/// and whether that shape is the user's own or an unusual one.
///
/// **The whole card is absent when there is no night, and that gate is at the call site.** This type
/// takes a built `Summary`, not an optional, on `SleepBandBar`'s reasoning: there is no rendering of
/// four zero-percent rows that is honest, so a view that could draw one should not be able to. A
/// window too thin for a band is a *different* state and this card does draw it — the shares and
/// durations are real readings, and only the bands are withheld, which is why the bars lose their
/// dashed markers and the footer loses its comparison rather than the card disappearing.
///
/// **The four percentages are whole and sum to exactly 100**, by
/// `SleepStageRangeScoring.wholePercents(ofSeconds:)` and not by anything here. That matters because
/// the card prints `DURATION` above the column those percentages divide: a column summing to 99 or 101
/// would contradict the figure at the top of its own card.
///
/// **Every word on it is decided outside the body.** `spokenStageRow` and `spokenRestorativeRow` are
/// public statics and the numbers come from the `Summary`, so the strings a listener hears are
/// asserted in the suite rather than left to a screenshot — the repo's rule that a rule written into a
/// `View` is a rule nothing here can assert, and the runner has no renderer.
public struct SleepTypicalRangeCard: View {

    /// The night and its window, already resolved. See `SleepStageRangeScoring.summary(for:priorNights:)`.
    public let summary: SleepStageRangeScoring.Summary

    public init(summary: SleepStageRangeScoring.Summary) {
        self.summary = summary
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            ForEach(summary.rows) { row in
                stageRow(row)
            }

            divider

            restorativeRow
        }
        .glassCard()
    }

    // MARK: - The header

    /// `TYPICAL RANGE` on the left and the night's total on the right.
    ///
    /// The duration is labelled `DURATION` rather than left bare because it is a **total** and not one
    /// of the four figures beneath it: it is the sum of the column, and the percentages are shares of
    /// it. Unlabelled it would read as a fifth reading.
    ///
    /// `SectionLabel` carries `frame(maxWidth: .infinity, alignment: .leading)` of its own, which is
    /// what pushes the pair to the right and holds the two ends of the row apart without a `Spacer`.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SectionLabel("Typical range")

            Text("DURATION")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)

            Text(summary.durationSeconds.formattedCompactHoursMinutes())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .padding(.bottom, 12)
    }

    // MARK: - One stage

    /// A stage's name, its share, its duration, and the bar that draws the share against its band.
    ///
    /// The label is `SleepStageType.rawValue` — so the third row reads `DEEP / SWS` — rather than the
    /// reference's `SWS (DEEP)`. One vocabulary for the four stages matters more than matching the
    /// reference's wording: the hypnogram's own legend above this card prints the same raw string, and
    /// a card that renamed a stage would make a reader match two names to one colour.
    ///
    /// **The share and the duration are two fixed-width columns**, which is what makes the four rows
    /// scannable: `10%` and `5%` are different widths and a leading-aligned column would step. The
    /// share is in the stage's colour, tying the figure to the bar beneath it and to the legend above;
    /// the duration is muted, because it is the figure the reference de-emphasises and the share is
    /// what the band is read on.
    private func stageRow(_ row: SleepStageRangeScoring.Row) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.stage.color)
                    .frame(width: 7, height: 7)

                Text(row.stage.rawValue.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(row.percent)%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(row.stage.color)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Text(row.seconds.formattedCompactHoursMinutes())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            TypicalRangeBar(
                stage: row.stage,
                layout: TypicalRangeBarLayout(percent: row.percent, typical: row.typical))
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenStageRow(row))
    }

    // MARK: - The footer

    /// Deep plus REM against the window's own mean of the same sum.
    ///
    /// **It carries no bar, deliberately**, and the asymmetry with the four rows above it is the point:
    /// those draw a *share of this night* on a 0–100% track, and restorative sleep is a *duration* — a
    /// sum of two stages, on a different denominator, that no 0–100% scale describes. A band for it
    /// would be a second kind of mark on one card, which is how a reader comes to compare two things
    /// that are not comparable. It prints a figure and its mean, which is exactly what
    /// `MetricChange` was built to draw.
    ///
    /// `higherIsBetter: true`, and that is a real judgement rather than a default: SWS and REM are the
    /// two stages the sleep literature associates with restoration, which is why WHOOP groups them and
    /// why this app does not put the same marker on the four rows above, where a larger share of any
    /// one stage is not better news.
    ///
    /// **A `nil` mean prints the figure with no marker**, never a `0` — `MetricChange.between` returns
    /// `nil` on a missing side for exactly this, so a window too thin to produce a mean yields a bare
    /// duration rather than a comparison against nothing. The unit is `formattedCompactHoursMinutes`,
    /// matching the four rows and the header.
    private var restorativeRow: some View {
        let current = summary.restorativeSeconds
        let typical = summary.typicalRestorativeSeconds
        let change = MetricChange.between(
            current: current,
            previous: typical,
            higherIsBetter: true,
            formatted: { $0.formattedCompactHoursMinutes() })

        return HStack(spacing: 8) {
            Text("RESTORATIVE SLEEP")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Text(current.formattedCompactHoursMinutes())
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()

            if let change {
                Image(systemName: change.symbolName)
                    .font(.system(size: 9))
                    .foregroundStyle(change.color)
                    .accessibilityHidden(true)

                Text(change.previousText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
        }
        .padding(.top, 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenRestorativeRow(seconds: current, typicalSeconds: typical))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    // MARK: - What a listener hears

    /// One stage row, as one sentence.
    ///
    /// **The band is spoken and not drawn-only.** The four shares are coloured numbers on a bar with
    /// two dashed marks, and neither the colour nor the marks have a spoken form — so a listener who is
    /// told only the share is told a figure with nothing to read it against, which is the half of the
    /// row that answers the card's actual question. When there is no band the sentence says so rather
    /// than falling silent, because "we could not say what is typical for you yet" is an answer and a
    /// missing clause reads as an omission.
    ///
    /// The durations are spoken through `formattedHoursMinutes()` and not the compact form that is
    /// printed: `4:03` on screen is a clock reading to VoiceOver, and `4h 3m` is a duration. That
    /// distinction is why both formatters exist.
    ///
    /// `nonisolated` because the `View` conformance puts the whole type on the main actor, and these
    /// two are strings built from a `Sendable` value and read by nothing on screen. The suite calls
    /// them from a plain `Task` — an assertion that had to hop to the main actor would be a test of
    /// the concurrency system rather than of the sentence a listener hears.
    public nonisolated static func spokenStageRow(_ row: SleepStageRangeScoring.Row) -> String {
        var spoken = "\(row.stage.rawValue), \(row.percent) percent of the night, "
            + row.seconds.formattedHoursMinutes()
        if let typical = row.typical {
            spoken += ", typical \(Int(typical.lowPercent.rounded()))"
                + " to \(Int(typical.highPercent.rounded())) percent"
        } else {
            spoken += ", no typical range yet"
        }
        return spoken
    }

    /// The footer, as one sentence — including the comparison when there is one.
    ///
    /// The word for the second figure is `typical`, not `average`: every other row on this card is read
    /// against a range, and calling one figure on it an average would suggest the four rows above are
    /// averages too.
    public nonisolated static func spokenRestorativeRow(
        seconds: TimeInterval, typicalSeconds: TimeInterval?
    ) -> String {
        let spoken = "Restorative sleep, \(seconds.formattedHoursMinutes())"
        guard let typicalSeconds else { return spoken + ", no typical range yet" }
        return spoken + ", typical \(typicalSeconds.formattedHoursMinutes())"
    }
}
