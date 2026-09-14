import SwiftUI

/// One night's sleep figures, with no navigation container of its own.
///
/// It is `RecoveryDetailView`'s counterpart and follows it deliberately: the day is handed in as a
/// plain `let`, there is no stepper and no calendar, `viewModel.load(for:)` runs in a `.task`, and the
/// page is a ring over a breakdown over a key. Like that screen it owns no `NavigationStack` of its
/// own, because it is pushed rather than presented: Home's sleep ring is its only entry point, and
/// that push happens inside Home's own stack.
///
/// **It is the sleep *performance* page, and the reference calls it that.** The ring prints
/// `sleepPerformancePercentage` — asleep over need — which is exactly the figure Home's sleep ring
/// prints, so tapping a 55% ring opens a ring that still says 55%. The `HOURS VS. NEEDED` row beneath
/// it prints the same digits, and the duplication is the honest state of an app that has one sleep
/// figure where the reference's app has two: WHOOP's ring is a composite of performance, consistency,
/// efficiency and respiratory rate, and this app does not reproduce that composite. It prints the
/// figure it has rather than inventing a second one to put under the same word.
///
/// **The rows are three readings, and one more on a day that had a nap.** Hours vs. Needed, Sleep
/// Consistency and Sleep Efficiency are percentages and each take a band from `SleepBand`. `NAP` is
/// the fourth, drawn **only on the eight days in the export that have one**, because an absent nap is
/// not a nap of unknown length: the read returns an empty array, and a `—` in that position would
/// claim the app looked for a nap and could not measure it. It carries a duration and no band — WHOOP
/// publishes no boundary for a nap — which is what `Figure`'s `.plain` case is for, and it exists to
/// keep "measured but unbanded" from collapsing into "not measured".
///
/// **Two rows and a caption this screen used to carry are gone, and the reference never had them.**
/// `RESPIRATORY RATE` and `SLEEP DEBT` printed `SleepSession.respiratoryRate` and `.sleepDebtSeconds`;
/// `HIGH SLEEP STRESS` printed nothing at all, and `stressCaption` under the card explained that no
/// path here produces that reading. **Removing the rows removed readers, not producers** — both
/// columns are still written, by `RespiratoryRateMath` and `SleepDebtMath` on the strap path and by
/// the import verbatim — and the two are not in the same position afterwards. The respiratory rate
/// keeps a screen without this one: `CalculateRecoveryUseCase` passes it onto the `recoveries` row,
/// which the Recovery detail page draws. The sleep debt does not, so **`sleeps.sleep_debt` is now a
/// stored value that no screen shows**. Recorded here rather than left to be found, because it reads
/// like an oversight and is not one.
///
/// **The page ends with a fourth element: the typical-range card.** Four stage rows, each printing
/// tonight's share and duration over a bar that marks the band that share is normally in, and a footer
/// summing the two restorative stages against the window's mean of the same sum. It is
/// `SleepStageRangeScoring`'s output drawn — the window, the quartiles and the whole-percent column are
/// all decided there, so nothing on this page computes a share or a boundary. The band is in
/// **percentage points of the night**, not the minutes WHOOP quotes its own REM range in, because the
/// bar's scale is 0–100% and a band in minutes could not be drawn on it. The card is absent, not empty,
/// on a night with no sleep period, and it draws bars without markers when the window held fewer than
/// `RecoveryScoring.minimumBaselineDays` nights.
///
/// **Two elements of the reference are omitted, for the reasons `RecoveryDetailView` gives.** The
/// WHOOP wordmark is another company's brand in the one position that says whose app this is, and the
/// `i` button beside the ring has no destination — a control that looks tappable and is not reads as
/// broken.
///
/// **One element the recovery screen does not have is kept: a line naming the night.** The reference
/// puts it above the ring and this screen follows that. `RecoveryDetailView` has nothing above its
/// ring because the only candidate was the screen's own name, which the reader had just tapped;
/// a date is not the screen's name. It is the parameter the screen was pushed with, it appears
/// nowhere else on the page — this screen has no comparison badge to carry it, because it has no
/// trailing window — and without it a push from an imported day shows three figures for no stated
/// night. The string is `DayBarRules.label(for:)`, which is the app's existing answer to "which day is
/// this" and already prints `TODAY` where that is the honest word.
public struct SleepDetailView: View {
    @State private var viewModel: SleepViewModel

    /// The night shown, fixed for the life of the view. A plain `let` for `RecoveryDetailView`'s
    /// reason: nothing here can change it, so nothing should be able to.
    private let date: Date

