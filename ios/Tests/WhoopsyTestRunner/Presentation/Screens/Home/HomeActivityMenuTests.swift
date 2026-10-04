import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The `+` menu, and which days are offered a way to record

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeActivityMenuTests {
    static func run() async throws {
        // ---- The `+` menu's rows ----
        //
        // `ActivityMenu` is a value rather than a rule written into `HomeDashboardView`'s body for
        // `DayBarRules`' and `ActivityGlyph`'s reason: the runner has no renderer, so a row built inline
        // is a row nothing here can see. **What this block proves is the rows and not the drawing** — the
        // card's frame, its scrim, its animation and the tab bar it hides are all invisible to it, and no
        // assertion below is evidence that the menu renders where it should. It is placed above the
        // section's first database so it runs even if the blocks below throw.
        //
        // The non-emptiness sweep is the only assertion that can catch a mistyped SF Symbol: a wrong name
        // is not an error, it draws an empty chip, and neither the compiler nor a screenshot of the other
        // row can see it. It cannot see the second failure either — every symbol must exist on the **iOS
        // 17.0** deployment target, which is a fact about the platform and not about the string. That
        // second check matters more for the third row than for the two above it, since its symbol is
        // `brain.head.profile` — an SF Symbol outside this app's `figure.*` vocabulary — while the other
        // two are `plus` and `clock`, which every iOS version this app can run on has had for a decade.

        assertTest(ActivityMenu.entries.count == 3,
                   "The `+` menu draws three rows (\(ActivityMenu.entries.count) held)")

        let titles = ActivityMenu.entries.map(\.title)
        assertTest(
            titles == ["ADD ACTIVITY", "START ACTIVITY", "ADD RECEPTIVE INACTIVITY"],
            "…titled in that order, which is what draws top-to-bottom (\(titles))")

        // The third row was **appended** rather than inserted beside `ADD ACTIVITY`, and the assertion
        // above is what pins that: every position the two original rows held is where it was, so this
        // is an addition rather than a reordering that happens to keep them together.
        assertTest(
            Array(titles.prefix(2)) == ["ADD ACTIVITY", "START ACTIVITY"],
            "…and the two rows above it are unmoved, so the new one is appended rather than inserted "
                + "(\(Array(titles.prefix(2))))")

        let blank = ActivityMenu.entries.filter(\.symbol.isEmpty).map(\.title)
        assertTest(blank.isEmpty, "…each carrying a non-empty SF Symbol (\(blank) draw an empty chip)")

        // **Exactly one row is a recording path, and it is not the new one.** `START ACTIVITY` is what
        // carries `.startSession`, and `ADD RECEPTIVE INACTIVITY` carries a case of its own rather than
        // reusing it — so the count below stays at one and the receptive row cannot become a second way
        // into a live session. §18 asserts the same count from the session's side; the pair is what keeps
        // `ADD ACTIVITY` legitimately inert without either neighbour joining it.
        let recordingRows = ActivityMenu.entries.filter { $0.action == .startSession }.map(\.title)
        assertTest(
            recordingRows == ["START ACTIVITY"],
            "…and exactly one of the three starts a recording, which is the assertion that fails if the "
                + "receptive row is given `.startSession` instead of its own case (\(recordingRows))")

        let inertRows = ActivityMenu.entries.filter { $0.action == .none }.map(\.title)
        assertTest(
            inertRows == ["ADD ACTIVITY"],
            "…and exactly one row is inert, so `ADD RECEPTIVE INACTIVITY` opening a sheet rather than "
                + "nothing is visible here rather than only on the screen (\(inertRows))")

        // ---- Every day is offered the menu; only today is offered a way to record ----
        //
        // The `+` is drawn whatever day is on screen. What the day changes is the *card*: off today it still
        // opens and still lists `ADD ACTIVITY`, and the row withheld is `START ACTIVITY`, because recording
        // is something a user does *now*. The rule is `ActivityMenu.entries(on:now:)`, and it forwards to
        // `DayBarRules.isToday` rather than restating the comparison here or in the view.
        //
        // **Yesterday is the assertion that matters.** `isToday` and the shorter `!isFuture` agree on today
        // and on tomorrow and differ on exactly one input — a past day — so a past day is the only case that
        // can tell the correct rule from the tempting one. `now` is pinned rather than read from the clock so
        // the three days cannot drift under the assertions, and the day arithmetic goes through
        // `Calendar.current` rather than a fixed 86,400-second stride, which a DST boundary can land on the
        // wrong calendar day.
        //
        // **Withholding the whole card is the mutation these catch**, and it is worth saying which one does
        // the work: returning no rows off today trips the *yesterday titles* assertion, which reads `[]`
        // where `["ADD ACTIVITY"]` belongs — confirmed by mutation, which fails there and exits 1. The
        // titles are what pin the row that must survive; the closing assertion states the same property in
        // general form, so it holds for a day nobody thought to pin rather than for the two that are here.

        let menuNow = Date(timeIntervalSince1970: 1_700_000_000)
        let menuYesterday = Calendar.current.date(byAdding: .day, value: -1, to: menuNow)!
        let menuTomorrow = Calendar.current.date(byAdding: .day, value: 1, to: menuNow)!

        let menuTodayTitles = ActivityMenu.entries(on: menuNow, now: menuNow).map(\.title)
        assertTest(
            menuTodayTitles == ["ADD ACTIVITY", "START ACTIVITY", "ADD RECEPTIVE INACTIVITY"],
            "Today is offered all three rows, so the `+` on the current day is unchanged by this rule "
                + "(\(menuTodayTitles))")

        let menuYesterdayTitles = ActivityMenu.entries(on: menuYesterday, now: menuNow).map(\.title)
        assertTest(
            menuYesterdayTitles == ["ADD ACTIVITY", "ADD RECEPTIVE INACTIVITY"],
            "…and yesterday is offered the two non-recording rows — the case that separates `isToday` from "
                + "the shorter `!isFuture`, since the two agree on today and on tomorrow and differ only on "
                + "a day already gone (\(menuYesterdayTitles))")

        let menuTomorrowTitles = ActivityMenu.entries(on: menuTomorrow, now: menuNow).map(\.title)
        assertTest(
            menuTomorrowTitles == ["ADD ACTIVITY", "ADD RECEPTIVE INACTIVITY"],
            "…and tomorrow the same, where there is nothing yet to start (\(menuTomorrowTitles))")

        // **The receptive row is not withheld on any day, and the assertion that carries it is the past
        // day.** A recording is something a user starts *now*, so `START ACTIVITY` is day-bound; a
        // receptive inactivity is filed on the day it happened, so a user paging back to the morning of a
        // dream is exactly who that row is for. The filter is on `Action`, so this falls out of the
        // implementation rather than being spelled in it — which is why it is asserted rather than
        // assumed, since a filter widened to `action == .none` reads identically on today.

        let menuDays = [menuYesterday, menuNow, menuTomorrow]
        let receptiveOnEveryDay = menuDays.map { day in
            ActivityMenu.entries(on: day, now: menuNow).map(\.title).contains("ADD RECEPTIVE INACTIVITY")
        }
        assertTest(
            receptiveOnEveryDay == [true, true, true],
            "…and `ADD RECEPTIVE INACTIVITY` is offered on every one of the three days, because a receptive "
                + "activity is filed on the day it happened rather than on the day it is entered "
                + "(\(receptiveOnEveryDay))")

        let recordingOffered = menuDays.map { day in
            ActivityMenu.entries(on: day, now: menuNow).contains { $0.action == .startSession }
        }
        let dayBarAnswer = menuDays.map { DayBarRules.isToday($0, now: menuNow) }
        assertTest(
            recordingOffered == dayBarAnswer,
            "…and a recording row is offered on exactly the days the day bar calls today, so this screen has "
                + "one definition of today and the two cannot come to disagree (\(recordingOffered) against "
                + "\(dayBarAnswer))")

        let menuEveryDayHasRows = menuDays.allSatisfy { !ActivityMenu.entries(on: $0, now: menuNow).isEmpty }
        assertTest(
            menuEveryDayHasRows,
            "…and no day draws an empty card, which is what separates withholding one row from hiding the "
                + "`+` — every one of the three still holds `ADD ACTIVITY`, a row that is not day-bound")

        // ---- The second reason a recording row is withheld: something is already recording ----
        //
        // The rule above is about the *day*; this one is about the *session*, and the two are independent —
        // a live fast on a past day still withholds `START ACTIVITY` for the day's own reason. The user's
        // rule is the asymmetry between the two live states: **there cannot be two active activities**, so
        // a recording activity closes the row, while a fast does not block an activity and leaves it open.
        //
        // Driven as a plain value, like everything else on this menu: `ActivityMenu.Recording` is an input
        // and not a policy store, so the whole question is answerable with no use case, no database and no
        // session — which is the only form it could take in a build with no renderer.
        let activityRecordingTitles = ActivityMenu
            .entries(on: menuNow, now: menuNow, recording: .activity).map(\.title)
        assertTest(
            activityRecordingTitles == ["ADD ACTIVITY", "ADD RECEPTIVE INACTIVITY"],
            "An activity already recording withholds `START ACTIVITY` on today — a second activity cannot "
                + "be started, and the row that would start one is dropped rather than greyed "
                + "(\(activityRecordingTitles))")

        // **The receptive row survives this filter too, and that is the answer rather than an oversight.**
        // What the rule withholds is a second *recording*: entering a meditation starts no clock and
        // writes one row to a different table, so it conflicts with a live session no more than a note
        // does. Asserted because the tempting repair for the line above — filtering to `action == .none`
        // — would silently take this row with it on exactly the day a user is most likely to want it.
        assertTest(
            activityRecordingTitles.contains("ADD RECEPTIVE INACTIVITY"),
            "…and the receptive row is *not* withheld while an activity records, since it starts no "
                + "second recording (\(activityRecordingTitles))")

        let fastRecordingTitles = ActivityMenu
            .entries(on: menuNow, now: menuNow, recording: .fast).map(\.title)
        assertTest(
            fastRecordingTitles == ["ADD ACTIVITY", "START ACTIVITY", "ADD RECEPTIVE INACTIVITY"],
            "…and a **fast** does not withhold it either, which is the user's own rule: a fast does not "
                + "block an activity, so 18 hours into one the row is still there and a run can be "
                + "recorded beside it (\(fastRecordingTitles))")

        assertTest(
            fastRecordingTitles == menuTodayTitles,
            "…and the fast's answer is byte-identical to the no-recording answer, which is the whole of the "
                + "claim — `.fast` changes nothing about this menu rather than changing it in a way that "
                + "happens to agree here (\(fastRecordingTitles) against \(menuTodayTitles))")

        // The two rules are independent, so a live activity on a day that is not today withholds the row
        // for *both* reasons at once and the answer must be the same single-row list. Asserted because a
        // rule written as an `else if` chain would read correctly on today and drop one of the two here.
        let pastDayWhileRecording = menuDays.map { day in
            ActivityMenu.entries(on: day, now: menuNow, recording: .activity)
                .contains { $0.action == .startSession }
        }
        assertTest(
            pastDayWhileRecording == [false, false, false],
            "…and a recording activity withholds the row on every day, not only on today — the day rule and "
                + "the session rule are two independent clauses and this is the case where both are false "
                + "(\(pastDayWhileRecording))")

        let fastEveryDayHasRows = menuDays.allSatisfy {
            !ActivityMenu.entries(on: $0, now: menuNow, recording: .fast).isEmpty
        }
        assertTest(
            fastEveryDayHasRows,
            "…while a running fast still leaves every day's card non-empty, so the fast state cannot hide "
                + "the `+` the way a mistake in the day rule would")
    }
}
