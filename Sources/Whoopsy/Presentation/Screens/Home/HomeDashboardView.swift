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
/// **The recovery ring is now the one exception, and it pushes rather than switching tabs.** Tapping
/// it opens `RecoveryDetailView` seeded with the day on screen, on the `NavigationStack` this screen
/// already owns. Switching to the Recovery tab would have been cheaper and is wrong: that tab keeps a
/// private day seeded to `Date()`, so tapping an 87% ring on an imported day would land on "No data
/// recorded" — today is past the export's end. The other two rings and the STRESS MONITOR tile stay
/// inert for the reason above: Strain, Sleep and Stress each keep their own day the same way, so each
/// needs the same push-shaped fix rather than a tab switch, and `RecoveryDetailView` is the shape to
/// copy when they get one. **The chevrons stay omitted** — a chevron on one of three otherwise
/// identical rings would say the other two are broken, and the tap target is discoverable without it.
///
/// **Implemented from the scrolled state of the reference:** the three rings collapse into a compact
/// row pinned to the top once they scroll out of view (`collapsedHeader`), and the STRESS MONITOR tile
/// draws the day's windows (`StressMonitorChartView`).
///
/// **The week's figures all come from one `MetricWeek`.** The RESTING HEART RATE, SLEEP NEEDED, HEART
/// RATE VARIABILITY and VO₂ MAX panels and the STRAIN & RECOVERY chart are views of the same seven
/// days, so they read through one value rather than five separate reads — see
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
/// whole mL·kg⁻¹·min⁻¹ — `ALGORITHMS.md` §6 carries the model, its 4.7 mL·kg⁻¹·min⁻¹ SEE, and the
/// sex-specific factor the app does not implement.
public struct HomeDashboardView: View {
    @State private var viewModel: HomeViewModel
    @State private var workoutViewModel: ActiveWorkoutViewModel
    /// Built here rather than reached for at the tap, because a pushed screen's view model has to
    /// exist before the push animation starts or the destination renders empty for a frame. It is a
    /// second `RecoveryViewModel` beside the Recovery tab's, deliberately: they are two screens with
    /// two days, and sharing one would make paging the pushed copy move the tab's day underneath it.
    @State private var recoveryViewModel: RecoveryViewModel
    @State private var selectedDate: Date = Date()
    @State private var isPresentingWorkout = false
    @State private var isPresentingCalendar = false

    public init(
        viewModel: HomeViewModel,
        workoutViewModel: ActiveWorkoutViewModel,
        recoveryViewModel: RecoveryViewModel
    ) {
        _viewModel = State(initialValue: viewModel)
        _workoutViewModel = State(initialValue: workoutViewModel)
        _recoveryViewModel = State(initialValue: recoveryViewModel)
    }

    public var body: some View {
        NavigationStack {
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
            // must stay a `VStack`: a `LazyVStack` may release the rings row once it is scrolled past,
            // and the preference that drives the header would go with it.
            .coordinateSpace(.named(Self.scrollSpace))
            .background(Theme.homeBackground.ignoresSafeArea())
            .overlayPreferenceValue(RingsBottomKey.self, alignment: .top) { ringsBottom in
                collapsedHeader(collapse: collapse(for: ringsBottom))
            }
            .task {
                await viewModel.observeDevice()
                await viewModel.load(for: selectedDate)
            }
            .onChange(of: selectedDate) { _, newDate in
                Task { await viewModel.load(for: newDate) }
            }
        }
        .preferredColorScheme(.dark)
        // The bar is hidden while the calendar is up, and that is not only for the look of it. An
        // overlay inside a tab cannot cover the tab bar — the `TabView` draws it above its content —
        // so leaving it visible would put a bright, tappable row of tabs under a modal, and tapping
        // one would switch screens with `isPresentingCalendar` still set, so the calendar would be
        // waiting on Home when the user came back. Removing the bar removes both problems at once.
        .hidingTabBar(isPresentingCalendar)
        .sheet(isPresented: $isPresentingWorkout) {
            ActiveWorkoutHUDView(viewModel: workoutViewModel)
        }
        .overlay {
            if isPresentingCalendar { calendarOverlay }
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // The only `DayNavigationBar` call site that passes `onTitleTap`. Strain and Sleep keep
            // the plain label, because this is the only screen with a calendar to open — and
            // Recovery no longer draws the bar at all.
            DayNavigationBar(date: $selectedDate, onTitleTap: {
                withAnimation(.snappy(duration: 0.3)) { isPresentingCalendar = true }
            })
            statusBadge
        }
    }

