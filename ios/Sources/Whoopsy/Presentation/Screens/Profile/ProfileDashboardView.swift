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
/// and `aiCoachNotice` **is** the whole of a tab that has no feature behind it. Both are asserted in
/// §18.
///
/// ## `LOGS` is `LocalDataViewModel`'s and `BIOMETRICS` is `ProfileViewModel`'s, and they are two
///
/// They were one type once, on `More → Settings`. See `LocalDataViewModel` for why the move off that
/// page was a rename-with-shrink rather than one instance drawn twice: a shared one would give the two
/// panes one `status` string and one `isImporting` flag, so an import on `LOGS` could rewrite the
/// sentence a save on `BIOMETRICS` had just written.
public struct ProfileDashboardView: View {
    @State private var viewModel: ProfileViewModel
    @State private var localDataViewModel: LocalDataViewModel
    @State private var tab: Tab = .biometrics

    /// The `BIRTHDAY` control's in-progress value, and the reason the row has three states rather than
    /// two. See `birthdayRow`.
    @State private var draftBirthday: Date?

    public init(viewModel: ProfileViewModel, localDataViewModel: LocalDataViewModel) {
        _viewModel = State(initialValue: viewModel)
        _localDataViewModel = State(initialValue: localDataViewModel)
    }

    // MARK: - Values the runner can assert

    /// The three panes, in the order they are drawn.
    ///
    /// A nested `enum` rather than an index or three `Bool`s, on `DeviceSettingsView.Tab`'s rule: the
    /// titles and their order **are** the drawing, and a reorder is invisible in a screenshot of the
    /// first tab — which is the one a screenshot would be taken of.
    ///
    /// **All three labels were renamed on the user's instruction** — *"rename "Body" tab to
    /// "Biometrics", rename "Data" tab to "Logs", rename "AI Coach" tab to "Storage""* — and the case
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

    /// What the third pane says, which is the whole of that pane.
    ///
    /// **The pane is now titled `STORAGE` and this copy is still about a coach, and the two are left
    /// disagreeing on purpose.** The instruction was a rename of three labels and said nothing about
    /// content, so rewording this would be inventing copy under the guise of a rename; the mismatch is
    /// recorded here instead of being quietly repaired. **It is an open question for the user** — the
    /// three new titles (`BIOMETRICS`, `LOGS`, `STORAGE`) read as a reshuffle of what each pane is
    /// *for*, where `STORAGE` describes the import/export surface the `LOGS` pane actually holds. The
    /// constant keeps its name because it names the *copy*, which is unchanged; §18 pins the string
    /// verbatim, so the disagreement is visible to the suite and not only to a reader.
    ///
    /// **A placeholder rather than a feature, and that is the user's own decision.** The app does hold
    /// `GenerateCoachInsightsUseCase`, and it is deliberately **not** wired to this tab: it survives
    /// with no reader but `DIContainer` and is documented as dead code on its own type. A tab that
    /// generated something would be a second, undocumented surface for a model nobody has argued for,
    /// where this says plainly that there is nothing here yet.
    ///
    /// It is a `nonisolated static` rather than a literal in the `body` so §18 can pin it — the same
    /// reason `SleepConsistencyCard.legendLabel` and `DeviceSettingsView.subject` are.
    public nonisolated static let aiCoachNotice = """
        No coach is built into this app yet.

        When it arrives it will read the recovery, strain and sleep history already stored on this \
        device, and it will run here rather than in the cloud — this app has no networking code at all.
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
        // `load()` is the page's, because `BIOMETRICS` is the pane it opens on. `LOGS` is loaded by the
        // `task(id:)` below instead — see `LocalDataViewModel.load()` for why the HealthKit query is
        // narrowed to the tab rather than paid for by a reader who came to type their weight.
        .task { await viewModel.load() }
        .task(id: tab) {
            guard tab == .logs else { return }
            await localDataViewModel.load()
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
    private func cardLabel(_ title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.footnote.weight(.bold))
                .tracking(1.2)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            Theme.homeCard,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - STORAGE

    /// The tab that is a sentence, because there is no feature behind it — see `aiCoachNotice`, whose
    /// copy and whose tab title deliberately no longer agree.
    private var storageTab: some View {
        Section {
            Text(Self.aiCoachNotice)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
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
