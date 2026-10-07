import Foundation
import Whoopsy

// MARK: - 18. The profile form, its panes and the profile row

/// A file of §18's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `LiveSessionTests.run()` calls it, in the order the section ran it in.

enum ProfileFormTests {
    static func run() async throws {
        // ---- The profile form's parsing ----
        //
        // `ProfileDraft` is a separate type rather than three `static` members on `ProfileViewModel` for
        // `DayBarRules`' reason: the view model is `@MainActor @Observable` and the runner would have to
        // build one to reach the rules. Here they are three free functions over `String`.
        //
        // **A blank field is an absence, not an error.** An empty weight parses to `nil`, which is what
        // makes the field clearable; text outside the band is a different answer and the view model
        // refuses it with a message.

        assertTest(
            ProfileDraft.weight(from: "") == nil && ProfileDraft.weight(from: "   ") == nil,
            "A blank weight is an absence rather than an error — it is how a weight is cleared")

        assertTest(
            ProfileDraft.weight(from: "75") == 75.0
                && ProfileDraft.weight(from: " 75.5 ") == 75.5,
            "…a supplied one parses, trimmed, at whatever precision it was entered")

        assertTest(
            ProfileDraft.weight(from: "75,5") == nil,
            "…a comma decimal separator is refused rather than silently dropped — entry is "
                + "locale-agnostic and expects a period, and dropping the separator would read `75,5` "
                + "as `755`")

        assertTest(
            ProfileDraft.weight(from: "2") == nil && ProfileDraft.weight(from: "500") == nil,
            "…and text outside the plausible band is refused: the bounds are typo guards, not a "
                + "judgement about bodies, and the cost of admitting one is a calorie figure scaled by "
                + "a body that does not exist")

        assertTest(
            ProfileDraft.weight(from: "20") == 20.0 && ProfileDraft.weight(from: "400") == 400.0,
            "…with both edges of the band admitted, so the range is inclusive at both ends")

        assertTest(
            ProfileDraft.heartRate(from: "190", in: ProfileDraft.maxHeartRateRange) == 190
                && ProfileDraft.heartRate(from: "100", in: ProfileDraft.maxHeartRateRange) == 100
                && ProfileDraft.heartRate(from: "250", in: ProfileDraft.maxHeartRateRange) == 250,
            "A maximum heart rate parses inside its own band, edges included")
        assertTest(
            ProfileDraft.heartRate(from: "99", in: ProfileDraft.maxHeartRateRange) == nil
                && ProfileDraft.heartRate(from: "251", in: ProfileDraft.maxHeartRateRange) == nil,
            "…and is refused outside it")

        assertTest(
            ProfileDraft.heartRate(from: "60", in: ProfileDraft.restingHeartRateRange) == 60,
            "A resting heart rate parses against the resting band, not the maximal one")
        assertTest(
            ProfileDraft.heartRate(from: "29", in: ProfileDraft.restingHeartRateRange) == nil
                && ProfileDraft.heartRate(from: "121", in: ProfileDraft.restingHeartRateRange) == nil,
            "…and `60` is inside the resting band where `29` and `121` are not — the two ranges differ, "
                + "which is why the band is a parameter and not a constant in the parser")
        assertTest(
            ProfileDraft.heartRate(from: "60.5", in: ProfileDraft.restingHeartRateRange) == nil,
            "…and a fractional rate is refused rather than truncated: a heart rate is a count of beats, "
                + "and the zones this feeds are built from integers")

        assertTest(
            ProfileDraft.text(forWeightKg: nil) == "",
            "An unset weight fills the field with nothing rather than a zero")
        assertTest(
            ProfileDraft.text(forWeightKg: 75) == "75.0" && ProfileDraft.text(forWeightKg: 62.5) == "62.5",
            "…and a set one prints what will be stored, to the precision it is stored at")
        assertTest(
            ProfileDraft.weight(from: ProfileDraft.text(forWeightKg: 82.4)) == 82.4,
            "The field's text round-trips through the parser, so opening and saving without typing "
                + "cannot change the stored weight")

        // ---- The profile form's units ----
        //
        // `ProfileUnits` is `ProfileDraft`'s sibling for its reason — the runner has no `@MainActor` object
        // to reach through — and this is the only place in the app where a unit is converted at all.
        //
        // **The first pair carries the block.** `192` typed into a `WEIGHT` box means two different bodies
        // depending on the system above it, and the failure this guards is a forgotten multiplication: the
        // wrong answer is `192.0` kg, which is inside `20...400`, so nothing refuses it, the form saves, and
        // `StrainAccumulatorMath.estimateCalories` scales a calorie figure by a body nearly twice the user's.
        // Asserting the right figure is not enough on its own — `!= 192.0` is what names the failure.

        assertTest(
            ProfileUnits.weightKilograms(from: "192", in: .imperial).map { abs($0 - 87.0897) < 0.001 } == true,
            "An imperial weight converts to kilograms on the way in — `192` lb is 87.0897 kg, not 192 kg, "
                + "which is the figure a dropped multiplication would store and no band would refuse")
        assertTest(
            ProfileUnits.weightKilograms(from: "192", in: .metric) == 192.0,
            "…and the same text under metric is the number itself, which is what proves the unit argument "
                + "is read rather than accepted and ignored")

        assertTest(
            ProfileUnits.weightKilograms(from: "30", in: .imperial) == nil
                && ProfileDraft.weightRangeKg.contains(30.0),
            "**The sharpest assertion in this block**: `30` lb is 13.6 kg and is refused *only* because "
                + "the band was applied to the converted value — `30.0` is inside `20...400` as typed, so a "
                + "guard placed before the multiplication admits it and a guard placed after refuses it")

        assertTest(
            ProfileUnits.weightKilograms(from: " 75.5 ", in: .metric) == 75.5,
            "The trimming is `ProfileDraft`'s, delegated rather than re-implemented, so the metric path "
                + "cannot drift from the parser above")
        assertTest(
            ProfileUnits.weightKilograms(from: "75,5", in: .imperial) == nil
                && ProfileUnits.weightKilograms(from: "", in: .imperial) == nil,
            "…and so are the comma refusal and the blank-is-absence rule: `75,5` is not silently read as "
                + "`755`, and an empty box clears the field rather than erroring")

        assertTest(
            [1.0, 44.1, 87.08973504, 200.0, 400.0].allSatisfy { kilograms in
                abs(ProfileUnits.kilograms(fromPounds: ProfileUnits.pounds(fromKilograms: kilograms)) - kilograms) < 1e-9
            },
            "The two conversions are exact inverses across the whole plausible band, which they are only "
                + "because `pounds(fromKilograms:)` divides by `kilogramsPerPound` — an independently "
                + "written `2.20462` would round the round trip and fail here")

        assertTest(
            ProfileUnits.weightRangeLb.lowerBound > 44.0 && ProfileUnits.weightRangeLb.lowerBound < 44.1
                && abs(ProfileUnits.weightRangeLb.upperBound - 881.849) < 0.001,
            "…and the pound band is derived from the kilogram one rather than written down, so the app "
                + "holds one weight band and not two that agree today")

        assertTest(
            ProfileUnits.weightText(forKilograms: 87.08973504, in: .imperial) == "192.0"
                && ProfileUnits.weightText(forKilograms: 87.08973504, in: .metric) == "87.1",
            "One stored body draws as `192.0` in one system and `87.1` in the other — the unit switch "
                + "changes the text and nothing else")
        assertTest(
            (["192.0", "87.1"].compactMap { text in
                ProfileUnits.weightKilograms(from: text, in: text == "192.0" ? .imperial : .metric)
            }).allSatisfy { abs($0 - 87.08973504) < 0.05 },
            "…and both of those texts parse back to the same body within half a display step, which is "
                + "what lets the unit switch re-seed the boxes without the form going dirty — comparing "
                + "the texts rather than re-deriving from them is the whole of that rule")

        assertTest(
            ProfileUnits.heightTexts(forCentimetres: 177.8, in: .imperial) == ("5", "10.0")
                && ProfileUnits.heightTexts(forCentimetres: 177.8, in: .metric) == ("177.8", ""),
            "A stored height draws as whole feet plus an inch remainder under imperial and as one "
                + "centimetre box under metric, and the second box is empty there because it is not drawn")
        assertTest(
            ProfileUnits.heightCentimetres(fromHeightText: "5", inchesText: "10.0", in: .imperial) == 177.8,
            "…and the imperial pair parses back to the centimetre it came from, so opening and saving "
                + "without typing cannot move a height — the direction that matters")
        assertTest(
            ProfileUnits.heightCentimetres(fromHeightText: "5", inchesText: "10.1", in: .imperial)
                .map { abs($0 - 178.0) < 0.13 } == true,
            "…with the other direction bounded rather than exact: half a display step is 0.05 kg but "
                + "0.13 cm, and an `==` here would be a claim this arithmetic cannot support")

        assertTest(
            ProfileUnits.heightCentimetres(fromHeightText: "5", inchesText: "13", in: .imperial) == nil
                && ProfileUnits.heightCentimetres(fromHeightText: "5", inchesText: "11.9", in: .imperial) != nil,
            "An inch box at twelve or above is refused rather than carried into the feet box — and this "
                + "per-field band is the only thing that catches it, since `5'13\"` is 198.12 cm and sits "
                + "comfortably inside `60...250`")
        assertTest(
            ProfileUnits.heightCentimetres(fromHeightText: "0", inchesText: "10", in: .imperial) == nil
                && ProfileUnits.heightCentimetres(fromHeightText: "10", inchesText: "0", in: .imperial) == nil,
            "…while `0'10\"` and `10'0\"` are refused by the canonical band on the converted centimetres, "
                + "which is the check that is not redundant with the inch one")

        assertTest(
            ProfileUnits.heightCentimetres(fromHeightText: "", inchesText: "", in: .imperial) == nil,
            "Two blank height boxes are an absence rather than a zero — a height is cleared, not set to nought")
        assertTest(
            ProfileUnits.heightCentimetres(fromHeightText: "5", inchesText: "", in: .imperial) == 152.4,
            "…but a blank *inches* box beside a supplied one is a real zero, because `5'` and `5'0\"` are "
                + "the same height — the asymmetry with the weight field above, where blank is an absence "
                + "and `0` is not a value at all")
        assertTest(
            ProfileUnits.heightTexts(forCentimetres: nil, in: .imperial) == ("", "")
                && ProfileUnits.weightText(forKilograms: nil, in: .imperial) == "",
            "A body nothing has been told about draws empty boxes in either system rather than a conversion "
                + "of a number the app invented")

        // ---- The three panes, and the form's dirty gate ----
        //
        // The rules that *surround* `BIOMETRICS`'s fields, as pure values. The runner has no renderer, so
        // the order of the tabs, the words `STORAGE` is built from, and "has this form moved" are only
        // visible at all if they are written down away from a `body` — which is why the tab list is an
        // enum, the pane's copy is a set of `nonisolated static`s, and the dirty rule is a value type.
        //
        // **All three titles were renamed on the user's instruction** — *"rename "Body" tab to
        // "Biometrics", rename "Data" tab to "Logs", rename [the third] tab to "Storage""* — so these two
        // lists are the assertion that the rename reached the row. **The `STORAGE` block below used to
        // assert the opposite of what it asserts now**, and the history is worth keeping: the rename named
        // three labels and no content, so the pane went on saying nothing was built yet about a feature
        // the app no longer has while being titled `STORAGE`, and that disagreement was pinned here
        // verbatim rather than smoothed over. It is now ended twice over — the pane is the sync boundary,
        // and the placeholder's own feature is deleted outright — so what is pinned is the copy the
        // feature is made of. The pane's own *behaviour* — what `canRun` answers, whether the run row is
        // drawn at all, which sentence the span's state produces — is asserted nowhere, here or in §22,
        // because asserting it would mean driving `SyncStorageViewModel` rather than reading a constant
        // off it. What stands in its place is the engine's own refusal: a run with no span drawn, or with
        // a span whose ends are the same day, throws `.nothingToDo` **before it touches anything** — which
        // §22.5 asserts against an empty call list.

        assertTest(
            ProfileDashboardView.Tab.allCases.map(\.title) == ["BIOMETRICS", "LOGS", "STORAGE"],
            "The profile page's three panes are titled and ordered `BIOMETRICS`, `LOGS`, `STORAGE` — the "
                + "order *is* the drawing, and a reorder is invisible in a screenshot of the first tab, "
                + "which is the one a screenshot would be taken of")
        assertTest(
            ProfileDashboardView.Tab.allCases.map(\.rawValue) == ["BIOMETRICS", "LOGS", "STORAGE"],
            "…and each case's raw value is the title verbatim, so the enum cannot carry a second spelling "
                + "of a word the tab row draws. Stored uppercase because that is the case they are drawn "
                + "in: `UnderlinedTabRow` applies no `.textCase`, so a sentence-case literal would draw "
                + "sentence case beside two capitals")

        // **The two destination titles, and this is what stands where the resource selector stood.**
        // The `STORAGE` pane used to open on a `RECOVERIES | WORKOUTS | STRAINS` segment that chose which
        // resource's cutoff the rows below belonged to; one destination for the install replaced it, and
        // the segment that remains is the one that says *where* rather than *what*. The row draws
        // `Destination.allCases.map(\.rawValue)` rather than a literal pair, so this list **is** the
        // segmented control, and it is asserted here rather than only in §22.1 because the two claims are
        // different: that section pins the value type's two arms, and this one pins what the pane puts on
        // the glass. `device` is first because it is the default and the state a fresh install is in —
        // which is also why the order is the half no screenshot can see, since the default selection is
        // the first segment, so a reorder leaves the pane a reader first opens looking byte-identical.
        assertTest(
            SyncSettings.Destination.allCases.map(\.rawValue) == ["DEVICE STORAGE", "WHOOPSY SYNC API"]
                && SyncSettings.Destination.allCases.first == .device
                && SyncSettings().destination == .device,
            "The destination row's two segments are `DEVICE STORAGE` and `WHOOPSY SYNC API` in that "
                + "order, and the pane opens on the first — the arm that says nothing leaves the phone. "
                + "The words are read off `rawValue` rather than typed at the call site, on the tab row's "
                + "rule directly above: a third destination has to be a segment that appears")

        assertTest(
            ProfileDashboardView.storageKeyEyebrow == "SYNC KEY"
                && ProfileDashboardView.storageCopyTitle == "COPY"
                && ProfileDashboardView.storageDestinationEyebrow == "STORE NEW DATA IN"
                && ProfileDashboardView.storageRangeFromEyebrow == "SYNC FROM"
                && ProfileDashboardView.storageRangeToEyebrow == "SYNC TO"
                && ProfileDashboardView.storageResourcesEyebrow == "SYNCED RESOURCES",
            "The `STORAGE` pane's five fixed headings, pinned as literals because the copy *is* that tab "
                + "and no renderer can read it off the screen. They are the pane's identity: a key is shown "
                + "under `SYNC KEY`, the control that shares it reads `COPY`, the switch says where the next "
                + "write goes rather than what it will do to the last one, the two span rows are named the "
                + "way a range is named everywhere, and the list is a list of what a run carries")
        assertTest(
            ProfileDashboardView.storageDestinationNote(for: .device).lowercased().contains("nothing")
                && ProfileDashboardView.storageDestinationNote(for: .cloud).lowercased().contains("nothing")
                && ProfileDashboardView.storageDestinationNote(for: .device)
                    != ProfileDashboardView.storageDestinationNote(for: .cloud),
            "…and **both** destination notes say that nothing is moved or removed. The shared word is the "
                + "load-bearing half and it is deliberately asserted on both arms rather than on the one "
                + "that needs it: the fear this control has to answer is *if I pick the database, do I "
                + "lose what is on my phone*, and a reader who only ever selects `DEVICE STORAGE` would "
                + "never see the answer if it were written once. The inequality is the other half — a "
                + "`switch` collapsed onto one arm draws the cloud's sentence under the device segment and "
                + "looks entirely plausible")
        assertTest(
            ProfileDashboardView.storageRangeNote(isEnabled: true).lowercased().contains("nothing")
                && ProfileDashboardView.storageRangeNote(isEnabled: false).lowercased().contains("nothing")
                && ProfileDashboardView.storageRangeNote(isEnabled: true)
                    != ProfileDashboardView.storageRangeNote(isEnabled: false),
            "The span's note has two states and both promise the same thing about this phone's rows. The "
                + "inequality is the load-bearing half, on the headings' reasoning above: a function "
                + "answering one string for both states would describe a span to a reader who has not "
                + "drawn one, which is the state the pane opens in")
        assertTest(
            !ProfileDashboardView.storageKeyNote.isEmpty
                && !ProfileDashboardView.storageResourcesNote.isEmpty
                && ProfileDashboardView.storageNoDatabaseNotice(missingKey: WhoopsyAPIClient.baseURLInfoKey)
                    .contains(WhoopsyAPIClient.baseURLInfoKey)
                && ProfileDashboardView.storageNoDatabaseNotice(missingKey: WhoopsyAPIClient.tokenInfoKey)
                    .contains(WhoopsyAPIClient.tokenInfoKey),
            "…the explanatory paragraphs are present, and the unconfigured build's sentence names the "
                + "`Info.plist` key that is missing rather than reporting a network fault that never "
                + "happened. **Both keys are exercised, and the second is the one that was wrong**: the "
                + "sync needs an address *and* a credential, so a build holding one and missing the other "
                + "is a state that exists — and this sentence used to be a constant naming the address, "
                + "which on that build sent its reader to check a line they had already filled in. The "
                + "key is a parameter now, and this is the pair of calls that says so")
        assertTest(
            ![ProfileDashboardView.storageKeyNote,
              ProfileDashboardView.storageDestinationNote(for: .device),
              ProfileDashboardView.storageDestinationNote(for: .cloud),
              ProfileDashboardView.storageRangeNote(isEnabled: true),
              ProfileDashboardView.storageRangeNote(isEnabled: false),
              ProfileDashboardView.storageResourcesNote,
              ProfileDashboardView.storageNoDatabaseNotice(missingKey: WhoopsyAPIClient.baseURLInfoKey)]
                .contains { $0.contains("**") },
            "…and none of the pane's seven paragraphs carries Markdown. This is the `Text` trap this repo "
                + "already carries: a `String` built with `+` takes the `StringProtocol` overload, which "
                + "does not parse Markdown, so an `**emphasis**` would be drawn as literal asterisks on a "
                + "screen no test and no compiler can see")

        // ---- The `STORAGE` pane's `SYNCED RESOURCES` list ----
        //
        // The list is a `ForEach` over `SyncedResource.allCases`, so what is assertable here is the
        // *enum* rather than the drawing — and §22 is where the one assertion that needs the contract
        // lives, because it reads `shared/openapi.json`. These are the two facts about the list that are
        // a property of this app: how many resources move, and the one that deliberately does not.
        //
        // **The count is pinned rather than derived**, because the number is the thing a reader is being
        // told: "seven resources travel, the eighth stays" is the pane's whole answer, and a resource
        // added to the enum without anyone deciding whether it should move would change the answer
        // silently. `biometricSamples` is the exclusion the count encodes, and the note's second half is
        // asserted alongside it so the list and the prose cannot come apart.
        assertTest(
            SyncedResource.allCases.count == 7,
            "Seven resources are drawn on the `SYNCED RESOURCES` list — the Worker carries eight, and the "
                + "count is pinned because *how many of my things travel* is the question the pane exists "
                + "to answer. A resource added to the enum changes that answer, and this is the line that "
                + "makes it a decision rather than an accident")
        assertTest(
            !SyncedResource.allCases.contains { $0.resourceName == "biometricSamples" }
                && ProfileDashboardView.storageResourcesNote.contains("Biometric samples"),
            "…and the eighth resource is named in the note rather than listed. Its absence is the list's "
                + "most misleading property — the Worker carries it, so a reader who has seen the "
                + "database's own documentation would expect it here — so a list that simply omitted it "
                + "would read as this app forgetting one. The pair is asserted together: the enum's "
                + "exclusion is the behaviour and the sentence is how a reader is told about it")
        assertTest(
            SyncedResource.allCases.allSatisfy { $0.rawValue == $0.rawValue.uppercased() },
            "…and every title is stored uppercase, because that is the case it is drawn in: this list "
                + "applies no `.textCase`, so a sentence-case literal would draw sentence case in a column "
                + "of capitals — `ProfileDashboardView.Tab`'s rule, two panes deeper")
        assertTest(
            Set(SyncedResource.allCases.map(\.rawValue)).count == SyncedResource.allCases.count
                && Set(SyncedResource.allCases.map(\.path)).count == SyncedResource.allCases.count
                && Set(SyncedResource.allCases.map(\.resourceName)).count == SyncedResource.allCases.count,
            "…and the three spellings of every resource are all distinct — the drawn title, the mounted "
                + "path and the Worker's own name. This is the three-way split `CLAUDE.md` records for "
                + "this resource, and it is a trap in both directions: two cases sharing a path would send "
                + "one resource's rows to another's route, and a title colliding with another title would "
                + "draw two identical lines on the screen with no way to tell them apart")

        // ---- The list survives the pane's branch ----
        //
        // **`SYNCED RESOURCES` is the one row both arms of the pane draw, and that is a fact about a
        // `body` rather than about a value.** `storageTab` is a two-armed `if`: a configured build gets
        // the key, the destination, the span and the run, and an unconfigured one gets a single sentence
        // instead, because every control on the pane would fail for a reason the screen cannot fix. The
        // list is drawn in **both**, and the reason is on its own eyebrow: *what would move* is a fact
        // about this app rather than about this build's configuration. On the build that has no database
        // behind it — which is every build in this repository — it is the only content the pane has, so
        // a list that fell inside the branch would leave the whole pane reading as a single apology.
        //
        // **The runner has no renderer, so this is a scan of the view's own source**, which is §22.7's
        // method for the same class of claim. What makes it an assertion rather than a search is the
        // counts: two occurrences of the row, one of the sentence, and one of the configured arm's own
        // `destinationRow` — so moving the list inside the branch, or leaving the `else` arm with the
        // sentence alone, fails here, and a scan that had read only one arm cannot pass the others.
        let pane = try storagePaneSource()
        assertTest(
            pane.components(separatedBy: "syncedResourcesRow").count == 3,
            "`storageTab` draws the `SYNCED RESOURCES` list twice — once in each arm — so neither a "
                + "configured nor an unconfigured build can open the pane to a list that is missing")
        assertTest(
            pane.components(separatedBy: "storageNoDatabaseNotice").count == 2
                && pane.components(separatedBy: "missingCloudKey").count == 2,
            "…and the other arm is in the same text, drawing the sentence that names whichever "
                + "`Info.plist` key is missing rather than reporting a fault that never happened. **The "
                + "arm is bound to `missingCloudKey`**, which is the second count: the pane branches on "
                + "*which key* is absent rather than on a flag, and that is what lets the sentence name "
                + "the right line — a `Bool` here would make the two arms' conditions the same while "
                + "leaving the sentence with nothing to interpolate")
        assertTest(
            pane.components(separatedBy: "destinationRow").count == 2,
            "…beside the configured arm's own destination row, once — so the two counts above are two "
                + "arms of one `if` and not one arm counted twice")

        // ---- The `LOGS` pane's `Whoop` section ----
        //
        // Three buttons, one per bundled CSV, on the user's instruction — *"remove 're-import whoop
        // history', instead i want 3 seperate buttons that import one of each whoop csv file, this would be
        // the Whoop section, only file i dont want to use is journal_entries.csv"*. The section is built by
        // a `ForEach` over `WhoopImportAction.all`, so these assertions are about the section's whole shape
        // rather than about a drawing: the count, the order, the words, and the file that is deliberately
        // absent. What the runner cannot see is the card styling on the buttons and their captions — that
        // is the reader's to check on a phone.

        assertTest(
            WhoopImportAction.all.count == 3,
            "The `Whoop` section draws exactly three rows, one per bundled CSV — the whole of what the "
                + "user asked for, and the figure a fourth file would silently change")
        assertTest(
            WhoopImportAction.all.map(\.file) == [.cycles, .naps, .workouts],
            "…in the declaration order of `WhoopExportFile`, which `all` derives from `allCases` rather "
                + "than restating: the order *is* the drawing, and an array written out by hand is a second "
                + "list free to disagree with the enum it mirrors")
        assertTest(
            WhoopImportAction.all.map(\.title) == ["IMPORT RECOVERY & SLEEP", "IMPORT NAPS", "IMPORT WORKOUTS"],
            "…each titled for what it lands rather than for the section it sits in. Pinned in the case it "
                + "is drawn in, because the button treatment is bold tracked capitals and a `.textCase` in "
                + "the `body` would put half of what the reader sees where nothing here can read it")
        assertTest(
            Set(WhoopImportAction.all.map(\.file.rawValue)) == Set(WhoopExportFile.allCases.map(\.rawValue))
                && WhoopImportAction.all.allSatisfy { !$0.caption.isEmpty },
            "…and the rows and the file list are the same set, so a case added to the enum reaches a button "
                + "through `all` without an edit here — the exhaustive `switch` in `make(for:)` is what makes "
                + "one that *cannot* reach a button a compile error rather than a missing row")

        assertTest(
            !WhoopExportFile.allCases.contains { $0.rawValue == "journal_entries.csv" },
            "`journal_entries.csv` is deliberately not one of the three, which is the user's own "
                + "*\"only file i dont want to use\"*. It is the fourth CSV on disk and the only one that is "
                + "unbundled — `Package.swift` processes the three above and nothing else — so a case for it "
                + "would draw a button that imports nothing under a filename promising otherwise")
        assertTest(
            WhoopExportFile.allCases.map(\.rawValue)
                == ["physiological_cycles.csv", "sleeps.csv", "workouts.csv"],
            "…and the raw value is the filename verbatim, so the mapping from a button to a bundled "
                + "resource is readable rather than a lookup table's second copy")

        // ---- The `LOGS` pane's `Zero Fasting` section ----
        //
        // One row, given the same treatment as the three above it — *"do same for zero fasting app section,
        // well only use biodata.json (fasting data)"* — and asserted the same way and for the same reason:
        // the words live on a value rather than in a `body`, so the section cannot be drawn without them and
        // the runner can read them. That it is a section of its own rather than a fourth `Whoop` row is a
        // consequence of it being a **different producer's file** whose rows carry no measurement, which is
        // the pair `WhoopExportFile` cannot express — §20 covers the importer behind it.
        //
        // **The two names are pinned one here and one in §20, and separating them is the user's own
        // correction.** *"so my modified version was fasts.json, in UI refer to it as "biodata.json" as thats
        // what zero gives when exporting"* — the resource this build ships is `fasts.json` (the assertion in
        // §20, on the importer), and the name a reader sees on the button is `biodata.json` (the assertion
        // just below, on the value the screen draws). They describe one file: the projection and the export
        // it was cut from. Writing either into the other's place is what these two assertions exist to catch,
        // and neither can be seen from a screenshot — one is a string in a bundle and the other is a caption.
        // What the runner still cannot see is the card styling — that is the reader's.

        assertTest(
            FastingImportAction.fileName == "biodata.json",
            "The row names the file **Zero hands a user on export** — `biodata.json` — and not the name of the "
                + "resource this build carries. The user's instruction is exact about the split: their "
                + "trimmed copy is `fasts.json`, and the UI is to say `biodata.json` because *\"thats what zero "
                + "gives when exporting\"*. The caption is built from this constant rather than repeating the "
                + "word, so the sentence cannot come to name a file the button does not read")
        assertTest(
            FastingImportAction.fasting.caption.contains(FastingImportAction.fileName),
            "…and the caption actually names it, which is what makes the constant above a fact about the "
                + "screen rather than a string nobody reads. A caption that drifted to the resource's name "
                + "would leave both assertions passing on their own and the button describing a file the "
                + "user has never seen")
        assertTest(
            FastingImportAction.fasting.title == "IMPORT FASTING HISTORY",
            "The `Zero Fasting` section's one row is titled in the case it is drawn in, on the same rule as "
                + "the three above it — the treatment is bold tracked capitals and a `.textCase` in the "
                + "`body` would put half of what the reader sees where nothing here can read it. It names "
                + "what lands rather than repeating the section header")
        assertTest(
            !FastingImportAction.fasting.caption.isEmpty,
            "…and it carries a caption, which is the whole of what tells a reader that a fast has no "
                + "measurement behind it and that a deleted fast comes back — neither is visible from the "
                + "button, and the caveat is restated here rather than read off the export's caption, "
                + "because an import that skips days and one that skips none reach it from opposite "
                + "directions")
        assertTest(
            ![FastingImportAction.fasting.caption, FastingImportAction.fasting.title]
                .contains { $0.contains("**") || $0.contains("`") },
            "…and neither the title nor the caption carries Markdown. Both reach `Text` as `String`s rather "
                + "than as literals, which takes the `StringProtocol` overload and parses nothing, so "
                + "backticks around a filename or asterisks around a phrase would render literally, "
                + "characters and all — a failure no compiler and no screenshot of another row can see")

        // ---- The `LOGS` pane's `Receptive inactivities` section ----
        //
        // The pane's fourth import section and the first whose header does not name a producer app. The
        // user's instruction is exact — *"Screen names the inactivity too"* — so the section, the button
        // and the row type all take the row's name rather than the file's, and this is the one section
        // here that is titled for what it *makes* rather than for where the file came from.
        //
        // **That deviation is why the header is a constant on the value and not a literal in the `body`.**
        // `Apple Health`, `Whoop` and `Zero Fasting` are typed where they are drawn, so nothing can read
        // them — and the same was true of this header until it was hoisted, which is what makes it the
        // only one of the four that is assertable at all. `WhoopsyExportAction.sectionTitle` is the
        // precedent, held for the same reason: the runner has no renderer, so a string typed into a
        // `body` is a string nothing can check, and the deviation would be a claim in a comment rather
        // than something a failing run could contradict.
        //
        // **The two words are the Home card's, and that correspondence cannot be asserted from here.**
        // `HomeDashboardView` draws `Text("RECEPTIVE INACTIVITIES")` — a bare literal in a `body`, with
        // no constant behind it — so there is nothing to compare this header against. What *is* pinned
        // is the header's own letters, and the second assertion states that half honestly rather than
        // pretending to a coupling that does not exist.

        assertTest(
            InactivityImportAction.sectionTitle == "Receptive inactivities",
            "The section is titled **`Receptive inactivities`** — the row the import produces, in title "
                + "case, which the `Form` draws in capitals. It is the one header on this pane that names "
                + "neither a producer app nor this app, and the deviation is the user's own instruction "
                + "(`Screen names the inactivity too`) rather than an oversight: the file is the owner's "
                + "own notes log, so there is no app to name. Held as a constant so the deviation is "
                + "assertable at all — its three neighbours are literals in the `body`, where nothing here "
                + "can reach them")
        assertTest(
            InactivityImportAction.sectionTitle.uppercased() == "RECEPTIVE INACTIVITIES",
            "…and once the `Form` uppercases it, it reads as the same two words as the Home card it fills. "
                + "That is stated as a property of the letters rather than as a comparison against the "
                + "card, and the difference matters: the card's title is a literal with no constant "
                + "behind it, so renaming *it* would not fail this — but renaming the header to anything "
                + "whose capitals are not the card's name does, which is the half that is reachable")

        assertTest(
            InactivityImportAction.fileName == "dreams.json",
            "The row names the file the reader has — `dreams.json`, the generator's own output beside the "
                + "`dreams.csv` it was drawn from, which is what a person following the caption would go "
                + "and look for. It is a separate constant from `InactivityImporter.bundledResourceName`, "
                + "on the split `FastingImportAction` already carries and for its reason: the name on "
                + "screen and the name of the resource answer to different readers, and §21 pins the "
                + "other one, so neither can drift into the other's place")
        assertTest(
            InactivityImportAction.inactivities.caption.contains(InactivityImportAction.fileName),
            "…and the caption actually names it, so the constant above is a fact about the screen rather "
                + "than a string nobody reads. The caption is *built* from it with `+` rather than "
                + "repeating the word, so the sentence cannot come to name a file the button does not read "
                + "while both assertions pass on their own")
        assertTest(
            InactivityImportAction.inactivities.title == "IMPORT RECEPTIVE INACTIVITIES",
            "The section's one row is titled in the case it is drawn in, on the same rule as the four "
                + "rows above it — the treatment is bold tracked capitals, and a `.textCase` in the `body` "
                + "would put half of what the reader sees where nothing here can read it. It names the row "
                + "that lands rather than the file it came from: `IMPORT DREAMS` would be a second name "
                + "for a thing the card, the picker and this header already call one")
        assertTest(
            !InactivityImportAction.inactivities.caption.isEmpty,
            "…and it carries a caption, which is the whole of what tells a reader that no entry has a "
                + "clock and that re-importing writes the file's text back over their own edits. Neither "
                + "is visible from the button, and the second is the consequence §21 confirms on a real "
                + "database rather than assumes — this import skips no day, because each entry's key is "
                + "derived from its own content and is disjoint from every other producer's")
        assertTest(
            ![InactivityImportAction.inactivities.caption, InactivityImportAction.inactivities.title]
                .contains { $0.contains("**") || $0.contains("`") },
            "…and neither the title nor the caption carries Markdown. Both reach `Text` as `String`s "
                + "rather than as literals, which takes the `StringProtocol` overload and parses nothing, "
                + "so backticks around `dreams.json` would render literally, characters and all — a "
                + "failure no compiler and no screenshot of another row can see")

        // ---- The `LOGS` pane's `Whoopsy` section ----
        //
        // The one section on that pane that takes data **out**, added on the user's instruction —
        // *"instead of "Local Backup", lets add another section called Whoopsy to export whoopsy data,
        // which would be everything from wherever user stores their data, local or a database"*. Its words
        // live on `WhoopsyExportAction`, a value, for this repo's standing reason: the runner has no
        // renderer, so a header or a caption typed into a `body` is a string nothing can read.
        //
        // **What the runner can see here is the section's identity and its two promises; what it cannot is
        // that the export is complete.** That half is §6's, because it needs a database — the coverage
        // assertion there compares the export's table set against `existingTableNames()`, which is the same
        // `sqlite_master` query the export walks, so a migration that adds a table cannot land unexported.
        // Splitting them that way is deliberate: this block still asserts if §6's database read throws, and
        // §6's block asserts the file rather than the words.

        assertTest(
            WhoopsyExportAction.sectionTitle == "Whoopsy",
            "The section is titled `Whoopsy` — the user's own word, and the same sentence the three "
                + "headers above it are making: `Apple Health`, `Whoop` and `Zero Fasting` each name the "
                + "app a file came **from**, and this one names the app that wrote it. Held as a constant "
                + "rather than typed into the `body` so the runner can read it")
        assertTest(
            WhoopsyExportAction.sectionTitle != "Local backup",
            "…it is not the `Local backup` it replaced, and that is a correction the user made rather than "
                + "a rename. `Local` was a claim about where the data lives, and this file holds everything "
                + "stored wherever it is stored; `Backup` promised a restore this app does not have, since "
                + "nothing in `Sources/` reads an exported file back. Reverting the header is what this "
                + "assertion catches")
        assertTest(
            ![WhoopImportAction.all.map(\.title),
              [FastingImportAction.fasting.title],
              [InactivityImportAction.inactivities.title]]
                .flatMap { $0 }.contains(WhoopsyExportAction.sectionTitle),
            "…and it collides with none of the five rows above it, which is the failure a shared header "
                + "would draw: two sections of one name on one pane, with nothing on either saying which "
                + "is which. The fifth is the receptive-inactivity row, added here rather than left out — "
                + "an array that stopped covering the pane would go on passing while covering less")

        assertTest(
            WhoopsyExportAction.export.title == "EXPORT WHOOPSY DATA",
            "The row is titled in the case it is drawn in, on the same rule as the four action rows above "
                + "it — this app's button idiom is bold tracked capitals and a `.textCase` in the `body` "
                + "would put half of what the reader sees where nothing here can read it")
        assertTest(
            !WhoopsyExportAction.export.caption.isEmpty,
            "…and it carries a caption, which is the whole of what tells a reader what is in the file and "
                + "that nothing reads it back — neither is visible from the button")

        // **The caption's two load-bearing claims, and each is one half of the instruction.** They are
        // asserted as substrings rather than pinned whole, on the `FastingImportAction.fileName` precedent:
        // the sentence is prose and may be rewritten, but a rewrite that drops either claim is changing what
        // the section promises rather than how it says it — so it should have to move these lines too.
        assertTest(
            WhoopsyExportAction.export.caption.lowercased().contains("settings"),
            "…and the caption names the settings, which is the load-bearing half of *\"everything from "
                + "wherever user stores their data, local or a database\"*: this app stores data in two "
                + "places, and `AppPreferences` — the unit choice and the three toggles, including the "
                + "anonymous-diagnostics switch that is the whole of the Settings page — is in `UserDefaults` "
                + "rather than in any table. An export reading only the database would leave it out, and a "
                + "caption describing only tables would describe a smaller file than the button writes")
        assertTest(
            WhoopsyExportAction.export.caption.lowercased().contains("no time limit"),
            "…and it says there is no time limit, which is the correction a reader who has seen the old "
                + "file needs: the export this replaced was a 30-day window whose JSON carried four counts, "
                + "so `a recent window` is the reasonable thing to expect of a button that has quietly "
                + "started writing the whole record")
        assertTest(
            ![WhoopsyExportAction.export.caption, WhoopsyExportAction.export.title]
                .contains { $0.contains("**") || $0.contains("`") },
            "…and neither the title nor the caption carries Markdown, on the `FastingImportAction` pair's "
                + "reason verbatim: both reach `Text` as `String`s rather than as literals, which takes the "
                + "`StringProtocol` overload and parses nothing, so asterisks or backticks would render "
                + "literally — a failure no compiler and no screenshot of another row can see")

        // ---- The `UNITS` control's shape ----
        //
        // `SegmentedPillControl` is a drawing, and the runner has no renderer — so what is assertable about
        // it is the four numbers it lays itself out with and the words it is handed, which is the same
        // bargain `UnderlinedTabRow`'s constants and `ActivityOverflowMenu`'s rows are held to. The
        // *behaviour* behind it is asserted elsewhere and is untouched by the restyle: the conversion pair
        // above, and the re-seed that keeps a unit switch out of storage.

        assertTest(
            ActivityRoute.Unit.displayOrder.map(\.title) == ["IMPERIAL", "METRIC"],
            "The `UNITS` control draws `IMPERIAL` on the left and `METRIC` on the right — and the list is "
                + "`Unit.displayOrder` rather than the declaration order, which is why `metric` being "
                + "declared first cannot flip the selected segment to the other side of the track")

        assertTest(
            ActivityRoute.Unit.displayOrder == [.imperial, .metric]
                && ActivityRoute.Unit.displayOrder.count == 2,
            "…and it holds both cases exactly once, so the control always draws two segments — a list that "
                + "lost a case would draw a one-segment control whose only segment is always selected, which "
                + "is a toggle that cannot be toggled and looks like a label")

        assertTest(
            SegmentedPillControl.pillRadius == SegmentedPillControl.trackRadius - SegmentedPillControl.trackInset,
            "The pill's radius is the track's less the inset, so the two shapes are concentric. Picked "
                + "instead, the difference shows as a sliver of track at each of the pill's corners — which "
                + "reads as a misalignment rather than as a radius that is slightly wrong, and is invisible "
                + "to the compiler, to this runner and to any screenshot of the other segment")

        assertTest(
            SegmentedPillControl.tracking == UnderlinedTabRow.tracking,
            "The control's letter-spacing is the tab row's, so the two controls on this page and the field "
                + "names above them share one treatment — three copies that agree today are three places a "
                + "restyle can move one and miss two")

        do {
            let bodyProfile = UserProfile(
                name: "Alex",
                birthDate: DateComponents(calendar: .current, year: 1985, month: 8, day: 10).date!,
                maxHeartRate: 190,
                restingHeartRate: 52,
                weightKg: 87.0897,
                heightCm: 187.96,
                gender: .man)

            let seededMetric = ProfileFormSnapshot.rendering(bodyProfile, in: .metric)
            let seededImperial = ProfileFormSnapshot.rendering(bodyProfile, in: .imperial)

            assertTest(
                !seededMetric.isDirty(against: seededMetric),
                "A form seeded from a stored body and compared against its own seed is clean — which is "
                    + "the mockup's greyed `SAVE` on open, and the state the button is built to draw")

            assertTest(
                seededImperial.isDirty(against: seededMetric),
                "…while the same body renders **different text** in the two systems, which is what makes "
                    + "re-seeding on a unit switch necessary rather than tidy: a view model that flipped "
                    + "the unit without re-rendering its seed would leave `SAVE` full-strength over a body "
                    + "the user has not touched")

            // The seed is the thing that moves, not the comparison: `select(unit:)` re-renders from the
            // stored profile, so the form is clean again the moment the switch lands.
            let reseeded = ProfileFormSnapshot.rendering(bodyProfile, in: .imperial)
            assertTest(
                !reseeded.isDirty(against: seededImperial),
                "…and a switch that re-seeds leaves the form clean, which is the property that keeps "
                    + "display rounding out of storage — without it every unit toggle would enable `SAVE` "
                    + "and each press would compound a half-step")

            var typedInto = seededMetric
            typedInto.weightText = "88"
            assertTest(
                typedInto.isDirty(against: seededMetric),
                "One box typed into makes the form dirty — the gate is a comparison of the eight boxes, "
                    + "not eight `@State` copies of 'was this touched', so a field cannot be edited and "
                    + "leave the button dark")

            assertTest(
                seededMetric.birthday == bodyProfile.birthDate!.startOfDay
                    && seededImperial.birthday == seededMetric.birthday,
                "The snapshot holds the birthday at `startOfDay` and identically in both systems — a "
                    + "`DatePicker` hands back an instant carrying the current clock time, so a birthday "
                    + "kept whole would compare unequal to its own seed and leave `SAVE` permanently live")

            assertTest(
                ProfileFormSnapshot.rendering(
                    UserProfile(maxHeartRate: 190, restingHeartRate: 60), in: .metric)
                    == ProfileFormSnapshot(
                        nameText: "", heightText: "", inchesText: "", weightText: "",
                        maxHeartRateText: "190", restingHeartRateText: "60"),
                "A profile nobody has described seeds a form of empty boxes — the four `v20` fields draw "
                    + "as absent rather than as the `Athlete`, the birthday and the `178.0` this app used "
                    + "to type on the user's behalf, and the two heart rates still draw because they are "
                    + "the zone table's floor and ceiling rather than facts about a body")
        }

        // ---- The profile row, round-tripped ----
        //
        // **This block was written before the mapper it tests, and that order is the point.** GRDB's `save`
        // is INSERT-or-UPDATE over the **whole row**, so a `saveUserProfile` left building a three-field
        // `UserProfileRecord` writes `NULL` over `name`, `birthDate`, `gender` and `heightCm` on every
        // save — no throw, no log, and the symptom is a form that is empty on the second launch. Nothing
        // else in this suite can see it: the record compiles, the migration runs, and the read path is a
        // different function. So this is the only thing standing between the profile page and a body it
        // silently forgets.
        //
        // The other half is the flip `v20` makes. `name`, `birthDate` and `heightCm` were initialiser
        // defaults that no row could override — `"Athlete"`, *28 years before `Date()`*, `178.0` — and the
        // assertion below is that a profile carrying none of them reads back as carrying none, rather than
        // as the three numbers this app used to type on the user's behalf.

        do {
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBUserProfileRepository(db: db)

            // The record declares no `CodingKeys`, so these property names *are* the column names. A
            // snake_case column here writes nothing and reads `NULL` forever with **no error raised** —
            // the failure mode `CLAUDE.md` records against `RecoveryRecord`'s explicit mapping and
            // `StrainRecord`'s absence of one.
            let columns = Set(try await db.columnNames(in: "user_profiles"))
            assertTest(
                Set(["id", "maxHeartRate", "restingHeartRate", "weightKg",
                     "name", "birthDate", "gender", "heightCm"]).isSubset(of: columns),
                "Every property `UserProfileRecord` declares is a real column on `user_profiles` — the "
                    + "record declares no `CodingKeys`, so a name that is not a column is not an error "
                    + "anywhere, it is a value that writes nothing and reads `NULL` forever")

            // The birthday is `Aug 10, 1985` at midnight, which is what a `DatePicker` writing
            // `displayedComponents: .date` produces and what the form's snapshot holds.
            let birthday = DateComponents(calendar: .current, year: 1985, month: 8, day: 10).date!

            let supplied = UserProfile(
                name: "Alex",
                birthDate: birthday,
                maxHeartRate: 190,
                restingHeartRate: 52,
                weightKg: 87.0897,
                heightCm: 187.96,
                gender: .man
            )
            try await repository.saveUserProfile(supplied)
            let read = try await repository.getUserProfile()

            assertTest(
                read.name == "Alex" && read.gender == .man,
                "A save carrying a name and a gender reads both back — **the assertion that fails if "
                    + "`saveUserProfile`'s mapper is left at three fields**, because `save` writes the "
                    + "whole row and the four it omits become `NULL`")

            assertTest(
                read.birthDate == birthday.startOfDay && read.heightCm == 187.96,
                "…and so do the birthday and the height, which are the other two columns the mapper "
                    + "could drop: four fields, four ways to lose a body the user typed")

            assertTest(
                read.weightKg == 87.0897 && read.maxHeartRate == 190 && read.restingHeartRate == 52,
                "…beside the three the row already carried, unmoved — one save writes all seven, and the "
                    + "old three are not collateral")

            // The flip, in the other direction: nothing supplied, nothing invented.
            let empty = UserProfile(maxHeartRate: 190, restingHeartRate: 60)
            try await repository.saveUserProfile(empty)
            let cleared = try await repository.getUserProfile()

            assertTest(
                cleared.name == nil && cleared.birthDate == nil
                    && cleared.gender == nil && cleared.heightCm == nil,
                "A profile carrying no body facts reads back carrying none — `v20` deleted the `Athlete`, "
                    + "the birthday 28 years before *now* and the `178.0`, and `nil` is what they always "
                    + "were: facts nobody supplied")

            assertTest(
                cleared.weightKg == nil && cleared.maxHeartRate == 190,
                "…which is also how the form is *cleared*: `nil` is a real value rather than 'leave it "
                    + "alone', so emptying a field and saving it must empty the column")

            assertTest(
                UserProfile.default.name == nil && UserProfile.default.birthDate == nil
                    && UserProfile.default.heightCm == nil && UserProfile.default.gender == nil
                    && UserProfile.default.age == nil,
                "…and the entity's own `default` carries none of them either, `age` included — an absent "
                    + "birth date must produce no age rather than a twenty-eight-year-old")

            // A vocabulary this build cannot describe reads back as *not supplied* rather than being
            // guessed into a neighbouring case — `UserDefaultsStrapModelRepository`'s rule for a strap
            // generation, applied to a word. Written straight to the column, because no `UserProfile`
            // can carry a case that does not exist.
            let stranger = UserProfileRecord(
                maxHeartRate: 190, restingHeartRate: 60, gender: "male")
            try await db.saveProfile(stranger)
            let unmapped = try await repository.getUserProfile()
            assertTest(
                unmapped.gender == nil,
                "A stored gender this build has no case for reads back as not supplied — never as a "
                    + "neighbouring case, which would put a word in the picker the user did not choose")

            assertTest(
                UserProfile.Gender.allCases.map(\.rawValue)
                    == ["man", "woman", "nonBinary", "preferNotToSay"]
                    && UserProfile.Gender(rawValue: "male") == nil,
                "The gender vocabulary is pinned — the four raw values are the stored column's whole "
                    + "content, so a rename is a migration and not a spelling change")

            assertTest(
                UserProfile.Gender.allCases.map(\.title)
                    == ["Man", "Woman", "Non-binary", "Prefer not to say"],
                "…and each case's title is the word the `GENDER` picker draws, pinned here because the "
                    + "runner has no renderer to read it off the row")
        } catch {
            assertTest(false, "The profile row's round trip threw: \(error)")
        }
    }
}

