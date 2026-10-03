import SwiftUI

/// The dashboard, rebuilt to `whoopsy-app-design/new/home-top.jpg`.
///
/// Every figure on it is either measured or a dash. That rule is the whole reason several of these
/// elements are optional properties rather than formatted strings: a day with no strap data and a day
/// whose strap recorded a zero look identical once a number is on screen, which is the failure mode
/// this screen has to avoid — see `HomeViewModel` for each source's absence rule.
///
/// **Omitted from the mockup, deliberately:** `CUSTOMIZE`, the pencil, the ACTIVITIES expand icon, and
/// the chevrons beside the rings and the STRESS MONITOR tile. None of them have a destination in this
/// app, and a control that looks tappable and is not reads as broken.
///
/// **All three rings push, and they push rather than switching tabs.** The recovery ring opens
/// `RecoveryDetailView`, the sleep ring opens `SleepDetailView` and the strain ring opens
/// `StrainDetailView`, all seeded with the day on screen and all on the `NavigationStack` this screen
/// already owns. Switching to a tab would have been cheaper and is wrong: the Recovery, Sleep and
/// Strain tabs each keep a private day seeded to `Date()`, so tapping an 87% ring on an imported day
/// would land on "No data recorded" — today is past the export's end. The STRESS MONITOR tile stays
/// inert for that same reason rather than the one it used to share with the strain ring: it has no
/// detail page to push yet, and the three rings are the shape to copy when it gets one. **The
/// chevrons stay omitted** — a chevron on one of three otherwise identical rings would say the others
/// are broken, and the tap target is discoverable without it.
///
/// **Implemented from the scrolled state of the reference:** the three rings collapse into a compact
/// row pinned to the top once they scroll out of view (`collapsedHeader`), and the STRESS MONITOR tile
/// draws the day's windows (`StressMonitorChartView`).
///
/// **The week's figures all come from one `MetricWeek`.** The RHR, SLEEP NEEDED, HRV and VO₂ MAX
/// panels and the STRAIN & RECOVERY chart are views of the same seven days, so they read through one
/// value rather than five separate reads — see
/// `HomeViewModel.metricWeek`. Each panel's small number is a **7-day mean of its own metric**, which
/// is what the reference's figures are; it is not the previous day, and not
/// `UserProfile.targetSleepHours`, which is a hard-coded `8.0` that nothing ever persists.
///
/// **One of the five panels prints a model's output beside four measurements, and its label is the
/// only thing that says so.** Nothing this app can read produces a VO₂ max — the export has no column
/// for one, the strap has no sensor for one, and the HealthKit read-through was deleted — so
/// `vo2MaxPanel` prints `Vo2MaxMath.heartRateRatioEstimate`, derived on read inside `MetricWeek` from
/// the slot's own gated resting heart rate and the profile's assumed maximal heart rate, and renders
/// `—` on every day that cannot produce one. That is the same bargain the STEPS tile makes, and the
/// alternative was a number nobody measured. Three consequences are load-bearing: the label carries
/// `(EST.)` and the other four must not, the panel takes no change arrow because the quantity moves
/// on a scale of years, and the figure is one significant figure because its error bar is quoted in
/// whole mL·kg⁻¹·min⁻¹ — `docs/ALGORITHMS.md` §6 carries the model, its 4.7 mL·kg⁻¹·min⁻¹ SEE, and the
/// sex-specific factor the app does not implement.
public struct HomeDashboardView: View {
    @State private var viewModel: HomeViewModel
    /// Built here rather than reached for at the tap, because a pushed screen's view model has to
    /// exist before the push animation starts or the destination renders empty for a frame. It is a
    /// second `RecoveryViewModel` beside the Recovery tab's, deliberately: they are two screens with
    /// two days, and sharing one would make paging the pushed copy move the tab's day underneath it.
    @State private var recoveryViewModel: RecoveryViewModel
    /// Built here for the same reason `recoveryViewModel` is: the sleep ring's destination needs a
    /// view model before the push animation starts. A second `SleepViewModel` beside the Sleep tab's,
    /// so paging the pushed screen cannot move the tab's night underneath it.
    @State private var sleepViewModel: SleepViewModel
    /// Built here for the same reason the two above are, and a second `StrainViewModel` beside the
    /// Strain tab's: they are two screens with two days, and sharing one would make paging the pushed
    /// copy move the tab's day underneath it.
    @State private var strainViewModel: StrainViewModel
    @State private var selectedDate: Date = Date()
    @State private var isPresentingCalendar = false
    /// The `+`'s menu. A second overlay flag rather than a mode of the calendar's: the two hang from
    /// different anchors, dismiss on their own, and cannot be open at once — the calendar's scrim
    /// covers the `+` that opens this one.
    @State private var isPresentingActivityMenu = false

    /// The activity row whose detail page is pushed, if any.
    ///
    /// **A state value rather than a `NavigationLink` destination, and the tab bar is why.** An activity
    /// row used to be a plain `NavigationLink { ActivityDetailView(…) }`, which gives no flag for the
    /// root view to read — and `.hidingTabBar(_:)` does nothing at all on a pushed destination
    /// (see the `hidingTabBar` call below). So the *value* is held here and the destination is declared
    /// from it, which is what gives this screen the flag. It is the same shape `isPresentingLiveSession`
    /// has, for the same reason, with `navigationDestination(item:)` instead of `isPresented:` so the
    /// page is not torn down mid-pop when the binding clears.
    ///
    /// `WorkoutSession` is `Hashable` for this one call site — see its own comment.
    @State private var presentedActivity: WorkoutSession?

    /// The running fast whose page is pushed, if any — a **second** item binding rather than a reuse of
    /// `presentedActivity`, and the two are not interchangeable.
    ///
    /// `presentedActivity` is wired to `viewModel.removeWorkout(_:)` and
    /// `viewModel.updateWorkout(_:on:)`, which mutate the list this screen is drawing. A live fast is
    /// not *in* that list — it is the bar, by the user's own choice — so a delete or an edit reported
    /// against its id would be a mutation of nothing. Keeping the two bindings apart is also what makes
    /// the live page's no-op `onDeleted`/`onSaved` genuinely unreachable rather than merely unused: its
    /// menu has no `Delete` and no `Edit` to reach them with.
    @State private var presentedFast: PresentedFast?

    /// The running fast, paired with the row it projected **at the moment of the tap**.
    ///
    /// **A wrapper rather than two state values, and the projection being stored is the whole point.**
    /// `ActivityDetailView` takes a `WorkoutSession` as a plain `let` on its view model — that is what
    /// keeps a re-render of Home from re-pointing a pushed page — and it additionally needs to know the
    /// session is still *running*, which no projected row can say (see
    /// `ActivityDetailViewModel.liveFast`). So the page takes both.
    ///
    /// **`session` is computed once, here, and never in the destination closure.** `projectedSession`
    /// mints a fresh `UUID` per call, so recomputing it while SwiftUI builds the destination would give
    /// the `item:` binding a new identity on every body evaluation — which tears the page down and
    /// rebuilds it, re-running its `.task` and its 180-day recovery read under the reader's finger. The
    /// `now` pinned here is the tap's, so the page opens showing the fast's length as of the tap and
    /// ticks on from its own anchor from there.
    ///
    /// It is nested here rather than in `Domain` because it is a *presentation* pairing: nothing below
    /// this screen has reason to hold a projected row beside the live fast it came from.
    private struct PresentedFast: Hashable {
        let session: WorkoutSession
        let fast: ActiveFast
    }

    /// The device page, reached from the badge in the top bar.
    ///
    /// **It is the same instance More → Device pushes**, built once in `MainContainerView.init` and
    /// handed to both. That is a change rather than a detail: the badge used to push a page of its own
    /// (`DeviceDetailView`) with its own view model, while More pushed a second page
    /// (`DeviceSettingsView`) with a second one — and the two came to disagree about the same strap's
    /// battery, one gating the reading and the other printing `device?.batteryPercentage ?? 0`. One
    /// page with one subject is the fix, and it is why this is a stored `let` built up front rather
    /// than a destination-side construction: a `NavigationLink` destination is re-evaluated on each
    /// push, and a view model constructed in its closure would lose the device subscription each push
    /// and start another.
    private let deviceViewModel: DeviceViewModel

    /// The profile page, reached from the control at the leading end of `topBar`.
    ///
    /// **This control is the page's only door.** `MoreView`'s list carried a `Profile` row until the
    /// user removed it. That does not make the view model a destination-side construction: it is built
    /// once in `MainContainerView.init` and handed down, which is what `deviceViewModel` above does and
    /// what the wiring rule requires — `MainContainerView` is the only place a screen's view model is
    /// built. A `NavigationLink` destination is re-evaluated on each push, so one constructed in its
    /// closure would be a fresh subject per push: a form that had loaded the stored profile would be
    /// re-read underneath the reader, and an unsaved edit would go with it.
    private let profileViewModel: ProfileViewModel

    /// The profile page's `LOGS` tab, which is every way data enters and leaves this app.
    ///
    /// **A second view model because the profile page is two subjects**, which `ui-regression-guard`
    /// §4's one-view-model-per-screen rule reads as a rule about *screens*: `BIOMETRICS` is a form over
    /// `user_profiles` and `LOGS` is four imports and an export over `AppPreferences` and the files on
    /// disk. Handing one instance both would give the two tabs one `status` string and one `isImporting`
    /// flag, so a save on BIOMETRICS could overwrite the sentence an import on LOGS had just written.
    ///
    /// It is a stored `let` built in `MainContainerView.init` rather than a destination-side
    /// construction, for `profileViewModel`'s own reason: `MainContainerView` is the only place a
    /// screen's view model is built, and a `NavigationLink` destination is re-evaluated on every push.
    private let localDataViewModel: LocalDataViewModel

    /// The live session, owned by the app rather than by this screen.
    ///
    /// It is **not** built here and not a `@State`: a session has to outlive the screen that starts it,
    /// and a value this screen owns would be torn down with it. `DIContainer` holds the one instance
    /// and `MainContainerView` hands it down, so backing out of `LiveSessionView` — or off Home
    /// entirely — leaves it recording. That is the user's stated requirement, and it is why this is a
    /// `let` and not the `@State` its three sibling view models are.
    private let liveSessionUseCase: LiveSessionUseCase