    public init(viewModel: SleepViewModel, date: Date) {
        _viewModel = State(initialValue: viewModel)
        self.date = date
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                dateLabel

                ring

                breakdownCard

                bandLegend

                typicalRangeCard
            }
            .padding()
        }
        .background(Theme.backgroundDark)
        .task { await viewModel.load(for: date) }
        .preferredColorScheme(.dark)
    }

    // MARK: - The night, and the window it is read over

    /// The day, and the window the typical-range card at the foot of the page reads it against.
    ///
    /// **The second line is the card's own caption, moved up here.** The card compares four shares and
    /// a total with the user's own recent nights, and a comparison with no stated baseline is a figure
    /// a reader has to take on trust — which night, out of how many. The reference puts the window
    /// beside the day at the top and this follows it: the two together are the sentence "this night,
    /// against these others", and neither half means much alone.
    ///
    /// **The window is read off `RecoveryScoring.baselineWindowDays`, never typed as `30`.** It is the
    /// same constant `baselineWindow(before:in:)` caps the window with, so the caption cannot come to
    /// describe a window the bands below were not taken over. `RecoveryDetailView.comparisonBadge`
    /// builds the identical string for the identical reason, and this is deliberately the same wording
    /// rather than a second phrasing for one idea.
    ///
    /// One thing the caption cannot carry at this length, and it is the same caveat that badge records:
    /// the window is the last thirty days **that have rows**, so on a gappy history it reaches further
    /// back than thirty calendar days. "last 30 days" is the honest short form and is not a claim that
    /// the thirty are contiguous.
    ///
    /// It is announced as one sentence, because two `Text` views read in sequence make a listener hold
    /// the day while the window arrives separately.
    private var dateLabel: some View {
        VStack(spacing: 3) {
            Text(DayBarRules.label(for: date))
                .font(.system(size: 12, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.textSecondary)

            Text("vs. last \(RecoveryScoring.baselineWindowDays) days")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "\(DayBarRules.label(for: date)), compared with the last "
                    + "\(RecoveryScoring.baselineWindowDays) days"))
    }

    // MARK: - The typical range

    /// The night's four stages against the user's own recent nights, or nothing.
    ///
    /// **The gate is here and not inside the card**, following the ring's own band bar: a card that
    /// could draw four `0%` rows would be a picture of a night that was not measured, so the type that
    /// draws it takes a built summary and cannot be handed an absent one. A thin window is a different
    /// state and *is* drawn — see `SleepViewModel.stageSummary`.
    ///
    /// It sits below `bandLegend` on the user's instruction, and that order is also the only one that
    /// makes sense of the two: the legend explains the three bands the card's rows above it are
    /// coloured by, and a key belongs after the things it keys.
    private var typicalRangeCard: some View {
        Group {
            if let summary = viewModel.stageSummary {
                SleepTypicalRangeCard(summary: summary)
            }
        }
    }

    // MARK: - The ring

    /// The night's performance, with the three-segment band bar in its lower interior.
    ///
    /// **The bar is an overlay on this ring and not a change to `GaugeRingView`.** That component is
    /// drawn by Strain, Sleep, Recovery and the workout HUD; a fifth parameter on it would move four
    /// other screens to place one segment bar, which is the reasoning that gave Home `MetricRingView`
    /// rather than a bent `GaugeRingView`. As an overlay it is inside the ring's lower interior
    /// without any of those four knowing it exists.
    ///
    /// The `30` is a placement, not a measurement: the ring is 190pt across with an 18pt stroke, so its
    /// inner edge at that height is about 44pt from the centre line and a 62pt bar leaves margin on
    /// both sides. It sits below the score and label, which are centred. A compile cannot check any of
    /// that — this is the one thing on the screen that only looking verifies.
    private var ring: some View {
        GaugeRingView(
            progress: gaugeProgress,
            scoreText: gaugeText,
            label: gaugeLabel,
            ringColor: Theme.sleepPerformance,
            // The one caller that passes a label colour, and the only one whose label is two lines.
            // Both come from the reference, which prints `SLEEP` over `PERFORMANCE` at full strength
            // under the score rather than in the muted grey every other ring's one-word label takes.
            labelColor: Theme.textPrimary,
            lineWidth: 18,
            size: 190)
        .overlay(alignment: .bottom) {
            // No band, no bar. A bar with nothing lit would be a picture of the scale with no reading
            // on it, which is the same fabrication a `0` would be.
            if let band = ringBand {
                SleepBandBar(band: band).padding(.bottom, 30)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - The breakdown

    /// The night's three readings, plus a nap on a day that had one.
    ///
    /// **The rows are not `RecoveryDetailView.breakdownRow`.** That row prints a day's figure over a
    /// trailing 30-day mean with a `MetricChange` marker between them, which is what the recovery
    /// screen is for; these rows print a value and nothing else, coloured by where it sits on its own
    /// band. Sharing the row would mean sharing neither behaviour. What **is** shared is the discipline
    /// it is built on: the value is an optional, the dash is `—`, and there is no `?? 0` in this file.
    ///
    /// The order is Hours vs. Needed, Sleep Consistency, Sleep Efficiency, then the nap when there is
    /// one. The first three each carry a band and between them use all three of the legend's swatches.
    private var breakdownCard: some View {
        VStack(spacing: 0) {
            breakdownRow(label: "HOURS VS. NEEDED", figure: hoursVsNeeded.map { .banded($0, .hoursVsNeeded) })

            divider

            breakdownRow(label: "SLEEP CONSISTENCY", figure: sleepConsistency.map { .banded($0, .consistency) })

            divider

            breakdownRow(label: "SLEEP EFFICIENCY", figure: sleepEfficiency.map { .banded($0, .efficiency) })

            // Drawn **only on a day the user actually napped** — 918 rows in the export's sleeps
            // file, eight of them naps, and this app has no other way to show one. The row is absent
            // rather than dashed, because an absent nap is not a nap of unknown length: the read
            // returns an empty array, and `—` in that position would claim the app looked for a nap
            // and could not measure it. That is the same distinction the four metrics draw between a
            // missing row and a stored placeholder, one level up.
            if let nap {
                divider

                breakdownRow(label: "NAP", figure: nap)
            }
        }
        .glassCard()
        // The reference's notched card: a caret on the top edge pointing up at the ring, which is the
        // one element that ties the four rows to the figure they explain. Drawn as an overlay on the
        // finished card so it sits over the card's stroke, which is what makes it read as a notch
        // rather than as a shape resting on a line. `Theme.cardBackground` is the card's own fill —
        // the modifier's — so the two composite to the same colour over the page background.
        .overlay(alignment: .top) {
            CardNotch()
                .fill(Theme.cardBackground)
                .frame(width: 20, height: 9)
                .offset(y: -9)
        }
    }

    /// A row's figure, and the fact that it is one.
    ///
    /// **The two cases exist because three of these rows are percentages on a band scale and one is
    /// not, and the difference is not cosmetic.** A nap is a measured duration with no published
    /// anchor to band it against — WHOOP publishes boundaries for sufficiency and consistency and none
    /// at all for this — so inventing a Poor / Sufficient / Optimal scale for it would be a
    /// calibration dressed as a measurement. What it *is* is measured, which is exactly what `.plain`
    /// says and what decides its colour: a measured figure drawn in `Theme.textMuted` would be
    /// indistinguishable from the dash, and a reader would take a real reading for an absence.
    ///
    /// `.plain` has carried more rows than it does now — the respiratory rate and the sleep debt were
    /// unbanded readings through it before those rows were removed — so it is not the nap's own shape.
    /// It is the shape of any measured row here that has no scale.
    private enum Figure {
        /// A percentage, read against its own scale. The band decides both the colour and the spoken
        /// form.
        case banded(Int, SleepBand.Metric)
        /// A measured figure with no band, already formatted, with the words to read it aloud as.
        case plain(text: String, spoken: String)

        /// The band this figure fell in, or `nil` when it is not a banded one.
        var band: SleepBand? {
            guard case .banded(let value, let metric) = self else { return nil }
            return SleepBand.band(for: Double(value), metric: metric)
        }

        var text: String {
            switch self {
            case .banded(let value, _): return "\(value)%"
            case .plain(let text, _): return text
            }
        }

        var color: Color {
            // A banded figure with no band is not reachable — `band` is non-nil for every `.banded` —
            // but the fallback is `textPrimary` rather than muted so that a future fourth case could
            // not turn a measured value into a dash by omission.
            band?.color ?? Theme.textPrimary
        }

        var spoken: String {
            switch self {
            case .banded(let value, _):
                guard let band else { return "\(value) percent" }
                return "\(value) percent, \(band.displayName)"
            case .plain(_, let spoken): return spoken
            }
        }
    }

    /// One row: a name on the left, the night's figure on the right in its own colour.
    ///
    /// **`metric` used to be what made a value a band, and its absence used to mean "no value".** That
    /// conflated two different rows: `HIGH SLEEP STRESS`, which carried no figure at all, and the
    /// measured-but-unbanded rows, which have figures and no *scale*. `Figure` separates them — `nil`
    /// is the dash, `.plain` is a reading with no band — and `SleepBand.band(for:metric:)` remains the
    /// one place any boundary is decided. The stress row is gone, so nothing here draws a dash by
    /// construction any more, but `nil` is still reached the ordinary way: a night with no session
    /// dashes all three banded rows at once.
    private func breakdownRow(label: String, figure: Figure?) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Text(figure?.text ?? dash)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(figure?.color ?? Theme.textMuted)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowDescription(label: label, figure: figure))
    }

    /// One row, one announcement. The colour is the only thing that says which band a figure fell in,
    /// and a colour has no spoken form, so the band is named — and a figure with no band is read with
    /// its own unit instead, which `.plain` carries.
    private func rowDescription(label: String, figure: Figure?) -> String {
        guard let figure else { return "\(label), no measurement" }
        return "\(label), \(figure.spoken)"
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
    }

    // MARK: - The key

    /// The three bands and their colours: the key to the three coloured values above.
    ///
    /// It is three-for-three with `SleepBand.allCases`, read from the cases rather than listed, so a
    /// fourth band could not be drawn on the card without appearing here.
    ///
    /// **The swatch is a segment of `SleepBandBar`, not a dot, and that is what makes it a key.** The
    /// bar inside the ring is three rounded segments and it is the thing this legend explains, so the
    /// legend's swatches are drawn in the same shape at the same height — a circle beside the word
    /// "Poor" would be a second visual language for one scale, and a reader matching the key to the
    /// bar above it would be matching a dot to a dash. The width is the one difference, and it is
    /// deliberate: 24pt against the bar's 18pt, because these sit beside text rather than inside a
    /// 190pt ring and the extra length is what makes the colour legible at this size.
    ///
    /// **It is a colour key and carries no direction.** Unlike `RecoveryDetailView`'s two-triangle key,
    /// which is a partial key to a three-state verdict, this one is complete: every band a row can draw
    /// has a swatch. What it deliberately does not say is that a higher figure is better than a lower
    /// one for a *different* row — the three scales are separate, and "Optimal" on one is not
    /// comparable to "Optimal" on another.
    private var bandLegend: some View {
        HStack(spacing: 0) {
            ForEach(SleepBand.allCases) { band in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(band.color)
                        .frame(width: 24, height: 6)
                        .accessibilityHidden(true)

                    Text(band.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Bands, from lowest to highest: "
                + SleepBand.allCases.map(\.displayName).joined(separator: ", "))
    }

    // MARK: - The night's figures

    private var dash: String { "—" }
    private var hasNight: Bool { viewModel.session != nil }

    /// Asleep over need. The ring's figure and the `HOURS VS. NEEDED` row's, deliberately — see the
    /// type's doc comment for why they are the same number.
    ///
    /// No gate beyond the optional: an unclassifiable night has no row at all, so `viewModel.session`
    /// being `nil` is the whole absence rule, exactly as it is on Home's sleep ring.
    private var hoursVsNeeded: Int? { viewModel.session.map(\.sleepPerformancePercentage) }

    /// Asleep over the sleep period. Same absence rule.
    private var sleepEfficiency: Int? { viewModel.session.map(\.sleepEfficiencyPercentage) }

    /// The stored figure for an imported night, else one computed from the night and its four
    /// predecessors, else `nil` — resolved in `SleepViewModel`, which owns the second repository read
    /// that the computed case costs.
    private var sleepConsistency: Int? { viewModel.sleepConsistency }

    /// The day's nap, when there was one.
    ///
    /// `viewModel.naps` is an array because a day can hold several, and this takes the first: the card
    /// is a list of one figure per row, and rendering three naps as three rows would make a row count
    /// that varies by more than one. A day with two naps shows the first — which is a real limitation
    /// and is why the accessor is named for what it does rather than for what the array holds.
    private var nap: Figure? {
        guard let first = viewModel.naps.first else { return nil }
        let minutes = Int((first.asleepSeconds / 60).rounded())
        return .plain(text: "\(minutes) min", spoken: "\(minutes) minutes asleep")
    }

    /// The band the ring's own figure fell in, which the segment bar lights. `nil` on a night with no
    /// figure, which is also when the bar is not drawn.
    private var ringBand: SleepBand? {
        guard let value = hoursVsNeeded else { return nil }
        return SleepBand.band(for: Double(value), metric: .hoursVsNeeded)
    }

    private var gaugeProgress: Double {
        hasNight ? Double(hoursVsNeeded ?? 0) / 100 : 0
    }

    private var gaugeText: String {
        guard let value = hoursVsNeeded else { return dash }
        return "\(value)%"
    }

    /// Two lines, and that is the whole of the difference from every other ring's label.
    ///
    /// `GaugeRingView` uppercases what it is handed, so the string here is in title case and the screen
    /// reads `SLEEP` over `PERFORMANCE` — the reference's own line break, which is what keeps a word
    /// this long from being shrunk to fit the ring's inner width on one line. A newline in a label is
    /// not something the component was built for, so the centring it needs is a line of its own there;
    /// see `GaugeRingView.multilineTextAlignment`.
    private var gaugeLabel: String { hasNight ? "Sleep\nPerformance" : "No data" }
}

/// The caret on the breakdown card's top edge. A shape rather than an `Image`, so it takes the card's
/// own fill and cannot come to be drawn in a colour the card is not.
private struct CardNotch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
