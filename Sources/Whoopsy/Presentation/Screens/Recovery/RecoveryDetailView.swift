import SwiftUI

/// One day's recovery statistics, with no navigation container of its own.
///
/// It exists separately from `RecoveryDashboardView` because the same figures are reached two ways —
/// the Recovery tab, and a tap on Home's green recovery ring — and a second copy of them would be a
/// second definition of everything this screen decides: the tier colour, the dash gates, the
/// never-mix trend filter, and which of the four rows has a producer. The tab wraps this in its own
/// `NavigationStack`; `HomeDashboardView` pushes it onto the stack Home already owns.
///
/// **Why Home pushes rather than switching to the Recovery tab.** A tab switch would show today, and
/// the day the reader tapped would be gone — the reader would tap an 87% ring on Aug 16 and land on
/// "No data recorded", because today is past the export's end. `RecoveryDashboardView` keeps a
/// private day seeded to `Date()`, so nothing outside it can ask it for a different one. Pushing
/// carries the day.
///
/// **The day is handed in and is not movable.** This screen carries no `DayNavigationBar`, so the
/// day it opens on is the day it shows — Home's ring push carries the day that was tapped, and the
/// Recovery tab passes `Date()`. That is a deliberate difference from the three day-keyed tabs it
/// otherwise follows, and the reason is the same affordance rule the rest of this screen is held to
/// in the other direction: this page has nothing to do with a second day. Its four rows are a reading
/// of one night against one trailing window, so a stepper here invites the reader to page away from
/// the score they just asked *why* about, and a figure at the bottom would then be describing a
/// window with no visible top.
///
/// The cost is real and is the reader's to weigh: the Recovery **tab** opens on today, and today is
/// past the export's end on an install that has only imported history, so that tab shows a dash with
/// no way to page back. Every imported day is still reachable — Home's ring pushes this view seeded
/// with the day on screen — which is the path that was added for exactly this reason.
///
/// **The page is a ring and a breakdown, and the breakdown is the point.** The ring prints the score;
/// the four rows beneath it print the figures that score was computed from, each against the trailing
/// baseline it was read against. None of them is dotted: every value comes off the day's stored row
/// and every baseline comes off `RecoveryScoring.baselines` over the same window the scorer used, so
/// a reader can see *why* the ring says what it says rather than being asked to trust it.
///
/// **There is no title header either.** Nothing sits above the ring: the screen is named by the tab
/// it was reached from or by the row that pushed it, and a `DashboardHeader` reading "Recovery" over
/// a day bar spent a fifth of the viewport restating what the reader had just tapped. The no-data
/// state is not lost with it — the gauge's own label reads "No data" on a day with no measurement,
/// which is where a reader looks for the score anyway.
///
/// **Two things in the reference this layout came from are deliberately not drawn.** The WHOOP
/// wordmark is another company's brand, and the one position on a screen that says whose app it is,
/// is not a place to render someone else's — with the header gone, that position is simply empty
/// rather than holding a substitute. The `i` button beside the ring is omitted for the reason every
/// other inert control here is: it has no destination, and a control that looks tappable and is not
/// reads as broken.
public struct RecoveryDetailView: View {
    @State private var viewModel: RecoveryViewModel

    /// The day shown, fixed for the life of the view.
    ///
    /// A plain `let` rather than `@State`, because nothing here can change it — there is no stepper
    /// and no calendar. That is also what keeps it stable: a re-render of the parent cannot move it,
    /// and neither can a change to whatever day Home is showing behind the push.
    private let date: Date

