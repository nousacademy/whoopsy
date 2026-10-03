import Foundation

/// What a session's row prints — the headline on Home's `ACTIVITIES` row, the strain on the activity
/// detail page, the fasting zone a fast is in, the end figure a fast's time range prints, and the dash
/// that stands in when nothing measured one.
///
/// ## Why this is a type and not a few lines in the views that draw them
///
/// The same reason `DayBarRules`, `ActivityMenu` and `ActivityGlyph` are: **the test runner has no
/// renderer**, so a rule written into a `body` is a rule nothing can assert. The rules here are
/// absence rules — the class of rule this app gets wrong most expensively — and until `v18` the first
/// two could not be exercised at all, because `WorkoutSession.strain` was non-optional and there was
/// no such thing as a session with no strain to draw.
///
/// ## A dash is not `0`, and the two are different answers
///
/// `strainText` returns the dash for `nil` and `"0.0"` for a measured `0.0`, and the second is a real
/// reading rather than a placeholder: `LiveSessionAccumulator` produces exactly `0.0` for a session it
/// watched that never left zone 1. Collapsing the two — the way a defaulted `strain: 0` would — puts a
/// confident *no strain at all* on a fasting window nothing measured, which is the fabrication every
/// absence rule in this app exists to prevent.
///
/// ## The headline picks the quantity the session actually has
///
/// A `WorkoutSession` on Home's `ACTIVITIES` card currently comes from one of three producers, and they
/// disagree about what the session's own interesting number is: an imported WHOOP workout has a strain
/// and no duration worth a headline, a live session has a strain, and a fast has a **duration** and no
/// strain at all. So the headline is the strain where the app measured one and the session's own length
/// where it did not — which is the same shape the `SLEEP` row above it already takes, a duration under
/// a word, so the two rows read alike on one card.
public enum ActivityFigure {

    /// Whether this session's row draws the fasting treatment: **nothing measured a strain**, and it
    /// is named `Fast`.
    ///
    /// ## This is the one definition, and it exists because there were two
    ///
    /// `fastingZone(for:on:)` and `fastingEndText(for:on:now:)` below each carried this same pair of
    /// guards, verbatim and in the same order — which is what the comment above `fastingEndText` says
    /// was deliberate, so that this app holds one definition of which rows are fasts rather than two
    /// that can drift. They were still two copies of one rule. Now they are one: both call this, and
    /// the fasting detail page's layout gate does too.
    ///
    /// ## The `strain == nil` guard is first, and it is what lets the name be read at all
    ///
    /// A `Fast` carrying a measured strain is **not** drawn as one — that is `headlineText`'s
    /// data-gate doctrine (*the gate is the data and never the label*), and it is why consulting the
    /// label here is not the regression that rule warns about. The name is read only on the branch
    /// where nothing was measured and the duration was a fallback anyway.
    ///
    /// **There is deliberately no `steps == nil` clause.** `steps` is `nil` on every export row and on
    /// every row written before `v17`, so it tests *no sensor* — which `strain == nil` already tests —
    /// and as a third clause it would put a hand-recorded fast carrying a step count on the ordinary
    /// layout while Home still drew it a pill.
    ///
    /// The key is the **name and not `source`**: `WhoopActivityCatalog.fastingName` is selectable in
    /// `ActivityEditSheet`, so a fast the user records by hand carries it with no `zero_fasting` label
    /// and must still be one, while a fast re-labelled to something else has stopped being one. It is
    /// the same key `ActivityGlyph.mark(for:)` resolves through, and the same `ActivityName.normalised`.
    public static func isFast(_ session: WorkoutSession) -> Bool {
        guard session.strain == nil else { return false }
        return isFastName(session.activityName)
    }

    /// The **name half** of the rule above, on its own.
    ///
    /// ## Why the half is separable, and the one caller that needs it that way
    ///
    /// Every reader up to now had a session in hand, so `strain == nil` was always available to ask
    /// first and the pair could be one function. The activity picker does not: it dispatches on a
    /// `String?` the user just chose, **before any session exists to hold a strain**. `Fast` is in
    /// `WhoopActivityCatalog`, so picking it has to route to `LiveSessionUseCase.startFast()` rather
    /// than to `start(name:)` — and asking *which branch* there is asking only whether the chosen name
    /// is the fasting one.
    ///
    /// **This is an extraction, not a second rule**, and the two stay in one order by construction:
    /// `isFast` is now the data gate followed by this. Nothing about `isFast`'s answer moves, which is
    /// what keeps §19's and §20's pinned pairs passing untouched.
    ///
    /// The `nil` case answers `false`, which is the same non-answer `isFast` gives it — a session with
    /// no name is not a fast, and the caller deciding whether to start one has nothing to start.
    public static func isFastName(_ name: String?) -> Bool {
        ActivityName.normalised(name) == ActivityName.normalised(WhoopActivityCatalog.fastingName)
    }

