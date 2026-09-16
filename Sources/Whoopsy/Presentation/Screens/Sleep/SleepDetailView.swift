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
/// **That figure is now on the page three times**, because `needCard` at the bottom heads itself with
/// it as well — the ring, the breakdown row and the card. The card is the reference's own composition
/// for the figure (a percentage over the need that produced it), and the user asked for it on top of
/// the row rather than in place of it. The three cannot disagree, since all three read the entity's
/// single `sleepPerformancePercentage` property rather than recomputing the ratio.
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
/// the import verbatim — and both have since been given a reader again, by two different routes. The
/// respiratory rate reaches the Recovery detail page, because `CalculateRecoveryUseCase` copies it
/// onto the `recoveries` row that screen draws. The sleep debt reaches the **`needCard` at the bottom
/// of this page**, which is the only consumer `sleeps.sleep_debt` has ever had and the reason that
/// card's breakdown box exists at all.
///
/// **The page ends with three more elements: the heart-rate chart, the typical-range card and the need
/// card.** The chart draws the night's own `biometric_samples` across its in-bed window, or `No Data` —
/// and on this machine it is `No Data` on every night, because nothing has ever written one of those
/// rows. That is the honest output rather than a failure; see `noSleepingData` for why the absence is
/// worded the way it is. **The chart is not the card's subject** — it is drawn inside
/// `hoursOfSleepCard`, under a headline that is the night's hours of sleep, which is why the types it is
/// built from are named `HoursOfSleepChart*` while the points they carry are `bpm`. The typical-range
/// card is four stage rows, each printing tonight's share and duration over a bar that marks the band
/// that share is normally in, and a footer summing the two restorative stages
/// against the window's mean of the same sum. It is `SleepStageRangeScoring`'s output drawn — the
/// window, the quartiles and the whole-percent column are all decided there, so nothing on this page
/// computes a share or a boundary. The band is in **percentage points of the night**, not the minutes
/// WHOOP quotes its own REM range in, because the bar's scale is 0–100% and a band in minutes could not
/// be drawn on it. The card is absent, not empty, on a night with no sleep period, and it draws bars
/// without markers when the window held fewer than `RecoveryScoring.minimumBaselineDays` nights. The
/// need card is `needCard`, documented there; it is the reference's `HOURS VS. NEEDED` card and it
/// prints a figure this page has already printed twice.
///
/// **Two elements of the reference are omitted, for the reasons `RecoveryDetailView` gives.** The
/// WHOOP wordmark is another company's brand in the one position that says whose app this is, and the
/// `i` button beside the ring has no destination — a control that looks tappable and is not reads as
/// broken.
///
/// **Nothing is drawn above the ring, and that is where this screen parts from the reference.** The
/// reference puts a line naming the night in its navigation-title slot; this screen had one — a bare
/// `DayBarRules.label(for:)`, `TODAY` or `SAT, AUG 22` — and it has been **removed**. The date is now
/// stated once, by `nightHeading`'s subtitle, which is the same claim the reference draws there.
///
/// **The consequence is worth stating, because it is not symmetric with what was there before.** That
/// label was ungated — it drew on every day, night or not — while `nightHeading` is gated on
/// `hasNight`. So on a nightless day the page now names no date at all: the rings and breakdown render
/// their `—` with no line saying which day it is. That is the honest reading of an absent night rather
/// than a regression (there are no figures for a date to qualify), but a reader who wants the date on
/// an empty day back should gate a line on `!hasNight` rather than restore the ungated one.
///
/// `Date` is still a parameter and still load-bearing: the `.task` reads the night through it and
/// `nightHeading` names it.
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
                ring

                breakdownCard

                bandLegend

                nightHeading

                hoursOfSleepCard

                typicalRangeCard

                needCard

                consistencyCard

                efficiencyCard
            }
            .padding()
        }
        .background(Theme.backgroundDark)
        .task { await viewModel.load(for: date) }
        .preferredColorScheme(.dark)
    }

    // MARK: - The night's name

    /// `Last Night's Sleep`, over the night and the window the page's bands were taken against.
    ///
    /// **This is the reference's header, and it sits directly above the card it heads.** The reference
    /// draws it at the top of its page, above a card that is the whole of that page; this screen has a
    /// ring, a breakdown and a band legend above the card as well, so the header follows the card and
    /// lands below the legend. That is the same position relative to the thing it names, which is the
    /// only relationship the header has.
    ///
    /// **The two strings are `SleepNightHeading`'s, not written here.** The subtitle's date is the one
    /// part with two answers — `Today` on today — and a rule that lives in a `body` is a rule nothing
    /// can assert.
    ///
    /// **Both lines are white and only the size separates them**, which is the reference's own
    /// treatment — measured off it rather than picked, because the first attempt at `28`/`.bold` was
    /// visibly heavier and wider than the mockup. Calibrated against this app's own render, which is
    /// the only way to read a size off an anti-aliased screenshot: at `28`/`.bold` the string's ink is
    /// `0.629` of the card's width where the reference's is `0.574`, and its cap height is `0.0526` of
    /// the card where the reference's is `0.0509`. The two disagree by design rather than by error —
    /// a *heavier* face is wider at the same size — and `27`/`.semibold` moves both ratios onto the
    /// reference's. The same comparison puts the subtitle at `16`, where its cap height already agreed.
    ///
    /// **The reference's `EDIT` button and pencil are not drawn.** There is nothing to edit — this app
    /// has no screen that writes a night — and a control that looks tappable and is not reads as broken,
    /// which is the same judgement that omits the `i` beside the reference's ring.
    ///
    /// **It is gated on `hasNight`, and that is the same gate the card below it takes.** A heading
    /// reading `Last Night's Sleep` over a card that was not drawn would name a night that does not
    /// exist, which is precisely what `hoursOfSleepCard` refuses one element down: a day with no night
    /// is absent, not empty, so there is nothing here to head.
    @ViewBuilder
    private var nightHeading: some View {
        if hasNight {
            // `6` is the reference's own gap between the two baselines — 28.2 pt against the 26.3 a
            // spacing of `4` draws — and it is the one number here the image settles outright, since
            // a baseline offset is a distance and not a shape.
            VStack(alignment: .leading, spacing: 6) {
                Text(SleepNightHeading.title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text(SleepNightHeading.subtitle(for: date))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(SleepNightHeading.spoken(for: date)))
        }
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

    // MARK: - Hours of sleep, and the night's heart rate

    /// The night's **hours of sleep** as a figure, and its heart rate across the same window as a
    /// chart — or `No Data` where the chart would be.
    ///
    /// **The card is one card with two things in it, and that is the reference's composition rather
    /// than a convenience.** The reference titles it `HOURS OF SLEEP`, prints the night's asleep total
    /// with the prior-30-day mean beneath it, and draws the heart-rate trace inside the same card. The
    /// title names the headline figure and not the trace, so a card titled after the chart would
    /// rename a card the reader is being shown — which is what this one did until the mockup was read
    /// again.
    ///
    /// **The headline is a reading and the chart is a recording, and they are gated apart.** The
    /// asleep total comes off the session and exists on every night this card is drawn for — including
    /// every imported one. The chart needs `biometric_samples`, which only a worn strap fills, so it is
    /// the chart alone that draws `No Data`. Gating the figure with the chart would hide a real reading
    /// behind an absent one, which is the fabrication every absence rule in this app exists to prevent.
    ///
    /// **The position is forced rather than chosen.** The reference draws the bars in this same card,
    /// and this screen cannot: `breakdownCard` carries a `CardNotch` pointing up at the ring and has to
    /// stay directly beneath it, and the three banded rows above `bandLegend` are what that legend
    /// keys. Between the legend and the typical-range card is the one place that leaves both of those
    /// intact — and it is the reference's own order, since the chart there also sits above the bars.
    ///
    /// **The gate is `hasNight`, not `hoursOfSleepSeries`.** They are not the same condition and only one
    /// of them is this card's subject: a day with no night at all already reads as `—` on all three
    /// breakdown rows and draws no typical-range card, and a headline announcing *this night's* hours
    /// would name a night that does not exist. A night that exists is what this card is for.
    @ViewBuilder
    private var hoursOfSleepCard: some View {
        if hasNight {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Hours of sleep")

                if let summary = viewModel.stageSummary {
                    hoursOfSleepHeadline(summary)
                }

                if let series = viewModel.hoursOfSleepSeries {
                    HoursOfSleepChartView(series: series)
                } else {
                    noSleepingData
                }
            }
            .glassCard()
            // The chart is a `Shape` and says nothing to VoiceOver, so the card is announced as one
            // element carrying the figure, its comparison and the absence — three `Text` views that
            // are one statement to a listener.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(hoursOfSleepSpoken))
        }
    }

    /// The night's asleep total in the reference's own shape: the figure, its direction, and the mean
    /// it moved against on the line below.
    ///
    /// **The comparison is `MetricChange`'s and not a second comparison written here**, so the
    /// triangle's direction, its colour and the "these two print alike, so they are the same" rule are
    /// the ones every other row on this screen uses. `higherIsBetter: true` is the judgement that makes
    /// a longer night green and a shorter one red — the same judgement the restorative row makes one
    /// card below, and the opposite of the one a resting heart rate makes.
    ///
    /// **`nil` prints the figure alone**, never a `0` for the mean: a window too thin for a baseline is
    /// unmeasured, and `MetricChange.between` returns `nil` on a missing side so this cannot draw one.
    /// That is also why the mean's own line is inside the `if let` rather than printed as a placeholder.
    ///
    /// The figure is `formattedCompactHoursMinutes`, the reading's own formatter, so the headline and
    /// the row beneath it that adds up to it are in one unit. The mean uses it too, so the pair reads
    /// as one quantity at two instants rather than as two shapes.
    @ViewBuilder
    private func hoursOfSleepHeadline(_ summary: SleepStageRangeScoring.Summary) -> some View {
        let asleep = summary.asleepSeconds
        let change = MetricChange.between(
            current: asleep,
            previous: summary.typicalAsleepSeconds,
            higherIsBetter: true,
            formatted: { $0.formattedCompactHoursMinutes() })

        // The drawing is `MetricHeadline`'s, shared with the need card at the bottom of this page —
        // same sizes, same marker, same three-state comparison. The `2` is the one thing that is this
        // card's: the gap between the mean's line and the chart beneath it.
        MetricHeadline(text: asleep.formattedCompactHoursMinutes(), change: change)
            .padding(.bottom, 2)
    }

    /// The absence state, and the reason it is not a blank chart.
    ///
    /// **It sits where the chart would and speaks for the chart alone.** The card above it carries a
    /// real reading — the night's hours of sleep — so a message that read as the card's own state
    /// would contradict the figure directly above it. It is phrased about the *recording* for that
    /// reason: the chart has no data, the night has 7:41 of sleep.
    ///
    /// **It does not say "sync your strap".** A drain is what would fill this, and this build has no
    /// drain — `SyncHistoricalDataUseCase` sends a request frame whose ACK loop and record walk are
    /// both unimplemented, so telling a user to sync would promise a fix that does not exist. What it
    /// says instead is the narrow true thing: this app records sleeping data only while it is connected.
    private var noSleepingData: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Data")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Text(
                "No sleeping data was recorded for this night. This app records sleeping data only while "
                    + "it is connected to a strap."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card in one sentence: the figure, what it is read against, then the chart.
    ///
    /// **The headline is spoken first because it is the card's subject.** The title names hours of
    /// sleep, so a listener who heard only the chart's sentence would have been told about the
    /// recording and not about the reading the card is titled for. The chart's own clause names the two
    /// ends and the count rather than reading out a trace nothing can see — a listener cannot hear a
    /// curve, and "the night's heart rate" alone would leave them unable to tell a full trace from a
    /// single reading.
    ///
    /// The durations are spoken through `formattedHoursMinutes()` and not the compact form that is
    /// printed, on `SleepTypicalRangeCard.spokenStageRow`'s rule: `7:41` on screen is a clock reading
    /// to VoiceOver, and `7h 41m` is a duration.
    private var hoursOfSleepSpoken: String {
        var spoken = "Hours of sleep"
        if let summary = viewModel.stageSummary {
            spoken += ", \(summary.asleepSeconds.formattedHoursMinutes())"
            if let typical = summary.typicalAsleepSeconds {
                spoken += ", typical \(typical.formattedHoursMinutes())"
            } else {
                spoken += ", no typical range yet"
            }
        }

        guard let series = viewModel.hoursOfSleepSeries else {
            return spoken + ". Heart rate, No Data. No heart rate was recorded for this night."
        }
        let readings = series.points.count == 1 ? "1 reading" : "\(series.points.count) readings"
        return spoken + ". Heart rate during sleep, \(readings) from "
            + "\(series.start.formattedHourMinute()) to \(series.end.formattedHourMinute())"
    }

    // MARK: - Hours against the need

    /// The night's hours of sleep against its need, and the need split into the parts the stored row
    /// can source — the reference's `HOURS VS. NEEDED` card.
    ///
    /// **It is the last element on the page, on the user's instruction.** The reference draws it
    /// directly under its own `HOURS OF SLEEP` card; here the typical-range card sits between them
    /// because it was already at the bottom of the page when this one was added. Nothing on this card
    /// is notched toward anything above it, so the position is free rather than forced — unlike
    /// `breakdownCard`, which has to stay under the ring its caret points at.
    ///
    /// **The gate is `hasNight`, like the two cards above it.** A day with no night has no need to draw
    /// against, and a card printing a `—` headline over two empty bars is a picture of a night rather
    /// than the absence of one — the same judgement `hoursOfSleepCard` makes one element up.
    ///
    /// **The night's figures come off the session and the comparison comes off `stageSummary`**, which
    /// is the same split `hoursOfSleepCard` makes and for the same reason: `asleep`, `need` and the
    /// performance percentage are readings every stored night carries, while the window's mean needs
    /// `RecoveryScoring.minimumBaselineDays` nights. A thin window prints the headline alone rather
    /// than a comparison against zero — and the mean it prints is
    /// `SleepStageRangeScoring.Summary.typicalPerformancePercent`, taken over the *usable* nights of the
    /// same window this page's typical-range card bands, so the two cards cannot come to describe
    /// different histories.
    @ViewBuilder
    private var needCard: some View {
        if let session = viewModel.session {
            SleepNeedCard(
                asleepSeconds: session.totalTimeAsleepSeconds,
                needSeconds: session.targetSleepNeedSeconds,
                breakdown: viewModel.needBreakdown,
                performancePercent: session.sleepPerformancePercentage,
                typicalPerformancePercent: viewModel.stageSummary?.typicalPerformancePercent)
        }
    }

    // MARK: - The five nights behind the score

    /// The consistency figure over the five nights it was read against — the reference's
    /// `SLEEP CONSISTENCY` card.
    ///
    /// **Its position is chosen rather than forced.** Nothing on this card is notched toward anything
    /// above it, unlike `breakdownCard`, whose caret has to stay under the ring it points at. What put
    /// it here is that the card answers a question the breakdown row near the top raises: that row
    /// prints a percentage and no reason for it, and this card is the reason, five nights of it. The
    /// efficiency card below it is the page's last element, and the two are ordered by their own
    /// subject matter rather than by the breakdown's row order — the consistency chart is five nights
    /// wide and reads as the page's conclusion, while the efficiency card is about one night's
    /// interior.
    ///
    /// **The card is gated on `consistencySummary` and not on `hasNight`**, which is the one place on
    /// this page that differs from its neighbours. The summary is `nil` below four prior nights, and a
    /// card drawn over four empty columns with a rule through them would be a picture of a comparison
    /// that was never made. It hides no reading when it is absent — the figure is on the breakdown row
    /// above either way — so the absence is honest in a way that gating the hours-of-sleep card on its
    /// chart would not have been. See `SleepViewModel.consistencySummary`.
    @ViewBuilder
    private var consistencyCard: some View {
        if let summary = viewModel.consistencySummary {
            SleepConsistencyCard(summary: summary)
        }
    }

    // MARK: - The ratio the two durations make

    /// The night's efficiency, the two durations it is the ratio of, and the two things this app
    /// cannot show about the night — the reference's `SLEEP EFFICIENCY` card.
    ///
    /// **It is gated on `hasNight`, and it is the only card on this page whose gate is that and nothing
    /// more.** The consistency card above is gated on `consistencySummary` because a chart of four
    /// empty columns would be a picture of a comparison that was never made; this card's middle is a
    /// note rather than a chart, so there is no shape here that can be drawn over nothing. What *is*
    /// required is a night: the three figures the card heads itself with are all readings off a
    /// `SleepSession`, and there is no session to read on a day with no night.
    ///
    /// **The comparison is optional and the card prints the figure alone without it.** It comes off
    /// `SleepViewModel.typicalEfficiency`, which is `nil` below `RecoveryScoring.minimumBaselineDays`
    /// measured nights — a state the consistency card's own gate would have hidden one element up, and
    /// here leaves the headline drawn and the mean withheld.
    @ViewBuilder
    private var efficiencyCard: some View {
        if let session = viewModel.session {
            SleepEfficiencyCard(
                efficiencyPercent: session.sleepEfficiencyPercentage,
                asleepSeconds: session.totalTimeAsleepSeconds,
                awakeSeconds: session.awakeSeconds,
                typicalEfficiencyPercent: viewModel.typicalEfficiency,
                disturbanceCount: session.disturbanceCount,
                timelineLanes: viewModel.timelineLanes)
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
