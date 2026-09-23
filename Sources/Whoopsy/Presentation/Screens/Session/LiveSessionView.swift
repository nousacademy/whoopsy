import SwiftUI

/// The screen a live session is watched on — pushed from Home's `START ACTIVITY` row.
///
/// **It owns no `NavigationStack` and no `@State` view model.** The first is the shape every pushed
/// page in this app has (`RecoveryDetailView`, `SleepDetailView`, `StrainDetailView`): Home supplies
/// the chrome. The second is the whole point of the feature — the session is
/// `LiveSessionUseCase`, held by `DIContainer` and handed down from `MainContainerView`, so the screen
/// is free to come and go while the recording continues. There is deliberately **no**
/// `.onDisappear { end() }`: backing out is not stopping, and that absence *is* the user's requirement,
/// quoted on the use case.
///
/// Three consequences of that arrangement are visible here and none of them is a defect:
///
/// - **The tab bar is hidden — but not by this file's `.hidingTabBar(true)`, which does nothing
///   from here.** Measured on the iOS 26.5 simulator: a `.toolbar(.hidden, for: .tabBar)` declared on
///   a pushed destination leaves the bar drawn over the session, hiding the END button behind it,
///   whether the push happens during first layout or after it. The modifier that works is
///   `HomeDashboardView`'s, on the tab's **root**, gated on the same flag that drives this push — so
///   the bar also comes back when the reader pops. The call below is kept as the intent it expresses
///   rather than as the mechanism; **do not treat it as load-bearing, and do not delete Home's line
///   because this one looks like it does the job.**
/// - **Re-entering shows the accumulated figures rather than a fresh screen**, because `snapshot` is
///   the use case's and not this view's. That is also why the ring, the reading and the timer are the
///   only state this page has: nothing here is `@State` except the flag guarding a double tap on END.
/// - **The timer is system-rendered** (`Text(_:style: .timer)`), so it ticks from the wall clock with no
///   update of any kind. That is what makes it survive suspension, and it is why elapsed time is never
///   computed from a sample count. It also means the timer and the figures can legitimately disagree:
///   `bluetooth-central` grants the app wake-ups rather than a background lifetime, so a suspended
///   process keeps a ticking clock over a frozen heart rate.
///
/// **Every figure on this page is a reading or a dash, and there is no third state.** Nothing here
/// substitutes a plausible constant for an absent measurement — see the individual members, each of
/// which says which absence it is drawing.
public struct LiveSessionView: View {

    /// The session, owned by the app. See the type's note on why this is not a `@State`.
    private let useCase: LiveSessionUseCase

    /// Pops this page after the session has been ended and written.
    @Environment(\.dismiss) private var dismiss

    /// Guards the END button against a second tap while `end()` is saving.
    ///
    /// `end()` is not idempotent in the way `start()` is — its own `isRunning` guard makes a second
    /// call return `nil` immediately, but that happens only *after* the first call has already
    /// cleared the flag, so a double tap is a race between a save and a no-op rather than a duplicate
    /// row. This flag is what keeps the button from being tappable during that window.
    @State private var isEnding = false

