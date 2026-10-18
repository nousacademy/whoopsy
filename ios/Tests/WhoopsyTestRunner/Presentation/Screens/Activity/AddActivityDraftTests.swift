import Foundation
import Whoopsy

/// The `+` menu's `ADD ACTIVITY` sheet, asserted through the value behind it.
///
/// The sheet itself is a view and the runner has no renderer, so what is asserted here is
/// `AddActivityDraft`: the day-rebuild of both pickers, the window's clamps, the identity the row is
/// saved under, and — the part a screenshot cannot see — the fact that the row it writes carries
/// `manual` as its source and `nil` as every measurement.
enum AddActivityDraftTests {
    static func run() async throws {
        // ---- A fresh draft, and the window it proposes ----

        // `day` is snapped at `init`, so the sheet's two pickers, both clamps and the saved row are all
        // facts about one midnight rather than an argument four methods could disagree about. The seed
        // is noon to one by elapsed seconds — not "now" — so a draft opened on a past day proposes a
        // time on *that* day rather than today's clock time in yesterday's date.
        let day = ActivityDetailTests.day(0)
        var draft = AddActivityDraft(on: day.addingTimeInterval(6 * 3600))
        assertTest(
            draft.day == day,
            "A draft build from any instant in the day snaps its `day` to that day's midnight, so the "
                + "sheet and its clamps cannot disagree about which day they are filing on "
                + "(\(draft.day))")
        assertTest(
            draft.start == day.addingTimeInterval(TimeInterval(AddActivityDraft.defaultStartHour * 3600))
                && draft.end == draft.start.addingTimeInterval(AddActivityDraft.defaultDuration),
            "…and it proposes noon to one on that day, built by elapsed seconds from the day's own "
                + "midnight rather than from the wall clock \((draft.start, draft.end))")

        assertTest(
            draft.name == nil && !draft.isComplete && draft.applying() == nil,
            "A fresh draft has **nothing to save** — no name, so `applying()` is `nil` and `SAVE` is "
                + "dark. The window cannot be the reason: both clamps keep it inside the day and at least "
                + "`minimumDuration` long, which is why the name is the whole gate")

        // ---- The name, and the two writers that do not mark it dirty ----

        var named = draft
        named.setName("Walking")
        assertTest(
            named.isComplete && named.applying()?.activityName == "Walking",
            "Choosing a name is what enables `SAVE`, and the row carries the catalogue's own spelling "
                + "(\(String(describing: named.applying()?.activityName)))")

        var sameName = named
        sameName.setName("  walking ")
        assertTest(
            sameName.name == "Walking",
            "…and a pick that differs only in case or padding is **dropped**, so an untouched sheet is "
                + "not marked dirty by the picker handing its own selection back "
                + "(\(String(describing: sameName.name)))")

        var blank = draft
        blank.setName("   \n ")
        assertTest(
            !blank.isComplete && blank.applying() == nil,
            "…and a whitespace-only name is *no* name, so the gate cannot be opened by three spaces")

        // A `DatePicker` re-fires its setter with a freshly built instant, and the rebuild is what makes
        // the resulting comparison meaningful: this pick carries a different day's stamp and the same
        // clock time, and must be recognised as the write it is not.
        let seeded = draft
        let todayNoon = Calendar.current.date(
            byAdding: .hour,
            value: AddActivityDraft.defaultStartHour,
            to: Calendar.current.startOfDay(for: Date()))!
        draft.setStart(todayNoon)
        assertTest(
            draft.start == seeded.start,
            "Re-picking the clock time a draft already holds is dropped, even though the raw instant "
                + "carries another date — the comparison is made on the rebuilt pair "
                + "(\(draft.start) against \(seeded.start))")

        // ---- The day-rebuild, for both ends ----

        // The sheet is on a fixed past day, and the pickers hand back whole instants carrying *today's*
        // year, month and day. Filing either raw would put yesterday's walk on today, and a workout's
        // `date` column is snapped from `startedAt` — so the row would be filed under a day the user
        // never opened.
        var rebuilt = AddActivityDraft(on: day)
        let todayEight = Calendar.current.date(
            byAdding: .hour, value: 8, to: Calendar.current.startOfDay(for: Date()))!
        rebuilt.setStart(todayEight)
        let todayNine = Calendar.current.date(
            byAdding: .hour, value: 9, to: Calendar.current.startOfDay(for: Date()))!
        rebuilt.setEnd(todayNine)
        assertTest(
            Calendar.current.startOfDay(for: rebuilt.start) == day
                && Calendar.current.startOfDay(for: rebuilt.end) == day,
            "**Both picked instants are rebuilt onto the draft's day**, so a picker that carries today "
                + "cannot move a session out of the day being viewed "
                + "(\(rebuilt.start) and \(rebuilt.end) on \(day))")
        assertTest(
            rebuilt.start == day.addingTimeInterval(8 * 3600)
                && rebuilt.end == day.addingTimeInterval(9 * 3600),
            "…and the rebuilt instants are 8:00 and 9:00 **on that day**, not merely inside it "
                + "(\((rebuilt.start.timeIntervalSince(day), rebuilt.end.timeIntervalSince(day))))")

        // ---- The clamps: the window never inverts and never leaves the day ----

        var floored = AddActivityDraft(on: day)
        floored.setEnd(day.addingTimeInterval(3600)) // one hour in, before the noon start
        assertTest(
            floored.end == floored.start.addingTimeInterval(AddActivityDraft.minimumDuration)
                && floored.end.timeIntervalSince(floored.start) == AddActivityDraft.minimumDuration,
            "An end picked before the start clamps up to `start + minimumDuration` rather than crossing "
                + "it, so no row this sheet writes has a zero or negative span "
                + "(\(floored.end.timeIntervalSince(floored.start)) s)")

        var carried = AddActivityDraft(on: day)
        carried.setStart(day.addingTimeInterval(13 * 3600 + 1800)) // 1:30 PM, past the 1 PM end
        assertTest(
            carried.end == carried.start.addingTimeInterval(AddActivityDraft.minimumDuration),
            "…and dragging the *start* past the end carries the end along to the floor rather than "
                + "inverting the window — the user moved one handle, and the other follows "
                + "(\(carried.end.timeIntervalSince(carried.start)) s)")

        var midnight = AddActivityDraft(on: day)
        midnight.setStart(day.addingTimeInterval(23 * 3600 + 59 * 60))
        assertTest(
            midnight.start == midnight.latestStart && midnight.end == midnight.latestEnd,
            "A start at the day's last minute is held at `startOfNextDay − 60 s`, and the end it carries "
                + "lands exactly on `startOfNextDay` — the day's exclusive bound, which still covers the "
                + "day under `WorkoutSession.covers(_:)` "
                + "(\(midnight.start) → \(midnight.end))")
        assertTest(
            midnight.start >= midnight.earliestStart && midnight.end <= day.startOfNextDay,
            "…and both ends are inside `day`'s own bounds, so the saved row files under this day rather "
                + "than the next one — `LocalDatabaseManager.saveWorkout` re-snaps `date` from "
                + "`startedAt`, and a start past midnight would be filed under a day the user never opened")

        // ---- Identity, and what the row is ----

        var saved = AddActivityDraft(on: day)
        let draftID = saved.id
        saved.setName("Walking")
        saved.setStart(day.addingTimeInterval(9 * 3600))
        saved.setEnd(day.addingTimeInterval(10 * 3600))
        guard let session = saved.applying() else {
            assertTest(false, "The named, windowed draft applies — a `nil` here would make the row "
                + "assertions below statements about nothing")
            return
        }
        assertTest(
            draftID == saved.id && session.id == draftID,
            "The draft's identity is stable across every write, and the row is saved under it — which is "
                + "what makes the sheet's own presentation survive a picker change and a repeated `SAVE` "
                + "replace rather than append")

        assertTest(
            session.source == WorkoutSession.manualSourceLabel,
            "**A hand-added session says `manual`, not `nil` and not a fast label.** `nil` is what "
                + "`LiveSessionUseCase.end()` writes for a session the strap watched, and this row had no "
                + "sensor behind it — a `nil` here would make it indistinguishable from a recorded "
                + "session in every read that asks what produced a row (\(String(describing: session.source)))")

        assertTest(
            session.strain == nil && session.averageHeartRate == nil && session.maxHeartRate == nil
                && session.route.isEmpty && session.splits.isEmpty && session.hrZonePercents == nil
                && session.steps == nil,
            "…and **every measured field is absent rather than zero** — no strain, no heart rates, no "
                + "route, no zone block and no step count. A `0.0` would claim a session measured at rest "
                + "and a `0` zone block would draw a measured-looking bar")

        assertTest(
            session.startedAt == saved.start && session.endedAt == saved.end,
            "…and it keeps the pair the user picked, so the row's window is the sheet's window "
                + "(\(session.startedAt) → \(session.endedAt))")

        // The name is not what decides the layout — `ActivityFigure.isFast` reads it, so a manual row
        // *named* `Fast` draws the fasting page, but that is a drawing rule and this column is not.
        var namedFast = AddActivityDraft(on: day)
        namedFast.setName(WhoopActivityCatalog.fastingName)
        assertTest(
            namedFast.applying()?.source == WorkoutSession.manualSourceLabel,
            "…and a hand-added session named `Fast` still carries `manual`, not a fast label: the page "
                + "it opens reads the name, while `source` answers which producer wrote the row — and "
                + "teaching the export's day skip that this row is a fast would be a second producer of "
                + "a value it never wrote")

        // ---- The export's day skip must not read this row as a measured day ----

        // `WhoopExportImporter.recordedWorkoutDays()` excludes every source in this set, so a day that
        // holds only a hand-added row still accepts the export's rows. Without the membership below,
        // adding a walk before importing the file would silently drop the export's rows for that day —
        // the same failure the fast filter was widened for, and the reason the set is one definition in
        // `Domain` rather than a literal in the importer.
        let measurementFree = WorkoutSession.measurementFreeSourceValues
        assertTest(
            measurementFree.contains(WorkoutSession.manualSourceLabel)
                && ActiveFast.fastSourceValues.allSatisfy { measurementFree.contains($0) },
            "**The set the export's day skip consults contains `manual` and every fast label.** A day "
                + "holding only a row from either producer has no measurement on it, so the skip must "
                + "still let the export write beside it — this is what makes adding a session before "
                + "importing the file order-independent (\(measurementFree.sorted()))")
        assertTest(
            !measurementFree.contains(""),
            "…and **`nil` is deliberately not a member.** An empty string is what `source ?? \"\"` "
                + "produces for a `nil` source, which is a session `end()` recorded live — a day that "
                + "*was* measured, and the export must never write beside one")

        // ---- The sheet's literals the menu row is titled from ----

        // One literal, drawn in two places: the row that opens the sheet and the sheet's own title. The
        // precedent is `ReceptiveInactivitySheet.addTitle`, and the reason is the runner cannot read a
        // `body` — this is the only assertion that can see the two drifting apart.
        assertTest(
            AddActivitySheet.title == "ADD ACTIVITY"
                && ActivityMenu.entries.first { $0.action == .addActivity }?.title == AddActivitySheet.title,
            "The row that opens the add sheet and the sheet's own title are the same literal, "
                + "`\(AddActivitySheet.title)`, so the menu cannot send the user to a surface named "
                + "something else")

        // ---- The picker's two groups, and the switch that reaches both ----

        // The picker used to draw one list with Recovery Activities as its second section, under ~150
        // strain rows — so a reader adding `Meditation` had to scroll the whole catalogue before
        // learning the name existed, which read as the recovery half being absent. The switch is the
        // fix, and these assertions pin the value it draws from rather than the body it draws into.
        assertTest(
            ActivityPickerView.SectionGroup.allCases == [.strain, .recovery]
                && ActivityPickerView.SectionGroup.strain.names == WhoopActivityCatalog.strainActivities
                && ActivityPickerView.SectionGroup.recovery.names == WhoopActivityCatalog.recoveryActivities,
            "**The picker's switch draws the catalogue's two lists, in its own order and without a "
                + "copy**: `strain` is `strainActivities` and `recovery` is `recoveryActivities`, so a "
                + "name added to either list reaches its tab — and `recovery` is the only answer that "
                + "makes `Meditation`, `Sauna` and `Massage Therapy` reachable on the add sheet")

        assertTest(
            ActivityPickerView.SectionGroup.containing("Meditation") == .recovery
                && ActivityPickerView.SectionGroup.containing("  meditation ") == .recovery
                && ActivityPickerView.SectionGroup.containing("Running") == .strain
                && ActivityPickerView.SectionGroup.containing(nil) == .strain,
            "…and the switch **opens on the group the selection belongs to**, using the same "
                + "case- and padding-tolerant comparison the rows tick with: editing `Meditation` opens "
                + "on Recovery with its tick in view, while a strain name or a fresh add opens on Strain")

        assertTest(
            ActivityPickerView.SectionGroup.strain.tabTitle == ActivityPickerView.strainGroupTitle
                && ActivityPickerView.SectionGroup.recovery.tabTitle == ActivityPickerView.recoveryGroupTitle
                && ActivityPickerView.SectionGroup.strain.sectionTitle == ActivityPickerView.strainSectionTitle
                && ActivityPickerView.SectionGroup.recovery.sectionTitle
                    == ActivityPickerView.recoverySectionTitle,
            "…and each group's two names are the same literals the control and its heading read, so the "
                + "tab cannot say `Recovery` over the strain list")
    }
}
