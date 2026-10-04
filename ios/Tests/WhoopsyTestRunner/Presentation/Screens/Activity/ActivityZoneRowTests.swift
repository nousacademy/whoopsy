import Foundation
import SwiftUI
import Whoopsy

enum ActivityZoneRowTests {
    static func run() async throws {
        // MARK: - The delta: a comparison with no verdict

        let strainDelta = ActivityDelta.between(
            current: 4.1, mean: 1.6, formatted: { $0.formattedOneDecimal() })
        assertTest(
            strainDelta?.magnitudeText == "2.5" && strainDelta?.meanText == "1.6"
                && strainDelta.flatMap(\.direction) == .up,
            "A figure above its window's mean points up, and the magnitude is the distance — **never "
                + "signed**, because the glyph is the only thing that says which way it went "
                + "(\(strainDelta?.magnitudeText ?? "nil"), \(strainDelta?.meanText ?? "nil"))")

        let downDelta = ActivityDelta.between(
            current: 1.6, mean: 4.1, formatted: { $0.formattedOneDecimal() })
        assertTest(
            downDelta.flatMap(\.direction) == .down && downDelta?.magnitudeText == "2.5",
            "…and a figure below it points down, with the same unsigned magnitude — the two directional "
                + "cases differ in the glyph and in nothing else")

        // `4.14` and `4.1` print alike at one decimal, so the row would read `4.1 = 4.1`. The comparison
        // is therefore made on the **formatted** pair, which is `MetricChange`'s rule and the reason
        // `between` takes the caller's own formatter rather than choosing one.
        let sameDelta = ActivityDelta.between(
            current: 4.14, mean: 4.1, formatted: { $0.formattedOneDecimal() })
        assertTest(
            sameDelta != nil,
            "A figure that prints the same as its mean still produces a delta rather than nothing: "
                + "`nil` is reserved for a **missing side**, never for *unchanged*")
        assertTest(
            sameDelta.flatMap(\.direction) == nil && sameDelta?.magnitudeText == "0.0",
            "…and that case has no direction and a magnitude of `0.0` — a raw comparison of 4.14 against "
                + "4.1 would instead draw `4.1 ▲ 4.1`, a row contradicting itself")

        assertTest(
            ActivityDelta.between(current: nil, mean: 4.0, formatted: { $0.formattedOneDecimal() }) == nil,
            "A session whose own figure was never measured yields no delta at all — the badge is "
                + "withheld, never drawn against a substituted number")
        assertTest(
            ActivityDelta.between(current: 4.0, mean: nil, formatted: { $0.formattedOneDecimal() }) == nil,
            "…and so does a window below the three-session floor, which has no mean to compare against")

        assertTest(
            (strainDelta?.symbolName ?? "nil") == "arrowtriangle.up.fill"
                && (downDelta?.symbolName ?? "nil") == "arrowtriangle.down.fill"
                && (sameDelta?.symbolName ?? "nil") == "circle.fill",
            "Each of the three answers has its own glyph, and the unchanged one is a filled circle "
                + "rather than a triangle pointing nowhere "
                + "(\(strainDelta?.symbolName ?? "nil"), \(downDelta?.symbolName ?? "nil"), "
                + "\(sameDelta?.symbolName ?? "nil"))")

        let verdicts = [Theme.recoveryGreen, Theme.recoveryYellow, Theme.recoveryRed]
        assertTest(
            strainDelta?.color == Theme.neutralDelta && downDelta?.color == Theme.neutralDelta,
            "Both directions draw in the neutral token — a computed property, so the page cannot come "
                + "to draw a delta in a verdict colour by hand")
        assertTest(
            verdicts.allSatisfy { $0 != strainDelta?.color && $0 != downDelta?.color },
            "…and **no verdict colour is reachable from either direction**. `MetricChange`'s three "
                + "tokens are what a page that disagreed would reach for, and `Theme.neutralDelta` is "
                + "deliberately a fourth token rather than `textSecondary` or `bandSufficient` borrowed "
                + "to mean a judgement: neither of those means one")

        assertTest(
            strainDelta.map(ActivityDeltaBadge.spoken)
                == "up 2.5, against an average of 1.6 over your last ten",
            "The badge's sentence names the window, because *last ten* is the fact that decides whether "
                + "the comparison means anything (\(strainDelta.map(ActivityDeltaBadge.spoken) ?? "nil"))")
        assertTest(
            sameDelta.map(ActivityDeltaBadge.spoken)
                == "unchanged, against an average of 4.1 over your last ten",
            "…and the unchanged case is spoken as words rather than as `0.0` with no glyph beside it")

        // MARK: - The five zone rows

        // The mockup's own session: 958 seconds, and a block summing to 90 — the remaining tenth is time
        // below zone 1, which WHOOP publishes no column for and which is why the column is short.
        let zoned = ActivityDetailTests.session(
            "Basketball", startOffset: 0, durationSeconds: 958, zones: [10, 20, 30, 25, 5])
        let rows = ActivityZoneRow.rows(for: zoned, zones: ActivityDetailTests.zones)

        assertTest(
            rows.count == 5 && rows.map(\.index.rawValue) == [5, 4, 3, 2, 1],
            "Five rows come back **hardest band first**, and the order is decided in `rows(for:zones:)` "
                + "rather than by a `reversed()` in the page's body: the runner can assert this array's "
                + "first element and cannot see a `ForEach` that walks it backwards "
                + "(\(rows.map(\.index.rawValue)))")
        assertTest(
            rows[4].percentText == "10%" && rows[4].secondsText == "0:01:36",
            "Zone 1's share is `10` of 958 seconds and the row prints `0:01:36` — 95.8 seconds rounded to "
                + "the clock's own resolution — and the two figures come from one division rather than "
                + "two (\(rows[4].percentText), \(rows[4].secondsText))")
        assertTest(
            rows.allSatisfy { $0.seconds != nil }
                && rows.compactMap(\.seconds).reduce(0, +) < zoned.durationSeconds,
            "…and the five times sum to **strictly less** than the session, because the block itself sums "
                + "to 90 rather than 100 (\(rows.compactMap(\.seconds).reduce(0, +)) of "
                + "\(zoned.durationSeconds))")
        assertTest(
            rows.first?.bpmRangeText.hasSuffix("+") == true,
            "Zone 5's range has an **open top end**: its ceiling is the profile's nominal maximum rather "
                + "than a measured one, and a strap reports a rate above it the moment a session is "
                + "harder than the profile assumes — printing `177-190` would name a ceiling the scoring "
                + "does not honour (\(rows.first?.bpmRangeText ?? "nil"))")
        assertTest(
            (0..<4).allSatisfy { rows[$0].lowerBpm == rows[$0 + 1].upperBpm },
            "…and the bands are contiguous: each band's floor is the one above it's ceiling, so the five "
                + "ranges tile the scale without a gap or an overlap "
                + "(\(rows.map(\.bpmRangeText)))")

        // An absent block and a measured zero are different answers, and the whole type exists to keep
        // them apart.
        let unzonedRows = ActivityZoneRow.rows(
            for: ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 958), zones: ActivityDetailTests.zones)
        assertTest(
            unzonedRows.count == 5
                && unzonedRows.allSatisfy { $0.percent == nil && $0.seconds == nil },
            "A session with no zone block still draws five rows, each with no figure on it — `nil` in, "
                + "`nil` out, on `WorkoutSession.zoneSeconds`'s own guard")
        assertTest(
            unzonedRows.allSatisfy { $0.percentText == "—" && $0.secondsText == "—" },
            "…and both properties draw the dash, so a row can never show a figure beside an absent one "
                + "(\(unzonedRows.map(\.percentText)), \(unzonedRows.map(\.secondsText)))")
        assertTest(
            ActivityZoneRow.spoken(unzonedRows[0]).hasSuffix("Not recorded for this session."),
            "…and the row says so out loud rather than reading a zero "
                + "(\(ActivityZoneRow.spoken(unzonedRows[0])))")