    /// The one em dash in this app's figure vocabulary.
    ///
    /// A single literal rather than a `"—"` typed at each call site, so the three readers here and
    /// `ActivityDetailViewModel` cannot come to draw three different dashes. It is an em dash and not a
    /// hyphen or an en dash: it is a typographic mark for *no value*, and a hyphen reads as a minus sign
    /// beside a figure.
    public static let dash = "—"

    /// The session's strain as the detail page prints it — the figure, or the dash when nothing
    /// measured one.
    ///
    /// **Never `"0.0"` for an unmeasured session**, and never a dash for a measured `0.0`. See the type
    /// comment; `ActivityDetailView`'s `ACTIVITY STRAIN` cell is the reader.
    public static func strainText(for session: WorkoutSession) -> String {
        guard let strain = session.strain else { return dash }
        return strain.formattedOneDecimal()
    }

    /// The figure on Home's `ACTIVITIES` row — the strain where the app measured one, and the session's
    /// own length where it did not.
    ///
    /// `formattedCompactHoursMinutes()` is the `SLEEP` row's own formatter (`7:33`), so a fast and a
    /// night read as the same kind of quantity under the same kind of word. **The gate is the data and
    /// not the label**: a session *named* `Fast` that carries a strain prints the strain, because what
    /// decides this figure is whether a sensor measured something, not what the session is called. A
    /// label-keyed rule would be a rule that lies the first time an activity has both.
    ///
    /// There is deliberately no dash branch. `WorkoutSession` always has a span, so this can always
    /// print *something* — and a row whose headline read `—` would be a row with no figure at all,
    /// which is a worse answer than the session's own length.
    public static func headlineText(for session: WorkoutSession) -> String {
        guard let strain = session.strain else {
            return session.durationSeconds.formattedCompactHoursMinutes()
        }
        return strain.formattedOneDecimal()
    }

    /// The fasting zone Home's `ACTIVITIES` row draws as a pill **in place of** that headline, or
    /// `nil` for every row that prints a figure.
    ///
    /// ## The third rule, and the one most likely to read as a violation of the second
    ///
    /// `headlineText` above carries the rule **the gate is the data and never the label** — a session
    /// *named* `Fast` that carries a strain prints the figure. This function consults the label, so it
    /// looks at first like the regression that rule warns about. It is not, and the reason is where
    /// the two sit relative to each other: **the pill occupies the slot the duration would have
    /// occupied, not the slot the strain would have.** The first `guard` below is that same data
    /// gate, and it returns `nil` the moment a sensor measured a strain — so a `Fast` with a strain
    /// still headlines `7.4`, byte-identically to before, and the name is read only on the branch
    /// where nothing was measured at all and the duration was a fallback anyway.
    ///
    /// ## Why the name and not `source`
    ///
    /// `WhoopActivityCatalog.fastingName` is selectable in `ActivityEditSheet`, so a fast the user
    /// records by hand carries that name and **no** `zero_fasting` label and must still get a pill;
    /// and a fast the user re-labels to something else has stopped being one. The name is therefore
    /// the honest key, and it is the same key `ActivityGlyph.mark(for:)` already resolves through —
    /// the same `ActivityName.normalised`, so the chip and the pill can never disagree about which
    /// rows are fasts.
    ///
    /// ## Why the zone is a function of the day
    ///
    /// A zone is a claim about how long the body has been fasting, so on a day a multi-day fast merely
    /// passes through, the honest answer is the zone it had **reached by the end of that day** —
    /// `elapsedSeconds(byEndOf:)`, clamped to the fast's own end. An 86-hour fast therefore walks
    /// `ANABOLIC` on the evening it starts, `KETOSIS` on its second and third days, and
    /// `DEEP KETOSIS` on its fourth and fifth.
    ///
    /// **That rewrites the start day of every multi-day fast**, which is the deliberate cost: 151 of
    /// the 170 bundled fasts span more than one day and all of them now draw a few hours' zone on day
    /// one where they previously drew the whole fast's. The alternative — the fast's overall zone on
    /// its start day and the reached zone only afterwards — would draw `DEEP KETOSIS` on day 1 above
    /// `KETOSIS` on day 2, a zone moving backwards down the week. A **single-day** fast is untouched,
    /// because its own end is inside its day and the clamp returns exactly its duration.
    ///
    /// A row that is not a fast is unaffected in every case: it has a strain and prints it, or it has
    /// no strain and prints its duration as it always did.
    public static func fastingZone(for session: WorkoutSession, on day: Date) -> FastingZone? {
        guard isFast(session) else { return nil }
        return FastingZone.zone(forDurationSeconds: session.elapsedSeconds(byEndOf: day))
    }

