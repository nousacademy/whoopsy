import SwiftUI

/// The strap's own page, and the app's only one — reached from Home's status badge and from
/// More → Device, both of which now push this screen.
///
/// ## Why there is one page and not two
///
/// This capability was split across two screens until the user asked for the device page to be
/// updated against a WHOOP-app reference: `DeviceSettingsView` was a thin `Form` behind More → Device
/// and `DeviceDetailView` was the real page behind Home's badge. They duplicated the connection,
/// battery and firmware rows, and the duplication had already gone wrong — the Settings copy printed
/// `device?.batteryPercentage ?? 0`, so it showed a fabricated `0%` with no strap attached and the
/// entity's literal `100` the moment one was merely *discovered*, while the badge's page gated the
/// same reading correctly. Two screens disagreeing about one strap is not a layout problem, so the fix
/// is one page, one view model (`DeviceViewModel`), and one gated battery readout.
///
/// ## What it will not draw
///
/// Three figures the reference carries have **no producer in this app**, and each renders the dash
/// instead — `ActivityFigure.dash`, the app's one `—` literal:
///
/// - **Firmware** is a permanent dash. `WhoopDevice.firmwareVersion` is defaulted to the constant
///   `"41.14.2.0"` and `WhoopBLEManager.resolvedDevice` only ever propagates it, so a real strap's
///   device carries the default and printing it would print a number this app wrote down. Both of the
///   screens this page replaced printed exactly that. Making it a dash is the point rather than a
///   regression: the firmware version is load-bearing here, because `SET_CLOCK`'s payload length is
///   firmware-specific and a wrong-length set is acknowledged but never latched
///   (`docs/BLE_PROTOCOL.md` §5) — so "unknown" is the informative answer.
/// - **The reference's red cloud-X** depicts *sync failed*, which nothing on this page can detect.
///   What the page can say is *nothing has ever arrived from the strap*, so the mark is drawn exactly
///   when `lastSync == nil` and it means that.
///
/// The two facts beside it are **not** dashes, and the difference is a producer rather than a
/// preference. `DEVICE ID` is `WhoopDevice.id` — the CoreBluetooth peripheral identifier, written at
/// discovery and the key the model choice is stored against, so it names the strap this app is
/// actually looking at. `SIGNAL` is the advertisement's RSSI. **`serialNumber`, which the reference's
/// rows imply, is the one that stays absent**: it is `String?`, no code path assigns it, and
/// `DEVICE ID` is drawn from the identifier this app has rather than from the one it does not.
///
/// ## The ADVANCED tab
///
/// The reference's ADVANCED tab is a row of labelled marks over a pair of full-width cards, and that
/// is the arrangement here: **`DEVICE ID`, `FIRMWARE` and `SIGNAL`** as one row of glyph-and-label
/// facts, then **`PAIR A DEVICE`** and **`UNPAIR DEVICE`** as two cards with a caption each. The
/// pairing control **moved down from STATUS**, which is the reference's own placement — and it moved
/// rather than being copied, so there is still one definition of it and one place the reader can be.
///
/// **The row carries three facts where the reference carries two**, and `SIGNAL` is the addition. It
/// is the only item in the row whose value this app actually reads: firmware is permanently absent and
/// the device identifier is absent until a strap is discovered, so a row built to the reference's two
/// would be two dashes with the app's one live diagnostic deleted from the page it belongs on. The
/// reference's row is the shape and this is the same shape with the strap facts this app has.
///
/// **`UNPAIR DEVICE` is a disconnect and not a forget, and its caption says so.** There is no forget
/// path anywhere in this app — `WhoopBLEManager.didDiscover` links to the first matching peripheral
/// and the stored model choice is keyed on the peripheral identifier, which nothing clears — so the
/// next scan re-links to the same strap. The reference's caption promises a removal from an account
/// this app does not have; the caption here states what the button does instead.
///
/// ## The controls that are absent on purpose
///
/// The reference draws an **X** top-left and an **ⓘ** top-right. Neither is here. The X would be a
/// second dismiss control: this page is *pushed* onto a `NavigationStack` from both entry points, so
/// it already carries a back chevron — the same affordance. The ⓘ would be a second route to words
/// that are already on the page: the protocol caveat lives on the ADVANCED tab, so a button whose
/// only job is to reveal it would be a control with nothing to reveal.
///
/// ## What the layout takes from the reference
///
/// The page is arranged the way the reference is: a **two-column header** — the relation and its
/// subject on the left, `LAST SYNC` and its instant on the right — over a **row of underlined tabs**,
/// with the strap's own drawing and the state word *below* those tabs rather than above them.
///
/// **The three header lines are now two, and the third moved down with the drawing.** The reference
/// splits the sentence in half: `NOT CONNECTED TO / WHOOP DEVICE` is the header, and
/// `WHOOP DISCONNECTED` is the caption under the illustration. This page previously put `lead` and
/// `stateWord` together in the header, which reads *"NOT CONNECTED TO / WHOOP DISCONNECTED"* — one
/// fact said twice in two type sizes. `Hero`'s three fields are unchanged and still the right three;
/// what changed is which of them the header draws.
///
/// **The strap's mark is `StrapGlyph`, carrying a plus.** That is the user's own specification — *"use
/// the capsule icon we used on home page but this time with that plus sign in the right corner of
/// it"* — and it replaces `sensor.tag.radiowaves.forward.fill`, which is the glyph this page drew while
/// its comment claimed it matched Home. The plus is not decoration: on the reference's own row the
/// left mark is the thing that is *paired*, and the row the reader is looking at says the strap is not.
/// The pair of marks still means what the dashed line between them says — this end is the strap, that
/// end is the link — and the plus is what the button below does about it.
///
/// The reference's **strap photograph is still not drawn**, and now for the reason it was always
/// going to be: this app has no such asset, and an approximation of a physical object reads as a
/// mistake where a mark reads as a symbol. That is also why the mark carries the pairing idea and not
/// an image of the hardware.
public struct DeviceSettingsView: View {
    @State private var viewModel: DeviceViewModel

