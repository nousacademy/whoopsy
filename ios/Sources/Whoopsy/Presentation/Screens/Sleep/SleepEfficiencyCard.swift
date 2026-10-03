import SwiftUI

/// The night's Sleep Efficiency: the figure, the two durations it is the ratio of, and the wake events
/// counted inside them.
///
/// **It is the reference's `SLEEP EFFICIENCY` card: a two-lane timeline down the middle — the night's
/// asleep episodes in blue over its awake episodes hatched — and a count beside `WAKE EVENTS` at the
/// foot.** The timeline is drawn whenever the night has a recorded one; each slot falls back to
/// `✱ Strap data not available.` on its own, and the two fall back for different reasons:
///
/// - **The timeline needs a recording, and `v12` is what made one survive.** `AnalyzeSleepUseCase`
///   builds a `[SleepStageSegment]` per 30-second epoch, but until `v12` there was no column for it —
///   `SleepRecord` wrote the four stage *totals* and nothing else — so the array was dropped at the
///   write and the read path's `[]` default filled it back in. A night the strap had staged perfectly
///   came back from storage indistinguishable from one that was never staged, and the timeline could
///   only ever have drawn on the night being computed live. It is now stored and read, so a past strap
///   night draws its own timeline too.
/// - **The export can never supply one**, and that is permanent rather than pending: it reports stage
///   totals and no timeline, which `WhoopExportImporter.makeSession` writes as `sleepStages: []`. So
///   every imported night draws the note, correctly, however the strap path is exercised.
/// - **`WAKE EVENTS` is a strap-only count**, `SleepSession.disturbanceCount`, and it is `nil` on every
///   imported night because the export has no such figure. It is also *not* a count of wake events in
///   the sense its label claims: see the note on `wakeEventsRow`.
///
/// **The two slots are gated separately and must stay that way.** A single "has strap data" flag would
/// be a claim about two producers made by neither of them — a night can hold a stored timeline with no
/// disturbance count, or (in principle) the reverse, and each slot answers to its own input. The
/// phrase is also repeated rather than stated once at the foot, for the same reason: one footnote would
/// make a reader work out which marker it excused.
///
/// **The `i` button is not drawn**, on `SleepConsistencyCard`'s rule: it is the reference's, it has no
/// destination here, and a control that looks tappable and is not reads as broken.
///
/// **The headline's comparison is real and is this app's own.** The reference prints `94%` over `87%`;
/// the mean under it is `SleepEfficiencyScoring.typicalEfficiency`, taken over
/// `RecoveryScoring.baselineWindow(before:in:)` — the same window every other "typical" figure on this
/// screen uses, so this card and the need card above it cannot come to disagree about how much history
/// a baseline needs. It is drawn here where the consistency card above declines the same shape, and the
/// difference is what the two cards have under them: the consistency card's headline sits over five
/// columns drawn from the same window and a second figure there restates the chart, while this card's
/// middle is a note and the comparison restates nothing.
///
/// **The card is gated on `hasNight` at the call site**, like the need card and the heading. It cannot
/// be gated on the figure — efficiency is a reading every stored night has — and it must not be gated
/// on the notes, which are the card's subject on every night this app can show.
public struct SleepEfficiencyCard: View {
    /// `SleepSession.sleepEfficiencyPercentage` — asleep over the sleep period.
    public let efficiencyPercent: Int

    /// `SleepSession.totalTimeAsleepSeconds` — the three staged sleep durations.
    public let asleepSeconds: TimeInterval

    /// `SleepSession.awakeSeconds` — the fourth row of the same night.
    public let awakeSeconds: TimeInterval

    /// The window's mean efficiency, or `nil` below `RecoveryScoring.minimumBaselineDays`.
    public let typicalEfficiencyPercent: Double?

    /// The night's counted disturbances, or `nil` when no strap produced one — which is every imported
    /// night, and therefore every night this app can currently show.
    public let disturbanceCount: Int?

    /// Where the night's timeline is filled, or `nil` when it has none.
    ///
    /// **This is the card's second gate, and it is separate from `disturbanceCount`'s on purpose.**
    /// The two slots have different producers: the count is a column that a strap night fills in, and
    /// the timeline is a recording that has to have been made *and stored* (`v12`). A night can
    /// therefore have one and not the other in either direction, and this card draws each slot from
    /// its own input rather than from a single "has strap data" flag — which would be a claim about
    /// two producers made by neither of them.
    public let timelineLanes: SleepTimelineLanes?

    public init(
        efficiencyPercent: Int,
        asleepSeconds: TimeInterval,
        awakeSeconds: TimeInterval,
        typicalEfficiencyPercent: Double?,
        disturbanceCount: Int?,
        timelineLanes: SleepTimelineLanes?
    ) {
        self.efficiencyPercent = efficiencyPercent
        self.asleepSeconds = asleepSeconds
        self.awakeSeconds = awakeSeconds
        self.typicalEfficiencyPercent = typicalEfficiencyPercent
        self.disturbanceCount = disturbanceCount
        self.timelineLanes = timelineLanes
    }