    public init(useCase: LiveSessionUseCase) {
        self.useCase = useCase
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                strainRing
                heartRateBlock
                statTiles
                routeCard
                routeNote
                endButton
                liveActivityNote
            }
            .padding()
        }
        // Load-bearing for `StrainDetailView`'s documented reason: a `ScrollView` whose content holds
        // nothing flexible lays out at its content's ideal width, and `.background` then paints a
        // centred column with the window's black either side of it. This page's content is cards, so
        // it would survive without this — but the header banner and the ring are not, and one
        // card-less page in this app has already shipped as a dark column.
        .frame(maxWidth: .infinity)
        .background(Theme.homeBackground.ignoresSafeArea())
        // Expresses the intent and is **not** what hides the bar — see the note at the top of this
        // type. Home's line is the one that works, and this will silently do nothing without it.
        .hidingTabBar(true)
        .navigationTitle("Activity")
        // `DeviceDetailView`'s helper, not a second `#if` — `navigationBarTitleDisplayMode` is
        // unavailable on macOS and this page is compiled for both.
        .inlineNavigationTitle()
        // Idempotent: `start()` returns immediately while a session is running, which is what makes
        // this safe to run on every appearance — the reader backing out and returning must not begin
        // a second session, and must not be a no-op either when the first `start()` never landed.
        .task { await useCase.start() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    /// The reference's banner: a flag, the running timer, and the state of the recording.
    ///
    /// **The timer is the whole of the elapsed-time implementation.** `Text(_:style: .timer)` is drawn
    /// by the system from `startedAt` and needs no update, no `TimelineView` and no tick of its own —
    /// so it keeps counting while the app is suspended, which is the user's lock-screen requirement
    /// satisfied by the same line of code that satisfies the on-screen one.
    ///
    /// `startedAt` is `nil` only before `start()` has landed, and the fallback is a dash pair rather
    /// than `00:00`: a stopped clock and a session that has not begun are different states, and a
    /// session genuinely at zero seconds prints `00:00` from the timer itself.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.fill")
                .font(.system(size: 15, weight: .bold))
                .accessibilityHidden(true)

            if let startedAt = useCase.startedAt {
                Text(startedAt, style: .timer)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text("--:--")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            liveBadge
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.recoveryRed.opacity(useCase.isRunning ? 0.85 : 0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timerDescription)
    }

    /// `LIVE` while recording, `ENDED` once it is not.
    ///
    /// The reference draws this as a circular `LIVE` button. It is a capsule here and **not a button**,
    /// because it has no destination: the control that ends the session is `END`, and a second control
    /// that looked tappable and was not is the defect `StrainDetailView` records against the
    /// reference's `i` button.
    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .opacity(useCase.isRunning ? 1 : 0.4)

            Text(useCase.isRunning ? "LIVE" : "ENDED")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.22))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// The banner reads as one element, so the timer's own value is announced here rather than left to
    /// the system's rendering of a `Text` it draws itself.
    private var timerDescription: String {
        guard let startedAt = useCase.startedAt else { return "Activity, not started" }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let state = useCase.isRunning ? "recording" : "ended"
        return "Activity \(state), \(elapsed / 60) minutes \(elapsed % 60) seconds elapsed"
    }

    // MARK: - Strain

    /// The ring: `ACTIVITY STRAIN` over the session's score, and nothing else.
    ///
    /// **The reference's `RESTORATIVE` word under the number is omitted**, on the user's instruction.
    /// It is also not a strain band: `StrainScore.category` carries WHOOP's four boundaries with five
    /// invented names and `Strenuous` on the wrong band, so drawing one would be a claim this app
    /// cannot support. The ring says the quantity and the figure, which is all it has.
    ///
    /// **No `OPTIMAL` arc and no `W` knob**, also per the user. This app produces no target strain for
    /// a session, so an arc marking one would be a recommendation nobody computed — the same judgement
    /// that leaves the sleep-consistency legend reading `AVG` where the mockup says `OPTIMAL`.
    ///
    /// The score is `nil` until a sample arrives, and a dash is what that draws. `0.0` is a different
    /// answer and it gets its own frame: the accumulator returns it for a session that has been
    /// measured and never reached zone 1.
    ///
    /// **`labelScale: 0.07` is this page's own, and it is a correction rather than a preference.**
    /// `ACTIVITY STRAIN` is the longest label any ring in this app prints, and at the shared default
    /// it is 159.9 pt wide on a 190 pt ring whose inner chord there is 151.8 pt — so the word crossed
    /// the stroke at both ends and read as touching it. `0.07` draws it at 131.6 pt against a 154.2 pt
    /// chord, which is 11.4 pt of clearance a side; the figure is 13.3 pt. `GaugeRingView`'s
    /// `labelScale` carries the geometry, and it is a parameter rather than a new default because
    /// five other call sites draw through this type.
    private var strainRing: some View {
        GaugeRingView(
            progress: strainProgress,
            scoreText: strainText,
            label: "Activity Strain",
            ringColor: Theme.strainRing,
            labelScale: 0.07,
            // The reference names the quantity above its figure, which is the opposite of every other
            // ring in this app. It also buys clearance: the label's chord is widest at the ring's
            // centre line, so moving it up from the bottom of the stack can only widen the chord it
            // has to fit inside — see `labelFirst` on the component.
            labelFirst: true,
            lineWidth: 18,
            size: 190)
        .padding(.vertical, 4)
    }

    private var dash: String { "—" }

    /// `nil` and `0.0` both draw an empty arc, which is correct for both: a session that has measured
    /// nothing has no strain to show, and one measured entirely below zone 1 has a strain of zero.
    /// The two are told apart by the *text*, which is where a reader looks for the figure.
    private var strainProgress: Double {
        guard let strain = useCase.snapshot?.strain else { return 0 }
        return strain / 21.0
    }

    private var strainText: String {
        guard let strain = useCase.snapshot?.strain else { return dash }
        return strain.formattedOneDecimal()
    }

    // MARK: - Heart rate

    /// The live reading over the reserve scale, or the same block with nothing to place on it.
    ///
    /// **This is one element, not two panels.** The reference puts a `HEART RATE` label over a large
    /// left-aligned reading with the five-band percentage scale directly beneath it, so the figure and
    /// the scale are read together: the number says what the heart rate is and the scale says where
    /// that falls. An earlier version of this page drew the scale in a card of its own, filled with the
    /// session's *time in each band* — a different quantity answering a question nobody had asked, and
    /// the reading arrived with no scale to read it against.
    ///
    /// **`LiveHeartRateView` is called only when a reading, an on-body state and a scale position all
    /// exist**, and none of the three is defaulted. `Snapshot.isOnBody` is `Bool?` precisely so this
    /// call site cannot pass a literal: `?? true` would draw a `LIVE TELEMETRY` badge — a claim about
    /// the strap — on a session that has heard from no strap at all, which is the fabrication class
    /// `WhoopDevice.batteryPercentage` already documents. `bandScalePosition` is `nil` exactly when
    /// `latestHeartRate` is, and unwrapping it here rather than defaulting it is what keeps a mark off
    /// a scale with no reading to place on it.
    @ViewBuilder
    private var heartRateBlock: some View {
        if
            let snapshot = useCase.snapshot,
            let heartRate = snapshot.latestHeartRate,
            let isOnBody = snapshot.isOnBody,
            let bandScalePosition = snapshot.bandScalePosition
        {
            LiveHeartRateView(
                currentBPM: heartRate,
                isOnBody: isOnBody,
                bandScalePosition: bandScalePosition)
        } else {
            awaitingHeartRateBlock
        }
    }

    /// What this page shows on every machine in this repo, and on every session before the first
    /// sample: **no strap has ever written a row to `biometric_samples` here**, so a reading is
    /// unreachable without hardware. It is a normal state and it is drawn as one — the block keeps the
    /// same shape as the real one so the page does not reflow when data arrives, and the dash is where
    /// the reading will be.
    ///
    /// **The scale is drawn here too, and it is the same scale.** It is a set of band edges rather than
    /// a measurement, so it is the same picture with or without a reading — which is exactly why it is
    /// drawn rather than withheld, and why the mark is what is missing rather than the bar.
    private var awaitingHeartRateBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEART RATE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
                .tracking(1.0)

            // The same slot, the same 40 pt, and the same left alignment `LiveHeartRateView` draws
            // its reading in — so the block keeps its height and nothing below it moves when the first
            // sample lands. The `BPM` unit is withheld here for the reason `statTile` gives: a
            // `— BPM` reads as a measurement with an unreadable value rather than as none.
            Text(dash)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textMuted)

            HeartRateBandScaleView(position: nil)

            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.textMuted)
                    .frame(width: 8, height: 8)

                Text("NO TELEMETRY")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textMuted)
                    .tracking(1.0)
            }
            .accessibilityHidden(true)

            Text("No heart rate has arrived yet. The strap reports one only while it is worn and connected.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Session statistics

    /// `AVG HR`, `MAX HR` and `CALORIES`, side by side.
    ///
    /// **`CALORIES` draws a dash on every session until the profile page has a weight**, and that is
    /// the point of it rather than a gap: `StrainAccumulatorMath.estimateCalories` refuses to
    /// substitute a body weight, because the figure is reported back to the user as their own
    /// expenditure and a defaulted `75 kg` would be an invention about their body. The formula is this
    /// app's own approximation and not a validated equation — `docs/ALGORITHMS.md` §7 says so — so what the
    /// dash is withholding is a rough number, and it is still withheld rather than guessed.
    ///
    /// All three are `nil` on a session that has measured nothing, which is why each one is an
    /// optional rather than a zero: an average of no samples is not `0` bpm.
    ///
    /// **The row carries no panel chrome**, which is what the reference shows: three columns of
    /// glyph-name-figure straight on the background, divided by a hairline rule rather than each
    /// sitting in a card of its own. The rules are drawn here rather than by the columns because they
    /// are the *dividers*, and a column that drew its own edge would draw one on the outside too.
    private var statTiles: some View {
        HStack(spacing: 12) {
            statTile(
                symbol: "heart.fill",
                tint: Theme.livePulseCyan,
                label: "AVG HR",
                value: useCase.snapshot?.averageHeartRate.map { "\($0)" },
                unit: "BPM")

            tileDivider

            statTile(
                symbol: "arrow.up.heart.fill",
                tint: Theme.livePulseCyan,
                label: "MAX HR",
                value: useCase.snapshot?.maxHeartRate.map { "\($0)" },
                unit: "BPM")

            tileDivider

            statTile(
                symbol: "flame.fill",
                tint: Theme.strainRing,
                label: "CALORIES",
                value: useCase.snapshot?.calories.map {
                    $0.rounded().formatted(.number.grouping(.automatic))
                },
                unit: "KCAL")
        }
        .padding(.vertical, 4)
    }

    /// The hairline between two figures.
    ///
    /// Written as a bare `Rectangle` and **not** given a `maxHeight: .infinity`: a shape is already
    /// greedy in the axis it is not constrained on, so inside an `HStack` it takes the height of the
    /// tallest sibling by itself. Adding the frame asks for an infinite ideal height, which is the
    /// arrangement that grows a row rather than dividing it. The inset is a `padding` and stays.
    private var tileDivider: some View {
        Rectangle()
            .fill(Theme.cardBorder)
            .frame(width: 1)
            .padding(.vertical, 6)
    }

    /// One tile: a glyph naming the quantity, its name, and then the figure.
    ///
    /// **The glyph and the name come first and the figure last**, which is the reference's order and
    /// the opposite of what this tile drew. It reads better for the same reason the ring's label moved
    /// above its score: the reader is told what they are about to be shown before they are shown it,
    /// and the three figures then line up on one baseline across the row rather than being separated by
    /// three different names.
    ///
    /// **The glyph carries the tint and the name does not**, following Home's `activityRow`, which
    /// paints a workout's symbol `Theme.strainRing` and a night's `Theme.sleepPerformance` while the
    /// label stays neutral. The two heart tiles take `Theme.livePulseCyan`, this page's heart-rate
    /// colour — the waveform, the reading's `BPM` unit and the live badge all already use it — and
    /// `CALORIES` takes `Theme.strainRing`, which is the colour the same figure is drawn in on Home and
    /// is *why* it is that colour: the number comes out of `StrainAccumulatorMath`, the strain model,
    /// and not out of a calorie model this app does not have.
    ///
    /// **A tint naming a quantity is not a reading and does not dim**, while an unmeasured tile's
    /// glyph and label fall to `Theme.textMuted` together — so the part that names the thing stays
    /// legible and only the part that would report a value says there is none.
    ///
    /// The unit is drawn beside a figure and **withheld beside a dash** — a `— KCAL` would read as a
    /// measurement with an unreadable value rather than as nothing measured, which is the same reason
    /// `StrainDetailView`'s dashed rows announce themselves as "no measurement".
    private func statTile(
        symbol: String,
        tint: Color,
        label: String,
        value: String?,
        unit: String
    ) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundColor(value == nil ? Theme.textMuted : tint)

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(value == nil ? Theme.textMuted : Theme.textSecondary)
                .tracking(0.8)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? dash)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(value == nil ? Theme.textMuted : Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if value != nil {
                    Text(unit)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            value.map { "\(label), \($0) \(unit.lowercased())" } ?? "\(label), no measurement")
    }

    // MARK: - Ending

    /// Ends the session, writes it as an activity, and pops back to Home.
    ///
    /// **The pop happens whether or not a row was written**, and `end()` returns `nil` for a session
    /// that measured nothing — a user who taps START and END with no strap connected gets no activity
    /// on Home rather than a `0.0` strain row, which is the repo's standing write rule. Staying on the
    /// page in that case would leave the reader on a screen whose session no longer exists, so the
    /// dismissal is unconditional and the use case is where the honesty lives.
    private var endButton: some View {
        Button {
            guard !isEnding else { return }
            isEnding = true
            Task {
                await useCase.end()
                dismiss()
            }
        } label: {
            Text("END")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.recoveryRed)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isEnding || !useCase.isRunning)
        .opacity(useCase.isRunning ? 1 : 0.5)
    }

    // MARK: - Route

    /// The opt-in switch for GPS route recording, off until the user turns it on.
    ///
    /// **Why this is a toggle and not automatic.** The session cannot decide whether it is outdoors:
    /// this app deliberately does not classify an activity, and the strap has no way to know if the
    /// phone is on a sofa or on a bike. Recording a route anyway would draw a cloud of GPS jitter
    /// around a living room and call it exercise. So the user answers, once per session.
    ///
    /// **The setter hands the work to a `Task` rather than awaiting it**, which is not a shortcut: a
    /// `Toggle` needs a synchronous setter, and the first flip *is* asynchronous — it puts the system
    /// permission prompt on screen and returns only once the user has answered it. So the binding reads
    /// its value back from `useCase.isRecordingRoute` rather than holding one of its own, and the switch
    /// moves when the use case says it moved. A refusal therefore leaves the switch off, which is the
    /// honest position and not a stuck control.
    ///
    /// **The session does not wait for this.** `start()` runs from the `.task` above, so the recording
    /// begins when the screen appears and a route turned on later begins at the flip. See
    /// `setRouteRecording(_:)`.
    private var routeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill")
                .font(.system(size: 15))
                .foregroundColor(useCase.isRecordingRoute ? Theme.livePulseCyan : Theme.textMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text("RECORD ROUTE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .tracking(0.8)

                Text("Uses GPS while this session runs. Keeps recording when the screen locks.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: routeBinding)
                .labelsHidden()
                .tint(Theme.livePulseCyan)
        }
        .padding(14)
        .background(Theme.homeCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    /// Reads through to the use case and writes through a `Task` — see `routeCard` for why.
    private var routeBinding: Binding<Bool> {
        Binding(
            get: { useCase.isRecordingRoute },
            set: { isOn in Task { await useCase.setRouteRecording(isOn) } }
        )
    }

    /// Reports a route that could not be recorded, and says nothing otherwise.
    ///
    /// **A refused permission is not a failed session.** Whether the phone will share its position has
    /// nothing to do with the strap, so the recording continues and this is a note under it — the same
    /// shape as `liveActivityNote` below, and absent entirely in the ordinary case rather than printing
    /// "route: on".
    ///
    /// **It prints `useCase.routeError` as the whole sentence**, which is the one way this differs from
    /// its sibling: a refused Live Activity arrives with a system `localizedDescription` worth relaying,
    /// so that note writes a frame around it, while a refused permission is an enum case with no string
    /// attached and the use case has to author the words. See the field's own note.
    @ViewBuilder
    private var routeNote: some View {
        if let error = useCase.routeError {
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    /// Reports a refused lock-screen card, and says nothing otherwise.
    ///
    /// **A card that could not be shown is not a failed session.** Live Activities can be switched off
    /// for the app, the system caps how many an app may have, and a build without
    /// `NSSupportsLiveActivities` is refused outright — all properties of the device or the build, none
    /// a reason to stop recording. So this is a note under the recording that continues anyway, and it
    /// is absent entirely in the ordinary case rather than printing "lock screen card: on".
    @ViewBuilder
    private var liveActivityNote: some View {
        if let error = useCase.liveActivityError {
            Text("The lock screen card could not be shown, so the session is recording here only. \(error)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }
}
