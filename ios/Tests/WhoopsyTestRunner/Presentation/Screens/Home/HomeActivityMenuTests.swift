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
        // 17.0** deployment target, which is a fact about the platform and not about the string.

        assertTest(ActivityMenu.entries.count == 2,
                   "The `+` menu draws two rows (\(ActivityMenu.entries.count) held)")

        let titles = ActivityMenu.entries.map(\.title)
        assertTest(titles == ["ADD ACTIVITY", "START ACTIVITY"],
                   "…titled in that order, which is what draws top-to-bottom (\(titles))")

        let blank = ActivityMenu.entries.filter(\.symbol.isEmpty).map(\.title)
        assertTest(blank.isEmpty, "…each carrying a non-empty SF Symbol (\(blank) draw an empty chip)")

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
            menuTodayTitles == ["ADD ACTIVITY", "START ACTIVITY"],
            "Today is offered both rows, so the `+` on the current day is unchanged by this rule "
                + "(\(menuTodayTitles))")

        let menuYesterdayTitles = ActivityMenu.entries(on: menuYesterday, now: menuNow).map(\.title)
        assertTest(
            menuYesterdayTitles == ["ADD ACTIVITY"],
            "…and yesterday is offered only `ADD ACTIVITY` — the case that separates `isToday` from the "
                + "shorter `!isFuture`, since the two agree on today and on tomorrow and differ only on a "
                + "day already gone (\(menuYesterdayTitles))")

        let menuTomorrowTitles = ActivityMenu.entries(on: menuTomorrow, now: menuNow).map(\.title)
        assertTest(
            menuTomorrowTitles == ["ADD ACTIVITY"],
            "…and tomorrow the same, where there is nothing yet to start (\(menuTomorrowTitles))")

        let menuDays = [menuYesterday, menuNow, menuTomorrow]
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
            activityRecordingTitles == ["ADD ACTIVITY"],
            "An activity already recording withholds `START ACTIVITY` on today — a second activity cannot "
                + "be started, and the row that would start one is dropped rather than greyed "
                + "(\(activityRecordingTitles))")

        let fastRecordingTitles = ActivityMenu
            .entries(on: menuNow, now: menuNow, recording: .fast).map(\.title)
        assertTest(
            fastRecordingTitles == ["ADD ACTIVITY", "START ACTIVITY"],
            "…and a **fast** does not, which is the user's own rule: a fast does not block an activity, so "
                + "18 hours into one the row is still there and a run can be recorded beside it "
                + "(\(fastRecordingTitles))")

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
