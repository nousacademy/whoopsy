import SwiftUI

/// The profile page: three tabbed panes over the app's own record of the person using it.
///
/// **It is a `Form`, like `SettingsDashboardView` beside it, and not one of the app's dark card
/// screens.** That is a decision about what kind of page this is: a card screen in this app draws
/// readings, and `BIOMETRICS` has none — every field there is an input, and the platform's own `Form`
/// styling is what makes a field look editable rather than like a figure the app measured. The
/// alternative was a hand-built card whose `TextField`s would have had to be styled back into looking
/// like controls.
///
/// ## It was one pane with three fields, and the rule that changed is on `ProfileViewModel`
///
/// The page used to be a single section of weight and two heart rates, and its doc comment argued that
/// the reference's other rows were **left off deliberately** under the no-control-without-a-destination
/// rule. That rule was mis-stated: the rule this app actually holds is *do not let the app invent a
/// number and report it back as the user's*, and a height the user types is the opposite of an invented
/// one — the user is the sensor. `v20` deleted the three defaults (`"Athlete"`, `178.0 cm`, and a birth
/// date relative to `now`) and this page collects those four facts instead. The full argument, and the
/// honest cost — **all four feed no model** — is in `ProfileViewModel`'s header.
///
/// ## The tabs are an enum, and the copy is a `nonisolated static`
///
/// For this repo's standing reason: the runner has no renderer, so a decision written into a `body` is
/// a decision nothing can assert. `Tab.allCases.map(\.title)` is the row's order and the row's words,
/// and the `storage*` constants beside it are the whole of the third pane. Both are asserted in §18,
/// and the sync pane's own behaviour in §22.
///
/// ## `LOGS` is `LocalDataViewModel`'s and `BIOMETRICS` is `ProfileViewModel`'s, and they are two
///
/// They were one type once, on `More → Settings`. See `LocalDataViewModel` for why the move off that
/// page was a rename-with-shrink rather than one instance drawn twice: a shared one would give the two
/// panes one `status` string and one `isImporting` flag, so an import on `LOGS` could rewrite the
/// sentence a save on `BIOMETRICS` had just written.
///
/// **`STORAGE` is a third, `SyncStorageViewModel`, and it is now the pane the rename was pointing at.**
/// It was a placeholder holding one sentence the title no longer named — see the history on the
/// `storage*` constants below for why that disagreement was left standing rather than repaired, and
/// what replaced it.
public struct ProfileDashboardView: View {
    @State private var viewModel: ProfileViewModel
    @State private var localDataViewModel: LocalDataViewModel
    @State private var syncViewModel: SyncStorageViewModel
    @State private var tab: Tab = .biometrics

    /// The `BIRTHDAY` control's in-progress value, and the reason the row has three states rather than
    /// two. See `birthdayRow`.
    @State private var draftBirthday: Date?

    /// The `SYNC FROM` control's in-progress value, and it is `draftBirthday`'s state for
    /// `draftBirthday`'s reason — see `spanRow`, and `birthdayRow` for the argument in full. The
    /// picker's opening position is a *control's* position; it does not become the user's span until
    /// both ends are set, and until then nothing is sent anywhere.
    @State private var draftRangeFrom: Date?

    /// The `SYNC TO` control's, for `draftRangeFrom`'s reason. **Two drafts rather than one**, because
    /// the engine stores both ends or neither: tapping one picker leaves that end on screen and written
    /// nowhere, so a single draft would have to hold half a span and lose which half it was.
    @State private var draftRangeTo: Date?

    public init(
        viewModel: ProfileViewModel,
        localDataViewModel: LocalDataViewModel,
        syncViewModel: SyncStorageViewModel
    ) {
        _viewModel = State(initialValue: viewModel)
        _localDataViewModel = State(initialValue: localDataViewModel)
        _syncViewModel = State(initialValue: syncViewModel)
    }

    // MARK: - Values the runner can assert

    /// The three panes, in the order they are drawn.
    ///
    /// A nested `enum` rather than an index or three `Bool`s, on `DeviceSettingsView.Tab`'s rule: the
    /// titles and their order **are** the drawing, and a reorder is invisible in a screenshot of the
    /// first tab — which is the one a screenshot would be taken of.
    ///
    /// **All three labels were renamed on the user's instruction** — *"rename "Body" tab to
    /// "Biometrics", rename "Data" tab to "Logs", rename [the third] tab to "Storage""* — and the case
    /// names moved with them. That is deliberate rather than tidy: the `rawValue` **is** the title, so
    /// a case still called `data` drawing `LOGS` would be a second spelling of one pane, which is the
    /// drift this enum exists to prevent.
    ///
    /// **The titles are stored in the case they are drawn in.** `UnderlinedTabRow` draws each `title`
    /// through a plain `Text` with no `.textCase`, so a sentence-case literal would draw sentence case
    /// and the three would stop matching — the rule `WhoopImportAction`'s titles are held to for the
    /// same reason.
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case biometrics = "BIOMETRICS"
        case logs = "LOGS"
        case storage = "STORAGE"