    /// The word a fast's row prints while it is still running.
    ///
    /// A constant rather than a literal at the call site, for `dash`'s reason one rule along: it is the
    /// same string the row draws and the same string §20 pins, so a rewrite cannot move one without the
    /// other.
    public static let inProgressText = "ACTIVE"

    /// Whether this session is running at `now` — **the fast's own state, with no reference to which
    /// day is on screen.**
    ///
    /// That distinction is the whole reason this is a separate function rather than a clause of
    /// `fastingEndText` below. A row asks *"is it running, on the day I am drawing"* and needs both
    /// halves; the fasting detail page's guidance sentence asks *"is it running"* and must not consult
    /// a day at all, because its tense is a fact about the fast and not about the page. Written twice
    /// they would be two definitions of one state, and the copy they decide would drift apart.
    ///
    /// It is **half-open at both ends on purpose**: `startedAt <= now` so a fast that has just begun
    /// counts as running, and `now < endedAt` so one that ended at exactly `now` does not. That is
    /// `WorkoutSession.covers(_:)`'s convention and the same one `fastingEndText`'s `11:59 PM` arm
    /// rests on.
    ///
    /// `now` is a parameter rather than a `Date()` read inside, for `DayBarRules`' reason: an assertion
    /// about "running now" must not say something different tomorrow.
    public static func isInProgress(_ session: WorkoutSession, now: Date = Date()) -> Bool {
        session.startedAt <= now && now < session.endedAt
    }

    /// The text a fast's row prints on the **right** of its time range, in place of its own end clock —
    /// or `nil` for a row that prints the session's real end, which is every row that is not a fast.
    ///
    /// ## The two states the user named
    ///
    /// A fast's covered days would otherwise read identically — the fast's own start clock on the left,
    /// its own **end** clock on the right, on every one of them, which is a claim that the fast ended at
    /// 11:01 AM on a day it was still running. So the end figure is replaced on the days the fast did
    /// not end on:
    ///
    /// - **a day the fast was still underway at the end of** reads `11:59 PM`, that day's own last
    ///   minute, because the fast ran to it and its real end belongs to a day this row is not about;
    /// - **the day it is running on right now** reads ``inProgressText``, because there is no end figure
    ///   to print — the fast has not finished.
    ///
    /// The day a fast **ended** on, and every single-day fast, still print the real end. That is the
    /// whole of the rule: a fast's rows read `11:59 PM` for as long as it is underway and its own end
    /// clock once it has stopped, and the left-hand clock and the weekday badge beside it do not move.
    ///
    /// ## `endOfDay` is the display value here and never a bound
    ///
    /// The `11:59` is `Date.endOfDay`'s label value, and this is the one place in the app it is the right
    /// thing to read: what it produces is a **string**. Its doc forbids it as a *bound*, and the
    /// comparison below is built on `startOfNextDay` instead — the half-open edge, one second past the
    /// text being printed. Borrowing `endOfDay` for that comparison would under-count every day by a
    /// second, which is the defect that flips four real fast-days on the bundled file. **Keep the two
    /// apart**: the string is a label, the bound is arithmetic.
    ///
    /// The `>=` rather than `>` is that same half-open convention, and it settles the one case where the
    /// two differ — a fast ending at exactly `00:00:00`. It ran to the last instant of the day, so the
    /// day reads `11:59 PM`; under `>` the row would print `12:00 AM`, a clock time belonging to a day
    /// the fast is drawn on **no** row of, since the covering read excludes it.
    ///
    /// ## The gate is `isFast`
    ///
    /// One call to the type's own gate, so this app holds **one** definition of which rows are fasts
    /// rather than two that can drift: a session that measured a strain is not one, and it prints its
    /// own end on every day it covers. §20 pins that pair.
    ///
    /// `now` is a parameter rather than a `Date()` read inside, for `DayBarRules`' reason: an assertion
    /// about "in progress" must not say something different tomorrow.
    public static func fastingEndText(
        for session: WorkoutSession,
        on day: Date,
        now: Date = Date()
    ) -> String? {
        guard isFast(session) else { return nil }

        // Running *now*, on the day now falls on. Both halves are needed: a fast that is running today
        // still prints `11:59 PM` on the days behind it, and a fast that ended this morning prints its
        // real end on today's row. The first half is `isInProgress` above rather than the comparison
        // written out, so the fast's own state has one definition; the day test stays here, because it
        // is this function's question and not the state's.
        if isInProgress(session, now: now), DayBarRules.isToday(day, now: now) {
            return inProgressText
        }
        guard session.endedAt >= day.startOfNextDay else { return nil }
        return day.endOfDay.formattedHourMinute()
    }
}
