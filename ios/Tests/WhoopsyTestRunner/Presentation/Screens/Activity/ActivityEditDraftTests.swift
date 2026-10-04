import Foundation
import Whoopsy

enum ActivityEditDraftTests {
    static func run() async throws {
        // MARK: - The duration formatter

        assertTest(
            280_860.0.formattedDayHoursMinutes() == "3 days 6 hrs",
            "78 h 01 m is the reference's own `3 days 6 hrs`, and above a day the minutes are dropped — "
                + "which is what makes that figure reproduce exactly, and the honest precision for a "
                + "span whose minutes are an artefact of when the user tapped "
                + "(\(280_860.0.formattedDayHoursMinutes()))")

        assertTest(
            (86 * 3600.0 + 60).formattedDayHoursMinutes() == "3 days 14 hrs",
            "…and the flagship 86-hour fast reads `3 days 14 hrs`, which is the figure the simulator "
                + "check steps through (\((86 * 3600.0 + 60).formattedDayHoursMinutes()))")

        assertTest(
            52_320.0.formattedDayHoursMinutes() == "14 hrs 32 min"
                && 1_920.0.formattedDayHoursMinutes() == "32 min"
                && 3_600.0.formattedDayHoursMinutes() == "1 hr"
                && 60.0.formattedDayHoursMinutes() == "1 min",
            "…and below a day the minutes are kept, with singular forms elided — one hour reads `1 hr` "
                + "and never `1 hrs` (\(52_320.0.formattedDayHoursMinutes()))")

        assertTest(
            86_400.0.formattedDayHoursMinutes() == "1 day"
                && 93_600.0.formattedDayHoursMinutes() == "1 day 2 hrs"
                && 0.0.formattedDayHoursMinutes() == "0 min",
            "…and a component that is exactly zero is dropped rather than printed: 24 h is `1 day` and "
                + "not `1 day 0 hrs`, and a span under a minute is `0 min` rather than an empty string "
                + "under a label that promises a figure (\(86_400.0.formattedDayHoursMinutes()))")

        // MARK: - The edit sheet's draft

        // `ActivityEditDraft` is the one value both of the sheet's time controls write through — the drag
        // handle at each end of the chart and the compact `DatePicker` under `Start Time`/`End Time` — so
        // every rule about what an edit *is* lives here rather than in the sheet's `body`, for this repo's
        // standing reason: a clamp written into a `View` is a rule nothing can check.
        //
        // The fixture carries **non-zero seconds**, which is the case the minute-write guard exists for:
        // 381 of the bundled export's 673 rows do, and it is those rows a `.hourAndMinute` `DatePicker` can
        // quietly move for a user who never touched a control.
        // The fixture is anchored on a whole minute plus 33 s rather than on `anchor`, so **where in its
        // minute it starts is a fact this block states** instead of a fact about `1_700_000_000`. Two
        // assertions below turn on that: a write that lands in the same minute must be dropped, and one
        // that crosses into the next must be kept, and both are unreadable if "same minute" depends on
        // arithmetic the reader has to redo.
        let minuteStart = Date(
            timeIntervalSince1970: (ActivityDetailTests.anchor.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let secondRow = WorkoutSession(
            startedAt: minuteStart.addingTimeInterval(33),
            endedAt: minuteStart.addingTimeInterval(33 + 900),
            strain: 5.2,
            averageHeartRate: 121,
            maxHeartRate: 164,
            route: [],
            splits: [],
            source: WhoopExportImporter.sourceLabel,
            activityName: "Basketball",
            hrZonePercents: [12, 26, 34, 18, 4],
            steps: 693)

        let untouched = ActivityEditDraft(secondRow)
        assertTest(
            !untouched.hasChanges && untouched.start == secondRow.startedAt
                && untouched.end == secondRow.endedAt,
            "A draft opened on a session reports **no change** and holds that session's exact instants, "
                + "seconds and all — this one carries \(Int(secondRow.startedAt.timeIntervalSince1970) % 60) "
                + "s. A draft that clamped or minute-floored at `init` would move the window of all 381 "
                + "such rows in the export, and the `SAVE` that did it would be one the user made over a "
                + "name")
        assertTest(
            untouched.startFraction == 0 && untouched.endFraction == 1
                && untouched.durationSeconds == 900,
            "…and the untouched draft's two handles sit at the plot's own ends. The fractions are "
                + "**computed from the draft on every read** rather than stored, which is what keeps a "
                + "handle and the readout above it from naming two different times")

        let shortSession = WorkoutSession(
            startedAt: ActivityDetailTests.anchor, endedAt: ActivityDetailTests.anchor.addingTimeInterval(40),
            strain: 1, averageHeartRate: 90, maxHeartRate: 110, route: [], splits: [])
        assertTest(
            untouched.minimumDuration == 60 && ActivityEditDraft(shortSession).minimumDuration == 40,
            "The floor is **`min(60, the session's own length)`** and not a flat minute: on a session "
                + "shorter than a minute, `end - 60` is *before* the original start, and the clamp's own "
                + "lower bound would then push the start backwards and lengthen the session — the one "
                + "thing a trim exists to forbid")

        var inward = ActivityEditDraft(secondRow)
        inward.setStart(secondRow.startedAt.addingTimeInterval(-600))
        inward.setEnd(secondRow.endedAt.addingTimeInterval(600))
        assertTest(
            inward.start == secondRow.startedAt && inward.end == secondRow.endedAt
                && !inward.hasChanges,
            "**The window narrows and never widens.** Handles dragged past either end of the recording "
                + "leave the draft exactly where it was, because the plot *is* the original window — a "
                + "handle outside it would have nowhere to be drawn — and because extending a session "
                + "would be inventing time the app never observed")

        var floored = ActivityEditDraft(secondRow)
        floored.setEnd(secondRow.startedAt.addingTimeInterval(27))
        assertTest(
            floored.end == secondRow.startedAt.addingTimeInterval(60)
                && floored.durationSeconds == 60,
            "…and an end dragged to less than a minute past the start clamps to exactly "
                + "`minimumDuration` later rather than crossing it, so no edit this sheet can make "
                + "produces a zero-length or negative session "
                + "(\(floored.durationSeconds) s)")

        // The minute-write guard, which is the rule that makes an untouched sheet *stay* untouched. Both
        // fixtures move the instant **forward within the same minute**, which is the only direction where
        // the guard is the thing doing the work: a backwards write is caught by the clamp's own low bound
        // as well, so an assertion built on one cannot tell the two rules apart.
        var sameMinute = ActivityEditDraft(secondRow)
        sameMinute.setStart(secondRow.startedAt.addingTimeInterval(14))
        assertTest(
            sameMinute.start == secondRow.startedAt && !sameMinute.hasChanges,
            "A `DatePicker` handed `2:17:33` shows `2:17` and can hand back **`2:17:00`** — and the "
                + "minute it hands back can be the same one it was given. That write is dropped and the "
                + "stored instant survives to the second — without this guard a picker that was merely "
                + "drawn would report a change, enable `SAVE`, and rewrite the start of every row in the "
                + "export that carries seconds")

        var movedMinute = ActivityEditDraft(secondRow)
        movedMinute.setStart(secondRow.startedAt.addingTimeInterval(27))
        assertTest(
            movedMinute.start == secondRow.startedAt.addingTimeInterval(27)
                && movedMinute.hasChanges,
            "…and once a minute *has* been chosen the draft stores that whole minute, because a minute is "
                + "the finest value either surface can express — writing back a finer one would be a "
                + "precision neither of them offered "
                + "(\(movedMinute.start.timeIntervalSince(secondRow.startedAt)) s in)")

        var renamed = ActivityEditDraft(secondRow)
        renamed.setName("basketball")
        assertTest(
            renamed.activityName == "Basketball" && !renamed.hasChanges,
            "Selecting the activity that is already selected is dropped, and `ActivityName.matches` is "
                + "the test rather than `==`: a picker resolving its own selection offers back "
                + "`Basketball` for a row stored as `basketball`, and a draft that took that write would "
                + "report a change nobody made and enable `SAVE` over it. The cost is stated where the "
                + "guard is — a name in the wrong case cannot be corrected from this sheet")

        var renamedOnly = ActivityEditDraft(secondRow)
        renamedOnly.setName("Walking")
        assertTest(
            renamedOnly.activityName == "Walking" && renamedOnly.hasChanges
                && renamedOnly.start == secondRow.startedAt && renamedOnly.end == secondRow.endedAt,
            "…and a real rename is a change that leaves **both instants byte-identical**, so the "
                + "name-only `SAVE` the page's own mockup implies writes times the session already had")

        // The day key, which is the reason the start's upper bound is clamped to its own midnight rather
        // than to the end of the recording. `LocalDatabaseManager.saveWorkout` re-snaps `date` from
        // `startedAt`, so a start dragged past midnight files the session on the next day — out of the day
        // its `workouts.csv` row belongs to, and out of the day the import's already-recorded skip keys on,
        // so a later re-import would insert a duplicate of a row still on disk.
        let lateStart = Calendar.current.startOfDay(for: ActivityDetailTests.anchor).addingTimeInterval(23 * 3600 + 48 * 60)
        let overnight = WorkoutSession(
            startedAt: lateStart, endedAt: lateStart.addingTimeInterval(1_200),
            strain: 3, averageHeartRate: 100, maxHeartRate: 140, route: [], splits: [])
        var draggedPastMidnight = ActivityEditDraft(overnight)
        draggedPastMidnight.setStart(lateStart.addingTimeInterval(1_500))
        assertTest(
            Calendar.current.startOfDay(for: draggedPastMidnight.start)
                == Calendar.current.startOfDay(for: overnight.startedAt),
            "A start dragged past midnight is held inside the session's own day — **the day key is "
                + "invariant under every edit this sheet can make**, which is what lets the import's skip "
                + "recognise the edited row on the next press of the button. The cost is that a session "
                + "starting at 23:48 cannot be trimmed to start later than 23:59:59; its end is "
                + "unconstrained, so it can still be shortened from the right")

        // MARK: - The picker's vocabulary

        // `WhoopActivityCatalog` is WHOOP's published list **curated** — five published names dropped
        // (`Barre`, `Barre3`, `Barry's`, the whoop-specific `WHOOP Labs` and the redundant `Cycling`) and
        // three added — and it is a pure value with no database behind it, so it asserts here, above every
        // `LocalDatabaseManager` below.
        //
        // **The two counts are the curated list's own and must not be "corrected" back to WHOOP's
        // published total.** They read `160`/`32` until the list was edited by hand, and the arithmetic
        // that shows those were right *then* is `157 − 1 + 3 = 159` strain literals, `+ abstentionName =
        // 160`. The stale figure was never wrong about the file, it was written for a *verbatim* copy of
        // WHOOP's page — see the catalogue type's own comment for what moved and why. The user has since
        // dropped `WHOOP Labs` and `Cycling`, which is `158 − 2 = 156`; neither name has a producer in the
        // bundled export, so no row this app can import loses its label to that removal.
        assertTest(
            WhoopActivityCatalog.strainActivities.count == 156
                && WhoopActivityCatalog.recoveryActivities.count == 33
                && WhoopActivityCatalog.allNames.count
                    == WhoopActivityCatalog.strainActivities.count
                        + WhoopActivityCatalog.recoveryActivities.count,
            "The catalogue holds \(WhoopActivityCatalog.strainActivities.count) strain activities and "
                + "\(WhoopActivityCatalog.recoveryActivities.count) recovery activities — the two sections "
                + "the picker draws, and `allNames` is exactly their concatenation rather than a third list "
                + "free to drift from either")
        assertTest(
            WhoopActivityCatalog.unpublishedNames.allSatisfy {
                WhoopActivityCatalog.allNames.contains($0)
            }
                && WhoopActivityCatalog.unpublishedNames.count == 3,
            "**The three names this catalogue offers that WHOOP's page does not carry are named, and every "
                + "one of them is really in a list.** `Activity`, `Fast` and `Road Biking` are the whole "
                + "of the divergence in this direction, so this is the assertion that fails if one is "
                + "dropped from the catalogue while its `unpublishedNames` entry stays behind — a record "
                + "outliving the fact it records. It pins the count as well as membership, so a fourth "
                + "addition has to be declared rather than absorbed")
        assertTest(
            WhoopActivityCatalog.strainActivities.first == WhoopActivityCatalog.abstentionName,
            "**`Activity` is the first row of the strain list, and it is not on WHOOP's published list at "
                + "all.** It is what their classifier writes when it declines to categorise a session, and "
                + "it is the stored name on 197 of the bundled export's 673 rows — so a picker without it "
                + "would open the file's most common activity on a list with nothing selected, which reads "
                + "as a bug rather than as an abstention")
        assertTest(
            WhoopActivityCatalog.recoveryActivities.first == WhoopActivityCatalog.fastingName
                && WhoopActivityCatalog.fastingName == "Fast",
            "**`Fast` is the first row of the recovery list**, mirroring `Activity` at the head of the "
                + "strain list: the position is a decision this app makes rather than a consequence of the "
                + "letter it starts with, so it is *prepended* rather than sorted in. It is in the recovery "
                + "section rather than the strain one because the split's own test is whether a strain "
                + "figure describes the session, and a fasting window is time held rather than work done. "
                + "The literal is pinned beside the constant so renaming one does not silently move the "
                + "other, and **the word is `Fast` and not `Fasting`**: the `ACTIVITIES` row draws a name "
                + "uppercased under its figure, so `Fast` renders as `FAST` beside `SLEEP`. **This app now "
                + "does produce one** — `ZeroFastingImporter` writes 170 of them, labelled `zero_fasting` "
                + "and carrying no measurement at all, which is what §20 covers")
        assertTest(
            WhoopActivityCatalog.allNames.allSatisfy {
                !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces)
            },
            "Every entry is a non-empty name with no padding, so no row of the picker draws as a blank "
                + "line and no name carries whitespace a stored one would not match")
        assertTest(
            Set(WhoopActivityCatalog.allNames.map { ActivityName.normalised($0) }).count
                == WhoopActivityCatalog.allNames.count,
            "**No two entries collapse to one name under `ActivityName.normalised`**, which is the rule "
                + "the sheet resolves a selection by — two entries that fold together would give the "
                + "picker two rows that select as one, and the tick would move between them")
        assertTest(
            WhoopActivityCatalog.allNames.allSatisfy { !$0.contains("*") && !$0.contains("^") },
            "Neither of WHOOP's two footnote markers survives into the picker. `*` promises a muscular "
                + "strain calculation and `^` a Strength Activity Time contribution, and this app computes "
                + "neither — `CLAUDE.md` records `STRENGTH ACTIVITY TIME` as the one row on this page with "
                + "no producer at all — so carrying a superscript would put a claim on a row that nothing "
                + "behind it can answer")
        assertTest(
            WhoopActivityCatalog.contains(WhoopActivityCatalog.abstentionName)
                && WhoopActivityCatalog.contains("  basketball ")
                && WhoopActivityCatalog.contains("BASKETBALL")
                && !WhoopActivityCatalog.contains("Not A Sport")
                && !WhoopActivityCatalog.contains(nil)
                && !WhoopActivityCatalog.contains(""),
            "…and membership is decided by `ActivityName.matches` rather than by `==`, so a stored "
                + "`  basketball ` is recognised as the list's own `Basketball` — while an unknown name is "
                + "offered as an extra *current* row instead of silently selecting nothing, and `nil` and "
                + "`\"\"` are both *not* members, because an empty name is the absence of one rather than a "
                + "name WHOOP publishes")
        // **The two biking names, pinned by name, because the counts above cannot see either of them.** Every
        // assertion in this block is an aggregate or a sweep, so swapping one offerable name for another
        // leaves all of them unchanged — and these two are the pair the vocabulary was reconciled over, the
        // export writing one of them and the picker having to offer it back. Membership and a real mark are
        // two separate claims: `contains` decides whether the row is offered at all, and `mark(for:)` decides
        // whether it draws a bicycle or the running fallback.
        assertTest(
            ["Road Biking", "Mountain Biking"].allSatisfy {
                WhoopActivityCatalog.contains($0)
                    && ActivityGlyph.mark(for: $0) == .single("figure.outdoor.cycle")
            },
            "**`Road Biking` and `Mountain Biking` are each offerable and each draw a bicycle.** They are "
                + "the two names the export's own vocabulary and the picker's were reconciled over — the "
                + "bundled `workouts.csv` writes `Road Biking` on 12 rows — and the aggregate counts in this "
                + "block are blind to both: a swap of one offerable name for another moves no total, and the "
                + "glyph sweep only counts. This fails if a future tidy drops a biking name from either list, "
                + "or if either loses its own entry in `ActivityGlyph`'s table")

        // **The glyph sweep, and the one figure in it that is a decision rather than a count.** A wrong SF
        // Symbol name is not an error — it draws an empty chip — so the table's typo risk is invisible to
        // the compiler and to any screenshot of a different row. §17 drives the file's own 21 names; this
        // is the other producer, whose vocabulary is neither a superset nor a subset of that one.
        let catalogued = WhoopActivityCatalog.allNames
        let drawn = catalogued.filter { ActivityGlyph.mark(for: $0) != .single(ActivityGlyph.fallback) }
        assertTest(
            drawn.count == 96,
            "**96 of the catalogue's \(catalogued.count) names draw a figure that is not the running "
                + "one, and \(catalogued.count - drawn.count) draw the fallback**, which is a *wrong* "
                + "drawing rather than a missing one — the same mark this card drew for every workout "
                + "before the table existed. The split is pinned rather than asserted as a floor because it "
                + "is a decision: SF Symbols has no figure for a sauna, a massage, `Poker`, `Cooking` or "
                + "`Public Speaking` at all, and inventing one would claim a distinction the list does not "
                + "make")
        // The four that make "is in the table" and "draws something other than the fallback" two different
        // counts. The running family's own entry *is* the fallback string, so `mark(for:)` cannot tell
        // those four from a name the table has never heard of — which is why the figure above is 96 and not
        // the table's 100 catalogue keys, and why this block is pinned beside it rather than left implicit.
        assertTest(
            ["Running", "Trail Running", "Sprint Training", "Obstacle Course Racing"]
                .allSatisfy { ActivityGlyph.mark(for: $0) == .single(ActivityGlyph.fallback) },
            "…and the four names where *the table has an entry* and *the drawing differs* come apart: the "
                + "running family's own entry is written as `figure.run`, which is `ActivityGlyph.fallback` "
                + "itself. They draw correctly and they draw exactly as an unmapped name does, so the count "
                + "above is 96 rather than the 100 catalogue names the table holds a key for")
        // **The arity sweep, and it is the one thing `drawn.count` cannot see.** A count of names that draw
        // something other than the fallback is unchanged whether `Fast` draws a pair or a single symbol,
        // so a typo that dropped the second half of its mark would leave every other assertion in this
        // block passing and put a bare timer where the user asked for a timer *and* a knife.
        let composites = catalogued.filter { ActivityGlyph.mark(for: $0).isComposite }
        assertTest(
            composites == [WhoopActivityCatalog.fastingName],
            "**Exactly one name in the whole catalogue draws two symbols, and it is `Fast`.** Swept "
                + "over `allNames` rather than over the table's keys, so it also fails if a second name is "
                + "ever given a pair without this line moving. `Drawing` makes the two failure modes this "
                + "guards against unrepresentable — an empty mark has no initialiser and a duplicate pair "
                + "cannot be spelled — but it cannot say *which* names are composites, which is what this "
                + "does")
        assertTest(
            ActivityGlyph.mark(for: "Fast") == .pair("fork.knife", "timer")
                && ActivityGlyph.mark(for: "fast") == .pair("fork.knife", "timer")
                && ActivityGlyph.mark(for: "  FAST  ") == .pair("fork.knife", "timer"),
            "**The pair is `fork.knife` then `timer`, in that order**, which is the user's own "
                + "specification — *\"fork and knife icon followed by clock icon\"* on the row whose label "
                + "reads `FAST` — and which a set comparison would lose. The food mark leads because the "
                + "label under it is the food half, so the pair reads as *fasting, for a duration*. Both "
                + "symbols clear the iOS 17.0 deployment target, measured against `name_availability.plist` "
                + "rather than recalled: `timer` is 2019 → iOS 13.0 and `fork.knife` is 2021 → iOS 15.0. "
                + "**No SF Symbol combines a food mark with a time mark** — `figure.fasting` is absent from "
                + "the plist altogether and no symbol's name contains \"fast\" — so this is a composite "
                + "drawing rather than a table entry, and it is why the table holds a `Drawing` and no "
                + "longer a `String`. The last two are the lookup's own rule: the name is normalised like "
                + "every other, so a stored `fast` draws the same pair")
        assertTest(
            catalogued.allSatisfy { name in
                let symbols = ActivityGlyph.mark(for: name).symbols
                return !symbols.isEmpty && symbols.allSatisfy { !$0.isEmpty }
            },
            "**Every symbol of every mark is a non-empty name, a composite's second included.** §17 makes "
                + "this sweep over the export's own 21 names and cannot see a pair at all — its names are "
                + "the file's, and none of them is `Fast`. This one is over the whole catalogue and reads "
                + "`Drawing.symbols`, so it covers both halves of the only composite. A wrong SF Symbol name "
                + "is not an error, it draws an empty chip, so this is still the only kind of check that can "
                + "see a typo — and the `symbols.isEmpty` half is the assertion that an absent mark is "
                + "unrepresentable rather than merely unused")
        let fastingMark = ActivityGlyph.mark(for: WhoopActivityCatalog.fastingName)
        assertTest(
            ActivityGlyph.drawnWidth(of: fastingMark, atPointSize: 15) <= ActivityGlyph.chipDiameter
                && ActivityGlyph.drawnWidth(of: fastingMark, atPointSize: 16) <= ActivityGlyph.listGutter
                && ActivityGlyph.drawnWidth(of: fastingMark, atPointSize: 18) <= ActivityGlyph.listGutter,
            "**The pair fits both of the fixed frames it is drawn in, at the size each one draws it.** "
                + "Home's chip is a 38pt square and the pair bounds at 33.45pt at its 15pt size; the "
                + "picker's and the edit sheet's gutters are `listGutter` (42) and it bounds at 35.68pt at "
                + "16 and 40.14pt at 18 — which is why `listGutter` is 42 and not the 26 a single symbol "
                + "needed. **Both figures are `drawnWidth`'s bound and not a measurement**: the runner has "
                + "no renderer and cannot know a glyph's aspect ratio, so what is asserted is that the "
                + "arithmetic the frames were chosen from leaves headroom, not that the marks are those "
                + "widths on a screen. The two gutters are a fixed width rather than a `minWidth` on "
                + "purpose — they are the column every catalogue row aligns against, so a per-row width "
                + "would put `Fast`'s name at a different x from its 190 neighbours")
        assertTest(
            ActivityGlyph.drawnWidth(of: fastingMark, atPointSize: 38)
                > ActivityGlyph.activityHeaderMinWidth,
            "**And the pair does not fit the header's old frame, which is why that frame is a `minWidth` "
                + "and no longer a `width`.** The same bound is 84.7pt at the header's 38pt against a fixed "
                + "48, so under `width:` the pair would overhang its frame and run into the session's title. "
                + "It is deliberately **not** asserted that the other names are unaffected, because they are "
                + "not: the bound for a *single* symbol at 38pt is 49.4, already past 48, and the five "
                + "cycling names measure wider still — `figure.outdoor.cycle` is about 56pt — so those five "
                + "grow the frame and their titles move right by roughly 8pt. That is the honest cost of "
                + "this change, and it is recorded on `ActivityDetailView`'s header as well as here")
        assertTest(
            ActivityGlyph.mark(for: WhoopActivityCatalog.abstentionName) == .single(ActivityGlyph.fallback)
                && ActivityGlyph.mark(for: "Other") == .single(ActivityGlyph.fallback),
            "…and WHOOP's own two words for an activity it did not categorise are among the fallbacks. "
                + "They are *in the catalogue* — the picker has to offer them or 208 of the file's rows "
                + "open on an unticked list — so this is the pair where *the catalogue has a name* and "
                + "*the table draws a figure for it* would otherwise look like one rule")
        assertTest(
            [
                "Dry Sauna", "Ice Bath", "Foam Rolling", "Massage Therapy", "Poker", "Cooking", "Darts",
                "Bartending", "Canoeing", "Snowshoeing", "Cheerleading", "Taekwondo", "Cleaning",
                "Dog Walking", "Billiards",
            ].allSatisfy { ActivityGlyph.mark(for: $0) == .single(ActivityGlyph.fallback) },
            "…and the deliberately unmapped names are the ones with no counterpart in SF Symbols — "
                + "`figure.cooking`, `figure.darts`, `figure.billiards`, `figure.taekwondo` and "
                + "`figure.snowshoeing` are **absent from `name_availability.plist` altogether**, not "
                + "merely newer than the target, so a table entry for any of them would draw an empty chip "
                + "rather than a figure")
        assertTest(
            ActivityGlyph.mark(for: "Archercy") == .single("figure.archery")
                && ActivityGlyph.mark(for: "Racquetball") == .single("figure.racquetball")
                && ActivityGlyph.mark(for: "Curling") == .single("figure.curling")
                && ActivityGlyph.mark(for: "F45 Training") == .single("figure.highintensity.intervaltraining")
                && ActivityGlyph.mark(for: "Pickleball") == .single("figure.pickleball")
                && ActivityGlyph.mark(for: "Table Tennis/Ping Pong") == .single("figure.table.tennis")
                && ActivityGlyph.mark(for: "Track & Field") == .single("figure.track.and.field")
                && ActivityGlyph.mark(for: "Weightlifting") == .single("figure.strengthtraining.traditional"),
            "…and the catalogue's own sports resolve to the symbols the table means, pinned **by "
                + "literal** — a name that resolves to a symbol which does not exist is still non-empty, "
                + "so the two halves of the mapping are unobservable from `symbol(for:)` alone. `Archercy` "
                + "is WHOOP's own typo, kept as published: the key is the string a producer writes, and "
                + "correcting it here would leave the row unmatched")
        assertTest(
            ActivityGlyph.mark(for: "Rowing") == .single("figure.rower")
                && ActivityGlyph.mark(for: "Ice Skating") == .single("figure.skating")
                && ActivityGlyph.mark(for: "Field Hockey") == .single(ActivityGlyph.fallback)
                && ActivityGlyph.mark(for: "Skateboarding") == .single(ActivityGlyph.fallback),
            "**Four answers that exist because the deployment target is 17.0.** "
                + "`figure.indoor.rowing`, `figure.outdoor.rowing`, `figure.ice.skating`, "
                + "`figure.skateboarding` and `figure.field.hockey` are all **2024** symbols — iOS 18 — so "
                + "each draws nothing on this build, and `name_availability.plist` is the measurement "
                + "rather than recall. Rowing and ice skating have an older symbol that means the same "
                + "thing (`figure.rower`, `figure.skating`, both 2022) and take it; field hockey and "
                + "skateboarding have none, so they take the fallback. All four return a non-empty string "
                + "either way, which is exactly why the sweep above cannot see any of this and these "
                + "literals can")
        assertTest(
            ActivityGlyph.mark(for: "Breathwork") == .single("figure.mind.and.body")
                && ActivityGlyph.mark(for: "Tai Chi") == .single("figure.mind.and.body")
                && ActivityGlyph.mark(for: "Meditation") == .single("figure.mind.and.body")
                && ActivityGlyph.mark(for: "QiGong") == .single("figure.mind.and.body")
                && ActivityGlyph.mark(for: "Guided Breathing - Increase Alertness")
                    == .single("figure.mind.and.body")
                && ActivityGlyph.mark(for: "Stretching") == .single("figure.flexibility")
                && ActivityGlyph.mark(for: "Restorative Yoga") == .single("figure.yoga"),
            "…and the recovery section's mapped names, which are the whole of that section's coverage "
                + "and the reason its other rows draw a running figure: a sauna, a massage and a "
                + "red-light session are not movements, and SF Symbols has no figure for any of them")

        // MARK: - The reading in force at a trim handle

        // The sheet labels each handle with the heart rate at that boundary, and *which* sample that is has
        // to be a rule rather than an interpolation: a figure averaged between the two readings either side
        // of a handle is a rate the strap never reported, which is the absence rule applied to a readout
        // instead of to a chart.
        //
        // The fixture's two readings are 74 and 132 bpm — fifty-eight apart — so an interpolated answer is
        // a number neither sample holds and is distinguishable from both. **It is synthetic**, on §16's,
        // §17's and §18's terms: `biometric_samples` holds 0 rows in every database on this machine and the
        // bundled export carries no series at all, so no session this app can show reaches this path, and
        // nothing asserted here is evidence about a strap.
        let inForceSeries = ActivityHeartRateSeries(
            samples: [
                BiometricSample(timestamp: ActivityDetailTests.anchor.addingTimeInterval(20), heartRate: 74),
                BiometricSample(timestamp: ActivityDetailTests.anchor.addingTimeInterval(80), heartRate: 132),
            ],
            start: ActivityDetailTests.anchor,
            end: ActivityDetailTests.anchor.addingTimeInterval(120))
        assertTest(
            inForceSeries != nil,
            "The fixture builds a series at all — a rejected init would make every assertion below a "
                + "statement about `nil`")
        assertTest(
            inForceSeries?.bpm(at: ActivityDetailTests.anchor.addingTimeInterval(50)) == 74,
            "**A handle between two readings takes the earlier one, never a value between them.** At "
                + "fifty seconds the session was still running at 74 bpm until the 132 arrived at eighty; "
                + "an interpolated answer here would print `103bpm`, a rate nothing measured "
                + "(\(String(describing: inForceSeries?.bpm(at: ActivityDetailTests.anchor.addingTimeInterval(50)))))")
        assertTest(
            inForceSeries?.bpm(at: ActivityDetailTests.anchor.addingTimeInterval(80)) == 132,
            "…and **at** a sample's own instant that sample is the one in force, which is what `<=` in the "
                + "lookup buys: a strict `<` would answer 74 for the very reading the handle is sitting on "
                + "(\(String(describing: inForceSeries?.bpm(at: ActivityDetailTests.anchor.addingTimeInterval(80)))))")
        assertTest(
            inForceSeries?.bpm(at: ActivityDetailTests.anchor.addingTimeInterval(10)) == nil,
            "…and before the first reading the answer is `nil` rather than the first reading carried "
                + "backwards — extrapolating a measurement into time it does not cover is the same claim a "
                + "point plotted at the axis foot would make, and it draws the dash an unmeasured session "
                + "draws")
        assertTest(
            ActivityTimeTrimChartView.bpmText(inForceSeries, at: ActivityDetailTests.anchor.addingTimeInterval(50)) == "74bpm"
                && ActivityTimeTrimChartView.bpmText(nil, at: ActivityDetailTests.anchor) == "—"
                && ActivityTimeTrimChartView.bpmText(inForceSeries, at: ActivityDetailTests.anchor) == "—",
            "The readout prints it as `74bpm`, and **every session on this machine draws the dash** — "
                + "`nil` in gives `—`, which is the whole of what the two figures above the handles read "
                + "on the 673 imported sessions, and a boundary before the first sample draws it too "
                + "(\(ActivityTimeTrimChartView.bpmText(nil, at: ActivityDetailTests.anchor)))")
    }
}
