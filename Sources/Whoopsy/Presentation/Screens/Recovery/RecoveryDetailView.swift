import SwiftUI

/// One day's recovery statistics, with no navigation container of its own.
///
/// It exists separately from `RecoveryDashboardView` because the same figures are reached two ways —
/// the Recovery tab, and a tap on Home's green recovery ring — and a second copy of them would be a
/// second definition of everything this screen decides: the tier colour, the dash gates, the
/// comparison window the rows are read against, and which of the four rows has a producer. The tab
/// wraps this in its own
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
/// **The page is a ring, a breakdown, a caption and a week chart, and the breakdown is the point.**
/// The ring prints the score; the four rows beneath it print the figures that score was computed from,
/// each against the trailing baseline it was read against. None of them is dotted: every value comes
/// off the day's stored row and every baseline comes off `RecoveryScoring.baselines` over the same
/// window the scorer used, so a reader can see *why* the ring says what it says rather than being
/// asked to trust it. `comparisonBadge` sits under the card as its caption, naming the day and the
/// window the rows were read over, and `weekSection` closes the page with the seven days ending on
/// that same day — the one thing here that is about a span rather than a night.
///
/// **There is no title header either.** Nothing sits above the ring: the screen is named by the tab
/// it was reached from or by the row that pushed it, and a `DashboardHeader` reading "Recovery" over
/// a day bar spent a fifth of the viewport restating what the reader had just tapped. The no-data
/// state is not lost with it — the gauge's own label reads "No data" on a day with no measurement,
/// which is where a reader looks for the score anyway. The one heading on the page is *inside* it,
/// over the week section, and that is a different thing: it names a section the reader has scrolled
/// to, not the screen they already know they are on.
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

                comparisonBadge

                weekSection
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
                label: "HRV",
                symbol: "waveform.path.ecg",
                value: hrvValue,
                unit: "ms",
                decimals: 0,
                baseline: viewModel.baselines?.displayed.hrvMs,
                higherIsBetter: true)

            divider

            breakdownRow(
                label: "RHR",
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
    /// the marker between them.
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
    /// The marker comes from `MetricChange.between`, shared with Home's panels. The glyph keeps its
    /// literal meaning — a triangle points the way the number went, a dot means it did not move — and
    /// the colour is the verdict alone, so `higherIsBetter` is what makes an HRV rise green and a
    /// resting-heart-rate rise red. The row never picks a colour itself: reading `direction` here and
    /// choosing a token is exactly the copy the shared type exists to prevent.
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
        let marker = MetricChange.between(
            current: value,
            previous: baseline,
            higherIsBetter: higherIsBetter,
            formatted: format)
        // With no marker the mean is still worth printing — it is the context the day's figure is
        // read against — so it falls back to the plain muted slot rather than disappearing. That
        // fallback now fires only when a side is missing: a day sitting exactly on its mean keeps its
        // marker and draws the dot, so "at your baseline" is stated rather than left looking unmeasured.
        let baselineText = marker?.previousText ?? baseline.map(format)
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
                        Image(systemName: marker.symbolName)
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
        .accessibilityLabel(
            rowDescription(
                label: label, value: valueText, unit: unit, baseline: baselineText, marker: marker))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
    }

    /// One row, one announcement. Both halves of the comparison are drawn — a glyph and a colour —
    /// and neither reaches VoiceOver: the glyph is `accessibilityHidden`, and a colour has no spoken
    /// form at all. So the verdict is spelled out, and it is the **verdict** that gets the words
    /// rather than the direction: a listener who hears the day's figure and the average it is read
    /// against can work out which way the number moved, and cannot work out which way was good.
    private func rowDescription(
        label: String, value: String?, unit: String, baseline: String?, marker: MetricChange?
    ) -> String {
        let spokenUnit = unit == "%" ? "percent" : unit
        guard let value else { return "\(label), no measurement" }
        let spokenValue = spokenUnit.isEmpty ? value : "\(value) \(spokenUnit)"
        guard let marker else {
            guard let baseline else { return "\(label), \(spokenValue)" }
            return "\(label), \(spokenValue), 30-day average \(baseline)"
        }
        switch marker.verdict {
        case .better: return "\(label), \(spokenValue), better than the 30-day average of \(marker.previousText)"
        case .same: return "\(label), \(spokenValue), the same as the 30-day average of \(marker.previousText)"
        case .worse: return "\(label), \(spokenValue), worse than the 30-day average of \(marker.previousText)"
        }
    }

    // MARK: - The day's figures

    /// The day, the window the rows above it were read over, and the key to their markers.
    ///
    /// **It sits directly under the breakdown card, and that adjacency is the whole placement.** It is
    /// a caption for those four rows — its window line names the mean they print and its two triangles
    /// are the key to the triangles they draw — so it belongs against them, and the foot of the card is
    /// as close as a caption can sit without interrupting the ruled list it describes. The week chart
    /// follows below it: the badge captions the card above and does not caption the chart below, and the
    /// page's stack in this order is the only arrangement that says so.
    ///
    /// **The key is two glyphs and no words, and that is the whole of it.** The words that used to sit
    /// beside each verdict have been removed: a marker is read where it is drawn, each row already
    /// spells its own verdict out to VoiceOver in `rowDescription`, and three labelled swatches spent a
    /// line of the page restating a rule the four figures beneath it demonstrate. What is left is the
    /// pair the rows draw most often — the rise and the fall — in the two verdict colours those markers
    /// are drawn in.
    ///
    /// **They are a colour key, not a direction key, and a reader who takes them as "up is good" will
    /// misread three of the four rows.** `MetricChange` decouples the two: a triangle always points the
    /// way the number went, and `higherIsBetter` alone picks the colour, so an HRV *rise* is green while
    /// a resting-heart-rate *rise* is red. The pair shows the two colours, not a claim that a rise is
    /// always one of them.
    ///
    /// **It is a two-glyph key on a three-state verdict, and the middle state is not in it.** A figure
    /// sitting exactly on its average draws `circle.fill` in yellow, and nothing on the badge accounts
    /// for that dot — the key names better and worse and leaves the third to be read off the row. That
    /// is a real gap rather than a symmetry that was not needed: the yellow dot is the one marker a
    /// reader has no colour vocabulary for, and a third glyph here would close it.
    ///
    /// The glyphs are drawn for their colour and are not a comparison, so they carry no `MetricChange`
    /// and are hidden from VoiceOver: they are decoration beside a caption that already says everything
    /// a listener needs.
    ///
    /// **The window is read off `RecoveryScoring.baselineWindowDays` rather than typed as `30`.** It
    /// is the same constant `baselines(...)` caps the window with, so a change there cannot leave this
    /// caption describing a window the figures beside it were not taken over. One thing the caption
    /// cannot carry at this length: that window is the last thirty days **that have rows**, not thirty
    /// calendar days, so on a gappy history it reaches further back — up to
    /// `baselineWindowLookbackDays` on the bundled export. "last 30 days" is the reference's wording
    /// and the honest short form; it is not a claim that the thirty are contiguous.
    private var comparisonBadge: some View {
        HStack(spacing: 8) {
            // The colours come off `MetricChange.color(for:)` rather than being typed as tokens, so the
            // key cannot come to show a colour no row draws. The verdict's own order is better, the
            // same, worse — this draws the two ends of it.
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
        // The two glyphs are drawn for their colour and say nothing to VoiceOver, so the announcement is
        // the caption's own sentence: the day, and the window it is read over.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "\(date.formattedShortDate()), compared with the last "
                    + "\(RecoveryScoring.baselineWindowDays) days")
        )
        .glassCard(cornerRadius: 14, padding: 12)
    }

    // MARK: - The week

    /// The section title over the week chart.
    ///
    /// It is `HomeDashboardView`'s section-heading style — 17pt bold in `Theme.textPrimary` — rather
    /// than a `SectionLabel`, because the two are different ranks and already coexist on Home: a
    /// `SectionLabel` is the small tracked caption *inside* a card ("RECOVERY" here, "STRAIN &
    /// RECOVERY" there) and this is the heading a section of the page hangs from. Using the caption
    /// style for both would flatten the two levels into one.
    ///
    /// **It carries no `My Day`-style trailing control.** The reference puts a chevron on the card
    /// below, not here, and there is no destination to give either of them.
    private var weekHeader: some View {
        Text("Weekly Trends")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    /// The seven days ending on the day shown, at the foot of the page: recovery scores as bars, then
    /// heart-rate variability, resting heart rate and respiratory rate as lines, then sleep
    /// performance as bars again.
    ///
    /// **The heading and its charts appear together or not at all.** The heading is drawn only inside a
    /// condition that found something to head, so an empty week does not leave "Weekly Trends" standing
    /// over nothing — a title with no section under it is a worse version of the empty grid the charts
    /// themselves refuse to draw. That is also why they are one `VStack` rather than siblings in the
    /// page's stack: the page's own spacing is 16, which is the gap *between* sections, and a heading
    /// has to sit tighter to what it heads than that.
    ///
    /// **The five charts are omitted independently, on their own data.** They are not the same series
    /// and do not have the same completeness, so one can be absent while the others are drawn. Recovery
    /// is absent when no day in the week has a score; HRV is absent when no day has a reading *in the
    /// quantity the week is narrowed to*, which the never-mix rule can make true in a week that has
    /// readings; resting heart rate is absent when no day has a rate — and a day whose row is measured
    /// can still have none, since a `0` bpm is written only by an older build's placeholder;
    /// respiratory rate is absent when no day has one, which is common on a week this app recorded
    /// itself — the strap derives it from the R-R series, so a night whose beats cannot support one
    /// carries none; sleep performance is absent when the week holds no classified
    /// night, and — being read off a `sleeps` row rather than off the recovery row the other four come
    /// from — it is the one that can be present on a week **all four of the others are absent from**,
    /// since the strap records nights and recoveries independently. None of them draws an empty one:
    /// seven labelled columns with nothing in them is a picture of a week of zeros, the same
    /// fabrication a bar or a point at zero would be, drawn once per column. The page still reads when
    /// all five are absent: the gauge above says "No data" for the day, which is where a reader looks
    /// first.
    ///
    /// **They sit below the comparison badge rather than above it.** The badge names the window the four
    /// rows were read against; these are a different reading of a different span — seven days, each its
    /// own figure — and putting them between the rows and their caption would separate the two.
    ///
    /// **The order is the page's own four rows**, and the two figures the page has outside them.
    /// Recovery first, because this is the recovery screen and the score is what the ring above says;
    /// then the four quantities the breakdown rows above are about, in the same order they appear
    /// there; then sleep performance, which has a bar chart of its own because it is a percentage of a
    /// need exactly as the recovery score is a percentage of a scale. So the page reads top-to-bottom
    /// as score, HRV, RHR, respiratory rate, sleep performance — day, then week, five times — rather
    /// than leaving a reader to work out which card belongs to which row. Respiratory rate is the last
    /// of the three lines because that is where its row is, and that row is where it is because it is
    /// the one the score does not read.
    ///
    /// Each card is captioned by its own label rather than by a sentence, because none has a second
    /// series to disambiguate: the bars are percentages of one quantity and each line is one quantity,
    /// and the only thing a label has to say is which. `SectionLabel` is the app's shared label for
    /// that position.
    ///
    /// **The two bar charts are the same card around the same drawing**, so they share `barWeekCard`
    /// and `WeekBarChartView`; the three lines share `lineWeekCard` and `WeekLineChartView` for the same
    /// reason. What is *not* shared is each card's sentence, and the bar pair differ there in one word:
    /// the recovery chart counts **days** and the sleep chart counts **nights**, which is the honest
    /// unit for each and the difference between two absences a reader would otherwise have to guess at.
    private var weekSection: some View {
        Group {
            if let week = viewModel.week, hasWeekCharts(week) {
                VStack(alignment: .leading, spacing: 10) {
                    weekHeader

                    if let series = WeekBarSeries(recoveryWeek: week) {
                        barWeekCard(
                            week, series: series, title: "Recovery",
                            caption: weekDescription(week))
                    }

                    if let series = WeekLineSeries(hrvWeek: week) {
                        lineWeekCard(
                            week, series: series, title: "Heart Rate Variability",
                            caption: hrvWeekDescription(week))
                    }

                    if let series = WeekLineSeries(restingHeartRateWeek: week) {
                        lineWeekCard(
                            week, series: series, title: "Resting Heart Rate",
                            caption: restingHeartRateWeekDescription(week))
                    }

                    if let series = WeekLineSeries(respiratoryRateWeek: week) {
                        lineWeekCard(
                            week, series: series, title: "Respiratory Rate",
                            caption: respiratoryRateWeekDescription(week))
                    }

                    // The second bar chart, and the page's last card. It is a bar rather than a line
                    // because a night's performance is a percentage of a need, exactly as a recovery
                    // score is a percentage of `RecoveryScoring`'s scale — the two are the same
                    // drawing with different answers to "which slots" and "what colour".
                    if let series = WeekBarSeries(sleepPerformanceWeek: week) {
                        barWeekCard(
                            week, series: series, title: "Sleep Performance",
                            caption: sleepPerformanceWeekDescription(week))
                    }
                }
            }
        }
    }

    /// Whether the section has anything to head. Read off the five charts' own conditions rather than
    /// restated, so a sixth chart added here cannot leave the heading unreachable by forgetting to
    /// widen this — and, more to the point, so the heading cannot outlive the last chart that justified
    /// it.
    private func hasWeekCharts(_ week: MetricWeek) -> Bool {
        WeekBarSeries(recoveryWeek: week) != nil
            || WeekLineSeries(hrvWeek: week) != nil
            || WeekLineSeries(restingHeartRateWeek: week) != nil
            || WeekLineSeries(respiratoryRateWeek: week) != nil
            || WeekBarSeries(sleepPerformanceWeek: week) != nil
    }

    /// One of the two bar cards, which are the same card around the same chart.
    ///
    /// They differ in the series, the label and the sentence, and in nothing else — exactly as the
    /// three line cards do, and for the same reason: a copy of the modifier stack is a copy that can
    /// drift. The two things about the card that are decisions rather than plumbing are both here: the
    /// label is a `SectionLabel` because that is the app's caption for this position, and the drawing
    /// is `accessibilityHidden` with the sentence on the card, because a `Shape` has nothing to say to
    /// VoiceOver.
    private func barWeekCard(
        _ week: MetricWeek, series: WeekBarSeries, title: String, caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            WeekBarChartView(week: week, series: series)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    /// One of the three line cards, which are the same card around the same chart.
    ///
    /// They differ in the series, the label and the sentence, and in nothing else — so they share this
    /// rather than three copies of the modifier stack. The two things about the card that are decisions
    /// rather than plumbing are both here: the label is a `SectionLabel` because that is the app's
    /// caption for this position, and the drawing is `accessibilityHidden` with the sentence on the
    /// card, because a `Shape` has nothing to say to VoiceOver.
    private func lineWeekCard(
        _ week: MetricWeek, series: WeekLineSeries, title: String, caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            WeekLineChartView(week: week, series: series)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    /// The recovery week in one sentence: how many days carry a score, and the span they cover.
    ///
    /// The count is in the words because the chart cannot say it — a column with no bar looks the same
    /// whether its day was unmeasured or merely unremarkable, and the seven columns are otherwise the
    /// only statement about the week's completeness.
    ///
    /// The sentence itself is the bars' shared one; only the subject and the unit word are this card's.
    private func weekDescription(_ week: MetricWeek) -> String {
        guard let series = WeekBarSeries(recoveryWeek: week) else {
            return "Recovery for the last seven days, no measurement"
        }
        return barWeekSentence(series, subject: "Recovery", counted: "days")
    }

    /// The sleep-performance week in one sentence.
    ///
    /// The same plain form as the recovery bars, and the only thing that differs besides the subject is
    /// the unit of the count: a performance is a night's, so this says *nights* where the recovery
    /// chart says days. That is not decoration — the two charts are on one page and a reader comparing
    /// their captions should be able to tell which of them counts nights and which counts days, since
    /// a day with no score and a night with no session are different absences.
    private func sleepPerformanceWeekDescription(_ week: MetricWeek) -> String {
        guard let series = WeekBarSeries(sleepPerformanceWeek: week) else {
            return "Sleep performance for the last seven days, no measurement"
        }
        return barWeekSentence(series, subject: "Sleep performance", counted: "nights")
    }

    /// The half of a bar chart's sentence that both of them say the same way: how many of the seven
    /// days carry a bar, and the span those bars cover.
    ///
    /// The counterpart of `lineWeekSentence`, and deliberately not the same function. A bar series is
    /// whole percentages in one fixed unit, so the figures are printed as they are stored and the unit
    /// is spoken; a line series carries its own `valueDecimals` and is rounded to it, so that sentence
    /// cannot state a week at a resolution the drawing does not. One function serving both would have
    /// to be told which it was looking at.
    ///
    /// The count is stated against the **bars drawn** and never against the week, for the reason the
    /// line version states it against its points: a day can be unmeasured, and for the recovery bars
    /// this count is also the only statement about the week's completeness — a column with no bar looks
    /// the same whether its day was unmeasured or merely unremarkable.
    private func barWeekSentence(_ series: WeekBarSeries, subject: String, counted: String) -> String {
        let values = series.points.map(\.value)
        guard let lowest = values.min(), let highest = values.max() else {
            return "\(subject) for the last seven days, no measurement"
        }
        return "\(subject) for the last seven days, "
            + "\(values.count) of \(MetricWeek.dayCount) \(counted) measured, "
            + "from \(lowest) to \(highest) percent"
    }

    /// The HRV week in one sentence, and it names the **quantity** in a way the other two have no
    /// equivalent of.
    ///
    /// SDNN and RMSSD are different measurements on different scales, and this chart plots only one of
    /// them, so a week that held both shows fewer points than it has measured days. That is correct and
    /// invisible — the difference between "four days were measured" and "four days were measured in the
    /// quantity this line is in" is exactly the kind of thing a reader cannot recover from the drawing.
    /// So the metric is spoken, and the count is stated against the plotted points rather than against
    /// the week, which is the count the line actually has.
    ///
    /// The metric is read off the week rather than off the series, which does not carry it: the series
    /// is the drawing, and a quantity label belongs to the sentence. Both come from
    /// `MetricWeek.hrvBaselineMetric`, so they cannot disagree.
    private func hrvWeekDescription(_ week: MetricWeek) -> String {
        guard let series = WeekLineSeries(hrvWeek: week), let metric = week.hrvBaselineMetric else {
            return "Heart rate variability for the last seven days, no measurement"
        }
        return lineWeekSentence(
            series, subject: "Heart rate variability in \(metric.displayName)",
            unit: "milliseconds")
    }

    /// The resting-heart-rate week in one sentence.
    ///
    /// No quantity clause is needed — a resting heart rate is one quantity — so this is the plain
    /// count-and-span form, with the unit spoken because the chart's bare numbers do not carry one.
    private func restingHeartRateWeekDescription(_ week: MetricWeek) -> String {
        guard let series = WeekLineSeries(restingHeartRateWeek: week) else {
            return "Resting heart rate for the last seven days, no measurement"
        }
        return lineWeekSentence(series, subject: "Resting heart rate", unit: "beats per minute")
    }

    /// The respiratory-rate week in one sentence.
    ///
    /// The same plain form as the resting rate, and for the same two reasons: one quantity, so no
    /// clause is needed to say which, and a unit the chart's bare numbers do not carry. What differs
    /// is only the precision, which comes off the series rather than being typed here — a span spoken
    /// as "from 15 to 17 breaths per minute" would drop the same decimal the chart's labels carry and
    /// describe a week this app did not measure.
    ///
    /// **The card is omitted far more often than it is drawn**, and that is worth knowing when reading
    /// a screenshot of this page: a respiratory rate comes from a night WHOOP scored, and the strap
    /// has no sensor for one, so a week the app recorded itself has no respiratory rates in it at all
    /// unless HealthKit supplied them. Nothing is missing when this card is absent — the week simply
    /// has no reading in this quantity, which is the same condition that omits the other two.
    private func respiratoryRateWeekDescription(_ week: MetricWeek) -> String {
        guard let series = WeekLineSeries(respiratoryRateWeek: week) else {
            return "Respiratory rate for the last seven days, no measurement"
        }
        return lineWeekSentence(series, subject: "Respiratory rate", unit: "breaths per minute")
    }

    /// The half of a line chart's sentence that all three of them say the same way: how many of the
    /// seven days the line has, and the span it covers.
    ///
    /// The count is stated against the **plotted points** and never against the week, because those
    /// two are not the same number — for HRV the narrowing drops measured days, and for any of the
    /// three a day can be unmeasured. It is the count the line actually has, which is what a reader
    /// listening to a chart they cannot see needs.
    ///
    /// The span is rounded to the series' own `valueDecimals`, which is the same number the chart
    /// labels each point to — so the sentence and the drawing state one week at one resolution, and a
    /// listener is not told a coarser or finer figure than a sighted reader is shown.
    private func lineWeekSentence(_ series: WeekLineSeries, subject: String, unit: String) -> String {
        let values = series.points.map(\.value)
        guard let lowest = values.min(), let highest = values.max() else {
            return "\(subject) for the last seven days, no measurement"
        }
        let format = "%.\(series.valueDecimals)f"
        return "\(subject) for the last seven days, "
            + "\(values.count) of \(MetricWeek.dayCount) days measured, "
            + "from \(String(format: format, lowest)) to \(String(format: format, highest)) \(unit)"
    }

    // The tier's colour, from the one mapping in `RecoveryState+Extensions.swift`. Gated on the
    // measurement rather than on the row, because it tints the gauge — so it has to be right at the
    // definition, not at the use site. A placeholder left by an older build carries `score: 0` and
    // would hand back `.red`, a tier the day does not have, and the `nil` case is the same yellow the
    // old private switch's `default:` produced.
    private var color: Color {
        hasMeasurement ? (viewModel.recovery?.state.color ?? Theme.recoveryYellow) : Theme.textSecondary
    }

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
    ///
    /// The SLEEP PERFORMANCE week chart below reads the same night through
    /// `MetricDay.sleepPerformance`, which is ungated for this reason — so the row and the bars cannot
    /// come to describe different sets of nights.
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
