import SwiftUI

/// One night's sleep page — the block the user's mockup draws, and nothing below it.
///
/// **It opens on `SLEEP` and the night's clock span, its two headline figures, one sentence about
/// them, and the heart-rate trace.** That is the whole page: the user's instruction was *"just do up
/// to the chart in the mockup, everything below is just duplicate from the sleep ring"*, and the ring
/// is Home's sleep ring — the composite, the stage breakdown, the consistency and efficiency cards and
/// the week charts all describe a figure the reader has already been shown. They are not deleted, only
/// undrawn here: `SleepTypicalRangeCard`, `SleepConsistencyCard`, `SleepEfficiencyCard`,
/// `SleepNeedCard`, `SleepStressCard` and the three week charts keep their own files and their own
/// suite assertions, so bringing one back is a line in this `body` rather than a rebuild.
///
/// **The user's rule that the sleep ring and the `SLEEP` row open one page still holds.** Both call
/// sites read `HomeDashboardView.sleepDetail`, so what this page is cannot be changed for one route
/// and missed at the other.
///
/// It is `RecoveryDetailView`'s counterpart: the day is handed in as a plain `let`, there is no
/// stepper and no calendar, and `viewModel.load(for:)` runs in a `.task`. It owns no
/// `NavigationStack` of its own, because it is pushed rather than presented.
///
/// **Nothing is drawn in the navigation-title slot**, where the reference also draws nothing: the
/// date is stated once, by the heading's subtitle — the night's span, dated when the night is not
/// today's. The heading is gated on `hasNight`, so a nightless day names no date at all and draws no
/// figures; that is the honest reading of an absent night rather than a regression.
public struct SleepDetailView: View {
    @State private var viewModel: SleepViewModel

    /// The night shown, fixed for the life of the view. A plain `let` for `RecoveryDetailView`'s
    /// reason: nothing here can change it, so nothing should be able to.
    private let date: Date

    /// Told the row that was written, so Home's `SLEEP` row can draw the new bounds without a reload.
    ///
    /// **The pop re-fires no `.task`**, so a page that saved and left would leave the card behind it
    /// printing the old span — the gotcha this repo has hit before. The callback is `ActivityDetailView`'s
    /// `onSaved`, for its reason, and it is optional so the previews and the runner are not forced to
    /// invent a Home to tell.
    private let onTimesEdited: ((SleepSession) -> Void)?

    /// The edit in progress, or `nil` when the sheet is closed. Owned here so a dismissal and a re-open
    /// start from the stored night rather than from a half-finished edit.
    @State private var editDraft: SleepTimeEditDraft?
    @State private var isSavingEdit = false

    /// Whether the `•••`'s menu is up.
    ///
    /// **A `•••` and not a pencil**, on the user's instruction that this page use *"the 3 dots like
    /// other activities"*: the activity page's overflow control is the app's one place a page's actions
    /// live, and a second affordance for the same kind of act would make a reader learn two.
    @State private var isPresentingOverflowMenu = false