// MARK: - Reading the pane's source

/// `storageTab`'s own text: from its declaration to the next member of the view.
///
/// **A slice rather than the whole file, because the counts are the assertion.** The pane's two arms are
/// one `if`, and the only thing separating "the list is drawn in both" from "the list is drawn once and
/// the sentence twice" is counting occurrences *inside that one property*. The slice runs from the
/// declaration to the next `private` at the type's own indent — every line inside the body is indented
/// at least eight spaces, so a `private` at four is the member that ends it — and a slice that came back
/// empty, or ran to the end of the file, would fail all three counts rather than pass them quietly.
///
/// The path is climbed from `#filePath` through `Support/TestResourceURLs.swift`'s `packageRoot()`,
/// which is `ios/` — the reason this reads a file rather than a bundle: the view's source is not a
/// resource and `Bundle.module` would not carry it. It is read as text, and the assertions above are
/// about text, which is exactly what makes them weaker than the runner's other blocks: what is proven
/// here is that the row is *written* twice, not that SwiftUI draws it twice.
private func storagePaneSource() throws -> String {
    let url = packageRoot().appendingPathComponent(
        "Sources/Whoopsy/Presentation/Screens/Profile/ProfileDashboardView.swift")

    let source: String
    do {
        source = try String(contentsOf: url, encoding: .utf8)
    } catch {
        assertTest(false, "The profile view's source is readable at \(url.path): \(error)")
        throw error
    }

    guard let declaration = source.range(of: "private var storageTab: some View {") else {
        assertTest(false, "`ProfileDashboardView` declares `storageTab`")
        return ""
    }
    let body = source[declaration.upperBound...]
    let end = body.range(of: "\n    private ")?.lowerBound ?? body.endIndex
    return String(body[..<end])
}