    /// Which tab is showing. A `@State` because it is the screen's own, and a `Tab` value rather than
    /// an `Int` so the two cases are the only two there are.
    @State private var tab: Tab = .status

    public init(viewModel: DeviceViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    // MARK: - Values the runner can assert

    /// The two tabs, in the order they are drawn.
    ///
    /// A nested `enum` rather than two `Bool`s or an index, on `ActivityMenu.Entry`'s and
    /// `DayBarRules`' rule: **the runner has no renderer**, so a decision written into a `body` is a
    /// decision nothing can assert. Here the decision is small — which sections are drawn — but the
    /// titles and their order are the drawing, and they are what the reference fixes.
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case status = "STATUS"
        case advanced = "ADVANCED"

        public var id: String { rawValue }
        public var title: String { rawValue }
    }

    /// What the header names as the thing [`hero(for:)`] is about.
    ///
    /// A constant rather than a sixth field on `Hero`, deliberately: it is **one value in all six
    /// arms**, so a field would be six copies of one string and a place for them to drift. The
    /// reference says `WHOOP DEVICE` where this app says `WHOOP` everywhere else, and the reference's
    /// word is used because the subject of the sentence is the hardware rather than the company.
    ///
    /// **It is asserted not to equal any arm's `stateWord`**, which is the trap it exists next to: the
    /// header reads `NOT CONNECTED TO / WHOOP DEVICE` and the caption below the tabs reads
    /// `WHOOP DISCONNECTED`, and a subject that had been typed as a state word would put the same
    /// sentence on the page twice in two sizes — which is the defect this arrangement fixes rather
    /// than one it introduces. §14 sweeps all six arms against it.
    public nonisolated static let subject = "WHOOP DEVICE"

    /// The relation, the state, and what to do about it — three fields rather than one composed
    /// sentence, because they are three different weights of type on the screen.
    ///
    /// **They are not drawn in one place, and that is the reference's own arrangement rather than a
    /// split of convenience**: `lead` sits in the header beside [`subject`], while `stateWord` and
    /// `sentence` sit below the tabs as the caption under the strap's mark. Composing them in the
    /// `body` would put the words out of the suite's reach; `ActivityDetailView.typicalDurationCaption`
    /// and `SleepConsistencyCard.legendLabel` are the same extraction for the same reason.
    public struct Hero: Equatable, Sendable {
        public let lead: String
        public let stateWord: String
        public let sentence: String

        public init(lead: String, stateWord: String, sentence: String) {
            self.lead = lead
            self.stateWord = stateWord
            self.sentence = sentence
        }
    }

