import SwiftUI

/// One day's strain, drawn as the ring alone, with no navigation container of its own.
///
/// **It is not the Strain tab.** The tab is `StrainDashboardView` — a separate screen with its own
/// `NavigationStack`, a day stepper, an average/peak heart-rate pair, the zone breakdown and a
/// target-strain slider. This page is reached from Home's strain ring and is pushed onto the stack
/// Home already owns. The two share no definition, which is the arrangement
/// `SleepDetailView`/`SleepDashboardView` already established, and it is the one that lets the tab
/// keep its four other elements: folding them in here would have meant deleting them, and the
/// Recovery tab is the only screen in this app where the tab and the push *are* one view.
///
/// **The shape is `RecoveryDetailView`'s**, because the push route is the same. No `NavigationStack`
/// — the pushing screen supplies the chrome. The day is a plain `let` rather than `@State`: nothing
/// here can change it, so a re-render of Home behind the push cannot move it. And the ring is drawn
/// **bare, not on a card**, because the ring is the screen's subject and a card around it would make
/// the one element that is not a reading look like the readings `RecoveryDetailView` stacks below its
/// own.
///
/// **The ring is `Theme.strainRing`, the blue Home draws, and not `Theme.strainPrimary`**, the orange
/// the Strain tab's gauge uses. The two are different tokens for a reason: this page is the
/// destination of Home's blue ring, so a reader who just tapped a blue arc arrives at a blue arc,
/// while the tab is a separate screen with a palette of its own.
///
/// **Nothing is drawn above the ring, and the reference's header is the reason there is nothing
/// there.** That header names the day and carries a WHOOP wordmark and an `i` button; none of the
/// three is drawn here. A heading restating the day would spend the top of the screen on the tap the
/// reader just made — the day *is* the one they tapped, because Home's push carries it. The wordmark
/// is another company's brand sitting in the one position on a screen that says whose app this is,
/// which is the judgement `RecoveryDetailView` records. And the `i` button is omitted for the reason
/// every other inert control in this app is: it has no destination, and a control that looks tappable
/// and is not reads as broken.
///
/// **The day is handed in all the same, because the ring has to load it.** It is read by
/// `load(for:)` and rendered nowhere — so tapping a 4.6 ring on a past day opens that day rather than
/// today, which is the whole defect the push route exists to avoid.
public struct StrainDetailView: View {
    @State private var viewModel: StrainViewModel

    /// The day shown, fixed for the life of the view and drawn nowhere.
    ///
    /// A plain `let` for the reason `RecoveryDetailView`'s is, and with the same consequence: a change
    /// to whatever day Home is showing behind the push cannot move it.
    private let date: Date