    /// The card's title, which is the reference's own and is also the name of the breakdown row above.
    ///
    /// The statics in this block are `nonisolated` for the reason `SleepConsistencyCard.title` records:
    /// the `View` conformance puts the whole type on the main actor, and these are strings built from
    /// `Sendable` values and read by nothing on screen. The suite calls them from a plain `Task`.
    public nonisolated static let title = "Sleep Efficiency"

    public nonisolated static let asleepLabel = "Asleep"
    public nonisolated static let awakeLabel = "Awake"

    /// The row at the card's foot, and the swatch beside it is the reference's own.
    public nonisolated static let wakeEventsLabel = "Wake Events"

    /// What a slot with no producer says, in the words the user chose.
    ///
    /// **It is one phrase for two slots**, and the suite asserts the word rather than the screenshot,
    /// because the word is the whole of what those slots currently say.
    public nonisolated static let strapDataNote = "Strap data not available."

    /// The marker the note is hung from — the user's own instruction, and the reason it is a `static`.
    ///
    /// **Not a symbol and not a dash.** A `—` is this app's mark for a figure that was measured and
    /// came back absent, which is a different claim: efficiency's `—` would say the night's ratio could
    /// not be taken, and it can. The asterisk is the reference-reading mark for a footnote, which is
    /// what the phrase under it is.
    public nonisolated static let strapMarker = "✱"

    /// The lane height the reference's two timeline bars share, and the slot is drawn at the height of
    /// both of them plus the gap between them — so the card's vertical rhythm is the reference's whether
    /// or not there is a timeline to draw.
    private static let laneHeight: CGFloat = 15
    private static let laneSpacing: CGFloat = 10

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(Self.title)

            headline

            VStack(alignment: .leading, spacing: 7) {
                measureRow(label: Self.asleepLabel, value: asleepSeconds.formattedCompactHoursMinutes())

                timelineSlot

                measureRow(label: Self.awakeLabel, value: awakeSeconds.formattedCompactHoursMinutes())
            }

            divider