    public init(
        viewModel: SleepViewModel,
        date: Date,
        onTimesEdited: ((SleepSession) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.date = date
        self.onTimesEdited = onTimesEdited
    }

    public var body: some View {
        ScrollView {
            // **The chart is the one element that runs edge to edge**, as the reference draws it: the
            // text keeps the page's margin and the trace does not, so the section label lines up with
            // the words above it while the plot spans the screen.
            VStack(alignment: .leading, spacing: 18) {
                nightHeading
                    .padding(.horizontal)

                nightStats
                    .padding(.horizontal)

                stageShareSentence
                    .padding(.horizontal)

                heartRateSection
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `StrainDetailView`'s line, for its reason: a `ScrollView` whose content holds nothing
        // flexible lays out at its content's width and paints a column.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .task {
            // The writer's feed first, so a night that lands after this load fills the page rather
            // than waiting for another push.
            viewModel.observeNights()
            await viewModel.load(for: date)
        }
        // The `•••`'s menu, drawn by the same `OverflowMenuOverlay` the activity page uses. An overlay
        // rather than a `.sheet`, on that page's rule: a menu is a row of actions whose whole reading
        // is that it belongs to the page behind it.
        .overlay {
            if isPresentingOverflowMenu {
                OverflowMenuOverlay(
                    groups: ActivityOverflowMenu.nightGroups,
                    dismissLabel: "Dismisses the sleep options",
                    onSelect: { perform($0) },
                    onDismiss: { dismissOverflowMenu() })
            }
        }

        // **The binding reads back through `editDraft` rather than through the closure's argument**,
        // on `ActivityDetailView`'s rule: the sheet writes into the draft on every pick, and a binding
        // built on the captured copy would hand the sheet its opening state on the next render.
        .sheet(item: $editDraft) { presented in
            SleepTimeEditSheet(
                draft: Binding(
                    get: { editDraft ?? presented },
                    set: { editDraft = $0 }),
                isSaving: isSavingEdit,
                onSave: { saveEdit() })
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The menu

    private func presentOverflowMenu() {
        withAnimation(.snappy(duration: 0.3)) { isPresentingOverflowMenu = true }
    }

    private func dismissOverflowMenu() {
        withAnimation(.snappy(duration: 0.26)) { isPresentingOverflowMenu = false }
    }

    /// Runs the row's action. **Every row closes the menu first**, `Cancel` included — what a menu row
    /// does — which is `ActivityDetailView.perform(_:)`'s order.
    ///
    /// The `switch` is exhaustive over `ActivityOverflowMenu.Entry.Action` so a case added for another
    /// page's menu stops this compiling until it is handled here too.
    private func perform(_ action: ActivityOverflowMenu.Entry.Action) {
        dismissOverflowMenu()
        switch action {
        case .edit:
            if let session = viewModel.session {
                editDraft = SleepTimeEditDraft(session: session)
            }
        case .delete, .endFast:
            // Neither row is in `nightGroups`, and the enum is shared with the activity page's menu,
            // which has both. A night has no delete — see `nightGroups` — and no fast to end.
            break
        case .cancel:
            break
        }
    }

    /// Writes the edit, and leaves the sheet **only** once the row is in.
    ///
    /// A failed write does not dismiss: a sheet that closed over a write that did not happen would
    /// leave the page printing the old span as though the save had landed — `ActivityDetailView.saveEdit`'s
    /// rule, and the reason the view model reports a `Bool` rather than throwing through the view.
    private func saveEdit() {
        guard let draft = editDraft else { return }
        guard draft.canSave else {
            editDraft = nil
            return
        }
        isSavingEdit = true
        Task {
            let saved = await viewModel.saveTimes(start: draft.start, end: draft.end)
            isSavingEdit = false
            guard saved else { return }
            editDraft = nil
            // Read back off the view model rather than off the draft: `saveTimes` re-reads the night,
            // so what Home is handed is the row that was persisted.
            if let updated = viewModel.session {
                onTimesEdited?(updated)
            }
        }
    }

    // MARK: - The night's name

    /// The reference's header: a crescent, `SLEEP`, and the night's clock span.
    @ViewBuilder
    private var nightHeading: some View {
        if let session = viewModel.session {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    // The reference's crescent, in the sleep token — the same mark Home's `SLEEP` row
                    // carries, so the row and the page it opens are recognisably one subject.
                    Image(systemName: "moon.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.sleepPerformance)
                        .accessibilityHidden(true)

                    Text(SleepDetailHeading.title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer(minLength: 0)

                    overflowControl
                }

                Text(
                    SleepDetailHeading.subtitle(
                        start: session.startTime, end: session.endTime, on: date))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // `.contain` rather than `.ignore`: the heading is one statement, and the `•••` beside it
            // is its own control — an `.ignore` here would swallow the menu's only way in.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                Text(
                    SleepDetailHeading.spoken(
                        start: session.startTime, end: session.endTime, on: date)))
        }
    }

    /// The control in the top-right corner: the `•••` — **drawn exactly as the activity page draws
    /// its own**, at the same size and weight in the page's own text colour, and in the page's content
    /// rather than in the navigation bar's toolbar slot.
    ///
    /// **That last part is the whole of the request**: a toolbar item is wrapped in the system's glass
    /// circle on iOS 26, which is a second affordance for the same act. The activity page's control is
    /// a bare glyph at the trailing end of its header, so this one is too.
    private var overflowControl: some View {
        Button {
            presentOverflowMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(height: 40, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
    }

    // MARK: - The two headline figures

    /// The night's hours of sleep and restorative sleep, side by side — the reference's pair.
    @ViewBuilder
    private var nightStats: some View {
        if let session = viewModel.session {
            SleepNightStats(
                asleepSeconds: session.totalTimeAsleepSeconds,
                typicalAsleepSeconds: viewModel.stageSummary?.typicalAsleepSeconds,
                restorativeSeconds: session.restorativeSleepSeconds,
                typicalRestorativeSeconds: viewModel.stageSummary?.typicalRestorativeSeconds)
        }
    }

    /// The restorative share in words, under the pair it describes.
    ///
    /// **Gated on the night, not on the window.** The sentence is about tonight's own two figures — the
    /// share REM and deep took of what was slept — so it needs no prior nights, and a night whose
    /// window is too thin for a mean still gets told what its share was. The threshold it grades
    /// against lives in `SleepScoreScoring`, beside the term the ring is scored from.
    @ViewBuilder
    private var stageShareSentence: some View {
        if
            let session = viewModel.session,
            let sentence = SleepStageShareMessage.sentence(
                restorativeSeconds: session.restorativeSleepSeconds,
                asleepSeconds: session.totalTimeAsleepSeconds)
        {
            Text(sentence)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - The night's heart rate

    /// `HEART RATE` over the night's trace — the reference draws the section label and the chart
    /// straight on the page, with no card around them, and this follows it.
    ///
    /// **The section is the trace alone.** The night's hours of sleep used to head this card and moved
    /// up into the pair above it, where the reference puts it. That is also why the types behind the
    /// trace are still named `HoursOfSleepChart*` while the points they carry are `bpm`: they were
    /// built for that card, and a rename would touch every fixture behind them for a word.
    ///
    /// **The chart needs `biometric_samples`, which only a worn strap fills.** A night imported from
    /// the export has hours of sleep and stage shares and no trace at all, so this is the one thing on
    /// the page that draws `No Data` — the two figures above it stay printed.
    @ViewBuilder
    private var heartRateSection: some View {
        if hasNight {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Heart rate")
                    .padding(.horizontal)

                if let series = viewModel.hoursOfSleepSeries {
                    HoursOfSleepChartView(series: series)
                } else {
                    noSleepingData
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The chart is a `Shape` and says nothing to VoiceOver, so the section is announced as one
            // element describing the recording.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(heartRateSpoken))
        }
    }

    /// The absence state, and the reason it is not a blank chart.
    ///
    /// **It speaks for the chart alone.** The two figures above it are real readings — the night has
    /// its hours of sleep and its restorative sleep — so a message that read as the page's own state
    /// would contradict them. It is phrased about the *recording* for that reason.
    ///
    /// **It does not say "sync your strap".** A drain is what would fill this, and telling a user to
    /// sync would promise a fix this build cannot deliver; what it says instead is the narrow true
    /// thing — this app records sleeping data only while it is connected.
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

    /// The recording in one sentence: the two ends and the count.
    ///
    /// A listener cannot hear a curve, so the trace is described by its bounds and its size rather than
    /// read out — and the two headline figures above it speak for themselves.
    private var heartRateSpoken: String {
        guard let series = viewModel.hoursOfSleepSeries else {
            return "Heart rate, No Data. No heart rate was recorded for this night."
        }
        let readings = series.points.count == 1 ? "1 reading" : "\(series.points.count) readings"
        return "Heart rate during sleep, \(readings) from "
            + "\(series.start.formattedHourMinute()) to \(series.end.formattedHourMinute())"
    }

    // MARK: - The night's figures

    private var hasNight: Bool { viewModel.session != nil }
}
