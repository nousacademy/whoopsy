import Foundation
import Whoopsy

// MARK: - 22.1 The destination and the span, the two values the whole pane is made of

/// **A pure value with no database behind it**, above §22's first `LocalDatabaseManager(inMemory: true)`
/// — §18's and §14's placement, for the same reason: it still asserts if a block below it throws, and a
/// span that is off by one day is the failure every other block in this section would inherit.
///
/// Two questions live here and they are the two the feature is built from: *where does the next write go*
/// (`destination`, which is a switch and moves nothing — the user's own ruling is *"if a DB is selected,
/// it doesnt purge anything, it just switches where data will be stored to"*) and *which days does a run
/// walk* (`range`, which is the one thing on the pane that is a transfer).
///
/// **What this file used to assert, and why none of it is here.** It was three questions: which days the
/// database *owns* (`isCloudDay`, asked of a boundary the user drew), which days it *holds* (`cloudHolds`,
/// asked of a boundary a transfer had reached) and which way the next run moves (`pendingWork`, derived
/// from the difference between the two). The second boundary existed to answer *what has to be fetched
/// back after a delete*, and there is no delete — with both stores always holding their rows, "the
/// database has this day" is a question nothing acts on. So `cutoff`, `uploadedCutoff`, `cloudHolds`,
/// `isCloudDay`, `pendingWork` and `Direction` are all gone, and the block that swept their edges at both
/// ends went with them. The **direction is still reported** — `SyncSummary` says how much moved and which
/// way — it just no longer decides the verb, which is `SyncStorageViewModel.runTitle`'s argument.
///
/// **Every edge is asserted at both ends.** A span comparison that is `>=` where it should be `>` moves
/// exactly one day, which is invisible on a pane whose sentence is still true of nine hundred others.
enum SyncSettingsTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped. Built by adding to *today* rather than by subtracting
        /// from a fixed literal, so the assertions hold on whatever day the suite runs — §11's rule — and
        /// snapped, so a DST transition cannot hand back an instant that is not a midnight.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        // MARK: The default is this phone, and it is the whole of "nothing leaves the phone"

        let fresh = SyncSettings()
        assertTest(fresh.destination == .device, "A fresh install stores new data on this phone")
        assertTest(fresh.range == nil, "…and has drawn no span, so no run can be started")
        assertTest(!fresh.uploadsBiometricSamples,
                   "…and does not send biometric samples, which is the behaviour the absent control "
                       + "would have had on arrival")

        // MARK: A destination is a switch, and the two arms are the two words

        // **The order is the drawing, on this repo's standing rule for a segmented control**, and
        // `device` is first because it is the default: a reorder or a dropped arm leaves the pane a
        // reader first opens looking byte-identical, because the default selection is the first segment.
        assertTest(SyncSettings.Destination.allCases == [.device, .cloud],
                   "There are exactly two destinations, `device` first")
        assertTest(SyncSettings.Destination.allCases.map(\.rawValue)
                       == ["DEVICE STORAGE", "WHOOPSY SYNC API"],
                   "…drawn as `DEVICE STORAGE` and `WHOOPSY SYNC API`, read off `rawValue` rather than "
                       + "typed at the call site — so a third arm is a segment that appears rather than "
                       + "one that silently never does")
        assertTest(SyncSettings().destination == .device, "The default is this phone")
        assertTest(SyncSettings(destination: .cloud).destination == .cloud,
                   "…and the other one is storable, which is what makes the switch a switch rather than "
                       + "a drawing of one")

        // MARK: The span snaps both ends, and the snap is the type's job

        // A `DatePicker` hands back an instant carrying the current clock time, so a span built from one
        // would make the set of days a run walks depend on the minute the user happened to tap. Both ends
        // are asserted on the *stored* value rather than through a predicate, so a `SyncRange` that
        // stopped snapping the far end is caught even where a comparison would still answer correctly for
        // a mid-morning instant on the same day.
        let noonish = calendar.date(byAdding: .hour, value: 9, to: day(-10)) ?? day(-10)
        let thisMorning = calendar.date(byAdding: .hour, value: 9, to: day(-1)) ?? day(-1)
        let bothEnds = SyncSettings.SyncRange(from: noonish, to: thisMorning)
        assertTest(bothEnds.from == day(-10), "A span's near end is snapped to its day")
        assertTest(bothEnds.to == day(-1), "…and so is its far end, which is the half a `from`-only "
                       + "implementation leaves unsnapped")

        // MARK: The span is half-open, and the two edges are where an off-by-one lives

        let oneDay = SyncSettings.SyncRange(from: day(-10), to: day(-9))
        assertTest(!oneDay.isEmpty, "`[day-10, day-9)` covers a day")
        assertTest(oneDay.dayCount == 1,
                   "…exactly one, so the pair is `[from, to)` and not `[from, to]` — the second reading "
                       + "would make every span one day longer than the user drew")

        let sevenDays = SyncSettings.SyncRange(from: day(-10), to: day(-3))
        assertTest(sevenDays.dayCount == 7,
                   "A seven-day span counts seven, and the count is a calendar count rather than "
                       + "`seconds / 86_400`: a span across a daylight-saving change is not a whole "
                       + "number of seconds, so a seconds-derived count is off by one for part of every "
                       + "year — which is the figure the engine checks a resource's ceiling against")

        // The two empty states, and they are different instructions that must both refuse to run. A pair
        // the user has drawn backwards is *not* an error — they are mid-edit and the pickers produce it —
        // so it is empty rather than refused, and the button is gated on this rather than the range being
        // rejected at the write.
        let sameDay = SyncSettings.SyncRange(from: day(-5), to: day(-5))
        assertTest(sameDay.isEmpty,
                   "A span whose ends are the same day covers nothing: a picker showing one date twice "
                       + "asks for no days at all")
        assertTest(sameDay.dayCount == 0, "…which counts zero days")
        let backwards = SyncSettings.SyncRange(from: day(-3), to: day(-10))
        assertTest(backwards.isEmpty, "A span drawn backwards is empty rather than refused")
        assertTest(backwards.dayCount <= 0,
                   "…and counts zero or fewer. The count is deliberately not clamped, because the two "
                       + "readers that matter both gate on `isEmpty` first — `SyncEngine.run` refuses the "
                       + "whole run and the pane's `hasSpan` withholds the button — so a negative here "
                       + "never reaches a comparison against a resource's ceiling")

        // MARK: The settings carry the span whole, or not at all

        // **Both ends or neither, which is why `range` is one optional pair rather than two optional
        // dates.** A half-drawn span is not a span: storing one end alone would leave the pane's button
        // gate describing a range that does not exist, and the drafts the two pickers write into are
        // where that half-state lives instead — a view's business and not this type's.
        let drawn = SyncSettings(destination: .cloud, range: sevenDays)
        assertTest(drawn.range == sevenDays, "A span is stored as one value")
        assertTest(drawn.destination == .cloud,
                   "…and the destination beside it is untouched by it — the two controls are independent, "
                       + "which is the whole of *a destination is a switch and the span is a transfer*")
        assertTest(sevenDays == SyncSettings.SyncRange(from: day(-10), to: day(-3)),
                   "…and two spans with the same snapped ends are equal, so `range` can be compared "
                       + "directly rather than field by field")
    }
}
