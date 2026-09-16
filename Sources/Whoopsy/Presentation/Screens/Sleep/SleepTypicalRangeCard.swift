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
/// band mark and the footer loses its comparison rather than the card disappearing.
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

    /// A key to the box, then `TYPICAL RANGE` on the left and the night's total on the right.
    ///
    /// The duration is labelled `DURATION` rather than left bare because it is a **total** and not one
    /// of the four figures beneath it: it is the sum of the column, and the percentages are shares of
    /// it. Unlabelled it would read as a fifth reading.
    ///
    /// `SectionLabel` carries `frame(maxWidth: .infinity, alignment: .leading)` of its own, which is
    /// what pushes the pair to the right and holds the two ends of the row apart without a `Spacer`.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            bandGlyph

            SectionLabel("Typical range")

            Text("DURATION")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)

            Text(summary.durationSeconds.formattedCompactHoursMinutes())
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .padding(.bottom, 16)
    }

    /// The key to the band mark the four bars below draw.
    ///
    /// **It is a legend and not decoration.** The mark is a filled span bounded by two dashed rules,
    /// which is a shape this screen invented, and a mark with no key is as likely to read as arbitrary
    /// as it is to read as a range — which is exactly the state the two bare dashed lines it replaced
    /// were in. It is built from `Theme.bandMarkFill` and `BandEdges`, the same two pieces the bars
    /// draw, so the key cannot come to depict a mark the bars no longer make; a hand-drawn miniature
    /// would have been a second copy to keep in step.
    ///
    /// **It is a small square of the mark itself rather than a bar with the mark on it**, which is what
    /// it used to be — a capsule of `ringTrack` with a dashed rounded box inset inside it. That glyph
    /// described a *bar*, and a key has to describe the *mark*: a reader looking up the grey block on
    /// the third row wants to find the same grey block in the header, not a bar that happens to contain
    /// one. The reference's own key is this shape, at this size.
    ///
    /// The baseline guide puts the glyph's bottom edge on the text baseline, which is where a small
    /// mark beside a word belongs. Without it a view carrying no text of its own aligns by its centre
    /// in a `.firstTextBaseline` stack and sits slightly low.
    private var bandGlyph: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.bandMarkFill)

            BandEdges(inset: 0.75)
                .stroke(
                    Theme.bandMarkEdge,
                    style: StrokeStyle(lineWidth: 1.5, dash: TypicalRangeBar.markDash))
        }
        .frame(width: 16, height: 16)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityHidden(true)
    }

    // MARK: - One stage

    /// A stage's name, its share and its duration, and the bar that draws the share against its band.
    ///
    /// The label is `SleepStageType.rawValue` — so the third row reads `DEEP / SWS` — rather than the
    /// reference's `SWS (DEEP)`. One vocabulary for the four stages matters more than matching the
    /// reference's wording: the hypnogram's own legend above this card prints the same raw string, and
    /// a card that renamed a stage would make a reader match two names to one colour.
    ///
    /// **The share sits immediately after the stage name; the duration is the column.** That is the
    /// reference's order, and it is the one that reads: the share is a property *of the stage named
    /// beside it*, while the duration is the fourth figure in a right-aligned column whose header is
    /// the card's own `DURATION`. This card used to right-align the two together, which puts a number
    /// the row is about at the opposite end of the row from the word it belongs to. The duration keeps
    /// a fixed width because the four of them are a column and `0:48` and `4:03` are different widths.
    ///
    /// The share is in the stage's colour, tying the figure to the bar beneath it and to the legend
    /// above; the duration is in `textPrimary` and set larger than anything else in the row, because it
    /// is the figure the row is *about* — the share beside it is a proportion of the whole and needs
    /// the duration to mean anything.
    ///
    /// **The marker is a large hollow ring in white, and neither of those is free.** It was a small
    /// ring in the stage's colour, on the argument that the ring is the leftmost thing on the row and
    /// the only place a stage colour is stated without a word beside it — so a neutral one would break
    /// the chain a reader follows from the ring to the share to the bar. That argument is real and it
    /// lost to a stronger one: **the ring is not a key to the colour, it is a mark on the scale.** Its
    /// left edge sits on the bar's own left edge — the two are at the same `x` on every row — so the
    /// ring column and the four tracks beneath it line up as one grid, and a stage-coloured ring is a
    /// fifth coloured thing competing with the bar directly below it. The stage colour still reaches
    /// the row twice, in the share and in the bar, which is enough for the chain to hold.
    private func stageRow(_ row: SleepStageRangeScoring.Row) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Circle()
                    .strokeBorder(Theme.textPrimary, lineWidth: 3.5)
                    .frame(width: 34, height: 34)

                Text(row.stage.rawValue.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text("\(row.percent)%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(row.stage.color)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Text(row.seconds.formattedCompactHoursMinutes())
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }

            TypicalRangeBar(
                stage: row.stage,
                layout: TypicalRangeBarLayout(percent: row.percent, typical: row.typical))
        }
        .padding(.vertical, 12)
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

        // Centre-aligned, unlike the four rows above: this one's right-hand side is two lines tall and
        // its left-hand side is one, and a legend centred against the pair reads as belonging to both
        // of them. Top-aligning would hang the swatch and the words off the bigger figure.
        return HStack(alignment: .center, spacing: 11) {
            restorativeSwatch

            Text("RESTORATIVE SLEEP")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            // The comparison is **two lines, not one**, and the pair is read down rather than across.
            // A row printing `2:46 ▼ 3:17` on one line at one weight reads as three facts of equal
            // standing; stacked, the night's own figure carries the row and the mean is what it is
            // being read against — which is the relationship `MetricChange` computes and the row above
            // the divider draws with a band. The glyph stays on the first line because it is a
            // verdict on the figure beside it.
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text(current.formattedCompactHoursMinutes())
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()

                    if let change {
                        Image(systemName: change.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(change.color)
                            .accessibilityHidden(true)
                    }
                }

                if let change {
                    Text(change.previousText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.top, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenRestorativeRow(seconds: current, typicalSeconds: typical))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
            .padding(.top, 16)
    }

    /// The two stages this row sums, each on its own side of a diagonal.
    ///
    /// **A split square rather than a solid one.** Restorative sleep is `deep + rem`: a solid square in
    /// either stage's colour would claim the row *is* that stage, which is the specific claim
    /// `SleepStageType.color` exists to keep off the four rows above, where each colour means exactly
    /// one stage. The two halves say what the row is, using the same two tokens the bars do.
    ///
    /// **The split runs corner to corner and the stages are in the reference's order** — `rem` in the
    /// upper-left triangle, `deep` in the lower-right — so the swatch is a key to the figures above it
    /// rather than a second arrangement to learn. It was a horizontal half-and-half at 8pt; at 16pt a
    /// diagonal reads as a single object with two parts where a vertical seam reads as two rectangles
    /// that happen to touch, which is the difference between a swatch and a pair of chips.
    ///
    /// It is 16pt where the rings above are 34, and that is not an inconsistency: a ring is a mark *on*
    /// a row, one per stage, while this is a legend for a sum of two of them and sits beside a word
    /// that says so.
    private var restorativeSwatch: some View {
        ZStack {
            Rectangle().fill(SleepStageType.rem.color)

            DiagonalHalf()
                .fill(SleepStageType.deep.color)
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - What a listener hears

    /// One stage row, as one sentence.
    ///
    /// **The band is spoken and not drawn-only.** The four shares are coloured numbers on a bar with
    /// a dashed box, and neither the colour nor the box has a spoken form — so a listener who is told
    /// only the share is told a figure with nothing to read it against, which is the half of the row
    /// that answers the card's actual question. When there is no band the sentence says so rather than
    /// falling silent, because "we could not say what is typical for you yet" is an answer and a
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

/// The lower-right half of whatever rect it is given, cut corner to corner.
///
/// It is the half the footer's swatch paints over the other, which is how a square comes to hold two
/// colours without a seam down the middle: the caller fills the whole rect with one stage's colour and
/// lays this over it in the other, so the two halves meet on the diagonal rather than at an edge and
/// the mark reads as one object. Drawing the two triangles separately would work and would be two
/// shapes to keep in step.
///
/// The cut runs from `(maxX, minY)` to `(minX, maxY)` — top-right to bottom-left — which puts the
/// **upper-left** triangle in the colour beneath and the **lower-right** in the one this fills. That
/// orientation is the reference's, and it is the one that keeps the deeper of the two stage colours on
/// the diagonal's lower side, where the eye reads it against the card rather than against the other
/// half.
struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