            wakeEventsRow
        }
        .glassCard()
        // The timeline slot is a shape and the swatch is decoration, so the card is announced as one
        // element — the same treatment `SleepConsistencyCard` and `SleepNeedCard` take.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(
            efficiencyPercent: efficiencyPercent,
            asleepSeconds: asleepSeconds,
            awakeSeconds: awakeSeconds,
            typicalEfficiencyPercent: typicalEfficiencyPercent,
            disturbanceCount: disturbanceCount,
            timelineLanes: timelineLanes)))
    }

    // MARK: - The figure

    /// The night's efficiency over its own window mean, in `MetricHeadline`'s shape.
    ///
    /// **The comparison is made on the printed percentages and not on the ratio**, which is
    /// `MetricChange`'s own rule and matters here: `94%` over a mean of `93.6%` prints as `94` over
    /// `94`, and a marker pointing between two figures a reader can see are equal is a row contradicting
    /// itself.
    ///
    /// **`higherIsBetter: true`.** A night that spent more of its time in bed asleep is the better
    /// night, which is the direction `SleepBand.efficiency` bands in as well — the two readings of the
    /// same scale must not disagree about which end is good.
    ///
    /// `nil` arrives from `SleepEfficiencyScoring` on a window below `minimumBaselineDays`, and
    /// `MetricHeadline` prints the figure alone in that case. That is the *missing side* and not the
    /// consistency card's deliberate absence — see that card's `headline` for the other reason a caller
    /// passes `nil`.
    private var headline: some View {
        let change = MetricChange.between(
            current: Double(efficiencyPercent),
            previous: typicalEfficiencyPercent,
            higherIsBetter: true,
            formatted: { "\(Int($0.rounded()))%" })

        return MetricHeadline(text: "\(efficiencyPercent)%", change: change)
    }

    // MARK: - The two measures

    /// The label and figure pair the reference prints above and below its timeline.
    ///
    /// The same treatment `SleepNeedCard.measureRow` gives its two rows — value at the size the
    /// reference draws it, label in the uppercase-and-tracked form `SectionLabel` uses — so a reader can
    /// tell these apart from the card's own title without reading them, and so the two cards on this
    /// page that print a duration pair print it the same way.
    private func measureRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
    }

    // MARK: - Where the timeline goes

    /// The night's two lanes, or the note that says there are none.
    ///
    /// **`nil` lanes draw one faint slot at the combined height, and not two empty bars.** Two
    /// hatched-and-blue tracks with nothing in them would be a picture of a timeline this app did not
    /// record, in the two colours that mean "asleep" and "awake" — the strongest possible claim that
    /// the night had both, made by the absence of any reading. A single faint slot at the combined
    /// height says only that a recording belongs here, and it holds the card's vertical rhythm whether
    /// or not there is a timeline to fill it.
    ///
    /// The two heights are the same expression so the card does not change size when a night gains a
    /// timeline: `SleepTimelineView` is handed the identical `laneHeight`/`spacing` pair, so the drawn
    /// lanes and the note slot occupy exactly the same block. A card that grew by a few points on the
    /// nights it had more to say would move everything below it.
    ///
    /// The note slot is **not `Theme.ringTrack`**, and that is the difference between "unmeasured" and
    /// "zero": see that token's doc comment. A *drawn* lane is the other case, which is why
    /// `SleepTimelineView` uses the track colour where this does not.
    @ViewBuilder
    private var timelineSlot: some View {
        if let timelineLanes {
            SleepTimelineView(
                lanes: timelineLanes,
                laneHeight: Self.laneHeight,
                spacing: Self.laneSpacing)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.sleepTimelineSlot)
                .frame(height: Self.laneHeight * 2 + Self.laneSpacing)
                .overlay {
                    HStack(spacing: 5) {
                        Text(Self.strapMarker)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .accessibilityHidden(true)

                        Text(Self.strapDataNote)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                }
        }
    }

    // MARK: - The wake events

    /// The reference's closing row: a swatch, the word, and the night's disturbance count.
    ///
    /// **The count is `SleepSession.disturbanceCount`, which is absent on every night this app can
    /// show** — no strap has ever written one, and the export has no such column. The row draws the
    /// asterisk in the value's place and the note on the line beneath it, which is the shape the bar
    /// above takes and the only difference is layout: a bar's slot has no value column to hang a
    /// marker in, so the two go together inside it.
    ///
    /// **The number, when a strap does produce one, is a count of 30-second epochs and not of
    /// episodes.** `AnalyzeSleepUseCase` increments once per awake epoch, so a single 4-minute waking
    /// is filed as eight. That is a mislabel this card inherits rather than makes — the entity's own
    /// property carries it — and it is why the figure is drawn without a unit: `8` beside `WAKE EVENTS`
    /// is wrong by whatever the night's wakings were worth, and a unit would make it wrong in a way a
    /// reader could not check.
    private var wakeEventsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // The reference's own mark, and the same 11pt rounded square `SleepNeedCard.partRow`
                // uses for its key — one shape for "this row's colour" across both cards.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.textSecondary)
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)

                Text(Self.wakeEventsLabel.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 8)

                if let disturbanceCount {
                    Text("\(disturbanceCount)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                } else {
                    Text(Self.strapMarker)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                }
            }

            if disturbanceCount == nil {
                Text(Self.strapDataNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.15))
            .frame(height: 1)
    }

    // MARK: - The card in one sentence

    /// The figure, its comparison, the two durations, then the two things this app cannot show.
    ///
    /// **The durations are spoken through `formattedHoursMinutes()` and not the compact form printed**,
    /// on `SleepTypicalRangeCard.spokenStageRow`'s rule: `7:33` on screen is a clock reading to a
    /// listener, and `7h 33m` is a duration.
    ///
    /// **Both absences are spoken**, and in the same words the card prints. A listener gets no slot and
    /// no asterisk, so if the description omitted the note the card would announce two figures and
    /// silently drop the two things a sighted reader is told are missing — the failure the note exists
    /// to prevent, one accessibility tree over.
    ///
    /// It is a `static` rather than a computed property on the view, on the rule the rest of this repo's
    /// cards follow: this suite has no renderer, so text built inside a `body` is text nothing can
    /// assert. `nonisolated` for the reason `title` above records.
    public nonisolated static func spoken(
        efficiencyPercent: Int,
        asleepSeconds: TimeInterval,
        awakeSeconds: TimeInterval,
        typicalEfficiencyPercent: Double?,
        disturbanceCount: Int?,
        timelineLanes: SleepTimelineLanes?
    ) -> String {
        var spoken = "\(title), \(efficiencyPercent) percent"
        if let typical = typicalEfficiencyPercent {
            spoken += ", typical \(Int(typical.rounded())) percent"
        }

        spoken += ". \(asleepLabel), \(asleepSeconds.formattedHoursMinutes())"
        spoken += ". \(awakeLabel), \(awakeSeconds.formattedHoursMinutes())"

        // The picture, in words. A sighted reader gets two lanes and reads *when* the night woke; a
        // listener gets no shape at all, so the one thing worth speaking is how many separate
        // stretches of waking the lanes hold — which is `awake.count` precisely because
        // `SleepTimelineLanes.make` merged the epochs into runs. **It is not the `WAKE EVENTS` figure
        // below and must not be confused with it**: that count is absent on every night this app can
        // show, and where both exist they answer different questions — this one counts *episodes*, the
        // other counts the 30-second epochs they were cut into.
        if let timelineLanes {
            spoken += ". The night's sleep timeline was recorded,"
            spoken += " showing \(timelineLanes.awake.count) stretches of waking."
        } else {
            spoken += ". The night's sleep timeline was not recorded."
        }

        guard let disturbanceCount else {
            return spoken + " \(wakeEventsLabel), \(strapDataNote)"
        }
        return spoken + " \(wakeEventsLabel), \(disturbanceCount)"
    }
}