        let zeroRows = ActivityZoneRow.rows(
            for: ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 958, zones: [0, 0, 0, 0, 0]),
            zones: ActivityDetailTests.zones)
        assertTest(
            zeroRows.allSatisfy { $0.percentText == "0%" && $0.secondsText == "0:00:00" },
            "A stored block of five zeroes is a **measurement** — 45 of the export's 673 rows are exactly "
                + "that, workouts that never reached zone 1 — so it draws `0%` beside `0:00:00`, not the "
                + "dash an absent block draws. The two are the same pixels only if someone collapses them")
        assertTest(
            zeroRows.allSatisfy { $0.percent == 0 && $0.seconds == 0 },
            "**And a stored `0` percent implies exactly `0` seconds.** This is the property that "
                + "separates this app's rows from the reference's: the export's percents are whole, so a "
                + "row's two figures are one share of one duration and can never contradict each other, "
                + "where the reference's `ZONE 1 … 0% · 0:00:12` comes from a finer internal share it "
                + "rounds only for display")

        assertTest(
            ActivityZoneRow.rows(
                for: ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 958,
                             zones: [10.5, 20, 30, 25, 5]),
                zones: ActivityDetailTests.zones
            ).allSatisfy { $0.percent == nil },
            "A fractional percent is **refused outright** rather than rounded: all 3,365 `HR Zone n %` "
                + "cells in the bundled file are whole numbers, so a fraction is a value from some other "
                + "producer, and rounding it would silently invent a reading instead of losing one")
        assertTest(
            ActivityZoneRow.rows(
                for: ActivityDetailTests.session("Basketball", startOffset: 0, durationSeconds: 958, zones: [10, 20]),
                zones: ActivityDetailTests.zones
            ).allSatisfy { $0.percent == nil },
            "…and a block that is not five long reads as no block at all rather than as a partial set "
                + "summing to a confident figure")
        assertTest(
            ActivityZoneRow.rows(for: zoned, zones: Array(ActivityDetailTests.zones.prefix(4))).isEmpty,
            "A zone **table** that is not five bands long answers no rows at all: a page drawing three of "
                + "five zones would report the session's time as though the two hardest bands did not exist")

        // MARK: - The time's two halves

        // The page draws a row's time as a dim hours-and-minutes half and a bright seconds half, so the
        // split is a rule and it lives on the value type rather than in the `body` — the runner has no
        // renderer, and a split written into a view is a split nothing can assert.
        let clockParts = ActivityZoneRow.durationParts("0:15:58")
        assertTest(
            clockParts.leading == "0:15" && clockParts.trailing == ":58",
            "A clock duration splits at its **last** colon, so `0:15:58` draws `0:15` then `:58` — the "
                + "trailing half keeps its colon, so the two halves still read as one duration if the two "
                + "colours are ignored. Splitting at the first colon would put the minutes on the trailing "
                + "side and leave `0` alone on the leading one (got \(clockParts.leading), "
                + "\(clockParts.trailing))")
        assertTest(
            ActivityZoneRow.durationParts("0:00:12") == (leading: "0:00", trailing: ":12"),
            "**And the reference's own case off the export** — a 12-second share of a session draws "
                + "`0:00` then `:12`, which is the whole reason the split is at the last colon: a shorter "
                + "duration has the same two halves in the same two places, so the column does not move "
                + "shape as the numbers shrink")
        assertTest(
            ActivityZoneRow.durationParts("0:00:00") == (leading: "0:00", trailing: ":00"),
            "**And a measured zero keeps its two halves**, so a `0%` row from the 45 all-zero rows in the "
                + "export draws a real `0:00` and `:00` rather than collapsing to the single undivided "
                + "mark an absent block draws — the same distinction the row's values carry, carried "
                + "through the drawing")
        assertTest(
            ActivityZoneRow.durationParts("—") == (leading: "—", trailing: ""),
            "A string with no colon comes back **whole with an empty tail**, which is the dash an absent "
                + "block draws: a dash is not a duration and has no halves, so it is drawn once and "
                + "undivided rather than padded into a two-part shape it does not have")

        // MARK: - The window

        // Twelve `Basketball` sessions ten minutes apart, a `Walking` one interleaved among them, and a
        // `Basketball` one recorded *after* the target. Each is the assertion for one filter: a window
        // that ignored the cap takes twelve, one that ignored the name takes the `Walking` row, and one
        // keyed on the day rather than the instant admits the later session.
        let target = ActivityDetailTests.session("Basketball", startOffset: 7800, durationSeconds: 600)
        var history = [ActivityDetailTests.session("Walking", startOffset: 300, durationSeconds: 600)]
        for index in 0..<12 {
            history.append(ActivityDetailTests.session(
                "Basketball", startOffset: 600 + Double(index) * 600, durationSeconds: 600))
        }
        history.append(ActivityDetailTests.session("Basketball", startOffset: 8400, durationSeconds: 600))

        let window = ActivityBaseline.window(for: target, in: history)
        assertTest(
            window.count == ActivityBaseline.sessionWindowCount,
            "The window is capped at ten (\(ActivityBaseline.sessionWindowCount)) sessions — the count "
                + "the user chose over a calendar window, because a 30-day window would draw a dash on 20 "
                + "of the export's 28 basketball sessions")
        assertTest(
            window.allSatisfy { $0.activityName == "Basketball" },
            "…and holds only the target's own activity: the `Walking` session interleaved among them is "
                + "not pulled in (\(window.compactMap(\.activityName)))")
        assertTest(
            window.allSatisfy { $0.startedAt < target.startedAt },
            "…and none of them starts at or after the target — **strictly** before, so two sessions on "
                + "one day do not share a baseline and the later of them can be compared against the "
                + "earlier")
        assertTest(
            !window.contains { $0.id == target.id },
            "…and the target is not in its own baseline, which is the identity filter and not the instant "
                + "one: a session cannot be its own comparison")
        assertTest(
            !window.contains { $0.startedAt == ActivityDetailTests.anchor.addingTimeInterval(8400) },
            "…and neither is the session recorded *after* it — a window keyed on the calendar day rather "
                + "than the instant would have admitted the second basketball session on that day")
        assertTest(
            window.first?.startedAt == ActivityDetailTests.anchor.addingTimeInterval(1800),
            "…and the ten taken are the ten **most recent** matches, with the cap applied *after* the "
                + "filters: twelve basketball sessions are strictly before the target and the two oldest "
                + "are dropped, which a `.prefix(10)` before the name filter would have got wrong "
                + "(\(window.first.map { $0.startedAt.timeIntervalSince(ActivityDetailTests.anchor) } ?? -1))")

        assertTest(
            ActivityBaseline.window(
                for: target,
                in: [ActivityDetailTests.session("  basketball ", startOffset: 600, durationSeconds: 600)]
            ).count == 1,
            "Matching is `ActivityName`'s normalisation — trimmed and case-folded — because the export's "
                + "own names are not written consistently, and a page grouping on the raw string would "
                + "show one activity's history as two")

        // The abstention group is baselined like any other name, which is the user's own answer and the
        // reason there is no special case here to assert the absence of.
        let abstentionHistory = (0..<3).map {
            ActivityDetailTests.session("activity", startOffset: Double($0) * 600, durationSeconds: 600)
        }
        assertTest(
            ActivityBaseline.window(
                for: ActivityDetailTests.session("Activity", startOffset: 1800, durationSeconds: 600),
                in: abstentionHistory
            ).count == 3,
            "WHOOP's abstention word is baselined like any other name: `Activity` and `Other` are words "
                + "it writes on 208 of the export's 673 rows, which is a history rather than a hole — and "
                + "the 197 `Activity` rows are exactly the sessions with no name to group on")

        // MARK: - The floor, at both edges

        let twoPriors = (0..<2).map {
            ActivityDetailTests.session("Running", startOffset: Double($0) * 600, durationSeconds: 600)
        }
        let runTwo = ActivityDetailTests.session("Running", startOffset: 1800, durationSeconds: 600)
        let thinSummary = ActivityBaseline.summary(
            for: runTwo, priorSessions: ActivityBaseline.window(for: runTwo, in: twoPriors))
        assertTest(
            thinSummary.sessionCount == 0 && thinSummary.typicalDuration == nil
                && thinSummary.meanStrain == nil && thinSummary.meanSteps == nil,
            "Two prior sessions is below `RecoveryScoring.minimumBaselineDays` and **everything** is "
                + "withheld: no band, no strain mean, no step mean, and a session count of zero — which "
                + "is what tells the card to say there is nothing to compare against rather than printing "
                + "a mean over two sessions")

        let threePriors = (0..<3).map {
            ActivityDetailTests.session("Running", startOffset: Double($0) * 600, durationSeconds: 600)
        }
        let runThree = ActivityDetailTests.session("Running", startOffset: 1800, durationSeconds: 600)
        let threeSummary = ActivityBaseline.summary(
            for: runThree, priorSessions: ActivityBaseline.window(for: runThree, in: threePriors))
        assertTest(
            threeSummary.sessionCount == 3 && threeSummary.typicalDuration != nil
                && threeSummary.meanStrain != nil,
            "…and the third prior crosses the floor, so the band and the mean appear at exactly "
                + "`RecoveryScoring.minimumBaselineDays` and not one session later "
                + "(\(threeSummary.sessionCount))")

        // The step mean is taken over a **second population** — the priors that carry a step count at
        // all — and this pair is what keeps an unstored history from reading as a history of stillness.
        let mixedSummary = ActivityBaseline.summary(
            for: ActivityDetailTests.session("Basketball", startOffset: 6000, durationSeconds: 600),
            priorSessions: (0..<10).map {
                ActivityDetailTests.session("Basketball", startOffset: Double($0) * 600, durationSeconds: 600,
                        steps: $0 < 2 ? 500 + $0 : nil)
            })
        assertTest(
            mixedSummary.meanStrain != nil && mixedSummary.meanSteps == nil
                && mixedSummary.stepSessionCount == 0,
            "A ten-session window bands its duration and its strain while its **step** mean is withheld: "
                + "only two of the ten carry a count, and this app has not measured the other eight — "
                + "averaging `?? 0` over them would report a mean step count of nearly zero for a history "
                + "that is simply unstored")
        assertTest(
            mixedSummary.sessionCount == 10,
            "…and the session count is the **window's**, not the step population's, so the card's "
                + "footnote describes the band it actually drew (\(mixedSummary.sessionCount))")

        let steppedSummary = ActivityBaseline.summary(
            for: ActivityDetailTests.session("Basketball", startOffset: 6000, durationSeconds: 600),
            priorSessions: (0..<10).map {
                ActivityDetailTests.session("Basketball", startOffset: Double($0) * 600, durationSeconds: 600,
                        steps: $0 < 3 ? 500 + $0 * 100 : nil)
            })
        assertTest(
            steppedSummary.stepSessionCount == 3 && steppedSummary.meanSteps == 600,
            "…and three carrying one is enough to band it: the mean is taken over those three alone, not "
                + "over the ten (\(steppedSummary.meanSteps ?? -1) over "
                + "\(steppedSummary.stepSessionCount))")

        // MARK: - The band

        // Durations of 600, 1200, 1800 and 2400 seconds. R's `quantile(type = 7)` — which
        // `BaselineStatisticsMath.percentile` implements and NumPy defaults to — puts the first quartile
        // at `h = (4 − 1) × 0.25 + 1 = 1.75`, so `600 + 0.75 × 600 = 1050`, and the third at `h = 3.25`,
        // so `1800 + 0.25 × 600 = 1950`. Both are exact in binary, which is what lets them be pinned as
        // literals rather than to a tolerance, and both are reproducible outside this codebase.
        let quartilePriors = [600.0, 1200.0, 1800.0, 2400.0].enumerated().map { index, duration in
            ActivityDetailTests.session("Yoga", startOffset: Double(index) * 3600, durationSeconds: duration)
        }
        let yogaSummary = ActivityBaseline.summary(
            for: ActivityDetailTests.session("Yoga", startOffset: 4 * 3600, durationSeconds: 600),
            priorSessions: quartilePriors)
        assertTest(
            yogaSummary.typicalDuration == ActivityBaseline.Typical(low: 1050, high: 1950),
            "The band is the middle half of the window's durations, pinned against hand-computed "
                + "quartiles rather than against a second implementation "
                + "(\(String(describing: yogaSummary.typicalDuration)))")
        assertTest(
            yogaSummary.typicalDuration.map { $0.low <= $0.high } == true,
            "…and the pair is ordered as it is handed out, so no caller can be given an inverted band")
        assertTest(
            ActivityBaseline.Typical(low: 900, high: 100)
                == ActivityBaseline.Typical(low: 100, high: 900),
            "The initialiser orders an inverted pair rather than trusting its caller — the percentile "
                + "helper has no reason to hand one over, but a band drawn backwards puts the mark in the "
                + "wrong place and reads as a different scale rather than as a wrong reading")

        assertTest(
            ActivityDurationBarLayout.make(durationSeconds: 600, typical: nil) == nil,
            "**No band, no bar.** The bar's scale *is* the band, so a session with no window to read it "
                + "against draws no picture at all — and the row prints its duration either way, so the "
                + "absence costs the page a drawing and no figure")
        let layout = ActivityDurationBarLayout.make(
            durationSeconds: 1500, typical: ActivityBaseline.Typical(low: 1050, high: 1950))
        assertTest(
            layout?.lowFraction == 1050.0 / 1950.0 && layout?.highFraction == 1.0
                && layout?.filledFraction == 1500.0 / 1950.0,
            "…and with one, the session's own length lands **inside** the band's span on a scale that is "
                + "the band's upper edge — a track running to the session's own end would draw every "
                + "session as a full bar and say nothing "
                + "(\(String(describing: layout)))")
        let longLayout = ActivityDurationBarLayout.make(
            durationSeconds: 4000, typical: ActivityBaseline.Typical(low: 1050, high: 1950))
        assertTest(
            longLayout?.filledFraction == 1.0,
            "…and a session longer than the band's top edge **widens the scale** rather than being "
                + "clamped level with one that only just reached it")

        // MARK: - The page's own strings

        // The four sentences the page composes, asserted as statics for the reason every other spoken
        // string here is: the runner has no renderer, so a sentence built inside a `body` is a sentence
        // nothing can check. The numbers are the mockup's own — a fifteen-minute session against a 9–26
        // minute band — so the literals are figures a reader can hold beside the reference.
        assertTest(
            ActivityDetailView.comparisonBasis(sessionCount: 0)
                == "No comparison: not enough previous sessions of this activity yet.",
            "With no window the card says so in a whole sentence rather than leaving the badges off and "
                + "nothing beside them — a reader who sees no comparison should be told why "
                + "(\(ActivityDetailView.comparisonBasis(sessionCount: 0)))")
        assertTest(
            ActivityDetailView.comparisonBasis(sessionCount: 1)
                == "Compared with your last 1 session of this activity.",
            "…and one prior session takes the singular, which is a string a plural-only form gets wrong "
                + "on exactly the state a user reaches first (\(ActivityDetailView.comparisonBasis(sessionCount: 1)))")
        assertTest(
            ActivityDetailView.comparisonBasis(sessionCount: 10)
                == "Compared with your last 10 sessions of this activity.",
            "…and the count printed is the **window's**, which is what makes the two badges above it a "
                + "comparison against a stated population rather than against an unstated number — the "
                + "user's own answer to how the basis should be shown "
                + "(\(ActivityDetailView.comparisonBasis(sessionCount: 10)))")

        assertTest(
            ActivityDetailView.typicalDurationCaption(low: 540, high: 1560) == "Typical: 9-26 min",
            "The band's caption prints **whole minutes**, not a clock shape: two `m:ss` durations side "
                + "by side invite the eye to compare digits, and this is a span of a scale rather than a "
                + "reading (\(ActivityDetailView.typicalDurationCaption(low: 540, high: 1560)))")
        assertTest(
            ActivityDetailView.spokenDuration(durationText: "0:15:58", low: 540, high: 1560)
                == "Duration 0:15:58. Typical for this activity is 9 to 26 minutes.",
            "…and the card's spoken form says the session's own length first and the band second, so the "
                + "reading and the comparison are not read as one figure "
                + "(\(ActivityDetailView.spokenDuration(durationText: "0:15:58", low: 540, high: 1560)))")

        // Composed from the two ends' own formatted strings rather than pinned to `"Aug 10 2:17 PM to
        // 2:32 PM"`: the suite runs in whatever zone the machine is in, and a literal here would be a
        // test that passes only in one of them — §11's and §12's rule, on a string instead of a count.
        let subtitleStart = ActivityDetailTests.anchor
        let subtitleEnd = ActivityDetailTests.anchor.addingTimeInterval(958)
        let subtitle = ActivityDetailView.subtitle(startedAt: subtitleStart, endedAt: subtitleEnd)
        assertTest(
            subtitle == "\(subtitleStart.formattedShortDate()) \(subtitleStart.formattedHourMinute()) "
                + "to \(subtitleEnd.formattedHourMinute())",
            "The header's one line is the app's existing short date and its existing clock form at both "
                + "ends, joined by ` to ` — so this page introduces no fourth date format "
                + "(\(subtitle))")
        assertTest(
            subtitle.contains(" to ") && subtitle.hasPrefix(subtitleStart.formattedShortDate())
                && subtitle.hasSuffix(subtitleEnd.formattedHourMinute()),
            "…and it is composed rather than a bare date: the two ends are distinguishable in it, which "
                + "is what a one-ended form would lose (\(subtitle))")
    }
}