    public init(viewModel: RecoveryViewModel, date: Date) {
        _viewModel = State(initialValue: viewModel)
        self.date = date
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Bare, not on a card: the ring is the screen's subject, and Home already draws its
                // three the same way. A card around it would make the one element that is not a
                // reading look like the readings below it.
                GaugeRingView(
                    progress: gaugeProgress,
                    scoreText: gaugeText,
                    label: gaugeLabel,
                    ringColor: color,
                    lineWidth: 18,
                    size: 190)
                .padding(.vertical, 4)

                breakdownCard

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("14-day \(metric.displayName) trend")
                    if trend.isEmpty {
                        Text("No readings yet.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        MiniTrendView(values: trend, color: color)
                        Text("The same quantity on every day plotted — \(metric.displayName) only. SDNN and RMSSD are different measurements on different scales, so a line joining them would describe neither.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .glassCard()
            }
            .padding()
        }
        .background(Theme.backgroundDark)
        .task { await viewModel.load(for: date) }
        .preferredColorScheme(.dark)
    }

    // MARK: - The breakdown

    /// The four figures the day's score was computed from, each over its trailing baseline.
    ///
    /// The order is the reference's, and it is also the order of the model's own weights in
    /// `BaselineStatisticsMath.computeRecoveryScore` — HRV at 24, resting heart rate at 18, sleep at
    /// 20 — with respiratory rate last, the one row here that the score does **not** read. It is
    /// printed because it is a measured overnight figure with a producer and a baseline, which is the
    /// same bar every other row clears; it is *not* folded into the ring, and the ring's own label
    /// does not claim otherwise.
    private var breakdownCard: some View {
        VStack(spacing: 0) {
            breakdownRow(
                label: "HEART RATE VARIABILITY",
                symbol: "waveform.path.ecg",
                value: hrvValue,
                unit: "ms",
                decimals: 0,
                baseline: viewModel.baselines?.displayed.hrvMs,
                higherIsBetter: true)

            divider

            breakdownRow(
                label: "RESTING HEART RATE",
                symbol: "heart.fill",
                value: restingRate,
                unit: "bpm",
                decimals: 0,
                baseline: viewModel.baselines?.displayed.restingHeartRate,
                higherIsBetter: false)

            divider

            // No `hasMeasurement` gate of its own, because there is no reserved zero in this column
            // to gate: `RecoveryMetric.respiratoryRate` is optional and the strap has no sensor for
            // it, so an unmeasured day and a measured day with no respiratory reading are both
            // simply `nil`. Gating it on the row's flag as well would be a second absence rule for a
            // quantity that already has an honest one.
            breakdownRow(
                label: "RESPIRATORY RATE",
                symbol: "lungs.fill",
                value: respiratoryRate,
                unit: "rpm",
                decimals: 1,
                baseline: viewModel.baselines?.displayed.respiratoryRate,
                higherIsBetter: false)

            divider

            // The night's own performance, derived by `SleepSession` from asleep-over-need. An
            // imported night carries WHOOP's need, so this is this app's ratio over the export's
            // denominator — which is the app's existing decision about imported nights, not a second
            // opinion introduced here.
            breakdownRow(
                label: "SLEEP PERFORMANCE",
                symbol: "moon.zzz.fill",
                value: sleepPerformance,
                unit: "%",
                decimals: 0,
                baseline: viewModel.baselines?.displayed.sleepPerformance.map { $0 * 100 },
                higherIsBetter: true)
        }
        .glassCard()
    }

    /// One row: an icon and a name on the left, the day's figure over its baseline on the right, with
    /// the triangle between them when the two differ.
    ///
    /// **The value is already gated by the caller and the baseline is already gated by the domain.**
    /// A `nil` value is this row's whole absence rule — there is no `?? 0` here and there is nowhere
    /// for one to hide, because the parameter is an optional `Double` rather than a formatted string.
    ///
    /// The baseline arrives from `RecoveryScoring.Baselines.displayed`, which withholds it unless the
    /// trailing window held at least `minimumBaselineDays` observations of that metric. That gate is
    /// the reason this row can print a mean at all: `BaselineStatisticsMath.baseline` substitutes a
    /// cold-start **constant** when it is handed an empty window, and a screen that printed `65 ms`
    /// as "your HRV baseline" on a day with no history would be presenting a number this app wrote
    /// down as one it measured.
    ///
    /// The arrow and its colour come from `MetricChange.marker`, shared with Home's panels, so "up"
    /// keeps its literal meaning — a triangle points the way the number went — and only the verdict
    /// inverts: `higherIsBetter` is what makes an HRV rise green and a resting-heart-rate rise orange.
    private func breakdownRow(
        label: String,
        symbol: String,
        value: Double?,
        unit: String,
        decimals: Int,
        baseline: Double?,
        higherIsBetter: Bool
    ) -> some View {
        let format: (Double) -> String = { String(format: "%.\(decimals)f", $0) }
        let marker = MetricChange.marker(
            current: value,
            baseline: baseline,
            higherIsBetter: higherIsBetter,
            formatted: format)
        // With no marker the mean is still worth printing — it is the context the day's figure is
        // read against — so it falls back to the plain muted slot rather than disappearing. The two
        // disagree only when the day *is* its own mean, where a triangle would mark a movement of zero.
        let baselineText = marker?.change.previousText ?? baseline.map(format)
        let valueText = value.map(format)

        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 34, height: 34)

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valueText ?? dash)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(value == nil ? Theme.textMuted : Theme.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    // The unit is only drawn beside a figure. "— rpm" would attach a unit to a
                    // reading that does not exist.
                    if value != nil, !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }

                    if let marker {
                        Image(systemName: marker.change.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(marker.color)
                            .accessibilityHidden(true)
                    }
                }