    /// What the header says for a connection state.
    ///
    /// **An exhaustive `switch` over `WhoopConnectionState`, so a seventh case is a compile error**
    /// rather than a blank pair of lines on the screen. The `.disconnected` copy is the reference's
    /// own — *"Tap 'Pair a Device' … to continue."* — and it names the button because that is the only
    /// thing the reader can do from here.
    ///
    /// **Two arms say `on the ADVANCED tab` where the reference says `below`, and that is the pairing
    /// control's move rather than a rewording.** `PAIR A DEVICE` sits on STATUS in the reference and on
    /// ADVANCED here — the reference's own second tab's placement — so a sentence pointing *below* the
    /// caption would point at a `SYNC HISTORY` button and nothing else. The words name the tab because
    /// the tab is where the button is, and both arms still name the button, which is the half §14
    /// asserts.
    public nonisolated static func hero(for state: WhoopConnectionState) -> Hero {
        switch state {
        case .disconnected:
            return Hero(
                lead: "NOT CONNECTED TO",
                stateWord: "WHOOP DISCONNECTED",
                sentence: "Tap 'Pair a Device' on the ADVANCED tab to continue.")
        case .scanning:
            return Hero(
                lead: "NOT CONNECTED TO",
                stateWord: "SEARCHING FOR WHOOP",
                sentence: "Keep the strap nearby and awake. A scan links to the first strap this app hears.")
        case .connecting:
            return Hero(
                lead: "NOT CONNECTED TO",
                stateWord: "CONNECTING TO WHOOP",
                sentence: "Linking to the strap. This takes a few seconds.")
        case .connected:
            return Hero(
                lead: "CONNECTED TO",
                stateWord: "WHOOP CONNECTED",
                sentence: "The strap is linked. Sync history to pull in anything it recorded while this app was closed.")
        case .syncing:
            return Hero(
                lead: "CONNECTED TO",
                stateWord: "SYNCING HISTORY",
                sentence: "Draining what the strap banked in flash. Leave the app open until it reports complete.")
        case .error:
            return Hero(
                lead: "NOT CONNECTED TO",
                stateWord: "WHOOP ERROR",
                sentence: "The link dropped unexpectedly. Tap 'Pair a Device' on the ADVANCED tab to try again.")
        }
    }

    /// The battery figure, gated on the strap being *connected* rather than merely discovered.
    ///
    /// `WhoopDevice.batteryPercentage` is **not optional and defaults to `100`**, and
    /// `WhoopBLEManager` writes that same literal at discovery — so a percentage read off a strap that
    /// is not connected is a constant this app wrote down, not a measurement it took. The gate itself
    /// is `WhoopDevice.batteryReading`, which is where the rule is defined once and where its refusal
    /// of `.syncing` is argued; it is a static over a bare `WhoopDevice` so it can be asserted with no
    /// view model and no dependency behind it. The readout the old Settings page printed instead was
    /// `device?.batteryPercentage ?? 0`, which read a fabricated `0%` for an absent strap and a
    /// fabricated `100%` for one merely discovered.
    ///
    /// **Nothing draws this any more, and it is kept rather than deleted.** The user's own instruction
    /// took the `Strap` section — the `CONNECTION` and `BATTERY` rows — off the STATUS tab, so the
    /// dash-drawing half of the gate left the screen. What remains of the rule is `batteryReading`,
    /// which Home's badge still reads, and this function is its only `dash`-drawing reader — the
    /// `ActivityDurationBar` precedent, recorded in `CLAUDE.md`: a suite with no test discovery cannot
    /// tell a deleted assertion from a passing one, so deleting this would drop five passing assertions
    /// whose only trace is a falling `assertions=` count. Its assertions are also the clearest statement
    /// of the gate in the repo — the same `WhoopDevice` reporting `batteryPercentage == 100` *and*
    /// `batteryText == "—"`, side by side — so the constant and the gate stay legible together.
    /// **If the row comes back, this is what it draws.** See `docs/ARCHITECTURE.md` §2.C.
    public nonisolated static func batteryText(for device: WhoopDevice?) -> String {
        device?.batteryReading ?? ActivityFigure.dash
    }

    /// The instant the strap last delivered something, or the dash.
    ///
    /// **The mockup's `08/22` is deliberately not reproduced.** A literal `MM/dd` is a US-only format,
    /// and this repo already carries `formattedShortDate()` and `formattedHourMinute()` with a stated
    /// stance against formats that only hold in one locale — so the figure is composed from those two
    /// and reads `Fri, Aug 22 · 5:39 PM` on this machine and something else, correctly, on another.
    public nonisolated static func lastSyncText(_ instant: Date?) -> String {
        guard let instant else { return ActivityFigure.dash }
        return "\(instant.formattedShortDate()) · \(instant.formattedHourMinute())"
    }