        public var id: String { rawValue }
        public var title: String { rawValue }
    }

    // MARK: - What the third pane says

    /// ## `STORAGE` was a placeholder, and these constants are what replaced it
    ///
    /// The pane was one placeholder sentence, left under a title that no longer named it when the three
    /// labels were renamed. That disagreement was recorded rather than repaired, because the instruction
    /// named three labels and no content and rewording it would have been inventing copy under the guise
    /// of a rename. **It was ended by the feature rather than by a rewording**: the pane is where this
    /// phone's own SQLite file meets the database behind it, which is what the word `STORAGE` was always
    /// pointing at, and the placeholder went with the code it described — that code is now deleted, so
    /// nothing on this page could reach it even by accident.
    ///
    /// **Six members of this family went with the cutoff and the copy policy**, and the count is worth
    /// recording because each was a sentence about a control that no longer exists: the boundary's
    /// eyebrow and note, the policy's eyebrow and note, and the resource selector's eyebrow and note.
    /// What replaced them is one destination under `storageDestinationEyebrow` and one span under the
    /// two `storageRange*` eyebrows — the pane's two controls where it used to have three.
    ///
    /// Every string below is a `nonisolated static` rather than a literal in the `body`, for this page's
    /// standing reason — the runner has no renderer, so copy written into a `body` is copy nothing can
    /// assert. §18 pins them; the state machine that chooses between the two span sentences and the two
    /// destination notes is §22's.

    /// The key row's name, above the credential itself.
    public nonisolated static let storageKeyEyebrow = "SYNC KEY"

    /// The `COPY` control beside the key. It is a `ShareLink` and not a pasteboard write — see
    /// `keyRow` — and the word is the mockup's.
    public nonisolated static let storageCopyTitle = "COPY"

    /// What the key is, and the one thing about it a reader has to know before trusting it.
    ///
    /// **It says what the key is *for* and what its loss costs**, and it does not say the key is secret,
    /// because it is not the kind of secret a user can be told to guard: it is a bearer credential the
    /// server hashes and never stores, so the only thing a reader can act on is that this string *is*
    /// the whole of their access to those days. See `SyncKeyStore` for the mechanism, and
    /// `WhoopsyAPIClient.userIDHeader` for why the endpoint verifies nothing.
    public nonisolated static let storageKeyNote = """
        Your days in the database are filed under this key and nothing else. It is the only way to \
        reach them if this phone is lost — there is no account to recover, and nothing on the other \
        end can look them up for you.
        """

    /// Where new data goes, and the word `STORE` is chosen over `SYNC` on purpose.
    ///
    /// **The control is a switch and not a mode, and the eyebrow is where that is said first.** A row
    /// reading `WHOOPSY SYNC API` under a heading about storage reads like *move my history there*,
    /// which is the one thing pressing it does not do: the user's own instruction is *"if a DB is
    /// selected, it doesnt purge anything, it just switches where data will be stored to"*, so the
    /// question the row asks is about the future and its note says so in as many words.
    public nonisolated static let storageDestinationEyebrow = "STORE NEW DATA IN"

    /// What each destination does, in terms of where a day ends up rather than what the code does.
    ///
    /// **Both arms promise the same thing about deletion, and stating it twice is the point.** The one
    /// fear this control has to answer is *if I pick the database, do I lose what is on my phone*, and a
    /// reader who only ever selects `.device` would never see the answer. So the reassurance is in both
    /// sentences rather than in the one that needs it — and the `.cloud` arm says plainly that switching
    /// back moves nothing, because *moving back* is the action a reader would assume exists and no such
    /// button is on this pane or anywhere else.
    public nonisolated static func storageDestinationNote(
        for destination: SyncSettings.Destination
    ) -> String {
        switch destination {
        case .device:
            return "New days, sleeps, sessions and entries are written to this phone and stay on it. "
                + "Nothing is sent anywhere, and nothing already in the database is removed."
        case .cloud:
            return "New data is written to this phone and sent to the database as well. Nothing is "
                + "deleted from either side — choosing this does not move your history off the phone, "
                + "and choosing DEVICE STORAGE again does not move anything back."
        }
    }

    /// The span's two ends, which are two rows because they are two controls.
    ///
    /// **`FROM` is the name the control would have in any date-range UI and `TO` is its pair**, so the
    /// pair needs no explanatory sentence of its own the way the old single-boundary control did: the
    /// reader who has set a range before knows what these two do, and the note below says what happens
    /// to the days between them.
    public nonisolated static let storageRangeFromEyebrow = "SYNC FROM"
    public nonisolated static let storageRangeToEyebrow = "SYNC TO"

    /// The two sentences under the span, and the state that has no days to speak about.
    ///
    /// **Two states rather than one, because the printed sentence has to be true both times.** With a
    /// span set, *the days between these two go to the database* is a statement about something the
    /// reader has asked for; with none set it would be a statement about a range that does not exist,
    /// over two controls whose whole purpose is to create one. The empty state therefore describes the
    /// *action* rather than the standing fact — and it is not the app's usual absence, because the span
    /// rows are present in both states on purpose: they **are** the on-switch, and withholding them
    /// would be withholding the feature.
    ///
    /// **Neither arm claims the span is the only thing that ever goes**, which the old boundary's note
    /// could not avoid getting wrong: under `.cloud` a newly written day is sent as it is written, so a
    /// sentence reading *only these days are sent* would be false on the second day of use. The `.from`
    /// arm is about the run the button under it would start, and the destination's own note above is
    /// where the standing fact lives.
    public nonisolated static func storageRangeNote(isEnabled: Bool) -> String {
        isEnabled
            ? "SYNC sends the days between these two to the database. Nothing on this phone is "
                + "deleted, and days outside the span are not sent."
            : "Nothing is being sent anywhere. Set both ends and SYNC sends the days between them to "
                + "the database — nothing on this phone is deleted either way."
    }

    /// The list of what a run would carry, and it is drawn in both arms of the pane.
    ///
    /// **It is drawn even on a build with no database**, which is the one row that survives the pane's
    /// own `isCloudConfigured` branch: *what would move* is a fact about this app rather than about this
    /// build's configuration, and it is the answer a reader came to the pane for. The sentence above it
    /// is what changes, not the list.
    ///
    /// **The names come off `SyncedResource.allCases` rather than being typed here**, which is that
    /// enum's own rule and the reason its `allCases` order is `shared/openapi.json`'s: the list is a
    /// `ForEach` over the enum, so a resource added to it appears on the screen with no view edit, and
    /// the order is read off the contract rather than decided here.
    public nonisolated static let storageResourcesEyebrow = "SYNCED RESOURCES"

    /// What the list is, and the one thing about it a reader has to know.
    ///
    /// **`biometric samples` is named even though it is not in the list**, because its absence is the
    /// list's most misleading property: it is a resource the Worker carries, so a reader who has seen
    /// the database's own documentation would expect it here, and a list that simply omitted it would
    /// read as this app forgetting one. It is absent because a single day of it is up to 86,400 rows, so
    /// it stays on the phone by default and carries its own control — see `SyncedResource`.
    public nonisolated static let storageResourcesNote = """
        These are the records SYNC would carry. Biometric samples — the individual heart-rate and \
        R-R readings — are not among them: a single day of those is tens of thousands of rows, so they \
        stay on this phone.
        """

    /// What the pane says on a build with no database behind it.
    ///
    /// **A sentence naming the missing key, and no controls at all.** The pane could have drawn the
    /// cutoff control and a greyed button, and that would be worse than useless: every press would fail
    /// for a reason the screen had already been told, and the reader would be left to work out that the
    /// app was never configured. The key names the `Info.plist` entry rather than the URL, because the
    /// URL is build configuration and the entry is the thing a reader would set — see
    /// `WhoopsyAPIClient.baseURLInfoKey` and `UnconfiguredCloudSync`, which is the object that fails
    /// this build's requests and says the same sentence.
    public nonisolated static let storageNoDatabaseNotice = """
        This build has no database behind it, so there is nowhere for your days to go. \
        \(WhoopsyAPIClient.baseURLInfoKey) is not set in Info.plist. Until it is, every day stays on \
        this phone and nothing leaves it.
        """

    public var body: some View {
        Form {
            tabSection

            switch tab {
            case .biometrics: biometricsTab
            case .logs: logsTab
            case .storage: storageTab
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .navigationTitle("Profile")
        .inlineNavigationTitle()
        // `load()` is the page's, because `BIOMETRICS` is the pane it opens on. The other two panes are
        // loaded by the `task(id:)` below — see `LocalDataViewModel.load()` for why the HealthKit query
        // is narrowed to the tab rather than paid for by a reader who came to type their weight. `STORAGE`
        // is narrowed for a smaller reason on top of that one: its `load()` is cheap, but on a configured
        // build it **reads the Keychain, which mints and stores a key the first time** — so opening the
        // page would mint a credential for a reader who never looked at the pane. See
        // `SyncStorageViewModel.load()`.
        .task { await viewModel.load() }
        .task(id: tab) {
            switch tab {
            case .biometrics: return
            case .logs: await localDataViewModel.load()
            case .storage: await syncViewModel.load()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The tab row

    /// The three underlined text tabs, drawn by the shared component the device page also draws.
    ///
    /// **The row chrome is applied here and not inside `UnderlinedTabRow`**, which is that type's own
    /// documented split: `.listRowBackground` and `.listRowInsets` are trait-writing modifiers, and
    /// whether a trait written by a *nested* view reaches the `Form` row containing it is not something
    /// this repo can verify — a wrong answer draws a card rather than raising anything. So the insets
    /// are one definition on the component and two places it is attached, and this is the second.
    private var tabSection: some View {
        Section {
            UnderlinedTabRow(
                titles: Tab.allCases.map(\.title),
                selectedIndex: Tab.allCases.firstIndex(of: tab) ?? 0
            ) { index in
                tab = Tab.allCases[index]
            }
            .listRowBackground(Color.clear)
            .listRowInsets(UnderlinedTabRow.insets)
        }
    }

    // MARK: - BIOMETRICS

    /// The reference's rows in its order, then the two heart rates below them in their own section.
    ///
    /// **The heart rates stayed on this pane on the user's instruction**, so the reference's `SAVE`
    /// button is not the last row of the page — it is the last row of this pane, and that is a
    /// deliberate deviation from a picture that stops at `WEIGHT`. They are here rather than behind
    /// `LOGS` for the reason `ProfileViewModel`'s reader table gives: they are inputs to the zone table
    /// and to every calorie figure, which is to say they are facts about the body rather than about
    /// files.
    ///
    /// **The pane's first section header still reads `Body` while the tab above it reads `BIOMETRICS`**,
    /// and that is left alone rather than tidied: it is a `Form` section header in the platform's own
    /// sentence case and it names the *group* (`FIRST NAME`…`WEIGHT`) beneath the pane's title, the way
    /// `Heart rate` names the group below it. Renaming it would be inventing a word the instruction did
    /// not ask for.
    @ViewBuilder
    private var biometricsTab: some View {
        Section {
            field(
                title: "FIRST NAME",
                text: $viewModel.nameText,
                unit: nil,
                decimal: false,
                detail: nil)

            birthdayRow

            Picker("GENDER", selection: $viewModel.gender) {
                Text(ActivityFigure.dash).tag(UserProfile.Gender?.none)
                ForEach(UserProfile.Gender.allCases) { gender in
                    Text(gender.title).tag(UserProfile.Gender?.some(gender))
                }
            }

            unitsRow

            HStack(alignment: .top, spacing: 12) {
                field(
                    title: "HEIGHT",
                    text: $viewModel.heightText,
                    unit: viewModel.unit == .imperial ? "ft" : "cm",
                    decimal: viewModel.unit == .metric,
                    detail: nil)
                if viewModel.unit == .imperial {
                    field(
                        title: " ",
                        text: $viewModel.inchesText,
                        unit: "in",
                        decimal: true,
                        detail: nil)
                }
            }

            field(
                title: "WEIGHT",
                text: $viewModel.weightText,
                unit: viewModel.unit == .imperial ? "lb" : "kg",
                decimal: true,
                detail: nil)
        } header: {
            Text("Body")
        }

        Section {
            field(
                title: "MAX HEART RATE",
                text: $viewModel.maxHeartRateText,
                unit: "bpm",
                decimal: false,
                detail: "The ceiling of every heart-rate zone, and the numerator of the VO₂ max estimate — which is why that figure is labelled an estimate.")
            field(
                title: "RESTING HEART RATE",
                text: $viewModel.restingHeartRateText,
                unit: "bpm",
                decimal: false,
                detail: "The floor of every zone: the bands are percentages of the reserve between these two numbers.")
        } header: {
            Text("Heart rate")
        } footer: {
            Text("Zones are built from this pair, so they change when it changes. Days already recorded keep the figures they were scored with.")
        }

        Section { saveButton }

        if !viewModel.status.isEmpty {
            Section { Text(viewModel.status).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    /// The `BIRTHDAY` row, which has three states and needs all three.
    ///
    /// **A compact `DatePicker` has no "no value" state**, and that is the whole of the problem. The
    /// three ways out that were rejected are worth recording, because each looks reasonable:
    /// defaulting to `Date()` would draw *today* as the user's birthday until they corrected it, which
    /// is the fabrication `v20` deleted, and it would make them zero years old; defaulting to a fixed
    /// anchor like 1 Jan 1990 is the same invention with a different constant, and it is literally the
    /// `-28`-year default this column replaced; and a row that only ever toggles between a dash and a
    /// picker **leaves the field unclearable**, since nothing can put it back.
    ///
    /// So: `nil` and not yet being edited draws the app's own `—` as a button; tapping it opens the
    /// picker **on a draft, writing nothing**; and a chosen birthday draws the picker with a clear
    /// control beside it. The draft is what keeps the middle state honest — the picker's opening
    /// position is a control's position, like a slider's, and it does not become the user's birthday
    /// until they actually move it. Until then the form stays clean and `SAVE` stays greyed.
    @ViewBuilder
    private var birthdayRow: some View {
        if let birthday = viewModel.birthday {
            HStack(spacing: 8) {
                DatePicker(
                    "BIRTHDAY",
                    selection: Binding(
                        get: { birthday },
                        set: { viewModel.birthday = $0.startOfDay }),
                    displayedComponents: .date)
                    .labelsHidden()

                Spacer(minLength: 0)

                Button {
                    viewModel.birthday = nil
                    draftBirthday = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear birthday")
            }
        } else if draftBirthday != nil {
            DatePicker(
                "BIRTHDAY",
                selection: Binding(
                    get: { draftBirthday ?? Date() },
                    set: { newValue in
                        draftBirthday = newValue
                        viewModel.birthday = newValue.startOfDay
                    }),
                displayedComponents: .date)
                .labelsHidden()
        } else {
            Button {
                draftBirthday = Date()
            } label: {
                HStack {
                    Text(ActivityFigure.dash).foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a birthday")
        }
    }

    /// The `UNITS` control, which is a preference rather than a fact about the body.
    ///
    /// **It persists the moment it is tapped and is not part of `SAVE`**, because it writes
    /// `AppPreferences` in `UserDefaults` while `SAVE` writes the `user_profiles` row — two stores with
    /// no shared transaction, which is every other preference toggle in this app's shape.
    ///
    /// The selection reads the view model's resolved unit rather than the stored preference, so the
    /// control's position and the boxes beside it cannot disagree: `nil` in the preference means
    /// *nobody has chosen*, and `ProfileViewModel` resolves that through the phone's locale — which is
    /// the same answer the activity route card derives, so the two agree until a user deliberately
    /// chooses a unit their phone disagrees with.
    ///
    /// **A tapped segment repeats `select(unit:)` rather than being guarded here**, because that method
    /// already opens with `guard newUnit != unit` — so re-tapping the half that is already selected
    /// writes nothing, re-seeds nothing and leaves the form as clean as it found it. A second copy of
    /// that test on this side would be a second definition of "the user changed the unit".
    ///
    /// **It was a `.pickerStyle(.segmented)` `Picker` and is now `SegmentedPillControl`**, which is the
    /// same move the device page's tabs made off their own `Picker`: the stock control is the platform's
    /// drawing and not the reference's. See that component for what changed and what deliberately did
    /// not — the two words, their order and the tap-to-persist behaviour are all unchanged, and the order
    /// is `Unit.displayOrder` rather than a literal here.
    private var unitsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow("UNITS")
            SegmentedPillControl(
                titles: ActivityRoute.Unit.displayOrder.map(\.title),
                selectedIndex: ActivityRoute.Unit.displayOrder.firstIndex(of: viewModel.unit) ?? 0
            ) { index in
                let newUnit = ActivityRoute.Unit.displayOrder[index]
                Task { await viewModel.select(unit: newUnit) }
            }
        }
    }

    /// `SAVE`, full width, grey until there is something to save.
    ///
    /// **`hasLoaded` is the outer gate and `hasUnsavedChanges` the inner one**, and they answer
    /// different questions. The first is that a save before the row has been read would write the
    /// merge's other half from an empty entity; the second is the reference's greyed button, which is
    /// what the user asked for — *live once something has changed*. Until then this draws in the card
    /// surface, which is what the picture shows, and `disabled` is the real gate rather than the
    /// colour being one.
    ///
    /// **A refused save leaves the button live**, because a refusal writes nothing and the form is
    /// still dirty — so the sentence explaining it has something to sit under, which is `save()`'s own
    /// argument.
    private var saveButton: some View {
        let isLive = viewModel.hasLoaded && viewModel.hasUnsavedChanges
        return Button {
            Task { await viewModel.save() }
        } label: {
            Text("SAVE")
                .font(.footnote.weight(.bold))
                .tracking(1.2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLive ? Theme.textPrimary : Theme.textMuted)
        .background(
            isLive ? Theme.actionTint : Theme.homeCard,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!isLive)
    }

    // MARK: - LOGS

    /// The whole import/export surface, moved off `More → Settings` on the user's instruction.
    ///
    /// **Nothing here draws a figure**, which is the provenance note for this pane: every row is an
    /// action and a caption, and the one piece of variable text is `status` — which is the import's own
    /// return value (`WhoopImportSummary.message`, `HealthImportSummary.message`) or the exporter's,
    /// never a number this page composed.
    ///
    /// **`Whoop` holds three buttons, one per bundled CSV, on the user's instruction** — *"remove
    /// 're-import whoop history', instead i want 3 seperate buttons that import one of each whoop csv
    /// file, this would be the Whoop section, only file i dont want to use is journal_entries.csv"*. The
    /// single `Import WHOOP history` control that stood here walked all three files at once, so a reader
    /// could not load the zone block without also writing 910 recoveries. The rows come from
    /// `WhoopImportAction.all` rather than being spelled out here, so the section's *shape* — three
    /// rows, in this order, `journal_entries.csv` among none of them — is a value §18 can assert rather
    /// than a fact about a `body` nothing can read. **The section is titled `Whoop` and not `WHOOP`**,
    /// matching `Apple Health` above it: the header case is the `Form`'s, while the tracked capitals
    /// belong to the buttons.
    ///
    /// **`Zero Fasting` is the same treatment for the fourth import**, on the same instruction read one
    /// section further: *"do same for zero fasting app section, well only use biodata.json (fasting
    /// data)"*. Its one row is `FastingImportAction.fasting`, drawn through the same `actionRow` helper
    /// the three above it use, and it is a section of its own rather than a fourth row in `Whoop`
    /// because the header names who produced the file — a fasting tracker's history, not WHOOP's — and
    /// because its rows carry no measurement at all.
    ///
    /// **The caption names `biodata.json` while the build ships `fasts.json`, and that pair is the
    /// user's own correction**: *"so my modified version was fasts.json, in UI refer to it as
    /// "biodata.json" as thats what zero gives when exporting"*. The two describe one file — the export
    /// and the projection of it this app carries — and the caption takes the producer's name because it
    /// is the one a reader recognises, while the resource keeps the trimmed copy's. The name on screen is
    /// `FastingImportAction.fileName` and the name of the resource is
    /// `ZeroFastingImporter.bundledResourceName`; §18 pins one and §20 the other, so neither can drift
    /// into the other's place. See `FastingImportAction` for why the 599 KB `biodata.json` itself is
    /// neither bundled nor read.
    ///
    /// **`Whoopsy` is the one section on this pane that takes data out**, and it replaced a section
    /// called `Local backup` on the user's instruction: *"instead of "Local Backup", lets add another
    /// section called Whoopsy to export whoopsy data, which would be everything from wherever user
    /// stores their data, local or a database"*. Both halves of that are corrections rather than a
    /// rename. The header now names the **producer**, as the three above it do — they name the app a
    /// file came from and this one names the app that wrote it — and the export stopped being a 30-day
    /// window whose JSON carried only *counts*. **"Local or a database" is the load-bearing half**:
    /// this app stores data in two places, the SQLite database and the `UserDefaults` the unit choice
    /// and the three toggles live in, so an export reading only the database would leave the settings
    /// out. The row's copy is `WhoopsyExportAction`, a value §18 asserts, for this pane's standing
    /// reason — the runner has no renderer, so words typed into a `body` are words nothing can read.
    @ViewBuilder
    private var logsTab: some View {
        Section("Apple Health") {
            Toggle("HealthKit sync", isOn: Binding(
                get: { localDataViewModel.preferences.healthKitSyncEnabled },
                set: { _ in Task { await localDataViewModel.authorizeHealthKit() } }))
                .disabled(!localDataViewModel.healthKitAvailable)
            Text(localDataViewModel.healthKitAvailable
                ? "Reads HRV and resting heart rate from Apple Health into this app. Nothing is uploaded."
                : localDataViewModel.healthKitUnavailableReason)
                .font(.caption)
                .foregroundStyle(.secondary)
            if localDataViewModel.isImporting {
                HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) }
            }
        }

        Section("Whoop") {
            ForEach(WhoopImportAction.all) { action in
                importRow(action)
            }
            if localDataViewModel.isImporting {
                HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) }
            }
        }

        // **Its own section rather than a fourth row in `Whoop`**, which is the same argument as its own
        // button: the section header names who produced the file, and this file is a fasting tracker's
        // rather than WHOOP's. Its rows also carry no measurement at all, so a card sitting under
        // `Whoop` would put rows in `workouts` that WHOOP never recorded under a header promising
        // otherwise. The row draws through `actionRow`, the same helper the three above it use, so the
        // card treatment has one definition rather than two that can drift.
        Section("Zero Fasting") {
            actionRow(
                title: FastingImportAction.fasting.title,
                caption: FastingImportAction.fasting.caption
            ) {
                await localDataViewModel.importFastingHistory()
            }

            if localDataViewModel.isImporting {
                HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) }
            }
        }

        // **The fourth import and the first whose header names no producer app.** `Apple Health`,
        // `Whoop` and `Zero Fasting` above it each name the app a file came *from*, because each of
        // those files is another service's export of a record that service measured. This file is the
        // owner's own notes log and no app produced it, so the header names the row the import writes —
        // the same words as the Home card it fills, `RECEPTIVE INACTIVITIES` once the `Form` uppercases
        // it. That deviation is recorded rather than smoothed over; see `InactivityImportAction`.
        //
        // Its own section on the same argument that gave `Zero Fasting` one: the row it produces is a
        // `receptive_inactivities` entry rather than a `workouts` row, carrying no measurement of any
        // kind, so it could not sit under a header naming a producer of measured sessions. It draws
        // through `actionRow` like the three above it, so the card treatment keeps one definition.
        Section(InactivityImportAction.sectionTitle) {
            actionRow(
                title: InactivityImportAction.inactivities.title,
                caption: InactivityImportAction.inactivities.caption
            ) {
                await localDataViewModel.importInactivityHistory()
            }

            if localDataViewModel.isImporting {
                HStack(spacing: 8) { ProgressView(); Text("Importing…").font(.caption) }
            }
        }

        // **The one section here that takes data out rather than bringing it in**, which is what its
        // header says: the four sections above it name what they hold — three an app a file came *from*
        // and the fourth the row it produces — and this one names the app that wrote the file. It held
        // the JSON + CSV export under the name `Local backup` until the user replaced that section with
        // this one.
        //
        // **Nothing here writes**, so there is no `Importing…` row: the four sections above it bracket
        // their work in `isImporting` because they change a database under the reader, where this one
        // only reads it and the JSON it produces is the whole of its result.
        //
        // **Both share rows draw through `cardLabel`**, the same card the two action rows above use, so
        // a share control is not the one blue word in a column of cards — which is the shape `Local
        // backup` had, and the reason the restyle was offered for it in the first place.
        Section(WhoopsyExportAction.sectionTitle) {
            actionRow(
                title: WhoopsyExportAction.export.title,
                caption: WhoopsyExportAction.export.caption
            ) {
                await localDataViewModel.exportData()
            }

            if let export = localDataViewModel.export {
                ShareLink(
                    item: export.jsonString,
                    preview: SharePreview("Whoopsy export")
                ) {
                    cardLabel("SHARE JSON", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                ShareLink(
                    item: export.csvHeartRates,
                    preview: SharePreview("Whoopsy heart rate CSV")
                ) {
                    cardLabel("SHARE HEART RATE CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }

        if !localDataViewModel.status.isEmpty {
            Section { Text(localDataViewModel.status).font(.footnote) }
        }
    }

    /// One `Whoop` row: the button, then its caption directly under it.
    ///
    /// **The file is the only thing dispatched**, which is why this takes a `WhoopImportAction` rather
    /// than a title and a closure: an action carries its own `file`, so the words and the import are
    /// read off one value and the row cannot be drawn for one CSV and wired to another. The card itself
    /// is `actionRow`'s, shared with the `Zero Fasting` section below so the treatment has one
    /// definition rather than two that can drift.
    private func importRow(_ action: WhoopImportAction) -> some View {
        actionRow(title: action.title, caption: action.caption) {
            await localDataViewModel.importWhoop(action.file)
        }
    }

    /// One action row on this pane: a full-width card button, then its caption directly under it.
    ///
    /// **The label is this page's own `saveButton` treatment** — a full-width `Theme.homeCard` card
    /// carrying bold tracked capitals — rather than a default `Form` button, which is the user's
    /// instruction (*"use the styling we have been using through out the app"*). Rows of blue text in a
    /// column would read as links where these are actions of equal weight, and the reference draws this
    /// page's controls as cards: `SAVE` here, `PAIR A DEVICE` and `UNPAIR DEVICE` on the device page,
    /// the tab bars on both. `.buttonStyle(.plain)` is what lets the card be the whole of the look — the
    /// default styles tint the label and add a hit shape over it — and `.foregroundStyle` after it is
    /// what the label takes, exactly as on `saveButton`.
    ///
    /// **The caption is a sibling of the button and not a label inside it**, so the sentence is not part
    /// of the tap target: a reader pressing the paragraph to read it must not start a 910-day import. It
    /// is the same `caption`/`.secondary` pair every other row on this pane uses.
    ///
    /// **The words come in as parameters rather than being typed here**, so every row's copy is read off
    /// a value the runner can assert (`WhoopImportAction`, `FastingImportAction`) instead of living in a
    /// `body` nothing can read. What this helper owns is the drawing, and only the drawing.
    private func actionRow(
        title: String,
        caption: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await action() }
            } label: {
                cardLabel(title)
            }
            .buttonStyle(.plain)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The card every control on this pane is drawn as, whether it is a `Button` or a `ShareLink`.
    ///
    /// **It is a function rather than a copy per call site** for the reason the `Whoop` and
    /// `Zero Fasting` rows share `actionRow`: the treatment has one definition, so the `Whoopsy`
    /// section's two share controls cannot drift from the four action cards above them. It is extracted
    /// from `actionRow` when the first non-`Button` needs it — a `ShareLink` carries its own label and
    /// takes no `actionRow`, so without this the share rows would be the only rows on the pane that are
    /// not cards, which is exactly the shape the old `Local backup` section had.
    ///
    /// **`.foregroundStyle` and `.background` live here now and not on the buttons**, which is a
    /// deliberate move rather than tidying: a `ShareLink` is not a `Button` and would not inherit a
    /// modifier applied at the `actionRow` call site, so leaving them there is precisely how the two
    /// kinds of row come apart. `.font` and `.tracking` stay on the `Text` rather than on the stack, so
    /// the optional `systemImage` is sized and coloured by the card and not by the words' tracking.
    ///
    /// **`tint` is a parameter because the colour has to be settable from inside.** An outer
    /// `.foregroundStyle` cannot grey this label — the inner one wins — so `storageTab`'s run button
    /// would silently draw live while its `.disabled` gate said otherwise. It defaults to
    /// `Theme.textPrimary`, so the eight call sites that are always live are unchanged. The card surface
    /// is deliberately *not* a parameter beside it: `Theme.homeCard` is already the resting surface
    /// `saveButton` greys to, so a control that is not live needs no second colour to say so.
    private func cardLabel(
        _ title: String,
        systemImage: String? = nil,
        tint: Color = Theme.textPrimary
    ) -> some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.footnote.weight(.bold))
                .tracking(1.2)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            Theme.homeCard,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - STORAGE

    /// Where new data is stored, and how much of it a run would send.
    ///
    /// **This is what *"if a person wants to switch from using local to DB should be seamless"* asked
    /// for**, and the whole of the feature is a switch and a span. The switch says where the *next* write
    /// goes and moves nothing — *"if a DB is selected, it doesnt purge anything, it just switches where
    /// data will be stored to"* is the user's own ruling, and both destination notes say so on the
    /// screen. The span is what `SYNC` sends. Nothing is sent by opening this pane and nothing is sent by
    /// a user who never opens it: the app as it ships is `DEVICE STORAGE` with no span, which is
    /// byte-identical to the app before this feature existed.
    ///
    /// **A build with no database behind it gets one sentence, the resource list, and no controls.** See
    /// `storageNoDatabaseNotice`: every control on this pane would fail for a reason the screen already
    /// knows, and drawing a greyed button over that is how a reader comes to believe they configured
    /// something wrong. The list stays because *what would move* is a fact about this app rather than
    /// about this build — see `storageResourcesEyebrow`.
    ///
    /// **The controls are the page's own vocabulary rather than new ones.** The destination row is
    /// `unitsRow`'s `SegmentedPillControl`, whose titles come off `SyncSettings.Destination.allCases` —
    /// so the two options, their order and their words are read off the type rather than typed here,
    /// which is what keeps a third destination from being a segment that silently never appears. The span
    /// rows are `birthdayRow`'s three-state shape, and for its reason exactly — a compact `DatePicker`
    /// has no "no value" state, so each end has to be a control's position before it is a stored value,
    /// or the database is owed nine hundred days the moment the rows are first drawn.
    ///
    /// **The run button is drawn only when it could do something, and it no longer carries a verb.** It
    /// used to read `UPLOAD` or `DOWNLOAD`, off which way two boundaries disagreed. There is one
    /// destination and one span now, so the direction follows from the span rather than being a choice,
    /// and a button naming one of the two would name a choice the user never made — see
    /// `SyncStorageViewModel.runTitle`.
    @ViewBuilder
    private var storageTab: some View {
        if syncViewModel.isCloudConfigured {
            Section {
                keyRow
            }

            Section {
                destinationRow
            }

            Section {
                spanRow(
                    title: Self.storageRangeFromEyebrow,
                    stored: syncViewModel.range?.from,
                    draft: $draftRangeFrom,
                    otherDraft: $draftRangeTo
                ) { newFrom in
                    Task {
                        await syncViewModel.setRange(
                            from: newFrom, to: syncViewModel.range?.to ?? draftRangeTo)
                    }
                }

                spanRow(
                    title: Self.storageRangeToEyebrow,
                    stored: syncViewModel.range?.to,
                    draft: $draftRangeTo,
                    otherDraft: $draftRangeFrom
                ) { newTo in
                    Task {
                        await syncViewModel.setRange(
                            from: syncViewModel.range?.from ?? draftRangeFrom, to: newTo)
                    }
                }

                Text(Self.storageRangeNote(isEnabled: syncViewModel.hasSpan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                syncedResourcesRow
            }

            // **The gate is the span and not `canRun`**, and the difference is the run in flight: a row
            // drawn only while `canRun` would vanish under the reader's finger the instant they pressed
            // it, taking the `Working…` line below it with it. So the row appears with the span and
            // stays while a run is going, greyed and honest.
            if syncViewModel.hasSpan {
                Section {
                    runRow(title: SyncStorageViewModel.runTitle)
                }
            }

            if let keyError = syncViewModel.keyError {
                Section {
                    Text(keyError)
                        .font(.footnote)
                        .foregroundStyle(Theme.recoveryRed)
                }
            }

            // The status sentence is `logsTab`'s bracket exactly: a section that exists only once there
            // is something to say, so an untouched pane draws no empty row.
            if !syncViewModel.status.isEmpty {
                Section {
                    Text(syncViewModel.status)
                        .font(.footnote)
                }
            }
        } else {
            Section {
                Text(Self.storageNoDatabaseNotice)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }

            // **The list is drawn in this arm too, and it is the one row that survives the branch.** See
            // `storageResourcesEyebrow`: *what would move* is a fact about this app rather than about
            // this build's configuration, and it is the answer a reader came to the pane for. What
            // changes between the arms is the sentence above it, not the list.
            Section {
                syncedResourcesRow
            }
        }
    }

    /// Where new data is stored — the pane's whole subject, in the slot the resource selector vacated.
    ///
    /// **It replaced a segment that chose which resource's settings were being edited, and that segment
    /// is gone because its second answer is gone.** Each resource used to carry its own cutoff and its
    /// own copy policy, so the pane had to know which one the two rows below belonged to; there is one
    /// destination and one span for the install, so a selector here would be asking a question with one
    /// answer.
    ///
    /// **It is drawn above the span because the span is what the destination makes of a day**, and the
    /// key row above stays put: the key is this install's and not the destination's, so a selector over
    /// it would be claiming the credential changed with the segment — which is the one thing about it a
    /// reader must not believe, since the same key is what files a row under either destination.
    ///
    /// **The titles come off `Destination.allCases` rather than being typed here**, on `unitsRow`'s rule:
    /// the order *is* the drawing, and `device` is first because it is the default and the state a fresh
    /// install is in — so a case added to the enum is a segment that appears rather than one that
    /// silently never does. The selection reads the view model's own `destination` and not a local
    /// `@State`, because there is no draft here — every control on this pane writes through the moment
    /// it is touched, which is `unitsRow`'s arrangement and the reason `BIOMETRICS`'s snapshot type has
    /// no counterpart on this pane.
    ///
    /// **The note is the pane's most important sentence**, and it is why this row has one at all: a
    /// reader who sees `WHOOPSY SYNC API` expects their history to leave the phone, and they are owed
    /// the answer before they press it rather than after. See `storageDestinationNote(for:)` for why
    /// both arms carry the reassurance rather than only the cloud arm.
    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow(Self.storageDestinationEyebrow)

            SegmentedPillControl(
                titles: SyncSettings.Destination.allCases.map(\.rawValue),
                selectedIndex: SyncSettings.Destination.allCases
                    .firstIndex(of: syncViewModel.destination) ?? 0
            ) { index in
                let destination = SyncSettings.Destination.allCases[index]
                Task { await syncViewModel.setDestination(destination) }
            }

            Text(Self.storageDestinationNote(for: syncViewModel.destination))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The key, and the one control that gets it off this phone.
    ///
    /// **`COPY` is a `ShareLink` and not a `UIPasteboard` write**, and that is the app's own precedent
    /// rather than a preference: the `LOGS` pane's two share controls are `ShareLink`s, so this is the
    /// third on the page and the first whose payload is short enough for a share sheet to look
    /// disproportionate. The alternative — a pasteboard write with a `UIPasteboard` call — does not
    /// exist anywhere in this app, and the reason is that it would put a UIKit import into a file the
    /// host build compiles. A share sheet hands the key to the same clipboard in one more tap, and it
    /// also gets it to a note or a message, which is what a reader recovering a phone actually needs.
    ///
    /// **The key is drawn as the store spells it.** Sixty-four unbroken uppercase hex characters, not the
    /// mockup's dash-grouped `4F2A-9C1B-…`, because `KeychainSyncKeyStore` holds exactly one spelling of a
    /// key and a rendering invented on this row would be a second one — and the one that gets copied by
    /// hand would be the one that does not match. It is set in a monospaced font at the smallest size the
    /// page uses and allowed to shrink rather than wrap, so a full key stays on one line.
    ///
    /// **The `textSelection` is what makes the row usable without the button**, and it is not redundant
    /// with it: a `ShareLink` cannot be driven from the runner and a reader may want to select the key by
    /// hand on a device whose share sheet is full of things they would rather not send it to.
    @ViewBuilder
    private var keyRow: some View {
        if let key = syncViewModel.key {
            VStack(alignment: .leading, spacing: 8) {
                eyebrow(Self.storageKeyEyebrow)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)

                    Spacer(minLength: 0)

                    ShareLink(item: key, preview: SharePreview("Whoopsy sync key")) {
                        Text(Self.storageCopyTitle)
                            .font(.caption2.weight(.bold))
                            .tracking(0.9)
                            .foregroundStyle(Theme.actionTint)
                    }
                    .buttonStyle(.plain)
                }

                Text(Self.storageKeyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            // The unconfigured case never reaches here — `storageTab` draws one sentence instead — so
            // this is the gap between the pane appearing and `load()` answering. A spinner and no
            // sentence: the eyebrow above it already says what is being read.
            ProgressView()
        }
    }

    /// One end of the span, and `birthdayRow`'s three states applied to a date that has a partner.
    ///
    /// **The `—` is a button that writes nothing**, exactly as the birthday's is: tapping it opens the
    /// picker on a draft, and the draft does not become the user's span until they move it. The middle
    /// state is what makes a *pair* of controls safe to draw, and it is stronger here than it was on the
    /// single boundary this row replaced: without it, `SYNC FROM` would default to `Date()` and a span
    /// running from today to today would be the state a reader found the pane in, having asked for
    /// nothing.
    ///
    /// **`otherDraft` is the other end of the span being drawn, and it is the row's only way to read
    /// it.** `SyncSettings.range` is one optional pair, so while the pair is incomplete the store holds
    /// nothing at all and the drafts are the only record of what the user has picked — which is why the
    /// picker in the middle state opens on `otherDraft` rather than on `Date()`: two ends of one span
    /// must not open on two different days, and a reader setting `SYNC TO` after `SYNC FROM` is naming
    /// the far end of a range they have already started.
    ///
    /// **The clear control removes the whole span rather than one end**, and that is the type's contract
    /// rather than a simplification made here: there is no state in which one end is stored and the other
    /// is not, so there is nothing for a per-end clear to leave behind. It therefore clears **both**
    /// drafts as well as the store, and its accessibility label says *clear the span* rather than naming
    /// the end — an `xmark` that took one date away and left the other row still showing one would be
    /// drawing a state the store cannot hold. It is deliberately *not* the same as moving the end to a
    /// very old date — that sends everything, where this sends nothing.
    ///
    /// **`write` is the caller's because only the call site knows which end this row is.** The row knows
    /// its own new value and its partner's draft; the caller knows which of the two slots it fills, and
    /// nothing here can infer that from a `Date?`. It is called with `nil` by the clear control, which is
    /// how one closure serves all three states.
    ///
    /// The write goes through `setRange(from:to:)` rather than being assigned, so the snap lives on
    /// `SyncSettings.SyncRange` and the stored span cannot depend on what time of day the picker was
    /// tapped — the rule the single boundary followed, kept verbatim. The snap below is belt-and-braces
    /// at the call site and not the mechanism: it keeps the *draft* a day too, so a picker reopened on it
    /// draws the day the user chose rather than the minute they chose it.
    @ViewBuilder
    private func spanRow(
        title: String,
        stored: Date?,
        draft: Binding<Date?>,
        otherDraft: Binding<Date?>,
        write: @escaping (Date?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow(title)

            if let stored {
                HStack(spacing: 8) {
                    DatePicker(
                        title,
                        selection: Binding(
                            get: { stored },
                            set: { newValue in write(newValue.startOfDay) }),
                        displayedComponents: .date)
                        .labelsHidden()

                    Spacer(minLength: 0)

                    Button {
                        draft.wrappedValue = nil
                        otherDraft.wrappedValue = nil
                        write(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the span")
                }
            } else if draft.wrappedValue != nil {
                DatePicker(
                    title,
                    selection: Binding(
                        get: { draft.wrappedValue ?? otherDraft.wrappedValue ?? Date() },
                        set: { newValue in
                            draft.wrappedValue = newValue.startOfDay
                            write(newValue.startOfDay)
                        }),
                    displayedComponents: .date)
                    .labelsHidden()
            } else {
                Button {
                    draft.wrappedValue = otherDraft.wrappedValue ?? Date().startOfDay
                } label: {
                    HStack {
                        Text(ActivityFigure.dash).foregroundStyle(Theme.textMuted)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set \(title)")
            }
        }
        .padding(.vertical, 4)
    }

    /// What a run would carry, and the pane's only row that is a list rather than a control.
    ///
    /// **The names come off `SyncedResource.allCases` rather than being typed here**, which is that
    /// enum's own rule and the reason its order is `shared/openapi.json`'s: the list is a `ForEach` over
    /// the enum, so a resource added to it appears on the screen with no view edit, and the order is read
    /// off the contract rather than decided in this file. §22 asserts the two against each other.
    ///
    /// **Nothing here is tappable**, deliberately: the list answers *what would move*, and a row a reader
    /// could press would imply it could be excluded. The one resource that genuinely can be is the eighth
    /// and it is not drawn — `SyncSettings.uploadsBiometricSamples` is stored and deliberately read by
    /// nothing in this pass, which is why `storageResourcesNote` names it in prose instead.
    private var syncedResourcesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow(Self.storageResourcesEyebrow)

            ForEach(SyncedResource.allCases, id: \.self) { resource in
                Text(resource.rawValue)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
            }

            Text(Self.storageResourcesNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The one control that moves days, and it no longer carries a verb.
    ///
    /// **It reads `SYNC` because there is no verb left to read.** It used to say `UPLOAD` or `DOWNLOAD`,
    /// off which way two cutoffs disagreed, and with one destination and one drawn span the direction
    /// follows from the span rather than being a choice — so a button naming one of the two would name a
    /// choice the user never made. See `SyncStorageViewModel.runTitle`, which carries the whole argument,
    /// including why the mockup's `UPLOAD 912 DAYS` cannot be drawn honestly either.
    ///
    /// **Greyed rather than absent when it cannot run**, which is the opposite of the span rows above it
    /// and is deliberate. `storageTab` draws this row only once a span exists, so the one state where it
    /// is drawn and un-pressable is a run already in flight — and that state has to stay visible rather
    /// than disappearing under the reader's finger, which is also why the gate there is the span and not
    /// `canRun`. `saveButton`'s treatment one pane over: the tint and the `disabled` gate both read off
    /// one value, because `.buttonStyle(.plain)` with a custom background does not grey itself.
    private func runRow(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await syncViewModel.run() }
            } label: {
                cardLabel(
                    title,
                    tint: syncViewModel.canRun ? Theme.textPrimary : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!syncViewModel.canRun)

            // `logsTab`'s `isImporting` bracket, and it is honest here for the same reason it is there:
            // this row changes a database under the reader, and on a first upload that is five requests
            // carrying nine hundred days.
            if syncViewModel.isSyncing {
                HStack(spacing: 8) { ProgressView(); Text("Working…").font(.caption) }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Field vocabulary

    /// A field's name, above its box — the reference's own row shape.
    ///
    /// It is a function rather than a `Text` at each call site so the five labels cannot drift apart in
    /// size, weight or tracking: the reference draws them as a set, and a set is exactly what five
    /// copies are free to stop being.
    private func eyebrow(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(0.9)
            .foregroundStyle(Theme.textMuted)
    }

    /// One labelled field: the name above, a bordered box below, and an optional line of prose under
    /// it.
    ///
    /// **It replaced a label-left/value-right row**, which is the platform's `Form` idiom and not the
    /// reference's. The reference draws each fact as a name over a box, and the boxes are what make a
    /// page of seven entries read as a form rather than as a settings list — so this page has one field
    /// idiom and the two heart rates below use it too.
    ///
    /// `title` is `" "` for the second of the two side-by-side height boxes: it is a spacer that keeps
    /// the two boxes' tops level, and a name would be wrong there — the pair is one fact under one
    /// name.
    private func field(
        title: String,
        text: Binding<String>,
        unit: String?,
        decimal: Bool,
        detail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow(title)

            HStack(spacing: 8) {
                TextField(ActivityFigure.dash, text: text)
                    .numericKeyboard(decimal: decimal)
                    .monospacedDigit()

                if let unit {
                    Text(unit).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.homeCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))

            // Its own `Text`, and not a `**bold**` run inside a string built with `+`: a concatenated
            // `String` takes `Text`'s `StringProtocol` overload, which does not parse Markdown, and
            // this app has already shipped asterisks to a screen that way.
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Platform

extension View {
    /// Offers a numeric keyboard, on the platforms that have one.
    ///
    /// `keyboardType` is unavailable on macOS and this page is compiled for both — the host
    /// `swift build` is this repo's edit/compile loop and the test runner links its objects, so an
    /// unguarded modifier breaks the fast path while the simulator build stays green. This is the
    /// fourth member of the family `HomeDashboardView.hidingTabBar(_:)` documents.
    ///
    /// `.decimalPad` for a weight and `.numberPad` for the two heart rates: the difference is whether a
    /// decimal separator is a legitimate keystroke, and offering one where it is not is the surest way
    /// to make a user type something `ProfileDraft` then has to refuse. It rides on the *box* rather
    /// than on the value, which is why the height pair is split — whole feet take `.numberPad` while
    /// the inches beside them take `.decimalPad`.
    @ViewBuilder
    func numericKeyboard(decimal: Bool) -> some View {
        #if os(iOS)
        keyboardType(decimal ? .decimalPad : .numberPad)
        #else
        self
        #endif
    }
}