    /// Whether `LiveSessionView` is pushed.
    ///
    /// The destination itself has to live **inside** the `NavigationStack` below, while the menu whose
    /// row sets this is an overlay applied *outside* it — so the row cannot be a `NavigationLink`, and
    /// this flag is the bridge between the two.
    @State private var isPresentingLiveSession = false

    /// Whether the activity picker is pushed, and the name it is answering with.
    ///
    /// **The picker is what `START ACTIVITY` opens now, and it is how a fast is started.** The catalogue
    /// it draws holds `Fast`, so the picker is the app's one entry point to both kinds of live session —
    /// which is what makes the user's *"if a fast is started"* reachable at all, there having been no way
    /// to start one before. `ActivityPickerView` is unchanged: a plain pushed view writing a
    /// `Binding<String?>`, and on a `nil` selection its *Current* section and its checkmark are both
    /// inert, which is why `presentActivityPicker()` clears the name before each opening.
    ///
    /// A flag and a value rather than `navigationDestination(item:)`, because the picker's subject *is*
    /// that binding — an `item:` binding would need the picker's whole answer to be `Hashable` and would
    /// clear it on the way out, taking the value `onChange` has to read with it.
    @State private var isPresentingActivityPicker = false
    @State private var pickedActivityName: String?

    /// One session's detail page, built on demand.
    ///
    /// **A factory rather than three more stored repositories**, and the reason is the shape of the
    /// destination rather than a preference: the three rings push a page whose *subject* is the day
    /// this screen is showing, so one view model built up front serves every push. An activity row's
    /// subject is the row — `viewModel.workouts` is an array and any of its elements can be tapped —
    /// so there is nothing to build until the tap happens.
    ///
    /// **`MainContainerView` is still the only place a view model is built**, which is the rule this
    /// closure exists to keep: it is constructed there out of `DIContainer` and handed down, exactly as
    /// the three `@State` view models above are. What this screen supplies is the session.
    ///
    /// **A fresh instance per push is correct here, and `deviceViewModel`'s warning does not
    /// apply.** That comment is about a view model holding a stream subscription, which a second
    /// construction would silently re-open; `ActivityDetailViewModel` holds only repositories and does
    /// its one read in the destination's `.task`, so a per-push instance re-reads the history — which
    /// is what a reader returning to a session wants — and leaks nothing. Construction itself does no
    /// work, so it is also safe if SwiftUI evaluates this closure on a plain re-render of Home.
    ///
    /// **The second argument is the running fast, or `nil` on every other push.** It is not a second
    /// factory: the page is about a session either way, and the fast is the one subject that also knows
    /// it is still running — which the projection cannot say for itself, since a projected row's
    /// `endedAt` is its own `now`.
    private let makeActivityDetailViewModel: (WorkoutSession, ActiveFast?) -> ActivityDetailViewModel

    public init(
        viewModel: HomeViewModel,
        recoveryViewModel: RecoveryViewModel,
        sleepViewModel: SleepViewModel,
        strainViewModel: StrainViewModel,
        deviceViewModel: DeviceViewModel,
        profileViewModel: ProfileViewModel,
        localDataViewModel: LocalDataViewModel,
        liveSessionUseCase: LiveSessionUseCase,
        makeActivityDetailViewModel: @escaping (WorkoutSession, ActiveFast?) -> ActivityDetailViewModel
    ) {
        _viewModel = State(initialValue: viewModel)
        _recoveryViewModel = State(initialValue: recoveryViewModel)
        _sleepViewModel = State(initialValue: sleepViewModel)
        _strainViewModel = State(initialValue: strainViewModel)
        self.deviceViewModel = deviceViewModel
        self.profileViewModel = profileViewModel
        self.localDataViewModel = localDataViewModel
        self.liveSessionUseCase = liveSessionUseCase
        self.makeActivityDetailViewModel = makeActivityDetailViewModel
    }

