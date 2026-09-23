import SwiftUI

/// One recorded activity, opened from the `ACTIVITIES` card on Home.
///
/// ## The page, top to bottom
///
/// A header naming the session and when it was; its strain and its steps, each read against the same
/// activity's own recent history; its heart-rate trace; its length banded against what is typical for
/// that activity; and its five heart-rate zone rows.
///
/// ## What it is not
///
/// **No `AUTO-DETECTED` badge.** The reference draws one and the user's instruction was to take it out:
/// every session on this page came from a file or from a session the user started by hand, and this app
/// has no activity classifier at all — so a badge claiming the session was detected would be the app
/// describing a capability it does not have. That is the absence rule applied to a capability, on the
/// same terms as the `RECORD ROUTE` toggle's refused-permission sentence.
///
/// **No delete, no edit, no splits.** `workout_splits` still has no producer and nothing here writes.
///
/// ## Why it owns no `NavigationStack`
///
/// The pushed-page shape `RecoveryDetailView`, `SleepDetailView` and `StrainDetailView` all take: the
/// pushing screen — Home — supplies the chrome, and this page supplies the content. A `NavigationStack`
/// here would nest one inside Home's and draw a second navigation bar.
public struct ActivityDetailView: View {

    /// The page's state. A `@State` holding a `@MainActor @Observable` class, on the shape every other
    /// screen here uses: the pushing screen builds it and hands it over, and re-renders of Home behind
    /// the push cannot re-point it at another session because the session is a `let` on the view model.
    @State private var viewModel: ActivityDetailViewModel