    /// The facts the ADVANCED tab draws as one row of marks.
    ///
    /// A `CaseIterable` enum rather than three literals in a `body`, following `Tab` above and
    /// `ActivityMenu.Entry` / `DeviceFact`'s siblings across the app: **the runner has no renderer**, so
    /// the labels' words and their order are the drawing and nothing else can check them.
    ///
    /// **The row carries three where the reference carries two, and `SIGNAL` is the third.** The
    /// reference's two are a device identifier and a firmware version; firmware has no producer in this
    /// app at all (see [`factValue`]) and the identifier only appears once a strap is discovered, so a
    /// row built to the reference's two would be two dashes on a fresh install with the app's one live
    /// diagnostic deleted from the page it belongs on. `SIGNAL` is that diagnostic — a real reading off
    /// the advertisement — so it stays, and it is a one-line deletion if the reference is preferred.
    ///
    /// **`FRAMEWORK`, `SERIAL` and the rest of the reference's rows are absent rather than dashed
    /// here**, which is a different thing from how they would be drawn: adding a case for a figure with
    /// no producer would put a fourth permanent `—` in a row that already has one.
    public enum DeviceFact: String, CaseIterable, Identifiable, Sendable {
        case deviceId = "DEVICE ID"
        case firmware = "FIRMWARE"
        case signal = "SIGNAL"

        public var id: String { rawValue }

        /// The word drawn under the mark.
        public var label: String { rawValue }

