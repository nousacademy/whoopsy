import Foundation
import Whoopsy

enum SleepStageRangeScoringTests {
    static func run() async throws {
        // ── 4. The summary, and its absence rules ────────────────────────────────────────────────────
        //

        assertTest(
            SleepStageRangeScoring.stages == [.awake, .light, .deep, .rem],
            "The card's rows come off `SleepStageType.allCases`, which is the reference's order already")

        guard let summary = SleepStageRangeScoring.summary(for: TypicalRangeTests.target, priorNights: TypicalRangeTests.priors) else {
            assertTest(false, "A night with an eight-hour sleep period produced no summary")
            return
        }

        assertTest(
            summary.rows.map(\.percent) == [12, 50, 19, 19],
            "The four shares are whole, in stage order, and sum to 100 "
                + "(got \(summary.rows.map(\.percent)))")
        assertTest(
            summary.durationSeconds == TypicalRangeTests.target.sleepPeriodSeconds,
            "DURATION is the total the four shares divide — the identity the card asserts by printing "
                + "both above one another")
        assertTest(
            summary.restorativeSeconds == TypicalRangeTests.target.restorativeSleepSeconds
                && summary.restorativeSeconds == 10800,
            "Restorative sleep is the entity's own deep + REM, carried rather than re-summed by the card")
        assertTest(
            summary.rows.first { $0.stage == .awake }?.seconds == 3600,
            "…and each row carries its own stage's duration, read through the one stage-to-field switch")

        // The headline. `HOURS OF SLEEP` is the title of the card and this is the figure under it, so the
        // assertion that matters is the identity the card prints: asleep + awake = DURATION, checked
        // against the two figures printed a card below rather than against the entity the two were read
        // from. It is the one that fails if the headline is ever taken from a different sum than the rows.
        assertTest(
            summary.asleepSeconds == 25200 && summary.awakeSeconds == 3600,
            "The headline is the night's three sleep stages — 7h of a night whose fourth row is 1h awake "
                + "(got \(summary.asleepSeconds.formattedCompactHoursMinutes()))")
        assertTest(
            summary.asleepSeconds + summary.awakeSeconds == summary.durationSeconds,
            "…and it adds up with the awake row to the DURATION the typical-range card prints, which is "
                + "the check a reader can make on the screen itself")
        assertTest(
            summary.typicalAsleepSeconds == 28800,
            "The window's mean hours of sleep is 8h — its four priors carry no wake at all (got "
                + "\(summary.typicalAsleepSeconds.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

        // The headline's comparison, through the exact call the card makes. Tonight's 7h against a typical
        // 8h is worse news, and `higherIsBetter: true` is the judgement that says so — the same judgement
        // the restorative row makes, so a longer night cannot be red on one row and green on the other.
        let asleepChange = MetricChange.between(
            current: summary.asleepSeconds,
            previous: summary.typicalAsleepSeconds,
            higherIsBetter: true,
            formatted: { $0.formattedCompactHoursMinutes() })
        assertTest(
            asleepChange?.verdict == .worse && asleepChange?.direction == .down
                && asleepChange?.previousText == "8:00",
            "Tonight's 7:00 asleep against a typical 8:00 reads as worse, and prints the mean it was read "
                + "against")

        // The bands. The priors' deep shares are 20/25/30/35%, so the type-7 quartiles are 23.75 and
        // 31.25; light and REM are 40/37.5/35/32.5%, giving 34.375 and 38.125; awake is zero every night.
        assertTest(
            summary.rows.count == 4 && summary.rows.allSatisfy({ $0.typical != nil }),
            "Four prior nights clear the count floor, so all four rows carry a band")
        assertTest(
            summary.rows.first { $0.stage == .deep }?.typical
                == SleepStageRangeScoring.Typical(lowPercent: 23.75, highPercent: 31.25),
            "Deep's band is the middle half of the priors' own deep shares, in percentage points")
        assertTest(
            summary.rows.first { $0.stage == .light }?.typical
                == SleepStageRangeScoring.Typical(lowPercent: 34.375, highPercent: 38.125),
            "…and light's is its own, not a copy of deep's — four bands, four quantities")
        assertTest(
            summary.rows.first { $0.stage == .awake }?.typical
                == SleepStageRangeScoring.Typical(lowPercent: 0, highPercent: 0),
            "A stage that was zero on every prior night has a zero-width band, which is a real answer "
                + "and not the `nil` a thin window gives")

        assertTest(
            summary.nightCount == 4,
            "The band's window is reported as the count it was taken over (got \(summary.nightCount))")
        assertTest(
            summary.typicalRestorativeSeconds == 18360,
            "Restorative sleep is read against the window's **mean** of deep + REM — 5h 6m over these "
                + "four priors (got \(summary.typicalRestorativeSeconds.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

        // The footer's comparison, through the exact call the card makes. A night 5h 6m of typical
        // restorative against tonight's 3h is worse news, and `MetricChange` decides that on the
        // formatted pair — which is what the card prints.
        let change = MetricChange.between(
            current: summary.restorativeSeconds,
            previous: summary.typicalRestorativeSeconds,
            higherIsBetter: true,
            formatted: { $0.formattedCompactHoursMinutes() })
        assertTest(
            change?.verdict == .worse && change?.direction == .down && change?.previousText == "5:06",
            "Tonight's 3:00 restorative against a typical 5:06 reads as worse, and prints the mean it "
                + "was read against")

        // ── The count floor, at both edges ───────────────────────────────────────────────────────────
        if let twoPriors = SleepStageRangeScoring.summary(
            for: TypicalRangeTests.target, priorNights: Array(TypicalRangeTests.priors.suffix(2))) {
            assertTest(
                twoPriors.rows.allSatisfy({ $0.typical == nil })
                    && twoPriors.nightCount == 0
                    && twoPriors.typicalRestorativeSeconds == nil
                    && twoPriors.typicalAsleepSeconds == nil,
                "Two nights are below `minimumBaselineDays`, so every band is withheld — all four carriers "
                    + "of that one fact together — but the shares and durations are readings the night "
                    + "really has and are still drawn")
            assertTest(
                twoPriors.rows.map(\.percent) == [12, 50, 19, 19],
                "…the percent column is unaffected by a thin window, which is what makes it a separate "
                    + "state from an absent card")
        } else {
            assertTest(false, "A thin window returned no summary at all; it must still describe the night")
        }

        if let threePriors = SleepStageRangeScoring.summary(
            for: TypicalRangeTests.target, priorNights: Array(TypicalRangeTests.priors.suffix(3))) {
            assertTest(
                threePriors.rows.allSatisfy({ $0.typical != nil }) && threePriors.nightCount == 3,
                "Three nights are the other edge: the floor is inclusive, and every band reappears")
        } else {
            assertTest(false, "Three nights is `minimumBaselineDays` and must produce a summary")
        }

        // ── A stored night with no sleep period is not a prior ───────────────────────────────────────
        //
        // It has no share to contribute, so counting it would manufacture a baseline out of nights that
        // have none; and its zero restorative sleep would drag the mean down, which is the second half of
        // the same mistake. Both are asserted, because the mean is the one that fails silently.
        if let withEmpty = SleepStageRangeScoring.summary(
            for: TypicalRangeTests.target, priorNights: TypicalRangeTests.priors + [TypicalRangeTests.empty]) {
            assertTest(
                withEmpty.nightCount == 4,
                "A stored night with no sleep period is dropped from the window rather than counted "
                    + "(got \(withEmpty.nightCount) of 5)")
            assertTest(
                withEmpty.typicalRestorativeSeconds == 18360,
                "…and it does not drag the restorative mean toward zero — an unfiltered mean over the "
                    + "same five nights is 4:04, not the 5:06 the four real nights give")
        } else {
            assertTest(false, "Five nights, one of them empty, still produced no summary")
        }

        // Two real nights and one empty: the filter runs **before** the count floor, or three nights
        // would clear it and the bands would be built over two of them.
        if let belowFloor = SleepStageRangeScoring.summary(
            for: TypicalRangeTests.target, priorNights: Array(TypicalRangeTests.priors.suffix(2)) + [TypicalRangeTests.empty]) {
            assertTest(
                belowFloor.nightCount == 0 && belowFloor.rows.allSatisfy({ $0.typical == nil }),
                "Three stored nights of which one has no sleep period leave two, which is below "
                    + "`minimumBaselineDays` — so the filter is applied before the floor, not after it")
        } else {
            assertTest(false, "A window emptied below the floor must still describe the night itself")
        }

        // ── No night, no summary ─────────────────────────────────────────────────────────────────────
        let blank = TypicalRangeTests.night(dayOffset: 0, light: 0, deep: 0, rem: 0, awake: 0)
        assertTest(
            SleepStageRangeScoring.summary(for: blank, priorNights: TypicalRangeTests.priors) == nil,
            "A session with no sleep period produces **no** summary — the card is then not drawn at all, "
                + "rather than drawn as four `0%` rows, which would be a picture of a night")

        // ── 5. The window the bands are taken over ───────────────────────────────────────────────────
        //
        // The windowing itself is `RecoveryScoring`'s, reused rather than re-derived, so what is asserted
        // here is that the reuse is sound for nights: strictly before, snapped to the calendar day, and
        // capped at the constant the caption on the screen is built from.
        let fortyNights = (1...40).reversed().map { TypicalRangeTests.prior(dayOffset: $0, deepPercent: 20) }
        let today = Calendar.current.startOfDay(for: Date())
        let sameDay = TypicalRangeTests.night(dayOffset: 0, light: 14400, deep: 5400, rem: 5400, awake: 3600)
        let later = TypicalRangeTests.night(dayOffset: -1, light: 14400, deep: 5400, rem: 5400, awake: 3600)

        let window = RecoveryScoring.baselineWindow(before: today, in: fortyNights + [sameDay, later])
        assertTest(
            window.count == 30,
            "Forty nights, the target's own day and a later one still narrow to "
                + "`baselineWindowDays` = \(RecoveryScoring.baselineWindowDays) (got \(window.count))")
        assertTest(
            !window.contains { $0.date >= today },
            "…and neither the night itself nor a night dated after it is inside the window — the "
                + "strict-before rule, compared on the calendar day")
        assertTest(
            window.allSatisfy { $0.date < today },
            "…which is what keeps a night out of its own baseline — the defect the snapped anchor in "
                + "`baselineWindow` records, where the printed mean was taken over a different set of "
                + "days than the score above it")

        // The lookback the view model reads with. If this were `baselineWindowDays` the helper would be
        // handed thirty *days* and could not fill a window of thirty *nights* across the export's
        // recording gap, which is the whole reason the two constants are separate.
        assertTest(
            RecoveryScoring.baselineWindowLookbackDays > RecoveryScoring.baselineWindowDays,
            "The read reaches back further than the window it fills "
                + "(\(RecoveryScoring.baselineWindowLookbackDays) days for "
                + "\(RecoveryScoring.baselineWindowDays) nights)")

    }
}