    public init(viewModel: ActivityDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                metricsCard

                heartRateCard

                typicalRangeCard

                zonesCard
            }
            .padding()
        }
        // Not optional: a `ScrollView` whose content holds nothing flexible lays out at its content's
        // width, and this page's narrowest card is a card of text — see `StrainDetailView`'s gotcha for
        // the pure-black column that draws down both sides when this is left off.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .task { await viewModel.load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    /// The session's name, when it was, and the glyph Home drew for it.
    ///
    /// **The glyph comes from `ActivityGlyph.symbol(for:)`**, the app's one name-to-symbol mapping, so
    /// the chip here and the row on Home cannot come to draw one activity two ways. `nil` and an
    /// unmapped name both fall back inside that type rather than here.
    ///
    /// **The name is WHOOP's own word and the fallback is WHOOP's own word too.** `activityName` is
    /// `nil` on every session this app recorded itself, and the reference's own label for an activity
    /// its classifier could not name is `ACTIVITY` — the literal string on 197 of the export's 673
    /// rows. So the fallback is not a placeholder this page invented; it is the same word WHOOP writes.
    /// It is drawn as a **label and not a dash**, because a name was never a measurement.
    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: ActivityGlyph.symbol(for: viewModel.session.activityName))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.strainRing)
                .frame(width: 38, height: 38)
                .background(Theme.strainRing.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .textCase(.uppercase)
                    .lineLimit(1)

                Text(Self.subtitle(startedAt: viewModel.session.startedAt, endedAt: viewModel.session.endedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }

    /// The session's name, uppercased for the drawing only — `HomeDashboardView.activityRow`'s rule,
    /// and `textCase` is idempotent over the already-uppercase `ACTIVITY` fallback.
    private var displayName: String { viewModel.session.activityName ?? "ACTIVITY" }

    /// When the session was, in one line.
    ///
    /// `nonisolated static` rather than composed in the `body`, on the rule this page's other strings
    /// follow: the runner has no renderer, so a sentence written into a `body` is a sentence nothing can
    /// assert. The date is the app's existing short form (`Sun, Aug 10`) and the two ends are its
    /// existing clock form, so this page introduces no fourth date format.
    public nonisolated static func subtitle(startedAt: Date, endedAt: Date) -> String {
        "\(startedAt.formattedShortDate()) \(startedAt.formattedHourMinute()) to \(endedAt.formattedHourMinute())"
    }

    // MARK: - Strain and steps

    /// The session's two headline figures, each with its comparison against this activity's history.
    ///
    /// **Both badges are neutral and neither carries a verdict** — see `ActivityDelta`. Strain rising
    /// against the last ten basketball sessions is neither good news nor bad, and there is no token on
    /// this page that would let a reader think otherwise.
    ///
    /// **The basis is named on the card**, which is what the user asked for: the mean each figure is
    /// compared against is written under it, and the card's footnote says how many sessions it was taken
    /// over. Without that, `vs 3.8` is a comparison against a number with no stated provenance.
    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            metricRow(
                title: "ACTIVITY STRAIN",
                value: viewModel.strainText,
                delta: viewModel.strainDelta)

            Divider().overlay(Theme.cardBorder)

            metricRow(
                title: "ACTIVITY STEPS",
                value: viewModel.stepsText,
                delta: viewModel.stepsDelta)

            Text(Self.comparisonBasis(sessionCount: viewModel.comparisonSessionCount))
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// One figure with its label and its badge.
    ///
    /// The badge is drawn **only when there is a delta**, so a session with no history shows the figure
    /// and nothing beside it rather than an empty badge or a `vs —`.
    private func metricRow(title: String, value: String, delta: ActivityDelta?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                ActivityDeltaBadge(delta: delta, showsMean: false)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sentence naming what the two badges were taken over.
    ///
    /// **It says so plainly when there was nothing to compare against**, rather than leaving the card
    /// bare: a reader who sees no badge should be told why, and *"not enough history yet"* and *"this is
    /// the first time"* are the same sentence here because both are true of the same state.
    public nonisolated static func comparisonBasis(sessionCount: Int) -> String {
        guard sessionCount > 0 else {
            return "No comparison: not enough previous sessions of this activity yet."
        }
        let sessions = sessionCount == 1 ? "session" : "sessions"
        return "Compared with your last \(sessionCount) \(sessions) of this activity."
    }

    // MARK: - Heart rate

    /// The session's heart-rate trace, or the absence state where the chart would be.
    ///
    /// **`No Data` on every session this app can currently show**, and the caption says why in the
    /// narrowest true terms: `biometric_samples` holds nothing here, the export carries no heart-rate
    /// series, and this app records one only while it is connected to a strap. It deliberately does not
    /// say "sync your strap" — this build's drain has no record walk, so that would promise a fix that
    /// does not exist. `SleepDetailView.noSleepingData`'s wording, for its reason.
    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HEART RATE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)

            if let series = viewModel.heartRateSeries {
                ActivityHeartRateChartView(series: series)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Data")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(
                        "No heart rate was recorded for this activity. This app records heart rate "
                            + "only while it is connected to a strap."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Typical range

    /// This session's length, over the band that length normally sits in.
    ///
    /// **The whole card is absent when there is no band**, rather than the row being drawn with a
    /// figure and no bar: the bar's scale *is* the band — see `ActivityDurationBarLayout` — so a bar
    /// without one would be a length with nothing to read it against. Unlike the sleep page's card
    /// there is no second figure here to keep it alive.
    @ViewBuilder
    private var typicalRangeCard: some View {
        if let layout = viewModel.durationLayout, let typical = viewModel.baseline.typicalDuration {
            VStack(alignment: .leading, spacing: 12) {
                Text("TYPICAL RANGE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("DURATION")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textSecondary)

                    Text(viewModel.durationText)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer(minLength: 0)
                }

                ActivityDurationBar(layout: layout)

                Text(Self.typicalDurationCaption(low: typical.low, high: typical.high))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Self.spokenDuration(
                    durationText: viewModel.durationText, low: typical.low, high: typical.high))
        }
    }

    /// The band as a caption, in minutes — `Typical: 9-26 min`.
    ///
    /// **Minutes and not `m:ss`**, because this is a *range* rather than a reading: two clock-shaped
    /// durations side by side invite the eye to compare digits, and the band is a span of the scale. The
    /// session's own figure above it keeps the `0:15:58` shape, which is the reference's.
    public nonisolated static func typicalDurationCaption(low: Double, high: Double) -> String {
        "Typical: \(minutes(low))-\(minutes(high)) min"
    }

    /// The card in one sentence: what the session lasted, and what is typical.
    public nonisolated static func spokenDuration(
        durationText: String, low: Double, high: Double
    ) -> String {
        "Duration \(durationText). Typical for this activity is \(minutes(low)) to \(minutes(high)) minutes."
    }

    /// Whole minutes, rounded — the unit the caption prints.
    private nonisolated static func minutes(_ seconds: Double) -> Int {
        Int((seconds / 60).rounded())
    }

    // MARK: - Heart rate zones

    /// The five bands, hardest first, each with its BPM range, its share and its time.
    ///
    /// **This block is what the user asked to sit below the chart** — *"heart zones, zone 1, 2, 3, 4,
    /// and 5 and time duration within those zones for that workout"* — and it is drawn whether or not
    /// the chart above it has a trace, because the two answer different questions: the chart is a
    /// recording this app makes, the rows are WHOOP's own published block. A session with no trace can
    /// still have five real rows.
    ///
    /// **A session with no block draws five dashes**, not a `0%` and not an absent card. See
    /// `ActivityZoneRow` for why those are different answers and which one this is.
    @ViewBuilder
    private var zonesCard: some View {
        if !viewModel.zoneRows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("HEART RATE ZONES")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textSecondary)

                ForEach(viewModel.zoneRows, id: \.index) { row in
                    zoneRow(row)
                }

                Text(Self.zoneFootnote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private func zoneRow(_ row: ActivityZoneRow) -> some View {
        HStack(spacing: 8) {
            Text("ZONE \(row.index.rawValue)")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 58, alignment: .leading)

            Text(row.bpmRangeText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 62, alignment: .leading)

            Text(row.percentText)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, alignment: .trailing)

            Spacer(minLength: 4)

            Text(row.secondsText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivityZoneRow.spoken(row))
    }

    /// The one thing about this block a reader cannot work out from the rows.
    ///
    /// **The five do not sum to the session**, and a reader who adds the column up and finds it short
    /// would otherwise read that as an error. The remainder is time below zone 1, which WHOOP publishes
    /// no column for — the same fact `WorkoutSession`'s own doc comment records and the reason these
    /// rows are not derived through `WholePercentMath`.
    ///
    /// **And the edges are not WHOOP's.** The shares are its own; the BPM boundaries are this app's
    /// Karvonen table off the profile's two heart rates, which on a fresh install is the cold-start
    /// `190/60` constant. Saying so on the card is the same judgement that labels Home's VO₂ figure
    /// `(EST.)` — the figure is real, its provenance is this app's.
    private nonisolated static let zoneFootnote =
        "Zone percentages are WHOOP's own and need not sum to 100: time below zone 1 belongs to no band. "
        + "The BPM boundaries are this app's, from your profile's heart rates."
}