    public init(viewModel: StrainViewModel, date: Date) {
        _viewModel = State(initialValue: viewModel)
        self.date = date
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GaugeRingView(
                    progress: gaugeProgress,
                    scoreText: gaugeText,
                    label: gaugeLabel,
                    ringColor: gaugeColor,
                    lineWidth: 18,
                    size: 190)
                .padding(.vertical, 4)

                // **Absent, not empty, on a day with no workout.** The four rows describe a workout,
                // so there is nothing for them to say on a day that had none — and a card of four
                // dashes would read as a panel that failed to load rather than as an ordinary rest
                // day. `comparisonBadge` is gated with it, because the window it names is the window
                // the rows above it are read against.
                if !viewModel.workouts.isEmpty {
                    activityCard

                    comparisonBadge
                }
            }
            .padding()
        }
        // Load-bearing, and the two sibling pages do not need it. `ScrollView` falls back to its
        // content's ideal width when nothing in it is flexible, and this page's only element is a
        // fixed-size ring — so without this the scroll view is 190pt plus padding wide and
        // `.background` below paints a centred column with the window's black either side of it.
        // `RecoveryDetailView` and `SleepDetailView` escape it only because their content is cards,
        // which are `.frame(maxWidth: .infinity)` and so make the ideal width flexible. Measured on
        // the simulator: 666px of 1206 at 3x, exactly the ring plus the stack's padding.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .task { await viewModel.load(for: date) }
        .preferredColorScheme(.dark)
    }

    // MARK: - The day's figures
    //
    // These four are `StrainDashboardView`'s rules restated, not a second opinion about them: the two
    // screens are deliberately separate definitions (see above), and the difference between them is
    // the ring's colour and nothing else. A change to one is a change to both.

    /// A day the strap recorded nothing for stores no row at all, so `nil` is the ordinary case — but
    /// `hasMeasurement` is the gate regardless, because rows written by an older build hold `0.0` with
    /// the flag clear, and `strain != nil` is true for those and a measured zero-strain day alike. The
    /// flag is the only thing that separates them, and a ring reading `0.0` would state the opposite
    /// of what an unmeasured day is.
    private var hasStrain: Bool { viewModel.strain?.hasMeasurement == true }
    private var dash: String { "—" }
    private var gaugeProgress: Double { hasStrain ? (viewModel.strain?.score ?? 0) / 21 : 0 }
    private var gaugeText: String { hasStrain ? (viewModel.strain?.score ?? 0).formattedOneDecimal() : dash }

    /// `STRAIN` on a measured day, `NO DATA` on an absent one — the gauge uppercases its label, and
    /// the absent form is where a reader looks for the score, so the no-data state is not lost by
    /// having no heading above the ring.
    private var gaugeLabel: String { hasStrain ? "Strain" : "No data" }

    /// One token, and there is no tier to pick between. Recovery's ring is drawn in the day's tier
    /// because `RecoveryState` defines green/yellow/red over its 0–100 scale; a strain is read on a
    /// 0–21 Borg scale with no equivalent bands anywhere in this app, so the arc is the strain token
    /// on every measured day. The grey is the same one the Strain tab draws on an absent day.
    private var gaugeColor: Color { hasStrain ? Theme.strainRing : Theme.textSecondary }

    // MARK: - The activity panel

    /// The four activity rows the reference draws under the ring, with the day's comparison above
    /// them.
    ///
    /// **The card is absent on a day with no workout**, which is the user's rule rather than a
    /// layout choice: these rows describe a workout, and a card of four dashes under a ring would be
    /// a panel that failed to load rather than a day with nothing to say. `viewModel.workouts` is
    /// what decides it, and the rows are drawn only when the day has one.
    ///
    /// **Three rows have a producer and one does not, and the three have two different ones.** That
    /// distinction is the whole design of this card, so it is worth stating per row:
    ///
    /// * `HEART RATE ZONES 1-3` and `4-5`. These are WHOOP's own `HR Zone n %` figures for the day's
    ///   workouts, out of the bundled `workouts.csv`, scaled by each workout's own span. They are
    ///   **WHOOP's measurements, not this app's**: the export carries no heart-rate series for
    ///   `StrainAccumulatorMath` to integrate, `biometric_samples` holds no rows here, and the drain's
    ///   type-24 heart-rate record has no reader — so there is no path by which this app could compute
    ///   a zone from a heart rate it measured. `StrainScore.zones` is still computed and still
    ///   dropped at the write (see `GRDBStrainRepository`), and it is deliberately **not** read here:
    ///   that array exists for today alone, so drawing it would show a real figure on today and a dash
    ///   on every past day, the same quantity answered two ways with nothing on screen to say why.
    /// * `STEPS`. The one row this app measured itself: the strap's own accelerometer, decoded from
    ///   live or drained motion and stored one row per day in `stepCounts`. It is read through
    ///   `StepCount.measuredStepCount`, so a measured day of no walking is a real `0` and a day the
    ///   strap was not worn is `nil`. **It is `nil` on every day this machine can currently show** —
    ///   no database here holds a `stepCounts` row, and the export carries no steps at all — so the
    ///   figure the reference draws on this row is unreachable without a strap. It is a day-level
    ///   quantity sitting inside a workout-level card, which is why a rest day with steps measured
    ///   shows no step figure: `viewModel.workouts` gates the whole card.
    /// * `STRENGTH ACTIVITY TIME`. There is no such quantity anywhere in this app and **no column for
    ///   it in any of the four CSVs** — no strength detection, no per-activity-type duration. It is a
    ///   dash for a stated reason rather than by omission. The reference's `ACTIVITY TIME` row was the
    ///   same search and has been replaced by `STEPS`, which has a producer.
    ///
    /// **All four rows are drawn rather than the unproducible one being hidden**, which is the
    /// reference's shape and the honest one: a dash is a statement that the day has no reading here,
    /// and hiding the row would leave a reader unable to tell that from a feature this app lacks.
    /// Nothing about it costs a column or a computation — it is a literal at the call site.
    ///
    /// **Every row carries a leading glyph, and they are bare.** The reference draws them that way, so
    /// the icon is `HomeDashboardView.metricPanel`'s convention — 15pt semibold, `Theme.textMuted`, a
    /// 38×38 frame, no background — and **not** the tinted chip that screen's activities list uses.
    /// Two things about the glyphs are worth knowing before changing them. The reference's zone mark
    /// is a heart outline with a pulse through it and **SF Symbols ships no such symbol**;
    /// `waveform.path.ecg` is the pulse it draws, and it is already the symbol Home's HRV panel uses.
    /// And the symbol is passed at the call site rather than derived from the label, because the label
    /// is a display string: a row renamed would lose its icon with nothing to say why.
    private var activityCard: some View {
        VStack(spacing: 0) {
            activityRow(
                symbol: "waveform.path.ecg",
                label: "HEART RATE ZONES 1-3",
                value: viewModel.zoneTime?.zone1to3Seconds,
                baseline: zone1to3Baseline,
                higherIsBetter: true,
                format: Self.formatDuration)

            divider

            activityRow(
                symbol: "waveform.path.ecg",
                label: "HEART RATE ZONES 4-5",
                value: viewModel.zoneTime?.zone4to5Seconds,
                baseline: zone4to5Baseline,
                higherIsBetter: true,
                format: Self.formatDuration)

            divider

            activityRow(
                symbol: "dumbbell.fill",
                label: "STRENGTH ACTIVITY TIME",
                value: nil,
                baseline: nil,
                higherIsBetter: true,
                format: Self.formatDuration)

            divider

            activityRow(
                symbol: "shoe",
                label: "STEPS",
                value: viewModel.steps.map(Double.init),
                baseline: stepsBaseline.map(Double.init),
                higherIsBetter: true,
                format: Self.format)
        }
        .glassCard()
    }

    /// One activity row: a name, the day's figure, a marker, and the window's mean.
    ///
    /// **Laid out as a row of figures rather than as `RecoveryDetailView`'s stacked pair**, because the
    /// reference draws the two numbers side by side and this card has four rows to the recovery card's
    /// four — a second line under each would double the card's height to say the same thing.
    ///
    /// **The value is a `Double?` and the row takes its formatter**, because this card holds two kinds
    /// of quantity: a count and a duration. The zone rows are seconds and print as `0:12`; the step
    /// row is a count and prints as `5,049`; the one unproduced row is a dash and prints as nothing at
    /// all, so its formatter never runs. That widening is *toward* the existing design rather than
    /// away from it — `Self.format`'s doc comment already says the `Int` goes through the `Double` one
    /// rather than around it, and this row is where that happens.
    ///
    /// **The marker comes from `MetricChange.between` and the row never picks a colour itself.** That
    /// is the shared type's whole purpose: it decouples the glyph — which always points the way the
    /// number went — from the colour, which is the verdict `higherIsBetter` decides. The zone rows are
    /// read with `higherIsBetter: true`, which is a statement about the comparison and not about
    /// health: a reader comparing today against their own average expects a rise to be the good
    /// direction, and this app makes no claim that more time in zone 4 is better for any particular
    /// person.
    ///
    /// A row with no figure draws a dash and **no marker at all** — `MetricChange`'s `nil` is reserved
    /// for a missing side, and a marker beside a dash would be a comparison of nothing. An unproduced
    /// row carries no baseline either, so its second slot is a dash rather than an empty space: on this
    /// card the reader is comparing two columns down four rows, and a blank would read as a rendering
    /// fault rather than as an absence.
    private func activityRow(
        symbol: String,
        label: String,
        value: Double?,
        baseline: Double?,
        higherIsBetter: Bool,
        format: (Double) -> String
    ) -> some View {
        let marker = MetricChange.between(
            current: value,
            previous: baseline,
            higherIsBetter: higherIsBetter,
            formatted: format)

        return HStack(spacing: 10) {
            // `HomeDashboardView.metricPanel`'s icon, restated rather than shared: the two live in
            // different screens and this one is 38pt tall to that row's 38. Its colour is fixed at
            // `Theme.textMuted`, the way that helper's is — it does not follow the label into
            // `textPrimary` on a row that has a figure, because on this card the figure's own colour
            // is what marks a row as measured and a second element changing with it dilutes that.
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(value == nil ? Theme.textMuted : Theme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Text(value.map(format) ?? dash)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(value == nil ? Theme.textMuted : Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let marker {
                Image(systemName: marker.symbolName)
                    .font(.system(size: 9))
                    .foregroundStyle(marker.color)
                    .accessibilityHidden(true)
            }

            Text(baseline.map(format) ?? dash)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            activityDescription(
                label: label, value: value, baseline: baseline, marker: marker, format: format))
    }

    /// The count formatter, and it is the row's **only** one: the step row's `Int` is widened to
    /// `Double` at the call site rather than given a second formatter of its own.
    ///
    /// That is load-bearing rather than tidy. `MetricChange.between` decides "the same" by comparing
    /// the two strings its `formatted` closure produces, so a row that printed its value through a
    /// second formatter would be comparing text the reader is not looking at — the exact defect the
    /// type's own doc comment describes. One closure, one set of digits, both columns.
    private static func format(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// The zone rows' formatter: seconds as `0:12`.
    ///
    /// **The value is rounded once, here, and both columns go through this same closure** — which is
    /// what keeps a value and a baseline a second apart from printing as `0:12` over `0:12` with a
    /// marker beside them, the contradiction `MetricChange`'s formatted comparison exists to prevent.
    /// Rounding to whole minutes is honest at this scale: the figure is WHOOP's own percentage of a
    /// workout's span, so its resolution is minutes at best and a printed `0:12:04` would claim four
    /// digits of precision the producer never had.
    private static func formatDuration(_ seconds: Double) -> String {
        seconds.rounded().formattedCompactHoursMinutes()
    }

    /// One row, one announcement. The marker is a glyph and a colour, and neither reaches VoiceOver —
    /// so the verdict is spelled out, and it is the **verdict** rather than the direction, for the
    /// reason `RecoveryDetailView.rowDescription` gives.
    ///
    /// **A dashed row takes the first branch, and it is the same sentence the recovery screen's rows
    /// use for an absent value.** The wording deliberately omits the unit: a row that said "HEART RATE
    /// ZONES 1-3, no measurement", one that said "STRENGTH ACTIVITY TIME, no measurement" and one that
    /// said "STEPS, no measurement" are all saying the only true thing about that row, which is that
    /// nothing produced a figure for it. Naming the unit would not add anything a reader could act on
    /// — the row's own label is already announced ahead of it.
    private func activityDescription(
        label: String,
        value: Double?,
        baseline: Double?,
        marker: MetricChange?,
        format: (Double) -> String
    ) -> String {
        guard let value else { return "\(label), no measurement" }
        let figure = format(value)
        guard let marker else {
            guard let baseline else { return "\(label), \(figure)" }
            return "\(label), \(figure), against an average of \(format(baseline))"
        }
        let average = marker.previousText
        switch marker.verdict {
        case .better: return "\(label), \(figure), better than the average of \(average)"
        case .same: return "\(label), \(figure), the same as the average of \(average)"
        case .worse: return "\(label), \(figure), worse than the average of \(average)"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
    }

    /// The window's mean zone time, withheld unless the day above it is itself a reading.
    ///
    /// A mean drawn against a dash would be context for a comparison that is not being made, and the
    /// row's own marker is already absent in that case. `viewModel.zone1to3Baseline` is `nil` below
    /// `RecoveryScoring.minimumBaselineDays` days carrying zone data; this adds only the second
    /// condition, so a day whose workouts carry no zone block shows two dashes rather than a figure
    /// it cannot be compared against.
    private var zone1to3Baseline: Double? {
        guard viewModel.zoneTime != nil else { return nil }
        return viewModel.zone1to3Baseline
    }

    private var zone4to5Baseline: Double? {
        guard viewModel.zoneTime != nil else { return nil }
        return viewModel.zone4to5Baseline
    }

    /// The window's mean step count, withheld unless the day above it is itself a reading.
    ///
    /// The same guard as the two above and for the same reason: a mean drawn against a dash is context
    /// for a comparison that is not being made. `viewModel.stepsBaseline` is `nil` below
    /// `RecoveryScoring.minimumBaselineDays` measured days; this adds only the second condition, so a
    /// day the strap was not worn draws two dashes rather than a figure it cannot be compared against.
    private var stepsBaseline: Int? {
        guard viewModel.steps != nil else { return nil }
        return viewModel.stepsBaseline
    }

    // MARK: - The comparison badge

    /// The day and the window the figures above it are read over — `RecoveryDetailView`'s caption,
    /// with steps in place of the four recovery rows.
    ///
    /// **The window is read off `RecoveryScoring.baselineWindowDays` rather than typed as `30`**, for
    /// the reason that screen's own badge gives: it is the constant the window is capped with, so a
    /// change there cannot leave this caption describing a window the mean above it was not taken
    /// over. And as there, the window is the last thirty days **that have rows** rather than thirty
    /// calendar days — which for steps matters more than for anything else, because a day the strap
    /// was not worn has no row at all.
    private var comparisonBadge: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                Image(systemName: "arrowtriangle.up.fill")
                    .foregroundStyle(MetricChange.color(for: .better))
                Image(systemName: "arrowtriangle.down.fill")
                    .foregroundStyle(MetricChange.color(for: .worse))
            }
            .font(.system(size: 10))
            .accessibilityHidden(true)

            Text(date.formattedShortDate())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("vs. last \(RecoveryScoring.baselineWindowDays) days")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "\(date.formattedShortDate()), compared with the last "
                    + "\(RecoveryScoring.baselineWindowDays) days")
        )
        .glassCard(cornerRadius: 14, padding: 12)
    }
}