    /// The strap's connection dot and battery percentage.
    ///
    /// The percentage is a dash unless the strap is *connected*. `WhoopBLEManager` writes a literal
    /// `100` at discovery and `WhoopDevice` defaults to `100`, so a disconnected strap would
    /// otherwise show a confident fabricated "100%" — the exact failure the dash convention exists to
    /// prevent. The dot carries the state honestly in that case instead.
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(batteryText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.homeCard)
        .clipShape(Capsule())
        .accessibilityLabel(connectionLabel)
    }

    private var batteryText: String {
        guard let device = viewModel.device, device.connectionState == .connected else { return "—" }
        return "\(device.batteryPercentage)%"
    }

    private var connectionColor: Color {
        switch viewModel.device?.connectionState {
        case .connected: return Theme.recoveryGreen
        case .scanning, .connecting, .syncing: return Theme.recoveryYellow
        case .disconnected, .error: return Theme.textMuted
        case nil: return Theme.textMuted
        }
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

    /// The three rings. The collapsed header draws the same row small, which is why every dimension
    /// is a parameter rather than a literal — two copies of the three `progress` expressions is how
    /// the header's arcs would come to disagree with the rings they replaced.
    ///
    /// `compact` also fixes each ring's width and drops its label. `MetricRingView`'s label font is
    /// fixed at 10pt rather than scaled from `size`, so at 40pt the words would be wider than the
    /// rings they sit under and would decide the header's height.
    private func ringRow(size: CGFloat, lineWidth: CGFloat, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 18 : 6) {
            ring(
                value: sleepValue, label: "Sleep", progress: sleepProgress,
                color: Theme.sleepPerformance, size: size, lineWidth: lineWidth, compact: compact)
            // The one ring with a destination, and the only difference between the three besides
            // their values. The destination is handed the day Home is showing, so tapping an 87%
            // ring opens that 87% day — and it is now the *only* route to a past day on that screen,
            // since `RecoveryDetailView` no longer pages. See it for why the Recovery tab could not
            // be reached this way instead. `buttonStyle(.plain)` is load-bearing: the default styles
            // tint the label and add a hit shape, which would recolour the arc itself.
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
            ring(
                value: strainValue, label: "Strain", progress: strainProgress,
                color: Theme.strainRing, size: size, lineWidth: lineWidth, compact: compact)
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
            Button {
                isPresentingWorkout = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.homeBackground)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
            }
            .accessibilityLabel("Record a workout")
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
                if let sleep = viewModel.sleep {
                    activityRow(
                        symbol: "moon.fill",
                        tint: Theme.sleepPerformance,
                        value: sleep.totalTimeAsleepSeconds.formattedCompactHoursMinutes(),
                        label: "SLEEP",
                        startedAt: sleep.startTime,
                        endedAt: sleep.endTime)
                }

                ForEach(viewModel.workouts) { workout in
                    activityRow(
                        symbol: "figure.run",
                        tint: Theme.strainRing,
                        value: workout.strain.formattedOneDecimal(),
                        label: "ACTIVITY",
                        startedAt: workout.startedAt,
                        endedAt: workout.endedAt)
                }
            }
        }
        .padding(14)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func activityRow(
        symbol: String,
        tint: Color,
        value: String,
        label: String,
        startedAt: Date,
        endedAt: Date
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            timeRange(startedAt: startedAt, endedAt: endedAt)
        }
    }

    /// The range, with the weekday prefixed only when the two ends fall on different days.
    ///
    /// A session from 11:19 PM to 7:25 AM is on two calendar days and the clock times alone cannot say
    /// which; a session from 5:33 PM to 5:47 PM does not need telling. Prefixing both would put a
    /// redundant word on every row.
    private func timeRange(startedAt: Date, endedAt: Date) -> some View {
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
            Text("\(startedAt.formattedHourMinute()) / \(endedAt.formattedHourMinute())")
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
                        .foregroundStyle(change.direction == .up ? Theme.recoveryGreen : Theme.strainPrimary)
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

    /// One tile, one announcement. The arrow is a drawn glyph rather than text, so without this the
    /// direction it encodes is invisible to VoiceOver entirely.
    private func tileDescription(label: String, value: String?, change: MetricChange?) -> String {
        guard let value else { return "\(label), no measurement" }
        guard let change else { return "\(label), \(value)" }
        let direction = change.direction == .up ? "up from" : "down from"
        return "\(label), \(value), \(direction) \(change.previousText)"
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
        change: MetricChange?,
        changeColor: Color
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
                            .foregroundStyle(changeColor)
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

    /// One panel, one announcement. The arrow is a drawn glyph, and its direction is also the only
    /// thing that says whether the day is above or below the baseline.
    private func panelDescription(
        label: String, value: String?, baselineText: String?, change: MetricChange?
    ) -> String {
        guard let value else { return "\(label), no measurement" }
        guard let change else {
            guard let baselineText else { return "\(label), \(value)" }
            return "\(label), \(value), 7-day average \(baselineText)"
        }
        let direction = change.direction == .up ? "above" : "below"
        return "\(label), \(value), \(direction) the 7-day average of \(change.previousText)"
    }

    /// The day's resting heart rate over the week's mean.
    ///
    /// A measured day with no heart rate is a dash: the column's reserved `0` is not a bpm, which is
    /// why `MetricWeek` gates it twice — see `MetricDay`.
    private var restingHeartRatePanel: some View {
        let baseline = viewModel.metricWeek?.restingHeartRateBaseline
        let marker = MetricChange.marker(
            current: selectedMetricDay?.restingHeartRate.map { Double($0) },
            baseline: baseline.map { Double($0) },
            higherIsBetter: false,
            formatted: { String(Int($0.rounded())) })
        return metricPanel(
            label: "RESTING HEART RATE",
            symbol: "heart.fill",
            value: selectedMetricDay?.restingHeartRate.map { "\($0)" },
            baselineText: baseline.map { "\($0)" },
            change: marker?.change,
            changeColor: marker?.color ?? Theme.textMuted)
    }

    /// The night's need over the week's mean.
    ///
    /// `targetSleepNeedSeconds` rather than a profile constant: an imported night carries WHOOP's own
    /// `Sleep need (min)`, so this panel is comparing like with like, and `UserProfile.targetSleepHours`
    /// — a hard-coded `8.0` that is never persisted and never editable — would put this app's default
    /// against the export's measurement.
    private var sleepNeededPanel: some View {
        let baseline = viewModel.metricWeek?.sleepNeedBaselineSeconds
        let marker = MetricChange.marker(
            current: selectedMetricDay?.sleepNeedSeconds,
            baseline: baseline,
            higherIsBetter: false,
            formatted: { $0.formattedCompactHoursMinutes() })
        return metricPanel(
            label: "SLEEP NEEDED",
            symbol: "moon.zzz.fill",
            value: selectedMetricDay?.sleepNeedSeconds?.formattedCompactHoursMinutes(),
            baselineText: baseline?.formattedCompactHoursMinutes(),
            change: marker?.change,
            changeColor: marker?.color ?? Theme.textMuted)
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
        let marker = MetricChange.marker(
            current: selectedMetricDay?.hrvValueMs,
            baseline: baseline,
            higherIsBetter: true,
            formatted: { String(format: "%.0f", $0) })
        return metricPanel(
            label: "HEART RATE VARIABILITY",
            symbol: "waveform.path.ecg",
            value: selectedMetricDay?.hrvValueMs.map { String(format: "%.0f", $0) },
            baselineText: baseline.map { String(format: "%.0f", $0) },
            change: marker?.change,
            changeColor: marker?.color ?? Theme.textMuted)
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
    /// of the same kind, which is the "At baseline" mistake in a different tile. See `ALGORITHMS.md`
    /// §6 for the model and §`Vo2MaxMath` for the anchor decision.
    ///
    /// The marker is the part that is still a decision. `MetricChange.marker` would compare the day's
    /// estimate with the week's mean and colour an arrow by the result, which asserts a day-to-day
    /// movement this quantity does not have: VO₂ max declines over decades, and the estimate's own
    /// error is several times the daily swing. The mean is still context worth printing, so it goes in
    /// the plain muted slot `metricPanel` keeps for a figure with no direction attached; a dash there
    /// means the week has fewer than three days that could produce an estimate at all.
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
            change: nil,
            changeColor: Theme.textMuted)
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
            formatted: { $0.formatted(.number.grouping(.automatic)) })
    }

    private var restorativeSleepChange: MetricChange? {
        MetricChange.between(
            current: viewModel.restorativeSleepSeconds,
            previous: viewModel.previousDayRestorativeSleepSeconds,
            formatted: { $0.formattedCompactHoursMinutes() })
    }
}

// MARK: - Platform

private extension View {
    /// Hides the tab bar, on the platforms that have one.
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