        /// The mark drawn above it.
        ///
        /// `DEVICE ID` reuses `StrapMark.symbol` rather than naming `capsule.portrait` a second time, so
        /// the app keeps one definition of the strap's mark — the same rule that has `StrapGlyph` shared
        /// between Home's badge and this page.
        ///
        /// **A wrong symbol name is not an error**: it draws an empty chip, invisible to the compiler and
        /// to any screenshot of a different row, which is why §14 asserts every arm non-empty. Neither of
        /// the two new names is a deployment-target risk — `memorychip` and
        /// `antenna.radiowaves.left.and.right` are both iOS 13, and this app targets 17.0 — unlike the
        /// `figure.*` family `CLAUDE.md` warns about.
        public var symbol: String {
            switch self {
            case .deviceId: return StrapMark.symbol
            case .firmware: return "memorychip"
            case .signal: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    /// A strap this app can actually name, or `nil`.
    ///
    /// **The empty identifier is the whole test, and it is not a formality.** `WhoopBLEManager`'s
    /// `startScanning` builds `WhoopDevice(id: "", name: "Scanning...", connectionState: .scanning)` and
    /// omits every argument it can — so that object carries the entity's **defaulted
    /// `signalStrengthRssi` of `-65`**, and printing it would put a confidently plausible
    /// `-65 dBm` on screen for a strap that has not been found yet. It is the only object in the app
    /// that holds that default: `resolvedDevice` passes `fallback?.signalStrengthRssi` *explicitly*, so
    /// a device built without a fallback gets `nil` rather than the default, and a discovered one gets
    /// the advertisement's real RSSI. Gating on the identifier is therefore what keeps the default off
    /// the screen, and it is one gate for both facts that need it rather than two copies of the test.
    private nonisolated static func named(_ device: WhoopDevice?) -> WhoopDevice? {
        guard let device, !device.id.isEmpty else { return nil }
        return device
    }

    /// What one fact reads for a device — the row's own `batteryText(for:)`.
    ///
    /// A static over a bare `WhoopDevice` so §14 can assert all three arms with no view model and no
    /// dependency behind it, which is the shape `batteryText(for:)` and `lastSyncText(_:)` already take.
    public nonisolated static func factValue(_ fact: DeviceFact, device: WhoopDevice?) -> String {
        switch fact {
        case .deviceId:
            // The CoreBluetooth peripheral identifier: written at discovery, and the key the model
            // choice is stored against, so it names the strap rather than describing it.
            return named(device)?.id ?? ActivityFigure.dash
        case .firmware:
            // **Always the dash, on every device, connected or not.** `WhoopDevice.firmwareVersion` is
            // `String?` defaulted to the constant `"41.14.2.0"`, and `resolvedDevice` only ever
            // propagates it — so the field holds that literal on a real strap and returning it would
            // print a number this app wrote down. Reading nothing is the honest answer, and it is
            // informative rather than apologetic because the clock-set payload is firmware-specific.
            return ActivityFigure.dash
        case .signal:
            guard let rssi = named(device)?.signalStrengthRssi else { return ActivityFigure.dash }
            return "\(rssi) dBm"
        }
    }

    /// What the state word is drawn in.
    ///
    /// A three-way split, and the reason it is not two is that the colour is the state: a page that
    /// drew `WHOOP ERROR` in green would be contradicting its own words, and a page that drew a strap
    /// it is still hunting for in red would be calling it absent. `nil` — no strap object at all —
    /// reads as disconnected, which is what it is.
    ///
    /// **The comment here used to claim this was "the same three-way split
    /// `HomeDashboardView.connectionColor` makes", and no such property exists.** Home's badge is a dot
    /// on a strap glyph and it answers a two-way question — `WhoopConnectionState.linkColor`, which is
    /// right for a 7 pt dot and wrong for a title, since it paints `.scanning` and `.connecting` red.
    /// The two are deliberately different rules over the same state and neither should be described as
    /// the other.
    private var stateInk: Color {
        switch viewModel.device?.connectionState {
        case .connected: return Theme.recoveryGreen
        case .scanning, .connecting, .syncing: return Theme.recoveryYellow
        case .disconnected, .error, nil: return Theme.textPrimary
        }
    }

    private var hero: Hero {
        Self.hero(for: viewModel.device?.connectionState ?? .disconnected)
    }

    // MARK: - Body

    public var body: some View {
        Form {
            headerSection
            tabSection
            if tab == .status {
                statusSections
            } else {
                advancedSections
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .navigationTitle("Device Settings")
        .inlineNavigationTitle()
        .task { await viewModel.load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    /// The relation on the left, the last sync on the right.
    ///
    /// **Two columns rather than a stacked block, which is the reference's arrangement.** The pair on
    /// the left is the sentence's subject (`NOT CONNECTED TO` / `WHOOP DEVICE`); the pair on the right
    /// is when the strap last reached this app. They are set at different weights and on opposite
    /// alignments because they answer different kinds of question — *what is this page about* and *how
    /// stale is it* — and the reference's own visual argument is that the second one is a status, not a
    /// subtitle.
    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hero.lead)
                        .font(.caption2.weight(.semibold))
                        .tracking(0.9)
                        .foregroundStyle(Theme.textMuted)
                    Text(Self.subject)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                lastSyncBlock
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
            .accessibilityElement(children: .combine)
        }
    }

    /// When the strap last delivered anything, and a mark when it never has.
    ///
    /// **The mark is drawn only on the `nil` branch**, which is where it means something: it is the
    /// reference's red cloud-X mapped onto a condition this app can actually see — *nothing has ever
    /// arrived from the strap*. On a strap that has synced there is no mark, because there is nothing
    /// to warn about. `arrow.down.circle.dotted` is the honest glyph for it: data that has not come
    /// down yet, rather than a cloud failure this app has no network to have.
    ///
    /// **The figure turns red with the mark, and the label does not.** The mark is the signal and one
    /// red word beside it is the reading it belongs to; painting `LAST SYNC` red as well would make the
    /// label a claim rather than a caption, and the label is true on every strap.
    private var lastSyncBlock: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("LAST SYNC")
                .font(.caption2.weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: 6) {
                if viewModel.lastSync == nil {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.recoveryRed)
                }
                Text(Self.lastSyncText(viewModel.lastSync))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(viewModel.lastSync == nil ? Theme.recoveryRed : Theme.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Last sync \(Self.lastSyncText(viewModel.lastSync))"))
    }

    // MARK: - Tabs

    /// The two tabs, underlined rather than segmented.
    ///
    /// **This replaced the app's first segmented `Picker`, and the reference is why.** A segmented
    /// control draws a filled trough that claims a slot in the layout; the reference's tabs are two
    /// words on the page's own background with a rule under the selected one, which is a lighter
    /// thing — and it is the whole reason the state block below them can sit directly on the page
    /// instead of inside another card. The model `Picker` further down is untouched and still the
    /// platform's styling, for its own stated reason: three options in a `Form` row is what that
    /// control is for.
    ///
    /// **The rule is drawn on both tabs and filled on one**, so the row's height does not change by a
    /// pixel when the selection moves — a cleared rectangle and a coloured one are the same height,
    /// and a conditional `Rectangle` would make the whole block jump on every tap.
    private var tabSection: some View {
        Section {
            HStack(spacing: 24) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 7) {
                            Text(item.title)
                                .font(.footnote.weight(.bold))
                                .tracking(0.9)
                                .foregroundStyle(tab == item ? Theme.textPrimary : Theme.textMuted)
                            Rectangle()
                                .fill(tab == item ? Theme.textPrimary : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
        }
    }

    // MARK: - STATUS

    /// The state, then the two things that can be done about it.
    ///
    /// **The `Strap` section is gone, at the user's instruction** — *"from device settings page under
    /// status tab, remove 'Strap' area with connection and battery items"*. What it held was a
    /// `CONNECTION` row repeating `WHOOP DISCONNECTED` from the caption directly above it, and a
    /// `BATTERY` row whose figure this app only has while the strap is linked. Neither is a loss of
    /// reachable information: the state is on the caption in larger type, and the battery gate survives
    /// as `batteryText(for:)` and is still what Home's badge reads.
    ///
    /// **`PAIR A DEVICE` moved to ADVANCED rather than being deleted**, which is the reference's own
    /// placement for it, and it moved rather than being copied — there is one definition of that control
    /// and one place the reader can find it.
    @ViewBuilder
    private var statusSections: some View {
        captionSection

        Section {
            Button {
                Task { await viewModel.syncNow() }
            } label: {
                Text("SYNC HISTORY")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(viewModel.isConnected ? Theme.actionTint : Theme.textMuted)
            }
            .disabled(!viewModel.isConnected)
        } footer: {
            Text("Syncing needs a connected strap. It drains what the strap banked in flash, so it is the one action here that can take a while.")
        }

        if !viewModel.status.isEmpty {
            Section {
                Text(viewModel.status)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// The strap, a dashed line to where it leads, and the state in words.
    ///
    /// **This block sits below the tabs and not in the header, which is the reference's arrangement.**
    /// Its first line — `WHOOP DISCONNECTED` — is the state, and the header above already says the
    /// relation the state is about; putting both up there said one fact twice. Down here the mark is
    /// what the state is *of*, so the sentence reads as a caption on the drawing rather than as a third
    /// heading.
    ///
    /// It is **hidden from VoiceOver**, because it says nothing the state word beneath it does not say
    /// in words — the mark is a picture of the sentence directly below it.
    private var captionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                connector
                VStack(alignment: .leading, spacing: 4) {
                    Text(hero.stateWord)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(stateInk)
                    Text(hero.sentence)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
        }
    }

    /// The strap's mark, a dashed line, and the link's mark.
    ///
    /// **The left mark is `StrapGlyph` badged with a plus** — the capsule Home's badge draws, which is
    /// the user's own specification, replacing the `sensor.tag.radiowaves.forward.fill` this row used
    /// to draw. The plus is what the button below is *for*: this end of the dashed line is the thing
    /// that gets paired, and it says so before the reader reaches the button. `Theme.backgroundDark` is
    /// the ring's colour because it is what the mark is drawn on — the row is clear over the page's own
    /// background, so a ring in the card colour would draw a dark halo.
    private var connector: some View {
        HStack(spacing: 10) {
            StrapGlyph(size: 22, surface: Theme.backgroundDark) {
                StrapBadge(sign: "plus", surface: Theme.backgroundDark)
            }
            DashedConnector()
                .stroke(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
            Image(systemName: viewModel.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(viewModel.isConnected ? Theme.recoveryGreen : Theme.textMuted)
        }
        .accessibilityHidden(true)
    }

    /// The strap's own card, led by the strap's own mark.
    ///
    /// **It is a card rather than a `Form` row, which is the reference's own weight.** The reference
    /// gives this control the whole width and a raised surface, and the reason is that on this page it is
    /// genuinely the thing to do — every other row reads a state. `glassCard` is the app's one card
    /// treatment, so this reuses it rather than introducing a surface of its own; `Theme.actionTint`
    /// would have made it a link rather than a panel, and it is documented as the tint of a *menu row*.
    ///
    /// **The mark is `StrapGlyph` badged with a plus, and this replaces `dot.radiowaves.left.and.right`
    /// on the reference's own authority.** The comment here used to argue the opposite — *"the capsule
    /// above already means the strap; a second capsule here would say this button is a strap"* — and that
    /// reasoning was about the two marks sharing one screen. They no longer do: `PAIR A DEVICE` sits on
    /// ADVANCED now and the connector sits on STATUS, so the button has to say *strap* on its own rather
    /// than borrow the row above it. The plus is the reference's own vocabulary for the pairing control,
    /// and it is the same badged capsule the connector draws, so the two say one thing one way.
    ///
    /// **It is disabled while a scan is running and its words say so**, because a second press would
    /// otherwise start a second scan against a strap the first one is already linking to.
    private var pairSection: some View {
        Section {
            Button {
                Task { await viewModel.scan() }
            } label: {
                HStack(spacing: 10) {
                    StrapGlyph(size: 20, surface: Theme.cardBackground) {
                        StrapBadge(sign: "plus", surface: Theme.cardBackground)
                    }
                    Text(viewModel.isScanning ? "SCANNING…" : "PAIR A DEVICE")
                        .font(.subheadline.weight(.bold))
                        .tracking(0.7)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textPrimary)
                .opacity(viewModel.isScanning ? 0.55 : 1)
                .frame(maxWidth: .infinity)
                .glassCard(cornerRadius: 14, padding: 16)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isScanning)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        } footer: {
            // **The control says what pairing means here**, because it is not the usual thing. There is
            // no discovery list to choose from: `WhoopBLEManager.didDiscover` connects to the first
            // matching peripheral immediately, so a scan *is* the pairing rather than a step before it.
            //
            // The second sentence is the reference's *"This will replace any existing WHOOP pairings"*
            // restated as the fact this app can support: this app links to one strap at a time, so
            // pairing another does replace the current link — but it does so by connecting, not by
            // removing anything from a list, because there is no list. The reference's sentence is about
            // an account this app does not have.
            Text("Pairing scans for a nearby strap and links to the first one it hears. There is no list to choose from, and the app links to one strap at a time — pairing another replaces the current link.")
        }
    }

    /// Drops the Bluetooth link, and says plainly that it is not a forget.
    ///
    /// **The reference's caption promises a removal this app cannot perform, so the caption here states
    /// what the button does instead.** There is no forget path anywhere in this codebase:
    /// `WhoopBLEManager.didDiscover` links to the first matching peripheral and the stored model choice
    /// is keyed on the peripheral identifier, which nothing clears — so the very next scan re-links to
    /// the same strap. *"This will remove the Bluetooth connection"* is true of the link and would read
    /// as true of the pairing, which is the half a reader would take away.
    ///
    /// **It is dimmed and disabled exactly when there is no link**, which is both the honest gate and the
    /// reference's own drawing: the reference's screen is in the not-connected state and its unpair card
    /// is drawn greyed for that reason. `isConnected` is the gate rather than `hasDevice`, because a
    /// strap this app has discovered but not linked to has no connection to drop — `didDisconnect`
    /// leaves the device object in place with its identifier intact, so `hasDevice` stays true across
    /// exactly the state this button does nothing in.
    private var unpairSection: some View {
        Section {
            Button {
                Task { await viewModel.unpair() }
            } label: {
                HStack(spacing: 10) {
                    StrapGlyph(size: 20, surface: Theme.cardBackground) {
                        StrapBadge(sign: "minus", surface: Theme.cardBackground)
                    }
                    Text("UNPAIR DEVICE")
                        .font(.subheadline.weight(.bold))
                        .tracking(0.7)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textPrimary)
                .opacity(viewModel.isConnected ? 1 : 0.55)
                .frame(maxWidth: .infinity)
                .glassCard(cornerRadius: 14, padding: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isConnected)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        } footer: {
            Text("Unpairing drops the Bluetooth link to this strap. Nothing is forgotten — the next scan links to it again, and the model you chose for it is kept.")
        }
    }

    // MARK: - ADVANCED

    /// The strap's facts, then what can be done with the strap, then this app's own settings for it.
    ///
    /// **The order is the reference's**: its row of labelled marks sits directly under the tabs, and its
    /// two full-width cards follow. The pairing pair leads the cards because those two are about the
    /// hardware and everything below them is about this app's opinion of the hardware.
    ///
    /// **`DIAGNOSTICS` is now `deviceFactsSection`, and the row replaced the section rather than joining
    /// it.** Both drew `FIRMWARE` and `SIGNAL`, and two renderings of one reading on one screen is the
    /// drift `DeviceFact` exists to prevent — so the labelled rows went and the marks are what is left.
    /// `SERIAL` went with them: it was a third permanent dash in a section that already had two, and the
    /// reference's row has no serial in it.
    @ViewBuilder
    private var advancedSections: some View {
        deviceFactsSection

        pairSection
        unpairSection

        modelSection
        protocolSection

        Section {
            Toggle("BROADCAST LIVE HR", isOn: Binding(
                get: { viewModel.preferences.liveHeartRateBroadcastEnabled },
                set: { value in Task { await viewModel.setBroadcast(value) } }))
        } footer: {
            Text("Preference is stored locally. Broadcasting requires a supported strap transport.")
        }
    }

    /// The strap's own facts as one row of marks, which is the reference's shape.
    ///
    /// Three columns rather than a `Section` of `LabeledContent` rows, and each column is a mark, a word
    /// and a figure stacked and centred — the reference draws an *item* per fact rather than a row, so
    /// the label sits under the glyph instead of beside it.
    ///
    /// **A dash is drawn in the muted ink and a reading in the primary one**, which is the one place this
    /// row does something the reference does not: on a fresh install two of the three are dashes, and a
    /// `—` in the same white as a real figure reads as a value at a glance. It is the same distinction
    /// `ActivityFigure` draws between an absent figure and a measured zero, made in type colour rather
    /// than in glyphs.
    private var deviceFactsSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                ForEach(DeviceFact.allCases) { fact in
                    factColumn(fact)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 14, trailing: 16))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Firmware comes from the strap's Device Information Service, which this app does not read yet — so it is a dash rather than the defaulted constant the entity carries. That is not a cosmetic gap: the clock-set payload is firmware-specific, and a wrong-length set is accepted but never latched.")
                Text("Signal is the advertisement's RSSI as read when the strap was found. Nothing refreshes it while connected, so it describes discovery rather than the link's quality now.")
            }
        }
    }

    /// One fact: its mark, its word, and what it reads.
    ///
    /// The value is truncated in the **middle** rather than the tail, because `DEVICE ID` is a 36-
    /// character UUID in a column a third of the screen wide: a head-truncation and a tail-truncation of
    /// one UUID are the same eight characters either way, so the two ends are what distinguishes it from
    /// another strap's. The whole value is spoken regardless, through the accessibility label.
    private func factColumn(_ fact: DeviceFact) -> some View {
        let value = Self.factValue(fact, device: viewModel.device)
        return VStack(spacing: 6) {
            Image(systemName: fact.symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
            Text(fact.label)
                .font(.caption2.weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)
                .foregroundStyle(value == ActivityFigure.dash ? Theme.textMuted : Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(fact.label) \(value)"))
    }

    /// Which model the user says this strap is.
    ///
    /// Moved here unchanged from `DeviceDetailView`, which this page replaced — including the reason
    /// the picker is left unstyled: a `Form` row that pushes a list is the idiom on iOS, a pop-up
    /// button is the idiom on macOS, and this screen is built for both.
    private var modelSection: some View {
        Section {
            Picker("Model", selection: Binding(
                get: { viewModel.model },
                set: { viewModel.choose($0) }
            )) {
                ForEach(WhoopHardwareGeneration.selectableModels) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .disabled(!viewModel.hasDevice)
        } header: {
            Text("Model")
        } footer: {
            if viewModel.isModelSaved {
                Text("Saved for this strap. The choice is remembered per device and decides which protocol this app speaks to it.")
            } else {
                Text("Not chosen yet — this is inferred from the name the strap advertises, which cannot tell a 5.0 from a 5.0 MG. Confirm it above.")
            }
        }
    }

    /// Whether this build can frame commands for that model, and the honest caveat if it cannot.
    ///
    /// Moved here from `DeviceDetailView` so the words stay on one screen. This is also where the
    /// reference's ⓘ button's content ended up: the caveat is drawn, not hidden behind a second tap.
    private var protocolSection: some View {
        Section("Sync") {
            if viewModel.supportsSync {
                Label("Protocol implemented", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.recoveryGreen)
                // The envelope named here is the selected model's own, because there are two of them
                // and the sentence used to name the 4.0 unconditionally. A 5.0 framed with the 4.0's
                // envelope is not a message that strap rejects — it is a different one.
                Text("Commands are framed with the WHOOP \(viewModel.protocolEnvelopeName) envelope recorded in docs/BLE_PROTOCOL.md.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                // Said plainly rather than left to the docs: the envelopes match independent
                // reverse-engineering references and their checksums are pinned by published vectors,
                // but no frame this app builds has ever been seen by a strap. The 5.0's sentence is a
                // different one — see `DeviceViewModel.protocolCaveat`.
                Text(viewModel.protocolCaveat)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            } else {
                Label("No proprietary protocol", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.recoveryYellow)
                Text("This model has no WHOOP packet envelope, so nothing is framed for it and only the standard heart-rate service is read.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

}

// MARK: - Platform

/// The disc that badges the strap's mark, carrying the sign for what can be done with it.
///
/// **One definition for three readers** — the STATUS tab's connector, `PAIR A DEVICE` and
/// `UNPAIR DEVICE` — so the three cannot come to draw the pairing sign at three sizes. The sign and the
/// surface are the parameters and the geometry is not: every caller draws one disc at one size, because
/// the three marks are one idea (*this is the strap, and here is what can be done about it*) at two
/// scales, and a per-caller size is where they would drift apart.
///
/// It is a **non-generic** type with its own `static let`s for `StrapGlyph`'s reason in reverse: a
/// generic type cannot hold a static stored property, so the sizes live here rather than on `StrapMark`,
/// which holds only what the two *screens* share. The disc's size is this page's, not Home's.
///
/// **The badge is placed by the alignment alone and carries no `offset`** — that is `StrapGlyph`'s own
/// contract, stated there: a ring is drawn around the mark and the badge is hung on its corner, so an
/// offset would push it off the ring on one glyph size and onto the mark's own drawing on another.
private struct StrapBadge: View {
    let sign: String
    let surface: Color

    private static let discSize: CGFloat = 13
    private static let signSize: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.textPrimary)
                .frame(width: Self.discSize, height: Self.discSize)
            Image(systemName: sign)
                .font(.system(size: Self.signSize, weight: .bold))
                .foregroundStyle(surface)
        }
    }
}

/// The dashed line joining the strap's mark to the state's mark.
///
/// A `Shape` rather than a `Divider` with an overlay, because a stroke dash is a drawing decision and
/// this is the smallest type that can hold one. It stretches to whatever width the row gives it, which
/// is what makes the connector read as a link rather than as a rule.
private struct DashedConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