    public var body: some View {
        NavigationStack {
            // The recording bar is the outermost thing on this screen, so the scroll view sits below it
            // in a `VStack(spacing: 0)` rather than being overlaid by it. **An overlay would not work**,
            // and that is a layout fact rather than a preference: the collapsed header is an
            // `.overlay(alignment: .top)` on the scroll view, which aligns to that view's *frame* and
            // therefore to the top of the screen — so it would be drawn over the bar instead of under
            // it, and the only fix would be a height constant for the bar to offset it by.
            //
            // **It lives inside the `NavigationStack`, and that is what keeps it on this screen alone.**
            // A pushed page covers the root view, so the session page — which draws its own banner —
            // and the activity detail page — whose `•••` menu is anchored to the bottom edge — are both
            // untouched by it.
            VStack(spacing: 0) {
                liveSessionBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        topBar
                        rings
                        myDayHeader
                        activitiesCard
                        myDashboardHeader
                        dashboardTiles
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                // iOS 17 has no scroll-geometry API (`onScrollGeometryChange` is iOS 18), so the sticky
                // header is a preference key read through a named coordinate space. The `VStack` above
                // must stay a `VStack`: a `LazyVStack` may release the rings row once it is scrolled
                // past, and the preference that drives the header would go with it.
                .coordinateSpace(.named(Self.scrollSpace))
                .overlayPreferenceValue(RingsBottomKey.self, alignment: .top) { ringsBottom in
                    collapsedHeader(collapse: collapse(for: ringsBottom))
                }
                // Inside the `NavigationStack`, which is not a style choice: the menu that sets the flag
                // is an overlay applied to the view *below*, outside this stack, and a destination
                // declared out there cannot push — the link would be inert with no error.
                .navigationDestination(isPresented: $isPresentingLiveSession) {
                    LiveSessionView(useCase: liveSessionUseCase)
                }
                // The picker `START ACTIVITY` opens. Declared here for `isPresentingLiveSession`'s own
                // reason — see that flag — and it must be *inside* the stack even though the menu that
                // sets the flag hangs outside it.
                .navigationDestination(isPresented: $isPresentingActivityPicker) {
                    ActivityPickerView(selection: $pickedActivityName)
                }
                // The picker's answer. See `startSession(named:)` for the fork and the one-turn hop.
                //
                // **`nil` is ignored**, and that is what lets `presentActivityPicker()` clear the value
                // without starting anything: clearing is a write to this same binding, so without the
                // guard, opening the picker a second time would start the session the first one chose.
                .onChange(of: pickedActivityName) { _, name in
                    guard let name else { return }
                    startSession(named: name)
                }
                // Declared here rather than as a `NavigationLink` around each row, so that
                // `presentedActivity` exists for the `hidingTabBar` call below to read. The subject is
                // resolved by the row's own tap and not by a lookup, and because it is an `item:`
                // binding rather than an `isPresented:` one, SwiftUI keeps the page alive through the
                // pop animation instead of rebuilding it against a `nil` item half way out.
                .navigationDestination(item: $presentedActivity) { workout in
                    ActivityDetailView(
                        viewModel: makeActivityDetailViewModel(workout, nil),
                        onDeleted: { id in viewModel.removeWorkout(id) },
                        onSaved: { updated in
                            viewModel.updateWorkout(updated, on: selectedDate)
                        },
                        onEndFast: {})
                }
                // The running fast's page, off its own binding — see `presentedFast` for why it is not
                // `presentedActivity`. **The two callbacks are no-ops and that is not laziness**: the
                // initialiser requires them, and neither has a caller on this page. Its menu is
                // `ActivityOverflowMenu.groups(isLive: true)`, which holds one `End Fast` row and
                // `Cancel`; there is no `Delete` to report a removal with and no `Edit` to report a save
                // from, and the fast is not a row of `viewModel.workouts` for either to act on.
                //
                // **`onEndFast` is the one that acts.** It ends the fast — which sets
                // `liveSessionUseCase.activeFast` to `nil`, the value this screen's bar is drawn from,
                // so the bar goes as the page dismisses — and then hands back the row that was written.
                // Where that row lands on this screen is `updateWorkout(_:on:)`'s existing answer: a
                // fast ended today is inserted if the day on screen is one it covers, which is the
                // covering rule the stored rows are already drawn by and adds no second one.
                .navigationDestination(item: $presentedFast) { presented in
                    ActivityDetailView(
                        viewModel: makeActivityDetailViewModel(presented.session, presented.fast),
                        onDeleted: { _ in },
                        onSaved: { _ in },
                        onEndFast: { await endFast() })
                }
                .task {
                    await viewModel.observeDevice()
                    await viewModel.load(for: selectedDate)
                }
                .onChange(of: selectedDate) { _, newDate in
                    Task { await viewModel.load(for: newDate) }
                }
            }
            .background(Theme.homeBackground.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        // The bar is hidden while either overlay is up, and that is not only for the look of it. An
        // overlay inside a tab cannot cover the tab bar — the `TabView` draws it above its content —
        // so leaving it visible would put a bright, tappable row of tabs under a modal, and tapping
        // one would switch screens with the flag still set, so the overlay would be waiting on Home
        // when the user came back. Removing the bar removes both problems at once.
        //
        // **The live session is the third case, and it is why the flag is here rather than on the
        // session's own view.** `LiveSessionView` does apply `.hidingTabBar(true)`, and it does not
        // work: measured on the iOS 26.5 simulator, a `.toolbar(.hidden, for: .tabBar)` declared on a
        // *pushed destination* leaves the tab bar drawn over the session — hiding the END button
        // behind it — both when the push happens during first layout and when it is delayed until
        // after it. Declaring the same modifier at the tab's **root**, which is this line and the
        // position the calendar above already proves, does hide it, and un-hides it again on pop
        // because this flag is the binding `navigationDestination(isPresented:)` resets. So the
        // destination's own modifier is left in place as intent but is not the mechanism; this is.
        //
        // **The activity detail page is the fourth case and the one that forced a change above.**
        // That page's `•••` menu is a bar of rows pinned to the bottom edge of the screen, so the tab
        // bar drawn over it would sit on top of the rows it is about — and the same measurement
        // applies: nothing declared on `ActivityDetailView` can hide it. `presentedActivity` is
        // therefore hoisted here, which is the only reason that page's push is a
        // `navigationDestination(item:)` rather than a `NavigationLink`.
        //
        // **`presentedFast` is the fifth case and behaves exactly like the fourth**, because it is the
        // same page: a running fast is the fasting layout of `ActivityDetailView`, so its menu is the
        // same bottom-anchored bar of rows and the same measurement decides it. The picker is
        // deliberately *not* on this list — it is an ordinary pushed list, like the three rings'
        // detail pages, and no pushed page other than these two needs the bar out of the way.
        .hidingTabBar(
            isPresentingCalendar || isPresentingActivityMenu || isPresentingLiveSession
                || presentedActivity != nil || presentedFast != nil)
        .overlay {
            if isPresentingCalendar { calendarOverlay }
        }
        // The `+`'s menu. Applied as a second overlay rather than folded into the one above, because
        // this one needs the published anchor and that one does not — and `overlayPreferenceValue` is
        // a different modifier, so neither replaces the other.
        .overlayPreferenceValue(ActivityMenuAnchorKey.self, alignment: .top) { anchor in
            if isPresentingActivityMenu { activityMenuOverlay(anchoredBelow: anchor) }
        }
    }

    // MARK: - The month calendar

    /// The calendar, hanging from the top of the screen over a dimmed — not blacked-out — Home.
    ///
    /// **An overlay rather than a `.sheet`.** A sheet is a full-height card the system centres in the
    /// screen, which left the grid floating in the middle of a dark slab with the app's own screen
    /// invisible behind it. The calendar is a small bounded thing and only reads as one when it hangs
    /// from the top with the day it is choosing between still legible underneath.
    ///
    /// The scrim is deliberately partial. `Color.black.opacity(0.45)` dims the screen without erasing
    /// it, so the calendar reads as sitting *on* Home rather than replacing it — and the tiles behind
    /// it are still the context for the day the grid is about to select.
    ///
    /// The scrim takes the tap rather than the card, which is what makes dismissing a matter of
    /// touching anywhere outside the grid. Only the scrim ignores the safe area: the card must stay
    /// inside it or its month header would sit under the status bar.
    private var calendarOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismissCalendar() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("Dismisses the calendar"))
                .transition(.opacity)

            MonthCalendarView(
                selected: selectedDate,
                tiers: viewModel.monthTiers,
                isLoading: viewModel.isLoadingMonth,
                onSelect: { day in
                    // The grid's days are already `startOfDay`, so the binding stays a day key and
                    // the `.onChange(of: selectedDate)` below fires exactly once — down the same
                    // path a chevron tap takes, with no second reload mechanism.
                    selectedDate = day
                    dismissCalendar()
                },
                onMonthChange: { month in await viewModel.loadMonth(containing: month) }
            )
            // Rounded only at the bottom: the card is flush with the top of the safe area, so a
            // radius there would peel it away from the edge it is meant to hang from.
            .clipShape(.rect(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func dismissCalendar() {
        withAnimation(.snappy(duration: 0.26)) { isPresentingCalendar = false }
    }

    // MARK: - The activity menu

    /// The `+`'s menu: a small card hanging under the button over a dimmed Home.
    ///
    /// **An overlay rather than a `.sheet`**, for the calendar's reason and with its partial scrim: a
    /// sheet centres a full-height card in a dark slab and hides the screen the control belongs to,
    /// while this is a small bounded thing that only reads as hanging off the `+` when Home is still
    /// legible behind it.
    ///
    /// **The card is positioned from the button's own frame rather than from a padding constant.** The
    /// `+` sits under a top bar whose height is not fixed and inside a scroll view, so a literal here
    /// would be the magic number `RingsBottomKey`'s comment warns about — right today, silently wrong
    /// the first time the bar changes height. `anchor` arrives from a `GeometryReader` in the button's
    /// own background, measured in `scrollSpace`, which is anchored to the scroll view itself: the
    /// reported `maxY` is therefore already in the view's *visible* frame, so there is no scroll offset
    /// to subtract and the transform writes no `@State` — the rings header's other load-bearing rule,
    /// since it runs on every scroll frame.
    ///
    /// Only the scrim ignores the safe area; the card stays inside it, as the calendar's does.
    private func activityMenuOverlay(anchoredBelow anchor: CGRect) -> some View {
        // An unpublished anchor is `.null`. The menu can only be opened by tapping the button, so this
        // is unreachable in practice — it is here so a missing frame cannot place the card at a
        // coordinate no screen has.
        let top = anchor.isNull ? 0 : anchor.maxY + 8

        return ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismissActivityMenu() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("Dismisses the activity menu"))
                .transition(.opacity)

            // Trailing-aligned rather than offset to the button's own `maxX`: the `+` is at the page's
            // trailing edge behind 16 pt of padding, so the same inset lands the card under it without
            // this having to know the card's width.
            activityMenu
                .padding(.trailing, 16)
                .padding(.top, top)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
        }
    }

    /// The card: the rows the day is offered, drawn top to bottom with a rule between them.
    ///
    /// The rows come from that value rather than from two `Text`s written here, because a list written
    /// into a body is a list nothing can assert — `DayBarRules`' and `ActivityGlyph`'s reason, and §14
    /// drives it.
    ///
    /// **The day is asked for its rows, not filtered here.** `ActivityMenu.entries(on:now:recording:)`
    /// is what withholds `START ACTIVITY` off today, so the rule stays where the runner — which has no
    /// renderer — can read it, and this body holds no "is today" comparison to drift from the day bar's.
    ///
    /// **The second reason a row can be withheld is `recording`**, and it is an input rather than a
    /// comparison here for the same reason: *only a live activity blocks another one* is the user's own
    /// rule, and it is one sentence about two live states, so it lives beside the day rule rather than in
    /// this drawing.
    private var activityMenu: some View {
        VStack(spacing: 0) {
            ForEach(
                Array(ActivityMenu.entries(on: selectedDate, recording: recording).enumerated()),
                id: \.element.id
            ) { index, entry in
                if index > 0 { Divider().overlay(Theme.cardBorder) }
                activityMenuRow(entry)
            }
        }
        .frame(width: 232)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }

    /// One row. The tap dismisses, then does whatever the entry's `Action` names.
    ///
    /// **The `switch` is exhaustive over `ActivityMenu.Entry.Action`**, deliberately: a case added
    /// there stops this compiling until it is handled here, which is the property a stored closure in
    /// the entry would not have had.
    ///
    /// `buttonStyle(.plain)` is load-bearing: the default style tints its label and adds a hit shape,
    /// which would recolour the word the value specifies.
    private func activityMenuRow(_ entry: ActivityMenu.Entry) -> some View {
        Button {
            dismissActivityMenu()
            switch entry.action {
            case .none:
                // `ADD ACTIVITY` — the import path is not built. The tap closes the menu and stops
                // here; there is no destination to reach.
                break
            case .startSession:
                presentActivityPicker()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20)
                Text(entry.title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presentActivityMenu() {
        withAnimation(.snappy(duration: 0.3)) { isPresentingActivityMenu = true }
    }

    private func dismissActivityMenu() {
        withAnimation(.snappy(duration: 0.26)) { isPresentingActivityMenu = false }
    }

    // MARK: - Starting a session

    /// What the `+` menu should withhold, read off the live session.
    ///
    /// Three states rather than a `Bool`, because a fast and an activity answer the availability question
    /// differently and one flag could not hold both answers — and it is derived here rather than stored,
    /// so there is no second copy of the live state to go stale behind the use case's.
    private var recording: ActivityMenu.Recording {
        if liveSessionUseCase.isRunning { return .activity }
        if liveSessionUseCase.activeFast != nil { return .fast }
        return .none
    }

    /// Opens the picker, on an empty selection.
    ///
    /// **The selection is cleared first, and that is not tidiness.** The binding is a `String?` that the
    /// picker draws its tick from, and it keeps whatever the last pick was — so a second opening would
    /// draw a checkmark on the previous activity before the user had chosen anything. Clearing it to
    /// `nil` first also makes the `onChange` below fire on a real pick rather than on a leftover.
    private func presentActivityPicker() {
        pickedActivityName = nil
        isPresentingActivityPicker = true
    }

    /// Starts whichever kind of session the picked name means.
    ///
    /// **The dispatch is `ActivityFigure.isFastName`, and it is the whole of the feature.** Picking
    /// `Fast` through the ordinary path would run the full activity machinery — accumulator, telemetry
    /// consumer, step consumer, route, lock-screen card — and store a row named `Fast` that
    /// `ActivityFigure.isFast` refuses because it carries a strain; with no strap connected it would
    /// store nothing at all. Either way the fast the user asked for is unreachable through the flow they
    /// described, and the picker's own `Fast` entry would be a lie.
    ///
    /// **One turn later, and that is the whole of why this is not a plain assignment.** The picker's row
    /// sets the name and calls `dismiss()` in the same statement, so `NavigationStack` is being asked for
    /// a pop and a push in one update; it processes one transition per frame, so the push is dropped with
    /// the flag left `true`. That strands `hidingTabBar` — the tab bar hidden over a screen that never
    /// appeared — and the next unrelated `true` then pushes the session spuriously. `Task { @MainActor in
    /// … }` is what moves the push to its own turn.
    ///
    /// **A fast pushes nothing**, deliberately. The bar is the live indicator for a fast — the user's own
    /// answer — and its page is one tap away on that bar; a run pushes `LiveSessionView`, which is the
    /// screen that watches a session and holds its END. The asymmetry is the two screens' natures and not
    /// an oversight: one is a session controller and the other is a reading.
    ///
    /// **The push is gated on `isRunning` rather than on the call returning**, because `start()` returns
    /// nothing and can decline — a session already running, or a profile that could not be read. Pushing
    /// onto a session that never started would draw `LiveSessionView` over a use case that is idle.
    private func startSession(named name: String) {
        Task { @MainActor in
            if ActivityFigure.isFastName(name) {
                await liveSessionUseCase.startFast()
                return
            }
            await liveSessionUseCase.start(name: name)
            guard liveSessionUseCase.isRunning else { return }
            isPresentingLiveSession = true
        }
    }

    /// Ends the running fast and puts the row it became on this screen, if this screen's day is one it
    /// covers.
    ///
    /// **The row comes back off the use case rather than being projected here a second time.** `endFast()`
    /// returns the `WorkoutSession` it wrote, which is the value the `workouts` table now holds — so Home
    /// is handed the row itself and not a lookalike. A second `projectedSession(now:)` on this side would
    /// mint a *different* `UUID`, and `updateWorkout`'s `firstIndex(where: { $0.id == workout.id })` would
    /// then be comparing the stored row against an id that can never match it — harmless while the append
    /// branch happens to run, and wrong the moment anything looks a workout up by that id.
    ///
    /// **`nil` means nothing was written** — the fast had already ended, or it was ended within the
    /// second it started — and there is then no row to add. The bar goes either way, because the use
    /// case clears `activeFast` above its own first `await`; this method is about the card, not the bar.
    private func endFast() async {
        guard let summary = await liveSessionUseCase.endFast() else { return }
        viewModel.updateWorkout(summary.workout, on: selectedDate)
    }

    // MARK: - The recording bar

    /// The bar pinned above everything else on this screen while a session is recording — red for a
    /// regular activity, and the fill of the fasting zone reached for a fast.
    ///
    /// **The whole of its rule is `LiveSessionBar.subject`**, which is a plain value for this repo's
    /// standing reason — the runner has no renderer, so a gate written here is a gate nothing can
    /// assert. It answers `nil` for every state but a running session that also carries a start
    /// instant, and the `isRunning` half is what takes the bar away the moment END is pressed rather
    /// than when the session's state is finally cleared.
    ///
    /// **The colour is the whole of what a fast changes here, and it comes from `FastingZone`.** The
    /// zone is read over the fast's *whole* elapsed span while the bar is up, which is deliberately the
    /// other reading from the one a stored fast's row draws on this card: `ActivityFigure.fastingZone`
    /// is day-clamped, because a Home row is about a day, and an 86-hour fast walks down the week one
    /// zone at a time. The bar is about the fast, so it counts from the start with nothing clamped —
    /// see `LiveSessionBar.Subject.zone(at:)` for why the two must not be reconciled.
    ///
    /// **The clock is the system's.** `Text(_:style: .timer)` is drawn from the anchor and needs no
    /// tick and no `@State` — the same line `LiveSessionView` uses, and the reason a session's elapsed
    /// time keeps counting while the app is suspended. Nothing here counts samples.
    ///
    /// **`TimelineView` is for the colour and the accessibility label, and for nothing else.** The
    /// visible clock updates itself, but a label is built once per `body` evaluation, so without a
    /// periodic re-render VoiceOver would announce the session's *first* second for as long as the
    /// screen stayed up — and the fill would never move off the zone the fast was in when the screen was
    /// built. A minute is that label's own resolution, and it is also why the zone colour is up to a
    /// minute late at each boundary: a per-second timer for a colour that changes four times in three
    /// days would re-render the bar sixty times as often to be wrong ninety-nine percent of the time.
    ///
    /// **Full-bleed**, which makes it the one thing on this screen outside the 16 pt gutter — the
    /// reason it is a sibling of the scroll view rather than a row inside it. The tap opens the session
    /// the bar is about — the same `LiveSessionView` the `+` menu's `START ACTIVITY` row pushes for an
    /// activity, and the fasting detail page for a fast — so returning to a session and starting one
    /// are one push. See `present(_:)` for the fork and why the fast's projection is made here.
    @ViewBuilder
    private var liveSessionBar: some View {
        // **The read is here, in `body`, and not inside the `TimelineView`.** `LiveSessionBar.subject`
        // asks the use case four questions and is what registers this screen's Observation dependency on
        // it; a `TimelineView` closure is a *child* view's body, so a read placed inside it would be
        // attributed to the timeline and Home would not be invalidated when a session ends — leaving the
        // bar counting over Home for up to a minute after END was pressed. That is the exact property
        // §18's `subject` assertions pin, and the reason the split exists at all.
        if let subject = LiveSessionBar.subject(
            isActivityRunning: liveSessionUseCase.isRunning,
            activityName: liveSessionUseCase.activityName,
            activityStartedAt: liveSessionUseCase.startedAt,
            activeFast: liveSessionUseCase.activeFast
        ) {
            TimelineView(.everyMinute) { context in
                Button {
                    present(subject)
                } label: {
                    // The mark leads the clock — the activity the reader picked, drawn in the words
                    // `ActivityGlyph` names it with. `subject.mark` rather than a lookup here, so which
                    // mark the bar draws is a value §18 can assert; the four other sites that draw one
                    // resolve it at the call site because each frames it differently, and this bar does
                    // not frame it at all.
                    HStack(spacing: 6) {
                        ActivityGlyphLabel(subject.mark, size: 13, weight: .semibold)
                        Text(subject.anchor, style: .timer)
                            .monospacedDigit()
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    // **`foregroundStyle` is on the `HStack` and not on the `Text`, and the ink is the
                    // subject's rather than a fixed white.** The mark has to take the same colour the
                    // clock does, because `FastingZone.inkDepth` exists for the reason this would break:
                    // white is invisible on `ketosis`'s fill and near-invisible on `fatBurning`'s, so an
                    // icon pinned to white would vanish on two of the five zones while the timer beside
                    // it stayed legible — a mark missing from a bar that otherwise looks correct.
                    .foregroundStyle(subject.ink(at: context.date))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                        // `ignoresSafeAreaEdges: []` is load-bearing and must not be dropped. This
                        // `Color` takes the `ShapeStyle` overload of `background`, whose
                        // `ignoresSafeAreaEdges` **defaults to `.all`** — so a bare
                        // `.background(Theme.recoveryRed)` bleeds the fill up through the top safe
                        // area. Measured on the iOS 26.5 simulator: the bar's text box sat correctly
                        // at 62.3…90 pt while the red ran 0…90 pt, drawing a 90 pt red slab behind the
                        // status bar with the clock stranded near its bottom. The bleed also scales
                        // with the device's inset, so the bar would be a different height on every
                        // phone. Pinned to `[]`, the bar is the 28 pt it is authored as, on every
                        // device, directly under the status bar.
                        .background(subject.fill(at: context.date), ignoresSafeAreaEdges: [])
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    LiveSessionBar.accessibilityLabel(for: subject, now: context.date))
                .accessibilityHint(Text(LiveSessionBar.accessibilityHint(for: subject)))
            }
        }
    }

    /// The bar's tap: it opens whichever live session the bar is about.
    ///
    /// **The tap forks, which is why `LiveSessionBar.accessibilityHint` took a subject.** A regular
    /// activity's page is `LiveSessionView`, off the same process-held use case the `+` menu's
    /// `START ACTIVITY` row pushes — one push, two routes to it. A fast's page is `ActivityDetailView`
    /// in its fasting layout, reached through the same factory an activity row uses, because that page's
    /// subject is a `WorkoutSession` and a live fast can project itself as one.
    ///
    /// **The projection is made here, at the tap, and stored.** See `presentedFast`: computing it in the
    /// destination closure would re-mint the item's identity on every body evaluation and rebuild the
    /// page under the reader.
    private func present(_ subject: LiveSessionBar.Subject) {
        switch subject {
        case .activity:
            isPresentingLiveSession = true
        case .fast(let startedAt):
            let fast = ActiveFast(startedAt: startedAt)
            presentedFast = PresentedFast(session: fast.projectedSession(now: Date()), fast: fast)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // The row's three elements answer three different questions, and the order is the shape of
            // that: the reader on the left, the day in the middle, the hardware on the right.
            //
            // **It is the profile page's only route**, since the user removed More's `Profile` row —
            // so this is the one control to check when the page seems unreachable. It reads off the
            // view model built in `MainContainerView`, which is the same arrangement the badge at the
            // other end of this row has; the two are mirrors rather than copies of each other.
            NavigationLink {
                ProfileDashboardView(
                    viewModel: profileViewModel,
                    localDataViewModel: localDataViewModel)
            } label: {
                profileButton
            }
            .buttonStyle(.plain)
            // The only `DayNavigationBar` call site that passes `onTitleTap`. Strain and Sleep keep
            // the plain label, because this is the only screen with a calendar to open — and
            // Recovery no longer draws the bar at all.
            DayNavigationBar(date: $selectedDate, onTitleTap: {
                withAnimation(.snappy(duration: 0.3)) { isPresentingCalendar = true }
            })
            // The badge is the way into the strap's own page — it is the only thing on Home that is
            // about the strap rather than about the day, and the page behind it is where the model is
            // chosen. Home already owns the `NavigationStack` at the root of this body, so this is a
            // link rather than another navigation container.
            //
            // **It opens the same page More → Device opens**, off the one view model built in
            // `MainContainerView`. It used to push a second screen of its own; the two are one now.
            NavigationLink {
                DeviceSettingsView(viewModel: deviceViewModel)
            } label: {
                statusBadge
            }
            .buttonStyle(.plain)
        }
    }

    /// The way into the profile: one glyph on a `Theme.homeCard` disc, drawn as the strap badge at the
    /// other end of the row is drawn.
    ///
    /// **A circle where the badge is a capsule, and the difference is what each holds rather than a
    /// style choice.** The badge carries a glyph *and* a battery figure, so it has to grow sideways;
    /// this carries a glyph alone, and a circle is the shape that does not leave a slot looking empty.
    /// The `36` is the badge's own height — its 12 pt line and its 11 pt of vertical padding — so the
    /// row's two ends sit level rather than nearly level, which is the kind of difference that reads as
    /// a mistake without being one you can point at.
    ///
    /// **`person.crop.circle` and not `person.fill`.** This app has no avatar and no photograph of
    /// anybody: `user_profiles` holds three numbers and a name nothing draws, and the page behind this
    /// control is a form for two heart rates and a weight. A filled glyph would be a silhouette of a
    /// person the app has never seen, where the cropped circle is the shape every platform already uses
    /// for "your account". **Checked against the SDK's own `name_availability.plist` rather than
    /// assumed**: it resolves to `2019` → iOS 13.0, well under this app's 17.0 target, which is the
    /// check `ActivityGlyph`'s doc demands of every new symbol because a wrong name here draws an empty
    /// circle rather than raising anything.
    ///
    /// **No chevron**, for the reason the badge's own comment gives: a control that looks tappable and
    /// is not reads as broken, and one that *is* tappable does not need an arrow to say so — the hint
    /// below is what makes the destination reachable without sight of it.
    private var profileButton: some View {
        Image(systemName: "person.crop.circle")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 36, height: 36)
            .background(Theme.homeCard)
            .clipShape(Circle())
            // The symbol's own name is what VoiceOver would otherwise read — `person.crop.circle`,
            // which is a description of the drawing and not of where it goes.
            .accessibilityLabel(Text("Profile"))
            .accessibilityHint(Text("Opens your weight and heart-rate settings"))
    }

    /// The strap's link state, as a dot, and its battery reading.
    ///
    /// **Nothing is drawn where a reading would go when there is none, and that is a correction the
    /// user made rather than a preference.** The slot held `ActivityFigure.dash` in that state, and
    /// the user read the dash as a battery *bar* — measured, it draws 9.7 × 1.3 pt of white at this
    /// type size, which is a bar's proportions and nothing like a dash's. `WhoopBLEManager` writes a
    /// literal `100` at discovery and `WhoopDevice` defaults to `100`, so that slot is also the only
    /// thing standing between a disconnected strap and a confident fabricated `100%`; with it left
    /// empty there is nothing to misread and nothing to fill.
    ///
    /// The gate is `WhoopDevice.batteryReading`, which is the same `.connected` test
    /// `DeviceSettingsView.batteryText(for:)` applies. The two screens draw the absent case
    /// differently — a labelled row in a `Form` needs the dash, a glyph-and-figure badge needs an
    /// empty slot — and neither may disagree about *when* there is no reading.
    ///
    /// **The dot answers a different question from the figure, and is deliberately not keyed on the
    /// same state.** It reads `WhoopConnectionState.linkColor`, so it is green for `.connected` *and*
    /// `.syncing` — a strap draining its history is a strap this app is talking to — while the figure
    /// needs `.connected` alone. The two part company on a strap the app can address whose battery it
    /// has not been told, and that state draws a green dot beside no figure, which is the honest
    /// picture of it rather than a blank. `.syncing` is unreachable in this build either way.
    private var statusBadge: some View {
        HStack(spacing: 6) {
            // The mark and the dot's placement are `StrapGlyph`'s, which is also what the device page's
            // header draws — so one glyph and one corner rule serve both screens. What stays here is
            // what this badge alone decides: **which colour** the dot is (`linkState.linkColor`, the
            // `isLinked` rule) and **how big** it is, because the badge is read at 12 pt against a
            // 7 pt dot and the device page badges a 13 pt plus on a 22 pt mark.
            StrapGlyph(size: 12, surface: Theme.homeCard) {
                Circle()
                    .fill(linkState.linkColor)
                    .frame(width: 7, height: 7)
            }
            if let reading = viewModel.device?.batteryReading {
                Text(reading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.homeCard)
        .clipShape(Capsule())
        // The label describes the strap and the hint says what opening it is for, rather than the
        // link inheriting the label of the `HStack` inside it — which would announce a battery
        // percentage as a button with no indication of where it leads.
        //
        // **The hint is now the only signal that this is a control**, and that is the user's own
        // instruction: the `chevron.right` that used to trail the badge is gone, so nothing on the
        // badge looks tappable. The hint is what makes the destination reachable without sight of it,
        // which is the same rule that keeps a chevron off a row that leads nowhere — see
        // `ActivityDetailView`, where the inert `•••` was the incident.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connectionLabel)
        .accessibilityHint(Text("Opens strap details and model selection"))
    }

    /// The strap's state, with no strap object at all read as `.disconnected` — which is what it is,
    /// and the substitution `DeviceSettingsView.hero` makes at its own call site.
    ///
    /// The finer six-way state is not lost by collapsing it to two colours here: `connectionLabel`
    /// below still names it, so VoiceOver hears `Syncing strap history` where the dot is only green.
    private var linkState: WhoopConnectionState {
        viewModel.device?.connectionState ?? .disconnected
    }

    private var connectionLabel: String {
        switch viewModel.device?.connectionState {
        case .connected: return "Strap connected, battery \(viewModel.device?.batteryPercentage ?? 0) percent"
        case .scanning: return "Scanning for strap"
        case .connecting: return "Connecting to strap"
        case .syncing: return "Syncing strap history"
        case .error: return "Strap error"
        case .disconnected: return "Strap disconnected"
        case nil: return "No strap"
        }
    }

    // MARK: - Rings

    /// The full-size rings, and the publisher the collapsed header is driven by.
    ///
    /// The preference reports this row's *bottom edge* in the scroll view's coordinate space rather
    /// than a scroll offset, so the header keys off where the rings actually are. An offset threshold
    /// would be a magic number that silently stops matching the moment `topBar` changes height.
    private var rings: some View {
        ringRow(size: 92, lineWidth: 10)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RingsBottomKey.self,
                        value: proxy.frame(in: .named(Self.scrollSpace)).maxY)
                })
    }

    /// The night's page, and **one definition of it for the two places on this screen that open it**:
    /// the sleep ring and the `SLEEP` row on the `ACTIVITIES` card. The user's rule is that the two are
    /// the same page — *"the sleep ring will link to same page that sleep shows on activity sleep
    /// tile"* — so they are one expression rather than two literals that happen to agree today, and a
    /// change to what that page is cannot reach one call site and miss the other.
    ///
    /// It takes the day this screen is showing, exactly as the two rings beside it do, so tapping an
    /// 87% ring — or that night's row — opens the night whose figure was on screen and not today's.
    /// `RecoveryDetailView`'s own comment is where that reasoning lives; this is the same shape.
    private var sleepDetail: some View {
        SleepDetailView(viewModel: sleepViewModel, date: selectedDate)
    }

    /// The three rings. The collapsed header draws the same row small, which is why every dimension
    /// is a parameter rather than a literal — two copies of the three `progress` expressions is how
    /// the header's arcs would come to disagree with the rings they replaced.
    ///
    /// `compact` also fixes each ring's width and drops its label. `MetricRingView`'s label font is
    /// fixed at 10pt rather than scaled from `size`, so at 40pt the words would be wider than the
    /// rings they sit under and would decide the header's height.
    private func ringRow(size: CGFloat, lineWidth: CGFloat, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 18 : 6) {
            // The sleep ring pushes `SleepDetailView` on the day Home is showing, exactly as the
            // recovery ring below pushes its own — and off `sleepDetail`, which is the same page the
            // `SLEEP` row on the `ACTIVITIES` card opens. `buttonStyle(.plain)` is load-bearing here
            // for the same reason: the default styles tint the label and add a hit shape, which would
            // recolour the arc itself.
            NavigationLink {
                sleepDetail
            } label: {
                ring(
                    value: sleepValue, label: "Sleep", progress: sleepProgress,
                    color: Theme.sleepPerformance, size: size, lineWidth: lineWidth,
                    compact: compact)
            }
            .buttonStyle(.plain)
            // A hint only. An explicit `accessibilityLabel` here would *replace* the composed one and
            // drop the score out of the announcement.
            .accessibilityHint("Opens this night's sleep statistics")
            // The other ring with a destination. The destination is handed the day Home is showing,
            // so tapping an 87% ring opens that 87% day — and it is the *only* route to a past day
            // on that screen, since `RecoveryDetailView` no longer pages. See it for why the Recovery
            // tab could not be reached this way instead.
            NavigationLink {
                RecoveryDetailView(viewModel: recoveryViewModel, date: selectedDate)
            } label: {
                ring(
                    value: recoveryValue, label: "Recovery", progress: recoveryProgress,
                    color: recoveryRingColor, size: size, lineWidth: lineWidth, compact: compact)
            }
            .buttonStyle(.plain)
            // A hint only. An explicit `accessibilityLabel` here would *replace* the composed one
            // and drop the score out of the announcement, so the ring would read as a bare
            // "Recovery" button with no number in it.
            .accessibilityHint("Opens this day's recovery statistics")
            // The third ring with a destination, and the same shape as the two above. It hands over
            // the day Home is showing rather than switching to the Strain tab, for the reason in this
            // screen's own doc comment: the tab keeps a private day seeded to `Date()`.
            NavigationLink {
                StrainDetailView(viewModel: strainViewModel, date: selectedDate)
            } label: {
                ring(
                    value: strainValue, label: "Strain", progress: strainProgress,
                    color: Theme.strainRing, size: size, lineWidth: lineWidth, compact: compact)
            }
            .buttonStyle(.plain)
            // A hint only. An explicit `accessibilityLabel` here would *replace* the composed one and
            // drop the score out of the announcement, so the ring would read as a bare "Strain"
            // button with no figure in it.
            .accessibilityHint("Opens this day's strain statistics")
        }
    }

    private func ring(
        value: String?,
        label: String,
        progress: Double,
        color: Color,
        size: CGFloat,
        lineWidth: CGFloat,
        compact: Bool
    ) -> some View {
        MetricRingView(
            value: value,
            label: label,
            progress: progress,
            color: color,
            size: size,
            lineWidth: lineWidth,
            showsLabel: !compact)
            .frame(width: compact ? size : nil)
    }

    // The three fills, as fractions. Each reads 0 for an absent measurement, which `MetricRingView`
    // ignores: it draws no fill at all when its `value` is `nil`, so the arc and the figure cannot
    // disagree about whether the day has one.
    private var sleepProgress: Double {
        Double(viewModel.sleep?.sleepPerformancePercentage ?? 0) / 100.0
    }

    private var recoveryProgress: Double { Double(viewModel.recovery?.score ?? 0) / 100.0 }

    private var strainProgress: Double { (viewModel.strain?.score ?? 0) / 21.0 }

    /// A night the classifier could not read is never written, so `nil` is the whole test. The score
    /// is 0–100, hence the percent sign.
    private var sleepValue: String? {
        guard let sleep = viewModel.sleep else { return nil }
        return "\(sleep.sleepPerformancePercentage)%"
    }

    /// A day the strap recorded nothing for now stores no row at all, so `nil` is the ordinary case —
    /// but `hasMeasurement` remains the gate regardless, because rows written by an older build still
    /// hold zeros with the flag clear, and they are the same number as a real 0% day otherwise.
    private var recoveryValue: String? {
        guard let recovery = viewModel.recovery, recovery.hasMeasurement else { return nil }
        return "\(recovery.score)%"
    }

    /// The arc carries the day's tier — green 67–100, yellow 34–66, red 0–33 — so a 20% morning reads
    /// red here exactly as it does on the Recovery tab. `RecoveryMetric.state` defines the boundaries
    /// and `RecoveryState.color` is the one rendering of them.
    ///
    /// The fallback is unreachable rather than a claim about the day: `MetricRingView` draws no fill
    /// at all when its value is `nil`, and `recoveryValue` is `nil` exactly when `state` is. So a
    /// placeholder row left by an older build — the `score: 0` a strap-less day used to store — cannot
    /// put a red 0% on this screen, which is the same reason `RecoveryDashboardView` gives it no ring.
    private var recoveryRingColor: Color {
        viewModel.recovery?.state.color ?? Theme.recoveryGreen
    }

    /// Strain is read on a 0–21 Borg scale, not a percentage.
    ///
    /// The `hasMeasurement` test is the one `recoveryValue` makes, and it is what keeps a placeholder
    /// off this ring: its `score: 0.0` is the absence of a reading, and a ring showing `0.0` says the
    /// opposite — it used to render exactly that on a today with no strap data, where a past day
    /// rendered a dash. `CalculateStrainUseCase` no longer writes such a row; rows left by an older
    /// build are still in the database.
    private var strainValue: String? {
        guard let strain = viewModel.strain, strain.hasMeasurement else { return nil }
        return strain.score.formattedOneDecimal()
    }

    // MARK: - The collapsed header

    private static let scrollSpace = "home.scroll"

    /// The collapsed row's height, and therefore the distance over which it fades in: `size` 40 plus
    /// 6pt of padding either side. Derived from those two numbers rather than picked, so changing the
    /// ring size cannot leave the crossfade finishing after the rings have already gone.
    private static let collapsedHeaderHeight: CGFloat = 52

    /// How opaque the collapsed header should be, from where the rings row's bottom edge is.
    ///
    /// A clamped ramp rather than a `Bool`. The header fades in over the last 52pt of the rings row's
    /// travel instead of appearing on a single frame, and its background is opaque, so the big rings
    /// read as sliding *under* it rather than as a second set of rings fading in on top.
    ///
    /// Nothing here is `@State`: `overlayPreferenceValue`'s transform runs on every scroll frame, and a
    /// state write per frame would invalidate the whole screen each time.
    private func collapse(for ringsBottom: CGFloat) -> Double {
        let distance = Self.collapsedHeaderHeight
        return min(max((distance - ringsBottom) / distance, 0), 1)
    }

    /// The sticky row: the three rings, small, pinned to the top of the scroll view.
    ///
    /// The full-size rings stay the accessible presentation and the only hittable one, so this is
    /// hidden from VoiceOver and from hit testing — otherwise every metric is announced twice.
    private func collapsedHeader(collapse: Double) -> some View {
        ringRow(size: 40, lineWidth: 4, compact: true)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Theme.homeBackground.ignoresSafeArea(edges: .top))
            .opacity(collapse)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - My Day

    private var myDayHeader: some View {
        HStack {
            Text("My Day")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            // Opens the menu and nothing else. It used to present the workout HUD as a sheet; the
            // label changed with it, because "Record a workout" promised a recording path this app
            // no longer has.
            //
            // **Drawn on every day, and unconditionally.** What a day changes is the *card*, not this
            // button: `ActivityMenu.entries(on:)` withholds `START ACTIVITY` off today and keeps
            // `ADD ACTIVITY`. Gating the button instead would take the whole menu — and with it a row
            // that is not day-bound — off every day but one, and it would also have to carry the
            // anchor below, which publishes this frame for `activityMenuOverlay` to hang from.
            Button {
                presentActivityMenu()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.homeBackground)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
            }
            // Where the menu hangs from — the button's own frame, which is the only thing that stays
            // right when the bar above it changes height. See `activityMenuOverlay`.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ActivityMenuAnchorKey.self,
                        value: proxy.frame(in: .named(Self.scrollSpace)))
                })
            .accessibilityLabel("Opens the activity menu")
        }
        .padding(.top, 4)
    }

    private var activitiesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACTIVITIES")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)

            if viewModel.sleep == nil && viewModel.workouts.isEmpty {
                Text("Nothing recorded for this day.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                // **The `SLEEP` row is a `NavigationLink` to the night's page, and it was inert.**
                // The user's instruction is that it and the sleep ring open the same page, so both
                // read `sleepDetail` — see it for why that is one expression. A `NavigationLink`
                // rather than the `Button` the rows below use, because those set `presentedActivity`
                // only so that the page's bottom-anchored `•••` menu can have the tab bar out of the
                // way; `SleepDetailView` has no such control, so it is an ordinary pushed page like
                // the three rings' detail pages — and it is the rings' own shape, two hundred lines up.
                //
                // A sleep row has no workout behind it, which is why the helper itself is still not
                // wrapped: `activityRow` is shared, and a sleep row's subject is a `SleepSession`.
                // The link therefore goes around this one call, where the night is in hand.
                //
                // `.buttonStyle(.plain)` for the rings' reason: the default styles tint the label and
                // add a hit shape, which would recolour the moon chip and the duration beside it.
                if let sleep = viewModel.sleep {
                    NavigationLink {
                        sleepDetail
                    } label: {
                        activityRow(
                            glyph: .single("moon.fill"),
                            tint: Theme.sleepPerformance,
                            value: sleep.totalTimeAsleepSeconds.formattedCompactHoursMinutes(),
                            label: "SLEEP",
                            startedAt: sleep.startTime,
                            endedAt: sleep.endTime)
                    }
                    .buttonStyle(.plain)
                    // A hint only, on the rings' rule: an explicit `accessibilityLabel` here would
                    // *replace* the composed one and drop the night's duration out of the
                    // announcement.
                    .accessibilityHint("Opens this night's sleep statistics")
                }

                // **The `ForEach` is wrapped and the helper is not.** The rows that have a workout
                // behind them are buttons; the `SLEEP` row above is a link, for the reason its own
                // comment gives. Neither wraps `activityRow`, which is shared between them.
                //
                // A `Button` setting `presentedActivity` rather than a `NavigationLink`, because the
                // destination is declared from that flag so the tab bar can be hidden on it — see the
                // `navigationDestination(item:)` and `hidingTabBar` calls above. The tap is the same
                // tap: the row is drawn by `activityRow` either way, and the page it opens is the same
                // page.
                //
                // `.buttonStyle(.plain)` for the rings' reason: the default styles tint the label and
                // add a hit shape, which would recolour the strain figure and the chip.
                ForEach(viewModel.workouts) { workout in
                    Button {
                        presentedActivity = workout
                    } label: {
                        activityRow(
                            glyph: ActivityGlyph.mark(for: workout.activityName),
                            tint: Theme.strainRing,
                            value: ActivityFigure.headlineText(for: workout),
                            // The day on screen, not the session's own: a fast's zone is how far into
                            // the fast *that day* got, so an 86-hour fast draws a different pill on
                            // each of its five days. See `fastingZone(for:on:)`.
                            zone: ActivityFigure.fastingZone(for: workout, on: selectedDate),
                            // The trailing clock, on the same rule and for the same reason as the pill
                            // above: a fast's own end belongs to the day it ended on, so on every other
                            // day it covers the row prints that day's last minute instead — or `ACTIVE`
                            // while the fast is still running. `nil` for every row that is not a fast,
                            // which leaves the `SLEEP` row and every measured row printing their own
                            // two clock times exactly as before.
                            endText: ActivityFigure.fastingEndText(for: workout, on: selectedDate),
                            label: workout.activityName ?? "ACTIVITY",
                            startedAt: workout.startedAt,
                            endedAt: workout.endedAt)
                    }
                    .buttonStyle(.plain)
                    // A hint only, on the rings' rule: an explicit `accessibilityLabel` here would
                    // *replace* the composed one and drop the strain out of the announcement.
                    .accessibilityHint("Opens this activity's statistics")
                }
            }
        }
        .padding(14)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// One row of the `ACTIVITIES` card.
    ///
    /// **The label is an activity's own name**, which is the file's casing — `Walking`, `Manual Labor` —
    /// so the uppercasing is done here rather than on the entity: the drawing owns how it looks, and
    /// `textCase` is idempotent over the `SLEEP` row above, which passes an already-uppercase literal
    /// and therefore needs no branch of its own.
    ///
    /// **The glyph is a `Drawing` and not an activity name.** This helper is shared with the `SLEEP` row
    /// above, and a sleep row is built from a `SleepSession` — there is no activity behind it to look up,
    /// so a name parameter would force that row to invent one. Taking the mark instead lets it pass
    /// `.single("moon.fill")` and keeps the lookup at the one call site that has a workout.
    ///
    /// `lineLimit(1)` because the two longest names in the export, `Yard Work/Gardening` and `American
    /// Football`, are the only rows that would otherwise wrap — and a wrapped label makes those rows
    /// taller than the ones beside them, which reads as a broken layout rather than as a long word.
    ///
    /// **`zone` defaults to `nil` so the `SLEEP` row above is untouched.** A fast is the only row that
    /// draws a pill, and the pill replaces the `value` figure rather than accompanying it — so a caller
    /// with no zone passes nothing and keeps the row shape it has always had. `value` is still required
    /// and still computed by every caller, fasts included: the pill is drawn *instead of* the `Text`,
    /// not instead of the computation, which keeps `ActivityFigure.headlineText` the one definition of
    /// what a row prints when it is not a pill.
    ///
    /// **`endText` is the same shape for the trailing clock** — fasts are the only rows that pass it and
    /// it is handed straight to `timeRange`, which is the shared drawing. It replaces a *half* of the
    /// range, so a covered day reads `SUN 9:00 PM / 11:59 PM`: the start clock and the weekday badge
    /// stay the fast's own.
    private func activityRow(
        glyph: ActivityGlyph.Drawing,
        tint: Color,
        value: String,
        zone: FastingZone? = nil,
        endText: String? = nil,
        label: String,
        startedAt: Date,
        endedAt: Date
    ) -> some View {
        HStack(spacing: 12) {
            ActivityGlyphLabel(glyph, size: 15, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: ActivityGlyph.chipDiameter, height: ActivityGlyph.chipDiameter)
                .background(tint.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 1) {
                if let zone {
                    FastingZonePill(zone: zone)
                } else {
                    Text(value)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            timeRange(startedAt: startedAt, endedAt: endedAt, endText: endText)
        }
    }

    /// The range, with the weekday prefixed only when the two ends fall on different days.
    ///
    /// A session from 11:19 PM to 7:25 AM is on two calendar days and the clock times alone cannot say
    /// which; a session from 5:33 PM to 5:47 PM does not need telling. Prefixing both would put a
    /// redundant word on every row.
    ///
    /// **`endText` is a parameter rather than a branch in here, and that is the whole reason the fast's
    /// rule did not move the `SLEEP` row.** This helper is shared by all three kinds of row on the card,
    /// so a fast-only rule written into it would apply to a night and to every measured activity too.
    /// The override is computed at the one call site that has a fast — `ActivityFigure.fastingEndText`
    /// — and every other caller passes nothing and keeps the session's own end clock.
    ///
    /// The **left** half is not overridable, and that is deliberate: the weekday badge and the start
    /// clock are the fast's own on every day it covers, so a covered day reads `SUN 9:00 PM / 11:59 PM`
    /// rather than pretending the fast began that morning.
    private func timeRange(startedAt: Date, endedAt: Date, endText: String? = nil) -> some View {
        HStack(spacing: 5) {
            if startedAt.startOfDay != endedAt.startOfDay {
                Text(startedAt.formattedWeekdayAbbreviation())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.ringTrack)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text("\(startedAt.formattedHourMinute()) / \(endText ?? endedAt.formattedHourMinute())")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    // MARK: - My Dashboard

    private var myDashboardHeader: some View {
        Text("My Dashboard")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private var dashboardTiles: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                dashboardTile(
                    label: "STEPS",
                    value: viewModel.steps.map { $0.formatted(.number.grouping(.automatic)) },
                    previousValue: viewModel.previousDaySteps.map { $0.formatted(.number.grouping(.automatic)) },
                    change: stepsChange,
                    accent: Theme.strainRing)

                dashboardTile(
                    label: "RESTORATIVE SLEEP (HRS)",
                    value: viewModel.restorativeSleepSeconds?.formattedCompactHoursMinutes(),
                    previousValue: viewModel.previousDayRestorativeSleepSeconds?.formattedCompactHoursMinutes(),
                    change: restorativeSleepChange,
                    accent: Theme.recoveryGreen)
            }

            restingHeartRatePanel
            sleepNeededPanel
            stressTile
            strainRecoveryTile
            heartRateVariabilityPanel
            vo2MaxPanel
        }
    }

    private func dashboardTile(
        label: String,
        value: String?,
        previousValue: String?,
        change: MetricChange?,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(height: 26, alignment: .topLeading)

            Text(value ?? "—")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(value == nil ? Theme.textMuted : Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if let change {
                    Image(systemName: change.symbolName)
                        .font(.system(size: 9))
                        .foregroundStyle(change.color)
                    Text(change.previousText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                } else if let previousValue {
                    Text(previousValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                }
            }
            .frame(height: 14)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(accent.opacity(0.5))
                .frame(height: 2)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tileDescription(label: label, value: value, change: change))
    }

    /// One tile, one announcement. The marker is a drawn glyph and a colour, and neither reaches
    /// VoiceOver — so the verdict is spelled out, matching `RecoveryDetailView`'s rows. A listener
    /// who hears the day's figure and the one it is read against can work out which way the number
    /// moved; which way was good is the part that has to be said.
    private func tileDescription(label: String, value: String?, change: MetricChange?) -> String {
        guard let value else { return "\(label), no measurement" }
        guard let change else { return "\(label), \(value)" }
        switch change.verdict {
        case .better: return "\(label), \(value), better than \(change.previousText)"
        case .same: return "\(label), \(value), the same as \(change.previousText)"
        case .worse: return "\(label), \(value), worse than \(change.previousText)"
        }
    }

    // MARK: - The four metric panels

    /// The selected day's slot in the week, where all four panels' headline values come from.
    ///
    /// Read through the week rather than from `recovery` and `sleep` directly: the slot has already
    /// applied each source's own absence rule, and it is the same value the chart plots — so a panel
    /// cannot print a number for a day the chart drew as an empty column.
    private var selectedMetricDay: MetricDay? { viewModel.metricWeek?.day(for: selectedDate) }

    /// A full-width panel: an icon and a title on the left, the day's value over its 7-day baseline
    /// on the right.
    ///
    /// Its own builder rather than `dashboardTile`, which is a quarter-width card built around a
    /// label stacked above a value. These are one line of prose beside two trailing figures, and
    /// forcing that into the tile's shape would mean a title wrapping to three lines to make room for
    /// a number it does not describe.
    ///
    /// **The icon is a neutral grey with no chip behind it, and the label beside it is white.** The
    /// icon used to be drawn in a per-metric tint on a rounded tile of that same tint at 18%, which
    /// made four colours the only thing telling one panel from another — but a heart, a moon, a
    /// waveform and a pair of lungs already say which is which. The tint was decoration standing in
    /// for information, and four coloured chips stacked down one column read as four different kinds
    /// of thing when they are one kind of thing. The word is what names the row, so the word carries
    /// the contrast and the glyph stays furniture. The 38pt frame survives the chip it was sized for:
    /// it is what keeps the five labels in this column at the same x.
    ///
    /// No accent underline, unlike the tiles: that underline sits at a fixed inset from a 132pt
    /// card's bottom edge, and on a row this short it would float across the middle of nothing.
    private func metricPanel(
        label: String,
        symbol: String,
        value: String?,
        baselineText: String?,
        change: MetricChange?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 38, height: 38)

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value ?? "—")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(value == nil ? Theme.textMuted : Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 4) {
                    if let change {
                        Image(systemName: change.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(change.color)
                        Text(change.previousText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    } else if let baselineText {
                        Text(baselineText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                    }
                }
                .frame(height: 14)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            panelDescription(label: label, value: value, baselineText: baselineText, change: change))
    }

    /// One panel, one announcement. The marker is a drawn glyph and a colour and neither reaches
    /// VoiceOver, so the verdict is spelled out — the same choice `RecoveryDetailView`'s rows make.
    private func panelDescription(
        label: String, value: String?, baselineText: String?, change: MetricChange?
    ) -> String {
        guard let value else { return "\(label), no measurement" }
        guard let change else {
            guard let baselineText else { return "\(label), \(value)" }
            return "\(label), \(value), 7-day average \(baselineText)"
        }
        switch change.verdict {
        case .better: return "\(label), \(value), better than the 7-day average of \(change.previousText)"
        case .same: return "\(label), \(value), the same as the 7-day average of \(change.previousText)"
        case .worse: return "\(label), \(value), worse than the 7-day average of \(change.previousText)"
        }
    }

    /// The day's resting heart rate over the week's mean.
    ///
    /// A measured day with no heart rate is a dash: the column's reserved `0` is not a bpm, which is
    /// why `MetricWeek` gates it twice — see `MetricDay`.
    private var restingHeartRatePanel: some View {
        let baseline = viewModel.metricWeek?.restingHeartRateBaseline
        let change = MetricChange.between(
            current: selectedMetricDay?.restingHeartRate.map { Double($0) },
            previous: baseline.map { Double($0) },
            higherIsBetter: false,
            formatted: { String(Int($0.rounded())) })
        return metricPanel(
            label: "RHR",
            symbol: "heart.fill",
            value: selectedMetricDay?.restingHeartRate.map { "\($0)" },
            baselineText: baseline.map { "\($0)" },
            change: change)
    }

    /// The night's need over the week's mean.
    ///
    /// `targetSleepNeedSeconds` rather than a profile constant: an imported night carries WHOOP's own
    /// `Sleep need (min)`, so this panel is comparing like with like, and `UserProfile.targetSleepHours`
    /// — a hard-coded `8.0` that is never persisted and never editable — would put this app's default
    /// against the export's measurement.
    private var sleepNeededPanel: some View {
        let baseline = viewModel.metricWeek?.sleepNeedBaselineSeconds
        let change = MetricChange.between(
            current: selectedMetricDay?.sleepNeedSeconds,
            previous: baseline,
            higherIsBetter: false,
            formatted: { $0.formattedCompactHoursMinutes() })
        return metricPanel(
            label: "SLEEP NEEDED",
            symbol: "moon.zzz.fill",
            value: selectedMetricDay?.sleepNeedSeconds?.formattedCompactHoursMinutes(),
            baselineText: baseline?.formattedCompactHoursMinutes(),
            change: change)
    }

    /// The night's HRV over the week's mean.
    ///
    /// `higherIsBetter: true`, which is the opposite of the resting-heart-rate panel beside it and is
    /// the direction the rest of the app already reads HRV in: `RecoveryScoring` scores it upward, so
    /// a day above its own week is the green one.
    ///
    /// The mean is narrowed to a **single `HRVMetric`** by `MetricWeek` before it is averaged, and the
    /// value above it is gated on the same row flag. That is the never-mix rule, and it is not
    /// cosmetic: SDNN and RMSSD are different quantities on different scales, so an average across
    /// both would be a statistic about neither while looking exactly like a reading. A week holding
    /// both — the export's days are RMSSD, a HealthKit-imported day is SDNN — therefore prints a mean
    /// from the newest metric's days only, and can print none at all while the week has readings in it.
    private var heartRateVariabilityPanel: some View {
        let baseline = viewModel.metricWeek?.hrvBaselineMs
        let change = MetricChange.between(
            current: selectedMetricDay?.hrvValueMs,
            previous: baseline,
            higherIsBetter: true,
            formatted: { String(format: "%.0f", $0) })
        return metricPanel(
            label: "HRV",
            symbol: "waveform.path.ecg",
            value: selectedMetricDay?.hrvValueMs.map { String(format: "%.0f", $0) },
            baselineText: baseline.map { String(format: "%.0f", $0) },
            change: change)
    }

    /// The day's estimated VO₂ max, with the week's mean beneath it and **no change marker**.
    ///
    /// **The label says EST.** It is the one figure on this screen that is not a measurement of
    /// anything: it is `Vo2MaxMath.heartRateRatioEstimate` — `15.3 × HRmax / HRrest`, Uth et al.
    /// (2004) — computed on read from the day's own resting heart rate and the profile's assumed
    /// maximum. The paper's standard error is **4.7 mL·kg⁻¹·min⁻¹ (~7.8%)** when `HRmax` is
    /// age-predicted rather than measured, which is this app's case; the study's population was 46
    /// well-trained men and its authors say applicability elsewhere needs direct validation. Printing
    /// that as a bare `VO₂ MAX` beside three genuinely measured panels would present it as a reading
    /// of the same kind, which is the "At baseline" mistake in a different tile. See `docs/ALGORITHMS.md`
    /// §6 for the model and §`Vo2MaxMath` for the anchor decision.
    ///
    /// The marker is the part that is still a decision. `MetricChange.between` would compare the day's
    /// estimate with the week's mean and draw an arrow coloured by the result, which asserts a
    /// day-to-day movement this quantity does not have: VO₂ max declines over decades, and the
    /// estimate's own error is several times the daily swing. The mean is still context worth
    /// printing, so it goes in the plain muted slot `metricPanel` keeps for a figure with no direction
    /// attached; a dash there means the week has fewer than three days that could produce an estimate
    /// at all.
    ///
    /// **A dash is still a normal state, not a failure.** The estimate needs a measured resting heart
    /// rate for the day, so every day with no recovery row — the whole of a week before the first
    /// import, and every strap-less day since — is `—` by construction.
    private var vo2MaxPanel: some View {
        let baseline = viewModel.metricWeek?.vo2MaxBaselineMlKgMin
        return metricPanel(
            label: "VO₂ MAX (EST.)",
            symbol: "lungs.fill",
            value: selectedMetricDay?.vo2MaxMlKgMin.map { String(format: "%.0f", $0) },
            baselineText: baseline.map { String(format: "%.0f", $0) },
            change: nil)
    }

    /// The full-width STRESS MONITOR tile.
    ///
    /// Shows the band as well as the number because the number alone is unreadable without its scale:
    /// `1.4` means nothing until "Medium" is next to it, and the band is what the mockup's chevron
    /// would have led to. The band's colour reuses the recovery tier tokens — calm to activated is the
    /// same direction as recovered to strained, and inventing a parallel palette for one tile would
    /// give the app two greens that mean different things.
    private var stressTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("STRESS MONITOR")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(viewModel.stress.map { $0.averageScore.formattedOneDecimal() } ?? "—")
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .foregroundStyle(viewModel.stress == nil ? Theme.textMuted : Theme.textPrimary)
                            .monospacedDigit()

                        if let stress = viewModel.stress {
                            Text(stress.band.rawValue.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(stress.band.color)
                        }
                    }

                    Text(stressCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            // Drawn only when there is a series behind it, and the chart draws nothing itself when
            // there is not. A day whose samples yielded no eligible window has no `StressDay` at all,
            // so an empty plot and an absent one are the same condition — and `stressCaption` is what
            // says so in words.
            if let day = viewModel.stressDay, !day.windows.isEmpty {
                StressMonitorChartView(windows: day.windows, day: day.score.date, now: chartNow)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stressAccessibilityDescription)
    }

    /// `nil` on a day that is not today. The chart's marker is a claim about the present, and a day in
    /// the past has no present on it.
    private var chartNow: Date? {
        Calendar.current.isDateInToday(selectedDate) ? Date() : nil
    }

    private var stressAccessibilityDescription: String {
        guard let stress = viewModel.stress else {
            return "Stress Monitor, no measurement for this day"
        }
        let figure = "Stress Monitor, \(stress.averageScore.formattedOneDecimal()), "
            + "\(stress.band.rawValue.lowercased())"
        guard viewModel.stressDay?.windows.isEmpty == false else { return figure }
        return figure + ", with the day's daytime windows plotted below"
    }

    /// Says what the figure is, or why there is not one.
    ///
    /// The peak is worth surfacing next to the average because the two answer different questions and
    /// WHOOP's product behaviour keys off the high-stress *moment*. `windowCount` is not shown: it is
    /// there for the reader of the data, not the wearer of the strap.
    private var stressCaption: String {
        guard let stress = viewModel.stress else {
            return "No still, daytime windows with enough beats were recorded for this day."
        }
        return "Peak \(stress.peakScore.formattedOneDecimal()) · daytime average"
    }

    // MARK: - The week's chart

    /// The full-width STRAIN & RECOVERY tile: seven days, two series, two axes.
    ///
    /// It draws through `MetricWeek`, the same value the two panels above read, so the chart's
    /// highlighted column and the panels' figures are the same day by construction. The chart itself
    /// draws nothing when no slot holds a strain or a recovery — an empty seven-column grid reads as a
    /// week of zeros — and `strainRecoveryCaption` is what says so in words.
    private var strainRecoveryTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STRAIN & RECOVERY")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)

            if let week = viewModel.metricWeek, week.days.contains(where: \.hasAnyMeasurement) {
                StrainRecoveryChartView(week: week, selectedDate: selectedDate)
            }

            Text(strainRecoveryCaption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strainRecoveryAccessibilityDescription)
    }

    /// Says what the week holds, or why nothing is drawn.
    ///
    /// The measured count is in the words because the chart's columns are not labelled with it: four
    /// dots on seven columns should not leave a reader guessing whether the other three were measured
    /// at zero.
    private var strainRecoveryCaption: String {
        guard let week = viewModel.metricWeek, week.measuredDayCount > 0 else {
            return "No strain or recovery recorded in the last seven days."
        }
        return "Last 7 days · \(week.measuredDayCount) measured · blue strain, coloured recovery"
    }

    private var strainRecoveryAccessibilityDescription: String {
        guard let week = viewModel.metricWeek, week.measuredDayCount > 0 else {
            return "Strain and recovery, no measurement in the last seven days"
        }
        let strainDays = week.days.filter { $0.strain != nil }.count
        let recoveryDays = week.days.filter { $0.recoveryScore != nil }.count
        return "Strain and recovery over the last seven days, \(strainDays) days with strain "
            + "and \(recoveryDays) with a recovery score"
    }

    // MARK: - Tile deltas
    //
    // The two rules these tiles are built on — which way a figure moved, and whether that direction
    // is good news — now live in `MetricChange`, shared with `RecoveryDetailView`, which prints the
    // same arrow against a trailing mean on all four of its rows.

    private var stepsChange: MetricChange? {
        MetricChange.between(
            current: viewModel.steps.map(Double.init),
            previous: viewModel.previousDaySteps.map(Double.init),
            higherIsBetter: true,
            formatted: { $0.formatted(.number.grouping(.automatic)) })
    }

    private var restorativeSleepChange: MetricChange? {
        MetricChange.between(
            current: viewModel.restorativeSleepSeconds,
            previous: viewModel.previousDayRestorativeSleepSeconds,
            higherIsBetter: true,
            formatted: { $0.formattedCompactHoursMinutes() })
    }
}

// MARK: - Platform

extension View {
    /// Hides the tab bar, on the platforms that have one.
    ///
    /// **Not `private` any more.** It was, while Home was its only caller; `LiveSessionView` is the
    /// second, and the alternative to widening this is a second copy of the `#if os(iOS)` guard in
    /// that file — which is the drift this repo extracts helpers to prevent.
    ///
    /// `ToolbarPlacement.tabBar` is unavailable on macOS and this view is built for both — the host
    /// `swift build` is this repo's edit/compile loop and the test runner links against its objects.
    /// An unguarded `.toolbar(_:for: .tabBar)` breaks that path while the iOS build stays green,
    /// which is exactly how it got here; the guard is what the iOS build could not tell us.
    @ViewBuilder
    func hidingTabBar(_ hidden: Bool) -> some View {
        #if os(iOS)
        toolbar(hidden ? .hidden : .visible, for: .tabBar)
        #else
        self
        #endif
    }
}

/// The bottom edge of the rings row, in the scroll view's own coordinate space.
///
/// `defaultValue` is a `static let` rather than a `static var` — a mutable static is a concurrency
/// error under Swift 6, and `PreferenceKey` only ever reads it. It is deliberately far outside any
/// real geometry, so a frame in which nothing has published yet resolves to a fully hidden header
/// rather than to a fully shown one.
private struct RingsBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// The `+` button's frame, in the scroll view's own coordinate space — what the activity menu hangs
/// from.
///
/// `defaultValue` is `.null` rather than a zero rect, so an unpublished frame is distinguishable from
/// one measured at the origin and the card is never placed from a value no layout produced. `union` is
/// the identity for `.null`, which is what makes that reduction the honest one; there is only ever one
/// publisher of this key.
private struct ActivityMenuAnchorKey: PreferenceKey {
    static let defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = value.union(nextValue())
    }
}
