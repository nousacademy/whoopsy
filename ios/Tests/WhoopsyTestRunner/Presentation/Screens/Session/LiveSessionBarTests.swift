import Foundation
import SwiftUI
import Whoopsy

// MARK: - 18. The `+` menu's row, the recording bar, and the zone behind it

/// A file of §18's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `LiveSessionTests.run()` calls it, in the order the section ran it in.

enum LiveSessionBarTests {
    static func run() async throws {
        // ---- The `+` menu's one actionable row ----
        //
        // §14 owns the rows themselves — that there are two, titled in that order, each with a symbol.
        // This is the dimension §14 cannot see: **which one does something**. `ActivityMenu` is a value
        // rather than a rule written into `HomeDashboardView`'s body for the same reason as before — the
        // runner has no renderer, so a `switch` in a view's body is a switch nothing here can read.
        //
        // Two live-actionable rows would be two recording paths, which is why the count and not the
        // membership is the assertion that matters.

        let actionable = ActivityMenu.entries.filter { $0.action == .startSession }
        assertTest(
            actionable.count == 1,
            "Exactly one `+` row carries `.startSession` (\(actionable.count) held) — the second row is "
                + "inert, and a second recording path is the thing this count exists to prevent")

        assertTest(
            actionable.first?.title == "START ACTIVITY",
            "…and it is `START ACTIVITY`, not the row above it (\(actionable.first?.title ?? "none"))")

        let inert = ActivityMenu.entries.filter { $0.action == .none }
        assertTest(
            inert.map(\.title) == ["ADD ACTIVITY"],
            "…leaving `ADD ACTIVITY` with no destination at all (\(inert.map(\.title))), which is what "
                + "makes the import path's absence structural rather than a promise")

        // ---- The bar Home pins over a running session ----
        //
        // A pure value with no database behind it, like the block above. `HomeDashboardView` builds the
        // bar itself and the runner has no renderer, so what is assertable is the whole of
        // `LiveSessionBar`: the rule that decides whether the bar exists, and the one sentence it
        // announces. The drawing — full-bleed red, the system's clock, the tap that pushes the session —
        // is the user's to check on a screen.
        //
        // **The gate is two questions and not one, and that is the assertion that matters.** A bar keyed
        // on "does this session have a start instant" reads identically to the right one at rest and
        // differently for the length of `end()`'s two awaits, where `isRunning` is already false and
        // `startedAt` is still set — so the wrong gate keeps counting over Home while the `workouts` row
        // is being written.
        let barAnchor = Date(timeIntervalSinceReferenceDate: 0)

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: true,
                activityName: nil,
                activityStartedAt: barAnchor,
                activeFast: nil)?.anchor == barAnchor,
            "A running session's bar counts from its own start instant")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: false,
                activityName: nil,
                activityStartedAt: barAnchor,
                activeFast: nil) == nil,
            "…and it is gone the moment the session stops, **not** when its start instant is cleared — "
                + "`end()` clears `isRunning` at its top and `startedAt` only in `reset()`, after the card "
                + "is ended and the row written, so a gate on the instant alone would leave the bar "
                + "counting over Home through a database round trip")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: true,
                activityName: nil,
                activityStartedAt: nil,
                activeFast: nil) == nil,
            "A running session with no start instant draws no bar at all, because the clock "
                + "(`Text(_:style: .timer)`) is drawn *from* an anchor and this app has no state in which "
                + "a recording is underway and has no beginning — and nothing is left underneath it to "
                + "fall through to")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: false,
                activityName: nil,
                activityStartedAt: nil,
                activeFast: nil) == nil,
            "…and a session that has stopped and been cleared draws none either")

        // ---- The two live sessions, and which one the bar is about ----
        //
        // **The activity wins, and that is the user's own decision rather than a precedence accident.**
        // A fast does not block an activity — 18 hours in, the user can go for a run — so while the run is
        // on, the bar describes the run and the fast keeps counting underneath. The pair below is the
        // assertion that fails if the two branches are ever swapped, since each of the first two passes
        // with the wrong order and only the both-live case can see it.
        let barFast = ActiveFast(startedAt: barAnchor.addingTimeInterval(-90_000))

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: true,
                activityName: "Basketball",
                activityStartedAt: barAnchor,
                activeFast: barFast) == .activity(name: "Basketball", startedAt: barAnchor),
            "With both a fast and an activity live, the bar is about **the activity** — the run is the "
                + "newer thing happening, and the fast is still there underneath it")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: false,
                activityName: "Basketball",
                activityStartedAt: barAnchor,
                activeFast: barFast) == .fast(startedAt: barFast.startedAt),
            "…and the moment the activity stops the bar returns to the fast, still anchored to the "
                + "fast's own start instant rather than to the run's")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: true,
                activityName: "Basketball",
                activityStartedAt: barAnchor,
                activeFast: nil) == .activity(name: "Basketball", startedAt: barAnchor),
            "A recorded name reaches the bar, so the sentence it speaks is about the session the picker "
                + "chose rather than about every session alike")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: true,
                activityName: nil,
                activityStartedAt: barAnchor,
                activeFast: nil) == .activity(name: WhoopActivityCatalog.abstentionName, startedAt: barAnchor),
            "…and a session with no name falls back to the same abstention word `end()` writes onto the "
                + "row, so the bar and the stored session cannot disagree about what it was called")

        assertTest(
            LiveSessionBar.subject(
                isActivityRunning: false,
                activityName: nil,
                activityStartedAt: nil,
                activeFast: barFast) == .fast(startedAt: barFast.startedAt),
            "A fast with no activity beside it is what the bar draws, which is the whole of the "
                + "fasting-zone colouring: the subject is what the fill and the ink are derived from")

        // ---- The fast's zone, and the two colours that follow from it ----
        //
        // `HomeDashboardView` asks for `fill(at:)` and `ink(at:)` inside a `TimelineView`, so what is
        // assertable is the pair of answers for a given instant — and the sweep is over the **whole fast**,
        // not a day-clamped span, because that is the reading the live bar means: `ActivityFigure
        // .fastingZone(for:on:)` answers what a fast had reached *by the end of a day*, and this answers
        // what it has reached *now*. The two diverge on every day a long fast merely passes through and
        // must not be reconciled.
        //
        // The five boundaries are swept at the instant each one turns, because `zone(forDurationSeconds:)`
        // is the rule and this is where the bar's colour is shown to follow it rather than to hold a second
        // copy. Reaching `ketosis` on a screen means waiting 24 hours, so this is the only form that claim
        // can take in this repo.
        let barZoneCases: [(hours: Double, zone: FastingZone)] = [
            (0, .anabolic), (4, .catabolic), (16, .fatBurning), (24, .ketosis), (72, .deepKetosis),
        ]
        for (hours, expected) in barZoneCases {
            let subject = LiveSessionBar.Subject.fast(
                startedAt: barAnchor.addingTimeInterval(-hours * 3600))
            let now = barAnchor
            assertTest(
                subject.zone(at: now) == expected && subject.fill(at: now) == expected.color
                    && subject.ink(at: now) == expected.inkColor,
                "A fast \(hours) h in is \(expected.rawValue): its zone, its fill and its ink all come "
                    + "off `FastingZone` rather than off a second table here "
                    + "(\(String(describing: subject.zone(at: now))))")
        }

        assertTest(
            LiveSessionBar.Subject.activity(name: "Basketball", startedAt: barAnchor).zone(at: barAnchor)
                == nil,
            "An activity is in no fasting zone, and `nil` is the honest answer rather than a missing one — "
                + "there is no duration at which a run becomes ketosis")

        assertTest(
            LiveSessionBar.Subject.activity(name: "Basketball", startedAt: barAnchor).fill(at: barAnchor)
                == Theme.recoveryRed,
            "…so an activity keeps the red the bar has always drawn, which is the user's own rule — a "
                + "regular activity has that red timer on the Home page")

        assertTest(
            LiveSessionBar.Subject.activity(name: "Basketball", startedAt: barAnchor).ink(at: barAnchor)
                == .white,
            "…and white letters on it, which is what that red's contrast was chosen for")

        // The bar is deliberately *not* the pill: the pill states what kind of fast it was on a day the
        // fast covers, while the bar states what the fast is in **right now**. One fast, two readings,
        // both correct — pinned here so a later reader does not "fix" one into the other.
        assertTest(
            LiveSessionBar.Subject.fast(startedAt: barAnchor.addingTimeInterval(-90_000)).zone(at: barAnchor)
                == FastingZone.zone(forDurationSeconds: 90_000),
            "The bar's zone is the fast's whole elapsed span, and a stored row's pill is its day-clamped "
                + "one — a 25 h fast reads ketosis on the bar and fat burning on the day it began")

        // The label is the only place the elapsed figure exists as text — the visible clock is the
        // system's, which is what lets it keep counting while the app is suspended — so it is pinned at
        // four spans. The past-an-hour case is the deliberate one: the sentence stays in minutes rather
        // than rolling into hours, which is `LiveSessionView`'s own form, so the bar and the session
        // screen cannot announce one recording's length two different ways.
        let barActivity = LiveSessionBar.Subject.activity(name: "Activity", startedAt: barAnchor)

        assertTest(
            LiveSessionBar.accessibilityLabel(for: barActivity, now: barAnchor)
                == "Activity recording, 0 minutes 0 seconds elapsed",
            "A session at zero seconds announces zero rather than nothing "
                + "(\(LiveSessionBar.accessibilityLabel(for: barActivity, now: barAnchor)))")

        assertTest(
            LiveSessionBar.accessibilityLabel(
                for: barActivity, now: barAnchor.addingTimeInterval(754))
                == "Activity recording, 12 minutes 34 seconds elapsed",
            "…and 754 seconds announces as 12 minutes 34 seconds")

        assertTest(
            LiveSessionBar.accessibilityLabel(
                for: barActivity, now: barAnchor.addingTimeInterval(3725))
                == "Activity recording, 62 minutes 5 seconds elapsed",
            "…and past an hour it stays in minutes, as the session screen's sentence does — 62 minutes, "
                + "not `1 hour 2 minutes`")

        assertTest(
            LiveSessionBar.accessibilityLabel(
                for: barActivity, now: barAnchor.addingTimeInterval(-30))
                == "Activity recording, 0 minutes 0 seconds elapsed",
            "…and a clock read before the anchor clamps at zero rather than announcing a negative span, "
                + "which no state of this app can have measured")

        assertTest(
            !LiveSessionBar.accessibilityLabel(
                for: barActivity, now: barAnchor.addingTimeInterval(60)).contains("ended"),
            "…and the word is `recording`, never `ended`: the bar exists only while a session is running, "
                + "so the second branch `LiveSessionView` needs could only be a lie here")

        // The name is the half of the sentence that a fast added, so it needs its own assertion: without
        // one, `subject.name` could return `WhoopActivityCatalog.fastingName` for both cases and every
        // assertion above would still pass, because they all pin an activity and the default name is the
        // abstention word they were written against.
        assertTest(
            LiveSessionBar.accessibilityLabel(
                for: .activity(name: "Basketball", startedAt: barAnchor),
                now: barAnchor.addingTimeInterval(60))
                == "Basketball recording, 1 minutes 0 seconds elapsed",
            "A session the picker named says its own name rather than the abstention word")

        assertTest(
            LiveSessionBar.accessibilityLabel(
                for: .fast(startedAt: barAnchor), now: barAnchor.addingTimeInterval(60))
                == "Fast recording, 1 minutes 0 seconds elapsed",
            "…and a fast announces as `Fast` — the one word every layer of this app calls it, read off "
                + "`WhoopActivityCatalog.fastingName` rather than typed here")

        assertTest(
            LiveSessionBar.accessibilityHint(for: barActivity) == "Opens the activity session",
            "The bar's hint names what the tap does "
                + "(\(LiveSessionBar.accessibilityHint(for: barActivity))) rather than leaving the button "
                + "to be announced as a bare duration")

        // **The tap forks, so the hint is a function of the subject and not a constant.** Both arms push a
        // page off the same use case, but they are two different pages, and one sentence would describe a
        // destination the tap does not always reach.
        assertTest(
            LiveSessionBar.accessibilityHint(for: .fast(startedAt: barAnchor))
                == "Opens the fasting session",
            "…and a fast's hint names the other page, because the tap opens the fasting detail layout "
                + "rather than the session controller")

        // ---- The mark the bar leads with ----
        //
        // The bar draws the activity's own glyph in front of its clock, so the figure a reader sees is the
        // one they picked rather than one mark for every recording. Which mark that is lives on the subject
        // and not in the `body`, for this whole type's reason — and the arm that makes it worth pinning is
        // the fasting one: `ActivityGlyph.mark(for: nil)` is `figure.run`, so a `.fast` case that read its
        // name off anything but `WhoopActivityCatalog.fastingName` would draw a *running* figure over a
        // fasting bar. That is a wrong drawing rather than a missing one — the failure mode `ActivityGlyph`
        // exists to catch — and no build and no screenshot of any other bar would report it.
        assertTest(
            LiveSessionBar.Subject.activity(name: "Basketball", startedAt: barAnchor).mark
                == .single("figure.basketball"),
            "The bar leads with the mark for the activity the picker chose "
                + "(\(LiveSessionBar.Subject.activity(name: "Basketball", startedAt: barAnchor).mark.primary))")

        assertTest(
            barActivity.mark == .single(ActivityGlyph.fallback)
                && barActivity.mark == ActivityGlyph.mark(for: nil),
            "…and an unnamed session draws the fallback, the same mark Home's `ACTIVITIES` rows draw for "
                + "the 197 rows WHOOP did not categorise — so the bar's icon and the card's chip cannot "
                + "come to disagree about one session")

        assertTest(
            LiveSessionBar.Subject.fast(startedAt: barAnchor).mark == .pair("fork.knife", "timer"),
            "…while a fast draws the app's one composite, reached through the subject's own name rather "
                + "than a literal here — and it keeps both halves, since `ActivityGlyph` has no accessor "
                + "that hands back a single symbol and dropping `timer` would mean reintroducing the one "
                + "that must not come back")
    }
}