                // A space rather than nothing when there is no baseline: it reserves the line, so a
                // window too thin to produce one does not make its row a different height from the
                // three beside it.
                Text(baselineText ?? " ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowDescription(label: label, value: valueText, unit: unit, baseline: baselineText))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
    }

    /// One row, one announcement. The triangle is a drawn glyph, so without this the direction it
    /// encodes — which is the row's whole comparison — never reaches VoiceOver.
    private func rowDescription(label: String, value: String?, unit: String, baseline: String?) -> String {
        let spokenUnit = unit == "%" ? "percent" : unit
        guard let value else { return "\(label), no measurement" }
        let spokenValue = spokenUnit.isEmpty ? value : "\(value) \(spokenUnit)"
        guard let baseline else { return "\(label), \(spokenValue)" }
        return "\(label), \(spokenValue), 30-day average \(baseline)"
    }

    // MARK: - The day's figures

    /// Which quantity the HRV row and the trend line are showing. Once HealthKit SDNN days and strap
    /// RMSSD days share the table, a screen that does not name a metric is showing an unlabelled mix.
    private var metric: HRVMetric { viewModel.displayedHrvMetric }

    // The tier's colour, from the one mapping in `RecoveryState+Extensions.swift`. Gated on the
    // measurement rather than on the row, because it tints the gauge and the trend line alike — so it
    // has to be right at the definition, not at one of the use sites. A placeholder left by an older
    // build carries `score: 0` and would hand back `.red`, a tier the day does not have, and the `nil`
    // case is the same yellow the old private switch's `default:` produced.
    private var color: Color {
        hasMeasurement ? (viewModel.recovery?.state.color ?? Theme.recoveryYellow) : Theme.textSecondary
    }
    private var trend: [Double] { viewModel.hrvTrend(for: metric) }

    /// A day the strap recorded nothing for now stores no row at all, so `nil` is the ordinary case
    /// here — but rows written by an older build still hold zeros with the flag clear, and rendering
    /// one literally would show an unworn night as a hard 0% red recovery with a 0 ms HRV: a statement
    /// about physiology where the truth is the absence of data. The dash is what that looks like, and
    /// it is what an absent row renders too, since every gate below reads through the optional.
    private var hasMeasurement: Bool { viewModel.recovery?.hasMeasurement == true }
    private var dash: String { "—" }
    private var gaugeProgress: Double { hasMeasurement ? Double(viewModel.recovery?.score ?? 0) / 100 : 0 }
    private var gaugeText: String { hasMeasurement ? "\(viewModel.recovery?.score ?? 0)%" : dash }
    private var gaugeLabel: String { hasMeasurement ? "Recovery" : "No data" }

    /// A measured day's HRV and resting heart rate, or a dash.
    ///
    /// Both are read from the day's stored row and **not** from `RecoveryMetric.hrvBaselineDeltaMs`
    /// or `.rhrBaselineDeltaBpm`. Those two are computed by `RecoveryScoring` and handed to the entity
    /// by `CalculateRecoveryUseCase` and the importer, but `recoveries` has no column for either and
    /// no repository maps one — so they are `nil` on every day in the database, and a view that read
    /// them would be printing a comparison that was never loaded. The comparison this screen shows is
    /// recomputed on read instead, from `RecoveryScoring.baselines`, which is the same function the
    /// score beside it came from.
    private var hrvValue: Double? {
        hasMeasurement ? viewModel.recovery?.hrvValueMs : nil
    }

    /// The day's resting heart rate, gated twice — exactly as `MetricWeek.makeDay` gates it. The flag
    /// is about the row, and `> 0` is this column's reserved marker: a measured day whose heart rate
    /// was never reported holds a `0` that is not a bpm.
    private var restingRate: Double? {
        guard hasMeasurement, let rate = viewModel.recovery?.restingHeartRate, rate > 0 else {
            return nil
        }
        return Double(rate)
    }

    /// The night's own performance. No gate: an unclassifiable night has no row, so the optional is
    /// the whole absence rule.
    private var sleepPerformance: Double? {
        viewModel.sleepSession.map { Double($0.sleepPerformancePercentage) }
    }

    /// The night's respiratory rate.
    ///
    /// No `hasMeasurement` gate, unlike the two above, because there is no reserved zero in this
    /// column to gate: `RecoveryMetric.respiratoryRate` is optional and the strap has no sensor for
    /// it, so an unmeasured day and a measured day with no reading are both simply `nil`. Gating it on
    /// the row's flag as well would be a second absence rule for a quantity that already has one.
    private var respiratoryRate: Double? { viewModel.recovery?.respiratoryRate }
}
