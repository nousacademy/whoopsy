# Pages — the design reasoning

The decisions behind the screens, panes and controls that carry one worth recording: the instructions
behind them, the measurements that corrected them, and the traps a new screen modelled on one would
hit. The full inventory is `CLAUDE.md`'s `## Pages`; the five screens whose shape has no such decision
to record are listed below, each linked to the file that implements it.

> **Sources.** Other people's reverse-engineering is cited here by **role**, never by project
> name — the community reference, the research reference, the APK reading and the Swift 4.0
> client. Each role resolves to one file under `docs/<project>/`
> holding that project's identity, URLs and verbatim excerpts; the table is
> [`docs/BLE_PROTOCOL.md` § Sources](BLE_PROTOCOL.md#sources).

`CLAUDE.md` `## Pages` keeps the **map** — the three tables (tabs, More, reached-from-Home) and the
grep-able decisions list. This file is the reasoning behind those rows.

---

### The five screens with no decision long enough to carry a section

Each of these is a real, reachable page whose shape is settled by the page it shares with another
route or by a component already described above, so there is no separate instruction or measurement
to record. They are named here so a search of this file does not read their absence as their not
existing, and each name links to the implementation.

| Screen | File | What it is |
| :--- | :--- | :--- |
| `HealthTabView` | [HealthTabView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Health/HealthTabView.swift#L17) | The **Health tab**: a `NavigationStack` over four cards — Healthspan, Health Monitor, Blood Pressure Insights, Heart Screener. Only the second has a producer; the other three draw a dash and a sentence saying what would fill them. The Health Monitor card ticks each vital against its band and opens the same sheet Home's card does. **The Healthspan card stopped being all dashes on 2026-10-29**: its `WHOOPSY AGE` dial draws a risk-equivalent age from the bundled NCHS life table, and when it cannot it names which of the three halves is missing rather than leaving a bare dash — see the Whoopsy Age section below. |
| `RecoveryDashboardView` | [RecoveryDashboardView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Recovery/RecoveryDashboardView.swift#L14) | The Recovery tab's page until 2026-10-29. **No longer drawn**: the tab is a heart with no destination, on the user's instruction, so this screen is kept unrendered and is one line from returning. It is a `NavigationStack` around the day's figures, which are `RecoveryDetailView`, still reached from Home's recovery ring. |
| `RecoveryDetailView` | [RecoveryDetailView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Recovery/RecoveryDetailView.swift#L55) | One day's recovery statistics, with no navigation container of its own. Drawn twice: by the Recovery tab and by Home's recovery ring. |
| `StrainDetailView` | [StrainDetailView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Strain/StrainDetailView.swift#L37) | One day's strain: the ring, and below it the four-row activity card on a day holding a workout. The only strain screen left; the tab it used to sit beside is deleted. |
| `StepsDetailView` | [StepsDetailView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Steps/StepsDetailView.swift#L20) | The steps trend page Home's `STEPS` tile pushes: `W`/`M`/`6M` windows ending on an anchor the chevrons move, the measured-day average above a bar chart, and a footnote saying how many days were measured. |
| `ReadingTrendDetailView` | [ReadingTrendDetailView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Trends/ReadingTrendDetailView.swift#L17) | One reading's trend page, pushed by Home's `RHR`, `HRV` and `VO₂ MAX (EST.)` panels: `W`/`M`/`6M`, the average, the comparison with the previous window, a typical-range band, and the latest reading marked on the line. The HRV form narrows to one metric; the RHR form does not need to; the VO₂ form plots an **estimate** and says so. |
| `StressDetailView` | [StressDetailView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Stress/StressDetailView.swift#L18) | The day's Stress Monitor, pushed by Home's tile: a 0–3 gauge carrying the **latest** window and its time, the **last few hours** as a live line, and a sentence naming the day's average, the time spent in the high band and which reference the score is against. It seeds from Home's already-computed `StressDay` and its `StressLiveViewModel` extends the day while the page is open. |
| `SettingsDashboardView` | [SettingsDashboardView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Settings/SettingsDashboardView.swift#L20) | `More → Settings`, which is the Anonymous diagnostics toggle and nothing else — the imports and export moved to the profile page's `LOGS` pane. |
| `ReceptiveInactivityPickerView` | [ReceptiveInactivityPickerView.swift](../ios/Sources/Whoopsy/Presentation/Screens/Activity/ReceptiveInactivityPickerView.swift#L26) | The name picker the receptive sheet's `NAME` row pushes: a flat list over `ReceptiveInactivityCatalog`. |

### There were five, and the Strain and Sleep tabs are gone on the user's instruction

**There were five, and the Strain and Sleep tabs are gone on the user's instruction** (*"remove strain

and sleep links in bottom navigation and their associated pages, not needed"*). **Their pages went and

their view models did not**: `StrainDashboardView.swift` and `SleepDashboardView.swift` are deleted,

while `StrainViewModel` and `SleepViewModel` are still built — once each in `MainContainerView`, plus their previews — for the detail pages Home's

rings push. Both deleted files were a single `public struct` whose every rule lived in a `private var`,

so nothing on either was assertable and the suite's `assertions=` count is **unmoved** by their

removal, which was confirmed by running it rather than assumed. **Three components lost their last

reader with them** and are kept unrendered: `MetricCardView`, `HeartRateZoneBar` and

`HypnogramChartView`. That is *not* the `ActivityDurationBar` precedent — the runner holds no

assertion about any of the three, so deleting them would drop no guarantee — and each carries a doc

comment saying so, because the reason they are still here is that the sweep went out on two **pages**

and these are shared components, not pages.

### That list held four rows and the user removed three of them, one instruction at a time

**That list held four rows and the user removed three of them, one instruction at a time** — Profile,

then Device, then one more whose page, view model and the use case behind it are all **deleted**. **Each removal left the page reachable from somewhere else or deleted it, and

which of the two happened is the thing to check before adding a row back:**



- **Profile** moved to Home's day-bar row, where it is now the page's only door. `MoreView`'s

  `ProfileViewModel` property is gone with the row.

- **Device** is Home's status badge, and only that. `MoreView`'s `DeviceViewModel` property went with

  it, though the view model itself is still built on `MainContainerView` for the badge — and the

  lesson the row taught survives it: a `NavigationLink`'s destination closure is re-evaluated on every

  push, so a view model built inside one is a fresh instance per push. That is why both pages are

  handed a stored instance rather than constructed at the destination.

- **The imports and the export left this page without a row being removed**, which is the one entry

  here that is not a removal. `More → Settings` still lists `Settings`, and what is behind it is the

  Anonymous diagnostics toggle alone: the Apple Health sync, the WHOOP and Zero fasting imports and

  the JSON + CSV export all moved one tab deeper, onto the profile page's `LOGS` pane, on the user's

  instruction. **The row survives and the page is one switch** — do not read the shrunk page as the

  row outliving its purpose, and do not move the toggle across to "finish" the sweep: `LOGS` is about

  where a history comes from and goes, and this is a statement about the app. It is the only one of

  the four entries where what moved was the page's *contents* rather than a row.



The Strain and Sleep tabs are the earlier instance of the same sweep, and their sentence is above:

### their pages went and their view models did not

**their pages went and their view models did not**, because the detail pages Home's rings push still

build them.

**The profile page is three tabbed panes over the app's own record of the person using it, and only the first of them was ever specified.** The reference draws `BIOMETRICS` alone — `FIRST NAME`, `BIRTHDAY`, `GENDER`, a `UNITS` segmented control, `HEIGHT` and `WEIGHT` side by side, above a full-width greyed `SAVE` (**the `UNITS` control is hand-built**, `SegmentedPillControl`, on the same reasoning that took the device page's tabs off their `Picker` — see `docs/ARCHITECTURE.md` §2.C) — and the other two panes were named without contents, so their subjects are the user's decisions rather than the picture's: `LOGS` is the **whole import/export surface moved off `More → Settings`**, and `STORAGE` is the **cloud sync's own pane**, `SyncStorageViewModel` — the sync key, then a `DEVICE STORAGE │ WHOOPSY SYNC API` destination, then the span a run would send, then a `SYNCED RESOURCES` list, above a `SYNC` button. **It held a `RECOVERIES | WORKOUTS | STRAINS` segment over one `RUN` button, and that segment is gone.** It selected which resource's cutoff and local-copy policy the rows below belonged to, and there is now one destination and one span for the install — so a selector here would be a control asking a question with one answer, while the run sent all seven. The list replaced it and is a `ForEach` over `SyncedResource.allCases`, so a resource added to that enum appears on the screen with no view edit — and the order is read off the generated contract rather than decided in the view. The tab list is a nested `ProfileDashboardView.Tab` enum whose `rawValue` *is* its title, on `DeviceSettingsView.Tab`'s rule: the order **is** the drawing, and a reorder is invisible in a screenshot of the first tab, which is the one a screenshot would be taken of. §18 pins the three titles and the pane's copy for the same reason — the runner has no renderer, so a rule written into a `body` is a rule nothing can assert — and §22 pins the state machine that chooses between the two span sentences and the two destination notes. It pins the `Whoop` section's three rows the same way: the count, the file order, the titles as drawn, and that `journal_entries.csv` is not among them. **All three titles were renamed on the user's instruction** — `BODY` → `BIOMETRICS` and `DATA` → `LOGS` among them — and that instruction named three labels and no content, so the third tab spent a while naming a subject its one sentence did not describe. **That disagreement was ended by the feature rather than by a rewording**: the pane is where this phone's own SQLite file meets the database behind it, which is what the word was pointing at all along.



### The page draws one field idiom, and it is the reference's rather than the platform's

**The page draws one field idiom, and it is the reference's rather than the platform's.** Each row is a small tracked label above a bordered box, so seven entries read as a form; the platform's own label-left/value-right `Form` row is what the page drew before, and it is why `field(title:text:unit:decimal:detail:)` was reworked rather than extended. `MAX HEART RATE` and `RESTING HEART RATE` stayed on this pane **below** the reference's rows, in their own `Heart rate` section, on the user's instruction — so `SAVE` is the last row of the pane and not of the page, which is a deliberate deviation from a picture that stops at `WEIGHT`. The two are here rather than behind `LOGS` because they are inputs to the zone table and to every calorie figure: facts about the body, not about files.



**Four of the pane's seven rows are facts the user supplies, and that is a category this app may hold without a sensor behind it.** `FIRST NAME`, `BIRTHDAY`, `GENDER` and `HEIGHT` have no column before `v20` and feed no model after it — they are saved and read back and nothing else consumes them. What they must never become is a plausible default the app writes down, which is what they were: `"Athlete"`, a birthday 28 years before `now`, and a hardcoded `178.0` cm. `UserProfile`'s own gotcha carries the full argument.



**The `UNITS` control writes a preference and not the profile row, and its `nil` state is load-bearing.** `AppPreferences.usesMetricUnits` is a **`Bool?`** defaulted to `nil`, because `defaults.bool(forKey:)` returns `false` for a key nobody has written and would draw an imperial profile for a user whose phone measures in metric. `nil` means *nobody has chosen*, and `ProfileViewModel` resolves it through `ActivityRoute.Unit.forLocale(.current)` — so a fresh install follows the phone, exactly as the activity route card does, and the two agree until a user deliberately picks a unit their phone disagrees with. That is the user's own scope decision: **`UNITS` governs the four `BIOMETRICS` fields and nothing else**, and the route card keeps reading the locale. The control **persists the moment it is tapped and is not part of `SAVE`**, because the two write different stores — `UserDefaults` and the `user_profiles` row — with no shared transaction, which is every other preference toggle in this app's shape. Switching it **re-renders both body fields from the stored canonical values** rather than from the printed text: `ProfileFormSnapshot.rendering(_:in:)` is called from exactly two places, `load()` and this toggle, and that single constructor *is* the unit-switch rule. Without the re-seed a toggle would enable `SAVE` and each press would compound a half-display-step rounding. **The control itself is now `SegmentedPillControl`** rather than a `.pickerStyle(.segmented)` `Picker` — a drawing change only, with the two words, their order, the tap-to-persist and the binding all untouched, and the order now read off `ActivityRoute.Unit.displayOrder` rather than typed at the call site. `docs/ARCHITECTURE.md` §2.C carries the constants and what is derived rather than picked; §18 pins the titles, the order, the concentric-radius identity and the shared tracking, and **nothing anywhere can see the drawing** — that part is the reader's to check on a phone.



### One weight band, one height band, and the range check is on the canonical value

**One weight band, one height band, and the range check is on the canonical value.** `ProfileUnits` is the app's first and only unit conversion, and `weightKilograms(from:in:)` converts *before* testing `ProfileDraft.weightRangeKg`: the band is `20...400` **kilograms**, so an imperial `192` validated first is accepted as 192 kg — inside the range, silently, with the calorie estimate then scaled by a body nearly twice the user's. §18's sharpest assertion for it is `"30"` lb, which is refused only because the band was applied after the multiplication; `"192"` is accepted either way and would not catch it. **The height pair is two boxes, and its blank/zero asymmetry is deliberate**: `5'` and `5'0"` are the same height, so a blank inches box beside a supplied feet box is a real zero, while two blank boxes are an absence — the opposite of the weight field, where blank is an absence and `0` is not a value at all. An inch box at ≥ 12 is refused rather than carried into the feet box, and **that per-field rule is the only thing catching `5'13"`**, which is 198.12 cm and sits comfortably inside `60...250`.



**`SAVE` is live only once something has changed, which is what the reference's greyed button actually depicts.** The gate is `hasLoaded && hasUnsavedChanges`, and the two answer different questions: the first is that a save before the row has been read would write the merge's other half from `nil`, and the second is the dirty rule. **The dirty rule is a value, not eight `@State` copies of "was this touched"** — `ProfileFormSnapshot` holds the eight boxes' *text* and nothing else, so `MetricChange`'s rule applies to a form: two figures that print alike *are* the same as far as the screen is concerned, and typing `75` over a seeded `75.0` is a change the button must see. Holding canonical numbers would let a difference the user cannot see leave `SAVE` dark over a form that looks edited. The birthday is held at `startOfDay`, which is `ActivityEditDraft`'s minute-write guard one resolution coarser and here is the difference between the form working and `SAVE` being permanently live — a `DatePicker` hands back an instant carrying the current clock time. **A refused save leaves the button live**, so the status sentence has something to explain itself against. The button drives both its `.disabled` and its colours off that one value, because `.buttonStyle(.plain)` with a custom background does not grey itself when disabled.



**The `BIRTHDAY` row has three states, and a compact `DatePicker` having no "no value" state is the whole of why.** Defaulting to `Date()` would draw *today* as the user's birthday until they corrected it — the fabrication `v20` deleted — and a fixed anchor like 1 Jan 1990 is the same invention with a different constant; a row that only toggled between a dash and a picker would **leave the field unclearable**. So an unset birthday draws the app's own `—` as a button, tapping it opens the picker **on a draft that writes nothing**, and a chosen birthday draws the picker with a trailing clear control. **The row carries a visible `BIRTHDAY` eyebrow in all three states, and it did not use to.** The controls were built with `DatePicker("BIRTHDAY", …).labelsHidden()`, so the row drew a bare dash with nothing naming it — the word existed only in the accessibility label — and the field was reported to the author as *missing* while the `v20` column behind it was collecting the value. Nothing about the data moved; the name on the row did. The draft is what keeps the middle state honest: the picker's opening position is a control's position, like a slider's, and it does not become the user's birthday until they move it — until then the form stays clean and `SAVE` stays greyed.



**The tab row is drawn by `UnderlinedTabRow`, and this page is its only call site; the device page hand-builds the same row, and the row chrome deliberately stayed at each call site.** `Presentation/DesignSystem/Components/UnderlinedTabRow.swift` is non-generic — `titles: [String]`, `selectedIndex: Int`, `onSelect: (Int) -> Void` — and that is load-bearing rather than convenient: `StrapGlyph`'s paragraph above records that a generic type cannot hold a static stored property, and this component's four layout constants have to live on a concrete type. It also keeps `Tab.allCases.map(\.title)` — the list §18 asserts — at the call site rather than buried. The underline rule is **drawn on every tab and filled on one**, so the row's height does not change with the selection. **`.listRowBackground(Color.clear)` and `.listRowInsets(UnderlinedTabRow.insets)` are applied per call site and not inside the component**, because they are trait-writing modifiers and whether a trait written by a *nested* view reaches the `Form` row containing it is not something this repo can verify — a wrong answer draws a card rather than raising anything. Two duplicated lines is the price of not betting on unverifiable behaviour.



**`LOGS` is `LocalDataViewModel`'s and `BIOMETRICS` is `ProfileViewModel`'s, and they are two objects rather than one drawn twice.** One instance would give the two panes one `status` string and one `isImporting` flag, so an import on `LOGS` could rewrite the sentence a save on `BIOMETRICS` had just written. The four actions and their captions moved off `SettingsViewModel` **verbatim** — the HealthKit result being the only honest signal of a permission that is never disclosed, the export import needing a deliberate tap rather than firing from `load()` — because those arguments are about those *actions* and not about the page they happened to be drawn on. **The HealthKit auto-import fires when `LOGS` opens and not when the page opens**, through `.task(id: tab) { guard tab == .logs else { return } … }`: a reader who came to type their weight does not pay for a 30-day HealthKit query they did not ask for. **Nothing on `LOGS` draws a figure** — every row is an action and a caption, and the one piece of variable text is the status sentence, which is the import's own return value or the exporter's.



**`LOGS` opens with a `Whoop` section holding three buttons, one per bundled CSV, and they replace the single `Import WHOOP history` control that walked all three files at once.** The user's instruction is exact: *"remove 're-import whoop history', instead i want 3 seperate buttons that import one of each whoop csv file, this would be the Whoop section, only file i dont want to use is journal_entries.csv"*. The three rows are `WhoopImportAction.all`, a plain value derived from `WhoopExportFile.allCases` through an **exhaustive `switch`** — so a fourth case is a compile error rather than a button that silently never appears — and `ProfileDashboardView` draws them with a `ForEach` rather than listing buttons, which is what keeps the count from drifting from the type. Each label is the page's own `saveButton` treatment (a full-width `Theme.homeCard` card, bold tracked capitals) rather than a default `Form` button, which is the user's *"use the styling we have been using through out the app"*; the caption is a **sibling** of the button and not a label inside it, so pressing the paragraph does not start a 910-day import. **The titles are stored in the case they are drawn in** — a `.textCase` in the `body` would put half of what the reader sees where §18 cannot read it. **`journal_entries.csv` has no button and no case**: it is the fourth CSV on disk and the only one that is unbundled, read by nothing anywhere in `ios/Sources/`, so a case for it would draw a button that imports nothing. **`hasImportedWhoopExport` is deleted with the label switch it existed for** — a single `Bool` could not have described which of three files had been imported, and every import here is idempotent, so the action is the same on every press. `importWhoop(_ file:)` is one method taking a file rather than three near-identical ones, and it is the `isImporting` bracket and the `status` write that would otherwise have three places to drift.



**`Zero Fasting` is that same treatment applied to another producer's file, and it is a section of its own.** The instruction was *"do same for zero fasting app section, well only use biodata.json (fasting data)"*. Its one row is `FastingImportAction.fasting` — the same title/caption value shape as the three above it, for the same reason (the runner has no renderer, so words typed into a `body` are words nothing can assert) — and it draws through the same `actionRow` helper, so the card treatment has one definition rather than two that can drift. It **is not a fourth `WhoopImportAction` and not a case on `WhoopExportFile`**, and each of the three reasons is load-bearing: the file is a fasting tracker's rather than WHOOP's, so a row under a header naming the producer would be a false claim; its rows carry **no measurement at all** — no strain, no heart rate, no zone block, the whole of why `v18` exists; and it is the one import here that **skips no day**, so `WhoopExportImporter.recordedWorkoutDays()` carries the matching half by filtering fasts out of the day set it skips against. **That one file goes by two names, and the split is the user's own correction**: *"so my modified version was fasts.json, in UI refer to it as "biodata.json" as thats what zero gives when exporting"*. What the build **ships** is `fasts.json` — `biodata.json`'s `fast_data` array projected down to the one key the importer reads — and what the **button prints** is `biodata.json`, because that is the file Zero hands a user on export and therefore the name a reader recognises. The two describe one file rather than two, which is why this is a naming decision and not a second resource: `FastingImportAction.fileName` (`"biodata.json"`) is the name on screen and `ZeroFastingImporter.bundledResourceName` (`"fasts"`) is the name of the resource, and the caption is built from the former so the sentence cannot come to name a file the button does not claim to read. **§18 pins the first and §20 the second, so neither can drift into the other's place** — and neither is visible from a screenshot, one being a string inside a bundle and the other a caption. The rejected reading of the instruction — bundle the 599 KB `biodata.json` itself — would put a real person's whole record into the app bundle, against the gitignore rule the `ZeroFasting/` directory exists for, and `ZeroFastingParser.parseFasts` would refuse it anyway. §18 pins the row's title, that the caption names `fileName`, the caption's presence, and that neither carries Markdown — the marking being `Text`'s `StringProtocol` overload, which parses none, so a backticked filename would render literally and no compiler and no screenshot can see it.



**`Receptive inactivities` is the fourth section on that pane and the first whose header does not name a producer app.** The instruction was *"Screen names the inactivity too"*. The three sections above it — `Apple Health`, `Whoop`, `Zero Fasting` — each name the app a file came *from*, because each of those files is another service's export of a record that service measured, and there is no such app here: this file is the owner's own notes log, so the only thing the header can honestly name is the **row the import produces** — `InactivityImportAction.sectionTitle`, `"Receptive inactivities"`, the same two words as the Home card it fills. The deviation is held as a constant and pinned by §18 rather than left as a claim in a comment. Its one row is `InactivityImportAction.inactivities`, the same title/caption value shape as the four above it, drawn through the same `actionRow` helper and the same `isImporting` bracket. **It is deliberately not a case on either importer above it**: `WhoopExportImporter` and `ZeroFastingImporter` both write `workouts`, and this one writes `receptive_inactivities` — a table whose rows have no span, no strain and no measurement of any kind — so folding it in would mean one importer writing two tables and answering a summary about one of them. **It is the second import here that skips no day**, and its caption restates that rather than inheriting the fasts' sentence: the two arrive at *a deleted row comes back* from opposite directions, and this one adds a second consequence of its own — re-importing writes the file's text back over any edit, because the note is what the row's id is derived from. **The caption's "carries its text" clause replaced one that promised the opposite.** It first read that the text stays in the file rather than in the app; the owner's reversal — *"text will be added to another screen, receptive inactivity detail page"* — made that false, and `v22`'s `note` column is what makes the new wording true. The page that will *draw* the prose is not built yet, so the text is stored now and the Home tile keeps opening `ReceptiveInactivitySheet` in edit mode, where it can be read and changed. **§18 pins the header literal, the title, the caption's presence, and that the caption names `InactivityImportAction.fileName`** (`"dreams.json"`), and that constant is kept separate from `InactivityImporter.bundledResourceName` for `FastingImportAction`'s reason — the name on screen and the name of the resource answer to different readers, so a rename of one cannot drag the other.



**`Whoopsy` is the third section on this pane and it is this app's own record going *out*, and it replaced one called `Local backup`.** The instruction is exact: *"instead of "Local Backup", lets add another section called Whoopsy to export whoopsy data, which would be everything from wherever user stores their data, local or a database"*. **Both changed words are corrections rather than renames.** `Local` was a claim about where the data lives, and the file holds it wherever it is stored — the SQLite database *and* the `UserDefaults` beside it. `Backup` was the consequential one: it promises a restore this app does not have, since nothing in `ios/Sources/` reads an exported file back, so the honest word is `export` and the caption says so on its face rather than leaving a reader to find out. **The header names the producer, like the three above it** — `Apple Health`, `Whoop` and `Zero Fasting` each name the app a file came *from*, and this section sits on the other side of that line — so `WhoopsyExportAction.sectionTitle` is a constant the runner can read rather than a literal in a `body`. Its one row is `WhoopsyExportAction.export`, the same title/caption value shape as the five imports above it, for the same reason (the runner has no renderer, so words typed into a `body` are words nothing can assert), and it is deliberately **not** a `[WhoopsyExportAction]`: one button writes the whole record, and a second beside it would be a second definition of what the record is.



**"Local or a database" is the load-bearing half, because this app stores data in two places and an export reading one of them would be a smaller file than the button claims.** The database goes out through `LocalDatabaseSnapshotting`, whose one implementation walks **`sqlite_master`** rather than a list of tables written into the exporter — so a migration that adds a table is exported with no edit and cannot land unexported — and the columns are read off each row rather than off a record's `CodingKeys`, which is the one reading that is right about both of this schema's two naming conventions (`RecoveryRecord` declares snake_case columns, `StrainRecord` is camelCase). The settings go out beside them from `AppPreferences`, which is `UserDefaults`-backed and a row in no table: the unit choice and the three toggles, including the anonymous-diagnostics switch that is the whole of the Settings page. `LocalExportResult.message` is the exporter's own sentence about what it wrote, on `WhoopImportSummary.message`'s precedent, and `exportData()` brackets **no `isImporting`** where the five imports above it do — they change a database under the reader and their spinner is honest about it, while this only reads one, and an `Importing…` caption over an export would name the wrong direction.



**The share rows are cards, and getting them there meant extracting `cardLabel` out of `actionRow`.** The restyle was offered for this row alongside the fasting one and only the fasting half was taken up, which left the export as the one plain `Form` button in a column of cards; `actionRow` now draws `cardLabel` and the section's two `ShareLink`s draw it too. That also moved `.foregroundStyle` and `.background` off the buttons and onto the label, which is load-bearing rather than tidy — a `ShareLink` is not a `Button` and would not have inherited either. **§6 pins the export's own block and §18 the section's identity**: that the exported table set equals `existingTableNames()`, that the JSON's `tables` and the result's `rowCounts` name the same tables, that every exported row carries its own table's columns, that the settings ride beside the tables, and that the header, the title and the two promises the caption makes are the ones written here. **The card treatment itself is the reader's to check on a phone**, since the runner has no renderer.



**The device page is one page reached from one place — Home's status badge — and it was two.** `DeviceSettingsView` (More → Device) and `DeviceDetailView` (Home's status badge, the real page) duplicated three rows between them and had already drifted apart: the old Settings page printed `viewModel.device?.batteryPercentage ?? 0`, so a strap that was merely *discovered* read `100%` and one that was absent read `0%`, where the detail page had the correct `connectionState == .connected` gate. `DeviceDetailView` and `DeviceDetailViewModel` are **deleted**, and the one `DeviceSettingsView` is what both entry points pushed — **More's `Device` row has since been removed, so Home's badge is now the only route**, and the merge is what makes that cost nothing rather than costing a screen. **They push one view model instance, held as a stored `let` on `MainContainerView` and built in its `init`** — `body` is a `ViewBuilder` and re-evaluates, so a computed one would be rebuilt per pass while `HomeDashboardView` holds it as a plain `let` whose `.task` never re-fires, and the badge would go blank. Building it in `init` is legal because `View` conformance makes the type `@MainActor`-isolated. **`MoreView` used to take it as a parameter for the same reason the plan named it an anti-pattern to construct one in a `NavigationLink`'s destination closure**: that closure is re-evaluated on every push, so an inline one would lose the device subscription every time and start another. **That row is gone and the reason is not** — the surviving route is the one holding the view model as a plain `let`, so the per-pass rebuild this guards against is untouched by the row going. The page is a `Form` whose header is **two columns** — `NOT CONNECTED TO / WHOOP DEVICE` on the left, `LAST SYNC` right-aligned beside it — above **underlined text tabs**, over `STATUS` and `ADVANCED`. The tabs were a **segmented `Picker`** until the reference was matched, and the underline rule is **drawn on both tabs and filled on one** so the row's height does not change with the selection. `DeviceSettingsView.subject` (`"WHOOP DEVICE"`) is a constant on the view rather than a sixth field on `Hero`, because it is one value in all six arms and six copies are six places to drift — §14 asserts it equals no arm's `stateWord`, which is what fails if the header starts saying the state twice. Below the tabs sits the reference's illustration row, which is **`StrapGlyph` badged with a plus**, joined by a dashed line to a circled X — the row's drawing is the reference's, its branding is not, so the strap photograph is replaced rather than imitated. **`StrapGlyph` is the one place the strap's mark and the badge's corner rule are defined, and it now has four readers**: this row, Home's status badge, which badges the same mark with a connection dot instead, and the `PAIR A DEVICE` / `UNPAIR DEVICE` cards on the ADVANCED tab, which badge it with a `plus` and a `minus`. That is what closed a real drift — the two screens drew *different* symbols while this page's own comment claimed they drew the same one, and nothing could see it, because a wrong symbol draws a different picture rather than an error. **The disc that badges the mark is `StrapBadge`, a separate non-generic type, and that split is a language constraint rather than a preference**: `StrapGlyph` is generic over its badge, and **a generic type cannot hold a static stored property**, so the two constants that size the disc (`discSize` 13, `signSize` 8) cannot live on it — which is why the mark itself is a `StrapMark` enum beside it and the disc is its own type. `StrapBadge`'s only parameters are the `sign` and the `surface` it knocks its glyph out of, so the three readers cannot vary the corner rule. **The badge is placed by the alignment alone and must never carry an `offset`** — one was tried and moved the mark. STATUS carries the caption and `SYNC HISTORY`, and **no longer carries a `Strap` section at all**: the connection and battery rows were removed on the user's instruction once the caption above already stated the connection, and `PAIR A DEVICE` moved to the ADVANCED tab, where the reference draws it. `batteryText(for:)` survives that removal **unrendered**, with its §14 assertions intact — the `ActivityDurationBar` precedent: no test discovery means deleting it would drop five passing assertions whose only trace is a falling `assertions=` count. ADVANCED carries the model `Picker`, the sync section and its per-generation `protocolCaveat`, the `BROADCAST LIVE HR` toggle, a **three-fact row** (`DEVICE ID`, `FIRMWARE`, `SIGNAL`) that replaced the old `DIAGNOSTICS` section, `PAIR A DEVICE` (which is `scan()`: `didDiscover` connects to the first matching peripheral, so there is no discovery list to draw), and `UNPAIR DEVICE`. **`UNPAIR DEVICE` is a disconnect and not a forget, and its caption says so** rather than repeating the reference's *"This will remove the Bluetooth connection."* — `disconnect()` reaches `cancelPeripheralConnection`, which ends the link and leaves the stored model choice (keyed on the peripheral identifier) untouched, and `didDiscover` re-links on the very next scan. It is gated on `isConnected` rather than `hasDevice`, because `didDisconnect` leaves the device object with its identifier intact — and the reference draws that row dimmed, which is exactly this state. **Which figures have a producer changed with the fact row, and it is not the same verdict per fact.** `DEVICE ID` is **Populated** — `WhoopDevice.id`, the CoreBluetooth peripheral identifier written at discovery, and the key the model choice is stored against. `SIGNAL` is **Partial** — the advertisement's RSSI, real but read once at discovery and never refreshed, which its footer says. `FIRMWARE` is **a reading when the strap has answered and a dash until then** (`firmwareVersion` is a `String?` defaulting to `nil`, filled from the Device Information Service's `2A26` read). `SERIAL`, which the reference's rows imply, was dropped with the `DIAGNOSTICS` section. `LAST SYNC` is the newest stored sample (`BiometricRepository.getLatestSample()?.timestamp`), a real producer that reads `—` until a strap has sent this app a sample and shows the newest arrival after that. **The fact row carries three items where the reference draws two, and that is a deliberate deviation to report rather than a miscount**: `SIGNAL` is the row's only reading with a real producer, so dropping it would leave the row entirely dashes. Removing it is a one-line change to `DeviceFact.allCases`. `factValue(_:device:)`'s `named(_:)` helper rejects an **empty id**, and that guard is load-bearing rather than defensive: the scanning placeholder (`WhoopDevice(id: "", name: "Scanning...", connectionState: .scanning)`) is the only object holding the entity's defaulted `-65` RSSI, so without the guard the row would print a fabricated `-65 dBm` while the app was merely looking for a strap. The mockup's red cloud-X depicts *sync failed*, which nothing here can detect, so it is drawn as `arrow.down.circle.dotted` in `Theme.recoveryRed` **exactly when `lastSync == nil`** — a cloud glyph would be a false claim about this app's architecture, which has no cloud. **The mockup's X-close is deliberately not drawn**: the page is *pushed*, so it already carries a back chevron top-left, and an X beside it would be two dismiss controls on one page. The ⓘ is dropped for the same kind of reason — the protocol caveat it would open is on the ADVANCED tab, and a second route to the same words is what that tab exists to avoid. `hero(for:)`, `batteryText(for:)` and `lastSyncText(_:)` are `nonisolated static`s on the view and the tab is a plain `CaseIterable` enum, for this repo's standing reason: the runner has no renderer, so copy and branching written into a `body` are things nothing can assert.



**Home's day-bar row carries two controls, one at each end, and they are the same arrangement.** The **profile control** leads the row and the **status badge** trails it, so the row reads reader → day → hardware, and both are `NavigationLink`s to a page that **had** a row behind More until the user removed it — so each of these two controls is now the only door to its page, and neither may be read as decoration. **They share one shape and not one definition**: each is one glyph on a `Theme.homeCard` surface with a label and a hint, but the badge is a **capsule** because it carries a glyph *and* a battery figure while the profile control is a **circle** because it carries a glyph alone — and the circle's `36` is the badge's own height, so the row's two ends sit level. Neither carries a chevron, which is the user's own instruction on the badge and is followed here for the same reason: a control that looks tappable and is not reads as broken, so what makes either destination reachable without sight of it is its hint. **The profile glyph is `person.crop.circle` and not `person.fill`** — this app has no avatar and no photograph of anybody, so a filled glyph would be a silhouette of a person it has never seen, while the cropped circle is the shape every platform already uses for "your account". Its availability is **checked against the SDK's own `name_availability.plist` rather than assumed** (`2019` → iOS 13.0, under this app's 17.0 target), and the check is not ceremony: a symbol name that does not exist on the deployment target draws an empty circle rather than raising anything, which is the trap `ActivityGlyph`'s paragraph records.



### `LOGS` ends in the app's only delete, and it deletes from the database first

The pane that says where a history comes from and where it goes ends with the one control that asks
for part of it to stop existing: a `FROM`/`TO` pair and a red `DELETE`, below every import and export
rather than between them. **It is last because that is the order the risk is in** — the rows above add
to a history and this one removes from it.

**Two dates rather than a "before this day" control**, and the difference is a footgun rather than a
preference: the owner's own case was three days in the middle of a two-year history, and a one-ended
control would have taken everything earlier. The range is inclusive at both ends, capped at 31 days,
and the caption names the scope — *recovery, sleep, strain, steps, naps, motion and heart-rate samples*
— beside what survives it: **activities, fasts and notes dated inside the range**, because those are
things the owner recorded rather than measurements a calibration produced.

**What it removes is the inputs, not only the answers.** A purge that deleted `recoveries` and left the
samples would be undone on the next foreground, when `RefreshRecoveryUseCase` finds a night whose edge
is past the stored watermark and folds it again. `LocalDatabaseManager.purgeMeasuredDays` takes all
seven tables in one transaction for that reason, and the `DayPurgeTally` it returns names each one so
the status sentence can say that the samples went with the scores.

**The database is called first, and a failure there deletes nothing here.** This is the pane's one
refusal rather than the local-first degrade every other cloud call does, for the reason
`docs/GOTCHAS.md` records: a local delete while the destination is the API is a *cache eviction*, and
the day comes back. `PurgeDaysUseCase` therefore calls `CloudSync.purge`, throws
`Refusal.cloudFailed` on any failure, and never reaches the store — and the sentence it prints says
nothing was deleted rather than reporting a partial success.

**The confirmation is the pane's only one.** `confirmationDialog` is the idiom the device page's two
hardware commands already use, and its title is a value on the view model — `"Delete 3 days? This
cannot be undone."` — rather than a literal in a `body`, so the runner can assert the number the reader
is shown is the number the range covers.

### There is exactly one recording path, and it starts from the +

**There is exactly one *recording* path, and it starts from the `+`.** `START ACTIVITY` opens `ActivityPickerView`, and the name it hands back is what the session records — that path is the only path that reaches `SaveWorkoutUseCase` and one of the two ways a `workouts` row is created, the other being the menu's measurement-free `ADD ACTIVITY` below. **The picker is also the only way to start a fast**, because `WhoopActivityCatalog` holds `Fast` and no menu row starts one; without that, the whole feature is unreachable. `HomeDashboardView.startSession(named:)` forks on `ActivityFigure.isFastName` — a fast goes to `startFast()` **and pushes nothing**, because the bar is its live indicator and its page is one tap away on that bar, while every other name goes to `start(name:)` and pushes `LiveSessionView`. Only the push is gated on `isRunning`; the fast path needs no such gate, since `startFast()` is idempotent and its bar is drawn from `activeFast`. **The fork is dispatched one turn later than the pick is read, and that hop is load-bearing**: the picker's row sets the binding and calls `dismiss()` in the same statement, so `NavigationStack` is asked for a pop and a push in one update, processes one transition per frame, and drops the push with the flag left `true` — which strands the hidden tab bar over a screen that never appeared and lets the next unrelated `true` push the session spuriously. **The `+` is the only way to *begin* a recording; it is no longer the only way to reach the screen.** The red bar below pushes the same view off the same use case, so a session the reader backed out of is one tap away — see the bar's own paragraph below for why that is a second route and not a second path. The activity detail page is the table's other mutator in both directions: its `Delete` removes a row and the children filed under it — the only destructive operation in the app — and its `EDIT ACTIVITY` sheet rewrites one in place through `WorkoutRepository.save`, which is INSERT-or-UPDATE by primary key, so an edit keeps the row's `id` and its day. `ADD ACTIVITY` is the table's **second creator**, and it is the one that writes a row no sensor produced: the row presents `AddActivitySheet`, whose `AddActivityDraft` clamps a picked name and a required start and end into a `WorkoutSession` carrying `WorkoutSession.manualSourceLabel` with nil strain, both heart rates absent, and no route, splits, zones or steps, and `HomeViewModel.saveActivity(_:on:)` writes it through `workoutRepository` before merging it into Home's day. **That page's one control is a map choice between `USE LIVE MAP` and `USE OFFLINE MAP`, both off by default**, and either choice starts the session's route: turning one on asks for location permission and streams GPS fixes into the session, each stamped with the heart rate in force at that moment. **What that toggle records is now drawn**, by a `ROUTE` map section at the bottom of the page — below the heart-rate panels and below both layouts, which is where the user asked for it — while `workout_splits` still has no producer at all, because there is no lap model. The section is **absent with no note** when the session has no route — which is every session this machine can show — **except a session that downloaded an offline map without recording a route**, which draws an `area` card in the same slot. That is the second reason the page has a map at all: a session can hold a `.ready` region whose route never reached two fixes — an indoor session, or one stopped before the GPS settled — and would otherwise get a row carrying an id and centre with no ground drawn anywhere. The area card is the route card minus the path **and minus the caption** — same `SectionLabel("Map")`, same 220 pt height and corner radius, same accessibility treatment, with the map drawing into the whole 220 because an area has no distance or speed to print and a bar of two dashes would claim two measurements — framed by `ActivityOfflineArea` on the persisted centre and drawn by the same renderer decision, so `.ready` is still the only state that draws offline and every other state draws the `MapKit` box. It is **absent, with no note, when there is no route *and* no area** — `zoneSection`'s precedent, a block simply not drawn, rather than `noHeartRateNote`'s always-drawn slot with a sentence in it — a note here would be a permanent fixture on every session and would have to name a toggle most readers never see. The rules live on the value and not in the map's `body`, for this repo's standing reason: **§19's route block is a pure value with no database behind it**, so it still asserts if a database block below it throws. **The card is a map with its caption *under* it, not an overlay on it, and the two `Annotation` titles are not drawn — both are measured corrections rather than styling.** The reference lays its figures over the map's foot, and that is what this was first built as; it does not survive contact with a real route. An overlay claims a fixed slice of a fixed height while the path's bottom margin is `spanPadding`'s share of a frame the map is free to widen, so the two are set against each other and the flag loses: measured on the iOS 26.5 simulator against a recorded route, the polyline's lowest drawn pixel sat at **171.3 pt of the card's 220** and the caption's top edge at **172.0**, so the 19 pt finish marker — centred on that point — was drawn under an 86%-opaque bar with the word `Finish` showing through it over the caption's own figures. The card therefore divides its 220 pt instead: `captionHeight` is 48 and the map draws into the 172 above it, which makes the two independent. That split also had to state a constant, because a `Map` has no intrinsic size and will not negotiate for the remainder — the bar is free to exceed its 48 and grows the card rather than clipping a figure. `.annotationTitles(.hidden)` removes the two words, which the reference has nowhere: it marks a route with a dot and a checkered flag and sets no text beside either. **That modifier is a `MapContent` modifier and not a `Map` view one** — it is declared on `MapContent` in the `_MapKit_SwiftUI` overlay, and a `MapContent` builder has no `Group` to hang it on — so it goes on each `Annotation` separately and a `Map`-level `.annotationTitles` is not a compile error away from working, it is simply not a member. The titles stay words rather than empty strings because hiding is a *display* modifier: it stops the drawing while leaving each mark described in the view tree.



**`LiveSessionView` carries two toggles — `USE LIVE MAP` and `USE OFFLINE MAP`, both off by default — and they are a choice between two maps rather than two features.** Either records the session's route, and choosing one releases the other, because two maps are never drawn at once. The wording is the user's own correction of a first version that called the live one `RECORD ROUTE` — *"record route is bad wording, maybe should be 'USE LIVE MAP', they both record the route, just one is offline the other is live"*. It exists because of the user's own hike (*"i encountered the map issue for connectivity, let user decide if they wont have coverage in region"*), so the decision is theirs and is made **before** signal is lost — never inferred from a connectivity check, because the failure being defended against is the one where there is nothing left to check with. The division of labour is one sentence: **The map choice is what produces the path** — the route starts with either toggle and stops when the last one goes off, and `workout_route_points` has no other producer; **the chosen map decides which SDK draws it**, on whichever of the activity detail page's two map cards the session has — the route card when there is a path, the area card when there is not — and the same renderer decision governs both. The offline card is a Mapbox tile region downloaded around the session's first GPS fix — a 10-mile radius capped at z14 — and a card draws it only while that region is `.ready`. **Every other state draws the `MapKit` card this page always drew**, which is the safety property the whole seam is shaped around: the worst outcome of a failed download is the old behaviour, and never a blank frame. Because both maps record the route, the offline switch starts the route too: the fix that centres the region is the route's own first point rather than a second GPS stream, and the path keeps running after the download. **The switch is offered only where an offline map is possible at all** (`OfflineMapRendering.isSupported`, `false` on every build whose `MBXAccessToken` is not a public token — an empty value, which is what a clone that never created the gitignored `ios/App/Config/Whoopsy.local.xcconfig` gets, or a secret pasted into the wrong file), so a clone that has not been through `README.md` §Building shows one toggle rather than two that half-work. The region's id is stored on the session's own row (`workouts.offline_region_id`, `v19`) and is `NULL` for every session recorded with the switch off, which is most of them. **So is the centre the download was taken around** (`offline_region_center_latitude`/`_longitude`, `v23`), because Mapbox's `TileRegion` carries no geometry to read back — and it is the reason a route-less session can draw an area at all. Those two columns are **local-only**: a tile region belongs to one phone's tile store, so the sync row drops them and a row arriving from the server stores `nil`. The page's `offlineArea` requires both the region id and the centre, so a row recorded before `v23` truthfully draws nothing.



### And the + is on every day; only the recording row is not

**And the `+` is on every day; only the recording row is not.** `ActivityMenu.entries(on:now:recording:)` forwards to `DayBarRules.isToday`, so paging back through the calendar to a day that already happened — or forward to one that has not — still opens the card and still lists `ADD ACTIVITY`, and withholds `START ACTIVITY` alone. The rule is a named, assertable policy rather than a comparison in the view for `DayBarRules`' own reason: the runner has no renderer, so a test written into a `body` is a test nothing can make. **There are two reasons the row is withheld and they answer different questions**: `DayBarRules.isToday` asks *is this a day a session can be started on*, and `ActivityMenu.Recording` asks *is something already recording*. The second is a plain input to `entries` rather than a read of the live use case inside it, so it stays a value the runner can assert, and `HomeDashboardView.recording` derives it — `.activity` while `isRunning`, `.fast` while a fast is running, `.none` otherwise — so there is no second copy of the live state to go stale behind the use case's. **The asymmetry between those two cases is the user's own rule: a fast does not block an activity.** `.fast` returns today's list byte-identically to `.none`, so 18 hours into a fast the app still offers a run; `.activity` is the only state that withholds the row, and it does so because there is no second recording to be had. `recording` is appended **after** `now:` rather than before it, so the six existing call sites keep their argument order, and its `.none` default is what leaves the identity assertion against `DayBarRules`' own answer untouched. **The row is withheld, not the button hidden**, and two things decide that. `ADD ACTIVITY` is offered on every day — it files onto the day being viewed, so a past day is exactly where a forgotten walk belongs, and nothing about it contends with a live session for the strap — and a `+` that vanished on every day but one would take that row with it and leave the header with no route to the menu at all. **The row is dropped rather than greyed out**, so a past day shows no disabled `START ACTIVITY` for a user to tap and wonder about. A day's *existing* activities are untouched: the rule is about starting a session, and an ended one is a row like any other.



**`ADD ACTIVITY` opens a sheet, and everything it decides is in `AddActivityDraft` rather than in the view.** The sheet's `NAME` row pushes `ActivityPickerView` — the same picker `START ACTIVITY` writes its binding from, now carrying a **`Strain` / `Recovery` segmented switch** so the recovery half of the catalogue is one tap away rather than below ~150 strain rows — and under it sit two required compact `DatePicker`s, `Start Time` and `End Time`; `SAVE` is dark until a non-blank name exists and lights the moment one does. The draft snaps the day at `init`, seeds noon to one hour by elapsed seconds rather than from `Date()`, rebuilds both picked instants onto that day through `Date.clockTime(on:)` — a `DatePicker` hands back today's date with the picked clock time, which would file yesterday's walk on today — clamps the window between `startOfNextDay − 60` and `startOfNextDay`, and carries the end to `start + 60` when the start is dragged past it rather than inverting the window. **Both times are required where the receptive sheet's are optional, and the subject is the reason**: an activity with no start has no band on the day's card and no duration to print, while an untimed meditation is a row that legitimately happened. The row it writes carries `manual` as its `source` and no measurement at all — nil strain, nil heart rates, no route, splits, zone block or steps — so it is distinguishable from a `nil` source, which is what `LiveSessionUseCase.end()` writes for a session the strap watched. `recordedWorkoutDays()` excludes `manual` along with every fast label through `WorkoutSession.measurementFreeSourceValues`, so adding a walk before importing the export does not make that day look recorded and silently drop the file's rows for it. `HomeViewModel.saveActivity(_:on:)` writes through `workoutRepository` and then merges the row into Home's day, the same `updateWorkout` path the live session's `onEnded` uses.

**The card below `ACTIVITIES` records the opposite of an activity, and its whole shape follows from having no end.** `RECEPTIVE INACTIVITIES` is a second card on the same chrome, holding the states where conscious exertion drops to zero and the internal, subtle, autonomic data gets processed — a dream, a meditation, qigong. A row holds a **name** and an **optional start time** and nothing else, because there is nothing else to hold: with no `endedAt` the type has no span, so it cannot `covers(_:)` a day, cannot be in progress, cannot have a duration and cannot aggregate into a zone block. **That is why it is its own table (`v21_receptive_inactivities`) and not a row of `workouts`** — `started_at` and `ended_at` are `NOT NULL` there since `v6`, and the half-open overlap read the `ACTIVITIES` card is built on depends on them. **It is also why the repository has one read and no `covering:` sibling**: that second read exists for a session that can still be underway at a day's midnight, and nothing here can be. **The day comes from the day on screen and not from the optional time** — the picker's hour and minute are rebuilt onto `selectedDate`'s own year/month/day before the write, which is the invariant that makes `date == startOfDay(startedAt)` true whenever a time is given, and is exactly why `saveNap` is *not* this table's precedent. The card draws on every day including empty ones, and its empty state gets **its own** sentence rather than repeating `ACTIVITIES`' — two identical lines stacked is worse than one. Its rows are added and edited through the same `+` the card above it uses: `ADD RECEPTIVE INACTIVITY` is the menu's third row and is offered on **every** day, because a meditation is filed onto the day it happened rather than onto today. **A row can also be imported**, from `LOGS`'s fourth section: `IMPORT RECEPTIVE INACTIVITIES` reads the bundled `dreams.json` and files all 62 of its entries on their own days as `Dream` rows, every one of them untimed. **And a row now carries text** — `v22`'s nullable `note` holds the entry's own prose, written by that import and editable in the sheet — which is both the value the receptive inactivity detail page will draw once it exists and the input the row's id is derived from. **Nothing on this card is measured** — no strain, no heart rate, no steps, no route — so a defaulted number on a stored row is the fabrication every absence rule here forbids, and the only figure a row prints is its own clock. **A row with no time draws *nothing at all* in that slot, not a dash**: `receptiveInactivityRow`'s trailing figure is an `if let startedAt` with no `else`, which is why every imported dream draws a bare name and no clock, and why importing untimed is the honest drawing of a file that carries no times. **The prose is deliberately not on the tile** — `no text for tile on home page`, the owner's instruction — so the card shows the name and nothing else, and the text lives one tap away in the sheet that the row opens.



**A live session draws a bar across the very top of Home, and its whole rule is one plain value.** `LiveSessionBar` (`Presentation/DesignSystem/Components/`) holds no drawing — `HomeDashboardView` builds the bar, exactly as `ActivityDetailView` hand-builds `ActivityOverflowMenu`'s rows — because the runner has no renderer, so a gate written into a `body` is a gate nothing can assert. What is left is *which session the bar is about* (`subject(isActivityRunning:activityName:activityStartedAt:activeFast:)`), *what colour it is* (`LiveSessionBar+Extensions.swift`, the fifth value-into-a-colour file and the first that maps two answers at once), *what mark it leads with* and *what it says* (its VoiceOver label and hint). **The mark is the activity's own glyph, in front of the clock**, read off `Subject.mark` — the subject's `name` through `ActivityGlyph.mark(for:)`, the app's one name-to-mark mapping, so the bar's icon and the `ACTIVITIES` card's chip cannot draw one activity two ways, and a fast draws the composite `fork.knife` + `timer` rather than the running figure a `mark(for: nil)` would give it. **It takes `subject.ink(at:)` like the clock and must not be pinned to white**: `inkDepth` exists because white is invisible on the `ketosis` fill and near-invisible on `fatBurning`'s, so an icon in a fixed colour would vanish on two of the five zones while the timer beside it stayed legible — a mark missing from a bar that otherwise looks correct. Measured on the simulator at 20 h: the fill `#FFCC00`, both symbols drawn in `#12141A`, and the bar still 27.7 pt tall, so the mark does not grow it. **The subject's `now` is on the extensions and never on `subject`, and that split is load-bearing rather than tidy.** `HomeDashboardView` reads `isRunning`/`startedAt`/`activityName`/`activeFast` in its `body` — that read is what registers the `@Observable` dependency — while the clock is a `TimelineView(.everyMinute)` around it. Passing `now` into the one function that decides *both* whether the bar exists and what colour it is would force that call inside the timeline closure, attributing the dependency to `TimelineView` instead of Home, and the bar would then survive END for up to **60 seconds**. Existence is `body`; colour is the timeline. Five things about it are decisions rather than detail. **The gate is `isRunning`, not `startedAt != nil`, and the two are different questions**: `LiveSessionUseCase.end()` clears `isRunning` at its top and `startedAt` only in `reset()`, which runs from a `defer` after the lock-screen card has been ended and the `workouts` row written — two awaits later — so a bar keyed on the instant alone would go on counting over Home for the length of a database round trip after the user pressed END. The `startedAt` clause beside it is not decoration either: the visible clock is drawn *from* an anchor, so a running session with none has nothing to draw and is withheld rather than drawn as `--:--`, which is `LiveSessionView`'s word for a session that has not started. **An activity wins when both are live** — the user's own rule, and the bar draws `.activity` for as long as one records, offering no sign that a fast is running underneath. It has to be `isRunning`-first for `end()`'s reason, and the fast takes over the moment the run stops with its own original anchor. **The two subjects are two colours and two destinations.** `.activity` keeps `Theme.recoveryRed` with white letters — *"a regular activity will have that red timer on home page"*, the user's words — while `.fast` takes `FastingZone.color` and `FastingZone.inkColor` off the zone the fast's **whole elapsed span** falls in, so the bar walks `ANABOLIC → CATABOLIC → FAT BURNING → KETOSIS → DEEP KETOSIS` over three days. The ink is not decoration: white is invisible on the `ketosis` fill, which is the whole reason `inkDepth` exists. And the tap forks — the activity subject pushes `LiveSessionView`, the fast subject pushes the fasting detail layout through `makeActivityDetailViewModel` — so `accessibilityHint` is a function of the subject rather than the constant *"Opens the activity session"* it used to be, and the label speaks the session's own name (*"Basketball recording, 12 minutes 34 seconds elapsed"*) rather than the word `Activity` for every session alike. **A live fast is the one subject whose projection cannot be recomputed on demand**: `projectedSession(now:)` mints a fresh `UUID` per call, so `HomeDashboardView` stores it in `@State` at tap time — recomputing it in a `navigationDestination` closure would change the item's identity on every body evaluation and tear the page down and rebuild it. **The day is deliberately not consulted**, though `HomeDashboardView.selectedDate` pages through history: a recording is about now, so the bar belongs on screen on a day in 2024 exactly as on today, and a gate that read the day would make it vanish on every day but one — the same mistake `ActivityFigure`'s fasting rules record against reading `DayBarRules.isToday` where the subject is the session's own state. **The clock is the system's** (`Text(_:style: .timer)`), so it ticks with no `@State` and keeps counting while the app is suspended; `TimelineView(.everyMinute)` is there for the accessibility label and the colour. The colour is therefore up to a minute late at each zone boundary, which is a per-second timer for a colour that changes four times in three days. **The bar is a sibling of the scroll view inside a `VStack(spacing: 0)`, not an overlay, and that is a layout fact rather than a preference**: the collapsed rings header is an `.overlayPreferenceValue(…, alignment: .top)` on the scroll view, which aligns to that view's *frame* and therefore to the top of the screen — so an inset or overlaid bar would be drawn *under* the header, and the only alternative fix would be a bar-height magic constant. The `RingsBottomKey` preference is unaffected, being anchored to the scroll view itself. **Its fill passes `ignoresSafeAreaEdges: []`, and dropping that argument silently doubles the bar.** `Theme.recoveryRed` is a `Color` and so takes `background`'s `ShapeStyle` overload, whose `ignoresSafeAreaEdges` **defaults to `.all`** — a bare `.background(Theme.recoveryRed)` bleeds the fill up through the top safe area, and the bleed scales with the device's inset, so the bar is a different height on every phone. Measured on the iOS 26.5 simulator: the bar's text box sat correctly at 62.3…90 pt while the red ran 0…90 pt, drawing a 90 pt red slab behind the status bar with the clock stranded near its bottom, and the symptom reads as a styling choice rather than as a bug. **The bleed is worse now than it was**: it would be a slab of the *zone's* colour rather than of one token. It is **full-bleed** and so the one thing on this screen outside the 16 pt gutter, and it lives **inside the `NavigationStack`** so a pushed page covers it — which is what keeps it on Home alone, since `LiveSessionView` draws its own banner and the activity page's `•••` is anchored to the bottom edge.



**A workout row on Home is a `Button` that sets `presentedActivity`; the `SLEEP` row beside it is a `NavigationLink`.** It and the sleep ring opened one page until 2026-10-28; the row's page was then reduced to the reference's mock and the user's correction was *"i didnt want that link touched, only the sleep activity / tile"* — so the row opens `SleepDetailView` and the ring opens `SleepPerformanceView`, two expressions rather than one. The user's instruction is that the two are one page — *"the sleep ring will link to same page that sleep shows on activity sleep tile"* — so both call sites read one `private var sleepDetail` rather than two literals that agree today, and a change to what that page is cannot reach the ring and miss the row. **Both are drawn by the same `HomeDashboardView.activityRow` helper, and the helper is still not wrapped** — only the `ForEach(viewModel.workouts)` call site is, and the `SLEEP` row's link goes around its own call, where the night is in hand: a sleep row is built from a `SleepSession` and has no workout behind it, so wrapping the helper would give it a destination that does not exist. That is the same no-control-without-a-destination rule that keeps the ACTIVITIES expand icon and the chevrons off this screen — and the row reaching a page is that rule *satisfied*, not an exception to it. **The two rows push by different mechanisms, and the tab bar is why the workout rows need theirs**: `.hidingTabBar` works only from a tab's *root* view and does nothing on a pushed destination, silently, so the flag that hides the bar while the activity page's bottom-anchored `•••` menu is up has to live on Home — and a view-based `NavigationLink` publishes no flag for Home to read, so those rows are a `navigationDestination(item:)` fed by `presentedActivity`. `SleepDetailView` has no such control and is the rings' own shape, so its row is an ordinary `NavigationLink` with `.buttonStyle(.plain)` — the rings' reason for that style applies here too: the default styles tint the label and add a hit shape, which would recolour the moon chip and the duration beside it. **The `item:` binding requires a `Hashable` item where a `NavigationLink` requires none**, which is why `WorkoutSession: Hashable` is spelled out on the entity — the link the `SLEEP` row uses needs no such conformance, since it carries no item. `ActivityDetailView` is still the pushed-page shape: no `NavigationStack` of its own, the session taken as a plain `let` on its view model, so a re-render of Home behind the push cannot re-point it at another session.



**That page's `•••` opens a bottom-anchored menu of full-width rows, and `Delete` in it is the app's only destructive control.** Tapping it dims the page over a `0.45` black scrim and raises `Edit` / `Delete` / `Cancel` as full-width rows of one height in **two** cards — `Edit` and `Delete` together under a hairline, an `8` pt gap showing the dimmed page, then `Cancel` alone — with both cards ending at the safe area, so `Cancel` is its row and only its row and the dimmed page shows below it, and both cards rounded on all four corners by one `cardCornerRadius`. **It is hand-built and not `confirmationDialog`, and the user is the reason**: the page was first implemented as the system's action sheet on the reasoning that the reference *is* one, and the instruction to put the three rows "at bottom … width of screen" is a shape the system's sheet does not draw — it insets them in a centred card with a detached Cancel card. The rows, their order, **their grouping into the two cards** — which is what puts the gap between `Delete` and `Cancel` and nowhere else — which of them is destructive, and all three layout constants live on `ActivityOverflowMenu`, a plain value the runner can assert, because a rule written into a `body` is a rule the runner (which has no renderer) can never check. `Delete` removes the session and everything filed under it (`workout_route_points` and `workout_splits` by `workout_id`, explicitly, mirroring `saveWorkout` rather than trusting the cascade) and then pops to Home, calling the `onDeleted` closure the pushing screen supplied. Home drops the row locally through `HomeViewModel.removeWorkout(_:)` rather than re-reading the day: whether a `.task` re-fires when a destination pops is undocumented, and no other figure on Home is built from a workout. **`Edit` opens `ActivityEditSheet` — the app's first `.sheet`, since joined by `ReceptiveInactivitySheet` and `AddActivitySheet` — and `Delete` is not durable against an explicit re-import.** The sheet is a real sheet rather than one of this repo's hand-built overlays, because the reference *is* one and an editing surface is something the reader goes to and comes back from — Home's calendar is read *against* the day behind it, which is the case the overlay convention exists for. It owns a `NavigationStack`, legal because it is presented rather than pushed, so the activity row's chevron pushes `ActivityPickerView`. Both controls on it — the trim chart's handles and the two `DatePicker`s — write one `ActivityEditDraft`, and `SAVE` on an untouched sheet dismisses without writing while a failed write does not dismiss.



**All four import paths that draw on the WHOOP export now skip a day that already holds data, so an edit survives a re-import.** The workouts path gained that skip last, and it is why `importWorkoutRows` computes its day set once before the loop rather than growing it — the file's 673 rows land on 445 distinct days, so a set updated during the walk would write 445 sessions and lose 228. **The Zero fasting and receptive-inactivity imports are the two paths that do not**, and each caption states it in its own words rather than inheriting the other's: a fast's id is disjoint from every other producer's, so a fast write can only touch a fast row and a skip would drop fasts on exactly the days the two files overlap; an inactivity's id is derived from its own note, so re-importing restores a deleted row rather than colliding with a measured one. **`Delete` is still not durable on either**: a day whose only workout was deleted is empty again, so the export's row for it comes back, and a deleted fast comes back on the next press of its own button. Both captions say so, and each restates it rather than inheriting it, because the two imports have different reasons for the same behaviour.



### The no-control-without-a-destination rule has no exception left, and it had two

**The no-control-without-a-destination rule has no exception left, and it had two.** The `•••` was drawn inert while the page was matched to its reference, and the `Edit` row was drawn inert from the user's *"edit we will wire later"*. Both have destinations now, so anything added to a screen without one is the bug the rule describes rather than a repeat of a precedent.



### The storage pane has two directions, and only one of them is automatic

**`SYNC` sends a drawn span up; `RESTORE` pulls the last thirty days down.** The second is new, and it
exists because of the first: since the repositories stopped answering a local miss from the API, a row
this phone does not hold is blank on every screen by design — so the way a cloud install recovers one is
deliberate rather than incidental. `RESTORE` needs no span (a phone missing days has not drawn one), is
gated only on the build being configured, and **its caption says that it replaces** days the phone
already holds. That sentence is the difference between it and `SYNC`, which only ever adds. **It is also
the one control on this pane that ignores the 6 PM Eastern call window.** Every other request the app
makes — `SYNC`, the engine's own run, the launch-time repair — is refused between midnight and 18:00
because the app's traffic is a schedule, and a person pressing a button on a phone that is missing days
is not one: the moment that is most true is the first launch after an uninstall, which can be any hour.
`DIContainer` therefore builds the restore's client with the window held open, and
`RestoreFromCloudUseCase.restoreIfNeeded` keeps the check itself, so the exemption is exactly one button
wide. The automatic path remains for a genuinely fresh install: `RestoreFromCloudUseCase.restoreIfNeeded`
runs on the first foreground, and it now requires **both** `recoveries` and `sleeps` to be empty before
it acts — one store was enough until `RefreshRecoveryUseCase` began computing a recovery row on the
phone, which made a recovery-only test report a populated device that had no nights at all.

### The lock screen draws a panel while an activity records, and a summary once it has ended

**The running session's lock-screen card is the user's own layout, supplied as a mock: *"when an activity is in progress … i want
this panel to be displayed, without whoop logo"*.** So while `isRunning` the card draws the timer, a centre mark, the heart rate
with its `bpm`, the five-band scale with a marker at the current reading, and the route's two figures. **A finished session leaves no
card at all** — the user's second instruction: *"remove this for when session is ended on lock screen"* — so both `end` paths dismiss
`.immediate` rather than `.default`, and the `ACTIVITY ENDED` summary the first build left up for hours is gone. The widget still
carries that summary branch for the transient card the system tears down; nothing should be seen in it. **The centre mark is the activity's own glyph** — the first version left the ring empty because the mock's circle holds the
strap maker's logo and drawing that would be another company's mark on this app's card, and the user replaced it with *"just add
the glyph for the current activity"*. So the card draws what the `ACTIVITIES` card draws for the same name, composite included,
and the symbol names are **pushed through the state** rather than resolved in the widget: the extension cannot import `Whoopsy`,
and a second copy of the name → symbol table there is the drift `ActivityMark`'s move to `Domain` exists to prevent.
**The bar is a position scale and not a distribution** — the same quantity the session screen's band row draws, which is why it
carries a dot rather than a filled share, and why its five colours are copied from `HeartRateZoneIndex+Extensions.swift` into the
widget's `Palette` (the extension cannot import `Whoopsy`, and the copy is greppable — the same trade `Palette`'s three original
tokens already make). **The distance is the route card's own number**: `RouteDistance` in `Core` is the one haversine, read by
`ActivityRoute` for the caption and by `LiveSessionUseCase` for the card, so the lock screen and the activity page cannot report
two lengths for one run; the speed divides by the **route's own span**, not the session's elapsed time. **The timer yields to the reading, and that pair is the card's one layout rule.** A three-digit heart rate beside a long
elapsed time truncated to `1…` in the first build — the figure a glance needs whole lost to a flexible row — so the bpm
text is `fixedSize` at the row's `layoutPriority(1)` while the timer takes `minimumScaleFactor(0.7)`: a slightly smaller
clock still counts, a truncated heart rate does not. Nothing on this machine lays a Live Activity out, so that correction
is only checkable on a phone. §18 pins all three on the
state the app pushes — including that the marker equals the session screen's snapshot, rather than a second computation of it — and
the widget's layout itself is checked only on a phone.

### The steps tile opens a trend, and the trend page has no goal line

**The user's instruction was one sentence over a mock: *"for steps tile on home page when its clicked it
should lead to this new steps page"*.** The mock is a `TREND VIEW` with a metric dropdown, a big
average, a `W`/`M`/`6M` control, chevrons around a date range, a seven-bar chart, and a sentence
congratulating the reader on meeting their step goal.

**Three elements are not drawn, each for a reason the page states by omission.** The dropdown is a
control with one option in this app — `STEPS` is the only trend page that exists — and a picker that
opens a list of one is the inert-control defect everything else here avoids, so the header names the
quantity instead. The goal sentence assumes a goal, and **nothing stores one**: a line claiming the
user met a target would be a number this app invented, which is the fabrication class `ui-data-provenance`
lists. What replaces it is the honest fact the chart cannot show — *"5 of 7 days measured. A day with no
bar was not measured — the strap was not worn, so it is a gap rather than a day of no walking."*

**The chart's three rules are `StepsTrend`'s, not the view's**, because the runner has no renderer: an
unmeasured day is a **gap** and never a zero-height bar, the average is over measured days only (a
window with none is `nil`, not `0`), and the axis ceiling is the next 5,000 above the tallest bar
rather than the bar itself — an axis whose top is the data makes every window look full. `6M` plots one
bar per **week**, a mean of the week's measured days, because 182 daily bars are a smear; the footnote
says "weeks" there and "days" elsewhere, and the average is a mean of whichever unit the bars are.

**The page opens on today and moves by its own chevrons**, which is why its view model takes no day from
Home: `STEPS` is the one pushed destination whose subject is a window rather than the day on screen, and
`canMoveForward` stops at today so a future range cannot be drawn as a page of gaps.

### The stress tile opens its own day, and the page extends it live

**The mock is WHOOP's Stress Monitor page:** a day header, a 0–3 arc with the figure, band and marker, the
day's stress series as one band-graded bar per five-minute window, and a sentence counting time in the
high zone. The user's
instruction on it was one line — *"this is a live stress monitor"* — and the follow-up settled the cadence
at a five-minute tick, which is the model's own window length.

**The page seeds from Home's value rather than recomputing it.** Home already computes the day's
`StressDay` to draw its tile, so `StressDetailView` takes it as a `let`. Recomputing from scratch would
fold the same fortnight of samples twice (the model's baseline is the previous fourteen days' waking
hours, and that read is the app's most expensive), and two evaluations could disagree, since every window
is scored against a personal baseline.

**What is live is the tail, not the day.** `StressLiveViewModel` scores each newly *completed* five-minute
window after the last stored one, against the baseline the day carries (`StressDay.baseline`), and appends
it — so the chart grows as the day does, a refused window leaves a gap rather than a guess, and no stored
window is ever rescaled or replaced. It polls the unscored tail of the samples and the motion epochs every
minute rather than subscribing to the live streams, because a drain writes samples no live stream saw and
a connected strap writes motion epochs the samples do not carry; a minute's tail is a handful of rows
where a full evaluation reads more than a million. The tick is the page's `.task`, so leaving the screen
cancels it without a detached timer to stop.

**The gauge is the newest window, with its time**, as the reference draws it — and the footnote states the
day's average, because a page holding a five-minute figure beside a Home tile holding a day average would
otherwise be one screen contradicting another. The **LIVE** marker beside the header is the same honesty:
without it a reader returning to the screen would read the newest window as the average.

**The chart is the last few hours, not the day**, which is what the reference draws and what a live monitor
is for: a day-wide axis is mostly future when the page is opened at noon, and the reader came for the
stretch that ends now. It is the same span the recent baseline reaches back over
(`StressMath.recentBaselineSpan`), so the number and the bars below it describe one stretch of time. On a
whole-day axis the chart shades the hours the model cannot score; on a custom span it shades nothing,
because the axis is no longer the day and shading its ends would claim hours outside the chart.

**The closing paragraph is written for the band the day landed in.** It opens by calling the day low,
medium or high and saying what that means in the model's own terms — below the reference, up to a sigma
above it, more than a sigma above — and then reports the time in the high band, or says in words that no
window reached it. It used to say *"you spent X in the high stress zone"* on every day, which on a calm
day is a sentence about a band the day never reached; that is the failure `StressDetailView.message`
exists to make assertable, since no screenshot can show more than one band.

**The reference the score is against is named on the page, and it is one of two.** A personal baseline —
the previous fortnight's waking hours, one point per day — takes three days of daytime stillness to exist,
and the model used to refuse a day entirely below that. That was wrong for live data: it reported the
absence of *history* as an absence of stress, and left the tile and the page empty for the first three
days. A day with no personal baseline is now scored against its own preceding hours instead — each
five-minute window against the windows inside the previous six hours, floor twelve — so the monitor works
on the first afternoon the strap is worn. The footnote says which of the two it is showing, because *"your
fortnight"* and *"your last few hours"* are different claims, and the recent one cannot say that a whole
uniformly-elevated day was stressful.

**Five things from the reference are not drawn, each for a rule this app already holds.** The gear and the
`i` button have no destinations; the zoom button would open an interaction that does not exist; the day
chevrons would page into days whose stress has never been computed, and a pushed page takes its day as a
plain `let`; and *"in line with a typical Thursday"* is a weekday baseline this app does not hold, so the
footer states the time in the high band instead — counted from the windows' own five minutes, never from a
difference between two instants, because the windows need not be contiguous and a gap belongs to no band.

**Time in a band is `StressDay.seconds(in:)`**, one count times `StressMath.windowSeconds` through the one
`StressWindow.band` mapping — so the page's sentence cannot put a window in two bands or in none.

### The reading panels open trends, and the band is the app's own

**The mocks are the steps page's shape with a line instead of bars:** average, `W`/`M`/`6M`, a
comparison pill, a sentence against the previous window, a `TYPICAL RANGE` band behind the line, and the
latest reading marked. The `HRV` panel's mock was supplied first and the `RHR` panel's next, and they
are one page in two forms — `ReadingTrend` and `ReadingTrendDetailView`, parameterised by
`ReadingTrend.Kind` — because the two differ only in a unit, a direction of "better" and one extraction,
and writing the page twice would be two definitions of the same window arithmetic. Three things about
it are decisions rather than drawing.

**The page is in one metric, and it says which.** `recoveries` holds RMSSD from the strap and SDNN from
the HealthKit import, and a trend that averaged them would put two distributions on one axis — the
never-mix rule `docs/ALGORITHMS.md` treats as a correctness bug. `HRVTrend.make` narrows to the metric
the newest measured row carries (the same rule as `RecoveryViewModel.displayedHrvMetric`) before it
averages or plots anything, and the footnote names it.

**The band is this app's derivation, not WHOOP's.** `TYPICAL RANGE` is the previous window's mean ± one
sample standard deviation over its measured days, withheld below `minimumBaselineDays` — stated in the
footnote because a band drawn in WHOOP's colours could otherwise read as WHOOP's baseline, whose anchor
is the end of a slow-wave episode this app cannot measure. The same prior window supplies the pill and
the sentence, so the comparison and the band describe one set of days.

**The VO₂ panel opens the same page in an estimating form.** Its figure is not a row: it is
`Vo2MaxMath.heartRateRatioEstimate` — 15.3 × the profile's assumed maximum over the day's resting rate —
derived per day exactly as `MetricWeek` derives the panel's number, so the page and the panel cannot
disagree about a day. That makes it the one form whose legend the reference's cannot be reproduced: the
mock draws `MANUAL ENTRY` beside `WHOOP ESTIMATE`, and this app has neither a manual entry nor WHOOP's
model, so the footnote's first sentence says *estimated, with a 4.7 mL/kg/min standard error, not a
measurement* instead of inventing a second series. A profile this app cannot read leaves the page empty
rather than anchored to an assumed maximum.

**A gap breaks the line.** A day with no measured reading is neither a zero nor interpolated across:
either draws a reading the app never took, and a straight segment through a missing week is the
strongest possible claim that nothing happened in it. The axis covers the readings **and** the band, so
the band is never clipped off the plot it is meant to be read against.

### The Whoopsy Age is a risk-equivalent age, and it stands on the last measured day

The Health tab's `WHOOPSY AGE` dial is the app's own answer to the reference's WHOOP Age, and the card
says in one sentence what it is: **your measured profile's mortality risk, run through a life table,
is the risk of the average person of that age in that population.** That is the standard construction
rather than an invention — PhenoAge, GrimAge and CosinorAge all read their biological age back out the
same way, and what differs between them is which inputs move the expectancy, not how the age is
inverted from it.

**Three of WHOOP's nine Healthspan inputs feed it**, because three are readings this app already
stores: cardiorespiratory fitness (the profile's max rate over the day's resting rate, via
`Vo2MaxMath`), steps per day, and resting heart rate. Each is a published hazard ratio against a
stated reference, multiplied together and clamped — `MortalityRiskProfile` carries the citations and
the clamp's argument. Sleep and strength time are deliberately left out and the card says why: sleep's
mortality curve is J-shaped and this app will not invent a slope for it, and the published strength
ratio is per week of a self-reported activity class rather than per minute a strap can count. Lean body
mass — the eighth of WHOOP's nine — is drawn beside the dial from height, weight and sex, because it is
a body fact the regressions can estimate and no measurement here can.

**The years come from somebody else's publication.** `lifeTables.json` is generated by
`scripts/build-life-tables.py` from NCHS's own spreadsheets (United States Life Tables, 2024, NVSR
75-05, Tables 1–3), and the app checks its own integration of `q_x` against the published `e_x` before
believing any of it. A multiplier acts on the force of mortality, not on the years — `q' = 1 − (1 − q)^HR`
— and the age is then read back by inverting the table's monotone expectancy curve. The region is the
device locale's; a country with no bundled table gets the multiplier and a sentence rather than another
country's mortality.

**It stands on the last measured day, and that was the fix that made the dial work.** The tab asks the
view model to load *today*, and a day with no measurement has no `recoveries` row — that is this app's
whole absence rule, not an edge case — so an estimate taken only from the day on screen dashed for
anyone who had not slept with the strap since the last import, which is every reader after a gap. The
fallback reads back up to a year and takes the most recent measured night, and **the card prints that
day** so an older night's numbers never read as this morning's. A year is the bound rather than
"everything": past a year the profile describes someone the wearer may no longer be, and a dash says
that better than a stale number. This is the `## Pages` rule about a value being honest about *when* it
was measured, applied to an estimate whose whole body is a measurement.

**A dash is not an answer, and the card stopped giving one.** Three different things can leave the dial
empty and each needs a different action from the reader — no measured night, no date of birth, or no
life table for the region — so `HealthMonitorViewModel.LongevityAbsence` names which one it is and the
card turns it into a sentence. The `BIRTHDAY` row this points at had existed on `BIOMETRICS` since
`v20` and drew a bare, unlabelled dash; see the row's own entry for why it read as missing.

### The map expands rather than becoming interactive in place

**Both map cards carry one control, and it is expansion — the user's own ask: *"can we add ability for map to go fullscreen,
give it an option to go full screen like two corner arrows, that are used for expansion"*.** So the route card and the area
card each draw a two-corner-arrows button at their top-right, and it opens the same map over the whole screen. **The card cannot
simply be made interactive instead**: it sits inside a scrolling page, where a drag means *move the map* to one view and *scroll
the page* to the other (the reason `ActivityRouteMapView.liveMap` is `interactionModes: []`), so the gesture conflict is resolved
by expanding — the cover has no page behind it, and there the map pans and zooms (and only those: a drifting pinch that rotated the map would draw the route at an angle).
**That is why a card holds two surfaces rather than one.** `MapKit`'s difference is an argument — `interactionModes: .all` — but
the offline SDK's gestures are set in `App/Map/`, a module this package never compiles, so the interactive drawing has to be built
there and handed in beside the card's through `expandedMapSurface`; a card with none falls back to its own map, which is every
build this package compiles and every build without the SDK. **The button is a sibling of the card, not a child**, because the card
is one accessibility element that speaks the route's sentence and a button drawn inside it would be silent to VoiceOver. The
overlay is a `fullScreenCover` on iOS and a sheet on the Mac — the cards compile for both, and `fullScreenCover` does not exist on
macOS — and §19 pins the two symbols and the two spoken labels the two cards share, which is the part a screenshot of one card
cannot check.

### Two types on that page are kept deliberately though nothing draws them

**Two types on that page are kept deliberately though nothing draws them.** `ActivityDurationBar`/`ActivityDurationBarLayout` and `ActivityDetailViewModel.durationLayout` — with `ActivityDetailView.typicalDurationCaption(low:high:)` — are the duration-band model the user commissioned, and their §19 assertions are that model's only coverage. Matching the reference removed the band bar from the screen, so they are unrendered rather than deleted: this suite has no test discovery, so deleting them would drop passing assertions and a falling `assertions=` count would be the only trace. `spokenDuration(...)` still reaches the range through the `TYPICAL RANGE` row's accessibility label, so the model is spoken even though it is not drawn.



### A strap's advertised name is a proprietary command, not GAP's `0x2A00`

**ADVANCED gained a `NAME` row, and it is the one control on that page that changes the strap rather
than this phone.** A strap named *"Alex WHOOP"* was named through the WHOOP app — not through GAP,
whose `0x2A00` CoreBluetooth hides from every third-party app. The rename is [reported] The community reference's ID 140
on a 5.0/MG and ID 77 on a 4.0, with different bodies and the same 15-byte ceiling (clamped on a
scalar boundary, so a multi-byte character is never cut in half). **The strap does not acknowledge the write** — though the write itself works: ID 140 was applied on
2026-10-25 on the owner's 5.0 and the advertisement lagged it by a few minutes. So the row says
*requested* and the footer says what will settle it: the name in the next advertisement, after enough
time that the phone is not answering from its CoreBluetooth cache. It is drawn as a plain `NAME` row opening an alert with a text field — no new sheet, no
new view model state beyond the draft, and nothing is written locally, because the strap is the owner
of this value.

### A stored night records the rule that classified it and the input it saw, and is re-read rather than re-analysed

**The sleep page used to re-classify today's night on every open, and the reason was a missing column.**
A `sleeps` row is a decision — onset, staging, need — and until `v37` it carried no record of which
rule made it or how much input it read, so the only way to know whether a stored night met the current
stager was to recompute it. That cost a full classification on every open, and it was dangerous the
way an unconditional write always is: a night whose drain had not finished classifies as absent, and
the page treated that as a verdict.

Now the row carries `algorithm` and `scored_through`, and the page asks three questions in order.
**Imported?** Never touch it — WHOOP's own night is not this app's to re-decide. **Version matches and
the analyzer can see nothing newer?** Read the row, which is what makes the page open at once. **Else?**
Classify again — and if that comes back empty, keep the stored night unless its version is one this
build no longer has, because a short read is evidence of a short read rather than of an absent night.
The figure the ring shows is unchanged by all of this: it is the composite of sufficiency, efficiency,
restorative share and timing, read from `MetricWeek`'s last slot.

### A zone row's time comes from exactly one producer, and the page's grey average is measured samples only

**The five zone rows under the chart draw time, not percentage, and the two producers that can name
that time are never mixed.** An imported session carries WHOOP's own `HR Zone n %` block, so its rows
are that share of the session's length; a session this app recorded carries no block at all — the live
path writes `hrZonePercents: nil` on purpose — so its rows are folded from its own samples by
`ZoneTimeMath`, the same integral the live session and the day's Strain use. Measured wins when a
session somehow has both. The instruction was *"i dont see the time durations i was in each specific
heart rate zone"*: the page had drawn five dashes for every recorded session, because its rows asked
for a column only an import ever writes, while the samples it was already plotting went unread.

**The bar's length is the session's time and its scale is the block's, not the row's.** Every bar is a
fraction of the largest time anywhere in the block, session or average, so a bar and its own grey mark
are on one track: a per-row scale would draw zone 2 as long as zone 5, and the session's length would
draw every bar as a sliver. The grey mark is the mean over the last ten sessions of the same activity
(`ActivityBaseline`'s window), built from **their samples** and shown once three of them have any —
an imported prior contributes nothing, which is what keeps the mean from mixing WHOOP's producer into
this app's. It is drawn taller than the track because zone 1's own fill is grey and a same-height
marker would vanish inside it.

The footnote varies with the producer, because one sentence cannot honestly describe two: a recorded
session's times are this app's and a row's five need not sum to the duration (time below zone 1
belongs to no band), and an imported one's are WHOOP's own percentages scaled by the session's length.
The BPM edges are this app's Karvonen table in both cases, and that disclosure is not removable to
match a picture.

### A session is not a screen's state, and that is the whole of the design

**A session is not a screen's state, and that is the whole of the design.** `LiveSessionUseCase` is a `@MainActor @Observable` class held as a stored `let` on `DIContainer` and handed down from `MainContainerView`, so `LiveSessionView` owns neither a `NavigationStack` nor a view model — the first follows every pushed page here, the second is the feature: **the screen is free to come and go while the recording continues**, which is what the user asked for (*"if user presses back, session will still be live recording"*). There is deliberately **no `.onDisappear { end() }`** on that view; backing out is not stopping, and re-entering shows the accumulated figures because `snapshot` is the use case's. Recording is also not *ended* by a process death and cannot be resumed by one: an ended session is written, and the orphan sweep below only cleans up the lock-screen card.



**There are two kinds of live session on that one use case, and they are deliberately not the same shape.** `isRunning`/`startedAt`/`activityName` are the *activity's*; `activeFast` is the *fast's*, held as one private `fastSlot` enum with a `.none` case rather than as a bare optional, so "no fast" and "a fast" are the only two states it has. **A fast measures nothing and therefore needs none of the machinery**, which is the whole of why it is affordable: `WorkoutSession`'s three measured fields are optional and a fast fills none of them, so there is no accumulator, no BLE consumer, no step consumer, no route and no lock-screen card to run — none of which could produce a figure a fast would store. What is left is one instant, and one instant is the thing that can be persisted *honestly*. **That is the one live session that survives a relaunch** — `ActiveFastRepository` is a required `LiveSessionUseCase.init` parameter rather than a defaulted one, so a production path cannot ship without it and silently lose a fast the user is three days into; `restoreFast()` is a method rather than `init` work because `init` is `nonisolated` and cannot assign main-actor-isolated stored state, so `MainContainerView.init` calls it — with no flash of no-bar, since that is the first main-actor moment the use case is reachable. **A run is the opposite case and the asymmetry is deliberate**: its accumulator's samples are gone after a kill and inventing them is the fabrication every absence rule here forbids, which is why `endOrphanedLiveActivities()` can only *end* a stale card and never adopt one. **Starting a session while a fast runs does not touch it** — the two states are independent fields, so the fast keeps counting from its own start and the bar returns to it the moment the run ends — and `endFast()` writes exactly what `ActiveFast.projectedSession(now:)` returns, so the page the user was looking at and the row they end with are one construction rather than two that agree today. **Both of `endFast()`'s clears sit above its first `await`**, `end()`'s own ordering, so the bar cannot go on counting through a SQLite write and a second END FAST is not callable in that window; the cost is the opposite window, where a kill between the clear and the save loses the fast — recorded rather than discovered, and the lesser failure, since the other ordering resurrects a fast already on disk and writes it a second time under a fresh `UUID`.



**The rows are not the same kind of thing, and `ActivityMenu.Entry.Action` is what records it.** The action is a case and not a `() -> Void`, for the reason the type's doc comment gives: a closure stored in a static list cannot be asserted, cannot be `Equatable`, and can capture anything. §18 asserts that **exactly one** row carries `.startSession`, and `HomeDashboardView`'s switch over the case is exhaustive, so a fourth action is a compile error at the one call site rather than a silent no-op. **A second input rides beside it as a second case-shaped enum, `ActivityMenu.Recording`, and it is what makes the availability rule assertable rather than a read inside a `body`.** The three cases carry the three answers the screen can be in — `none`, `activity`, `fast` — and the asymmetry between the last two is the user's rule rather than an implementation detail: `.activity` withholds `START ACTIVITY`, `.fast` leaves the list byte-identical to `.none`. Three cases rather than a `Bool` for `Recording`'s own reason, which is `ActivityFigure`'s: a fast and an activity are not two spellings of "busy", and a single flag could not hold both answers. The menu rows are anchored to the `+` by a `PreferenceKey` rather than a `padding(.top, N)` constant, because the button's y moves with the top bar's height — `ActivityMenuAnchorKey` mirrors `RingsBottomKey` and obeys the same two rules (a `static let` default, and no `@State` written by the transform).

### A session ends in two writes, and the second one is the question

`LiveSessionView`'s `END` used to write a row and pop. It now writes the row, then asks one question —
*how hard did that feel?* — in a sheet over the page, and pops when the sheet closes. **The order is
the whole decision**: `LiveSessionUseCase.end()` stamps `endedAt` at the press and saves, and only
then does `SessionRatingPrompt` offer five words. Asking first would hold the session open for however
long the sheet is up, and the recorded window would include the time spent rating it — a session that
grew while nobody was moving. So `rate(_:for:)` is a **second write of the same session**, with the
rating added; SKIP writes nothing and leaves it unrated, which is honest rather than a zero.

**Five words, not a slider.** `WorkoutRPE.Bucket` maps `EASY/MODERATE/HARD/VERY HARD/MAX` to
`2/4/6/8/10`, and the control draws the short labels because `SegmentedPillControl` gives five
segments an equal share of the phone's width and does not shrink its title — `VERY HARD` runs into
its neighbours at ~70 pt. The detail page's row prints the long word beside the figure.

**The same five words appear in `EDIT ACTIVITY`, and that is not a duplicate route to the same
answer.** The prompt exists at the one moment the user remembers the session; the sheet exists so a
rating can be added later or corrected, on a session the prompt was skipped for and on every imported
session (which never had a prompt). There is deliberately **no clear control**: `nil` means *never
rated* and there is no column path that means *unrate*, so re-rating is how an answer changes. The
detail row is drawn only when a rating exists — an unrated session shows nothing rather than a dash,
because the absence is the user's and not a measurement that failed to load.

### `0x9A` exists on one screen, behind one confirmation, and is not a setting

The device page's **ADVANCED** tab grew two buttons under `REBOOT STRAP` on 2026-10-24: `ENABLE
PERSISTENT RECORDING` sends `0x9A TOGGLE_PERSISTENT_R21` with `[1, 1]`, and `REVERT PERSISTENT
RECORDING` sends `[1, 0]`. It exists because the owner's flash recorder stopped writing history with a
correct clock, a healthy link and no battery-related change, and this is the last lever the community reference's 5.0
command table offers — the experiment is `docs/TODO.md` §7.2.

**Two explicit actions rather than a switch, and that is the whole design of the control.** The strap
cannot be asked what its flag is: `0x9A` is a write whose ACK does not report programming, so the app
can never read the state back. A toggle would therefore draw a position the app does not know, which is
the same fabrication class as a dash drawn as a zero. ON and REVERT say what they will send, and the
status line after a tap says **requested**, never *enabled*.

**It is 5.0/MG only, and the byte is in no opcode table.** The 4.0's reference lists `0x9A`, but no body
has been captured for that envelope and the two bodies are not interchangeable, so the builder refuses
it; `WhoopCommandFrames.persistentR21` is the single path to the byte, which keeps §16's forbidden-byte
sweep meaningful — that sweep reads the tables, and a second caller would have to come through a name
that says what it does.

**The confirmation carries the cost rather than hiding it behind the tap.** The reference warns the flag
can keep the optical engine running across reboots and drain the battery, and clearing the flag does
not stop an engine already running — `REBOOT STRAP`, directly above it, is the recovery. The buttons are
disabled unless a 5.0/MG is connected (`supportsPersistentRecording`, not `supportsSync`: the latter
answers whether this *build* frames the model, while the command is published for those two generations
alone).
