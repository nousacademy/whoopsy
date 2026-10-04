import Foundation
import SwiftUI
import Whoopsy

enum FastingRecoveryChartTests {
    static func run() async throws {
        // MARK: - A fast's own layout

        // Everything a fast's page decides is a value here, because the runner has no renderer:
        // `ActivityFigure.isFast` chooses between the two arrangements, `FastingRecovery` chooses which
        // nights, and `FastingRecoveryChartSeries` chooses the axis and the sentence. **What is left in
        // the `body` is the arrangement itself and nothing else** — which is the shape this whole section
        // exists in, and the reason the plan's "only the arrangement is left in `body`" is a claim these
        // blocks can hold it to.

        // MARK: - The gate

        let namedFast = ActivityDetailTests.fast(from: ActivityDetailTests.day(0, hour: 21), to: ActivityDetailTests.day(3, hour: 11))
        assertTest(
            ActivityFigure.isFast(namedFast),
            "A session that measured no strain and is named `Fast` draws the fasting layout — the two "
                + "guards `fastingZone` and `fastingEndText` have each carried since §20, now written "
                + "once and read from one place")

        assertTest(
            !ActivityFigure.isFast(ActivityDetailTests.session("Fast", startOffset: 0, durationSeconds: 3600, strain: 7.4)),
            "…and **a `Fast` that carries a measured strain is not one**. The gate is the data and never "
                + "the name — `headlineText`'s rule — which is what keeps a hand-recorded fast that has a "
                + "sensor reading on the ordinary layout, and keeps this page and Home agreeing about it")

        assertTest(
            !ActivityFigure.isFast(ActivityDetailTests.session("Walking", startOffset: 0, durationSeconds: 3600)),
            "…and a measured session of any other name is not one either")

        assertTest(
            ActivityFigure.isFast(ActivityDetailTests.session("  FAST  ", startOffset: 0, durationSeconds: 3600, strain: nil)),
            "…and the name is compared through `ActivityName.normalised`, so the edit picker's own "
                + "spelling and a stray space reach the same answer")

        // The pair that fails if the extraction drifts back into copies. §20 pins these two rules on a
        // `Fast` with no strain; what is added here is that all three now answer **the same question**,
        // including on the strained `Fast` that only the gate's first guard refuses.
        assertTest(
            ActivityFigure.fastingZone(for: namedFast, on: ActivityDetailTests.day(0, hour: 23)) != nil
                && ActivityFigure.fastingEndText(
                    for: namedFast, on: ActivityDetailTests.day(0, hour: 23), now: ActivityDetailTests.day(9)) != nil,
            "…and the two rules extracted onto it answer for the same session, so the page's layout, "
                + "Home's zone pill and Home's end clock hold one definition of which rows are fasts")

        let strainedFast = ActivityDetailTests.session("Fast", startOffset: 0, durationSeconds: 3600, strain: 7.4)
        assertTest(
            !ActivityFigure.isFast(strainedFast)
                && ActivityFigure.fastingZone(for: strainedFast, on: ActivityDetailTests.anchor) == nil
                && ActivityFigure.fastingEndText(for: strainedFast, on: ActivityDetailTests.anchor, now: ActivityDetailTests.day(9)) == nil,
            "…and all three refuse the same strained `Fast` — a fourth copy of the two guards is exactly "
                + "what this extraction exists to prevent")

        // The **name half on its own**, which is what the picker dispatches on: it has a `String?` the user
        // just chose and no session yet to hold a strain, so the data gate cannot be asked. Driven over the
        // same four names the gate above is driven over, so the extraction and its source cannot come to
        // different answers about any of them — the whole risk of splitting one function in two.
        assertTest(
            ActivityFigure.isFastName(WhoopActivityCatalog.fastingName)
                && ActivityFigure.isFastName("  FAST  ")
                && !ActivityFigure.isFastName("Walking")
                && !ActivityFigure.isFastName(nil),
            "The name half answers `true` for the fasting name and for the edit picker's own spelling of "
                + "it, and `false` for another activity and for no name at all — so the picker routes `Fast` "
                + "to `startFast()` and everything else, including *nothing chosen*, to `start(name:)`")

        assertTest(
            ActivityFigure.isFastName("Fast") == ActivityFigure.isFast(namedFast)
                && ActivityFigure.isFastName(strainedFast.activityName)
                    != ActivityFigure.isFast(strainedFast),
            "…and it is deliberately **not** `isFast`: on a `Fast` that carries a measured strain the two "
                + "disagree, and that disagreement is the whole reason the halves are separable. The picker "
                + "asks about a name, the layout asks about a row, and a strained `Fast` is a fast to the "
                + "first and an ordinary session to the second")

        assertTest(
            [nil, "", "activity", "Activity", "Walking", "Fasting", "F"].allSatisfy {
                !ActivityFigure.isFastName($0)
            },
            "…and no near-miss reaches it: no name at all, the empty string, WHOOP's own abstention word "
                + "in both spellings, another activity, and a one-letter prefix — a comparison that reached "
                + "for `hasPrefix` or `contains` instead of equality would start a fast on the last of those "
                + "and pass every assertion above it")

        // MARK: - Which nights the fast covered

        assertTest(
            FastingRecovery.encloses(ActivityDetailTests.day(1), in: namedFast)
                && FastingRecovery.encloses(ActivityDetailTests.day(2), in: namedFast)
                && FastingRecovery.encloses(ActivityDetailTests.day(3), in: namedFast),
            "A fast 21:00 D → 11:00 D+3 covers D+1, D+2 and D+3 — the three mornings it was running "
                + "through the end of, which is the 86-hour fast's own answer on the bundled files")

        assertTest(
            !FastingRecovery.encloses(ActivityDetailTests.day(0), in: namedFast),
            "…and **not D**. D's own morning reading came from a night that ended fifteen hours before "
                + "the fast began, so crediting it would put a pre-fast reading into the fast's own mean "
                + "— which is exactly what `covers(_:)` does, and this is the assertion that fails if "
                + "anyone reaches for it because the two look like the same question")

        assertTest(
            !FastingRecovery.encloses(ActivityDetailTests.day(4), in: namedFast),
            "…and not the morning after it ended either, so the rule is bounded at both ends")

        // The two day boundaries, which is where an off-by-one in either comparison shows up.
        let midnightFast = ActivityDetailTests.fast(from: ActivityDetailTests.day(0, hour: 20), to: ActivityDetailTests.day(2))
        assertTest(
            FastingRecovery.encloses(ActivityDetailTests.day(2), in: midnightFast)
                && !FastingRecovery.encloses(ActivityDetailTests.day(0), in: midnightFast),
            "A fast ending at exactly midnight covers the night that ended that morning. The fast ran "
                + "to that day's first instant, so an exclusive comparison would drop the last night of "
                + "every fast that ended on the hour — the same `>=` / `<=` half-open convention "
                + "`fastingEndText` carries for a fast ending at `00:00:00`")

        let smallHoursFast = ActivityDetailTests.fast(from: ActivityDetailTests.day(1, hour: 2), to: ActivityDetailTests.day(1, hour: 9))
        assertTest(
            !FastingRecovery.encloses(ActivityDetailTests.day(1), in: smallHoursFast)
                && !FastingRecovery.encloses(ActivityDetailTests.day(2), in: smallHoursFast),
            "…and a fast starting in the small hours of D and ending later the same day covers "
                + "**nothing**, though it ran through D's morning. A `RecoveryMetric` stores a snapped "
                + "day key and no wake instant, so the app cannot tell whether D's reading was taken "
                + "before or after 02:00 — and where a day key cannot distinguish, an absence is the "
                + "honest answer rather than a guess that credits the fast with a night it may not have "
                + "covered")

        // MARK: - The nights a fast's page draws

        // The window is built so every literal below is hand-checkable rather than read back off the code
        // under test: three values `a−d, a, a+d` have a **sample** standard deviation of exactly `d`, so
        // the z-scores are ±1 and 0. The spreads also clear
        // `BaselineStatisticsMath.minimumCoefficientOfVariation` — 10 against HRV's floor of 3.5, 10
        // against RHR's 3, 3 against RR's 0.75 — which is the trap `CLAUDE.md` records: a window of
        // 58/60/62 has the *floor* as its denominator and every literal downstream moves.
        let fastingHistory = [
            ActivityDetailTests.night(-5, score: 50, hrv: 60, rhr: 50, rr: 12),
            ActivityDetailTests.night(-4, score: 50, hrv: 70, rhr: 60, rr: 15),
            ActivityDetailTests.night(-3, score: 50, hrv: 80, rhr: 70, rr: 18),
            ActivityDetailTests.night(1, score: 40, hrv: 60, rhr: 70, rr: 18),
            ActivityDetailTests.night(2, score: 60, hrv: 70, rhr: 50, rr: 12),
            ActivityDetailTests.night(3, score: 80, hrv: 80, rhr: 60, rr: 15),
        ]
        let fastingSummary = FastingRecovery.summary(for: namedFast, history: fastingHistory)

        assertTest(
            fastingSummary?.nights.count == 3,
            "The fast covers exactly its three mornings — the window's own days and the fast's start "
                + "day are not among them (\(ActivityDetailTests.shown(fastingSummary?.nights.count)))")

        assertTest(
            fastingSummary?.baselineObservationCount == 3,
            "…and the baseline window is the three measured days before the fast started, so the "
                + "comparison is against a stated reference and not against the fast's own nights "
                + "(\(ActivityDetailTests.shown(fastingSummary?.baselineObservationCount)) days)")

        assertTest(
            fastingSummary?.meanScore == 60 && fastingSummary?.scoredNightCount == 3,
            "The score is the **mean of the nights' own stored scores** — 40, 60 and 80 — carried "
                + "beside the count it was taken across, so the figure and the badge under it cannot "
                + "describe two different populations (\(ActivityDetailTests.shown(fastingSummary?.meanScore)) over "
                + "\(ActivityDetailTests.shown(fastingSummary?.scoredNightCount)))")

        let firstFastNight = fastingSummary?.nights.first
        let secondFastNight = fastingSummary?.nights.dropFirst().first
        let lastFastNight = fastingSummary?.nights.last

        assertTest(
            firstFastNight?.hrvZScore.map { ActivityDetailTests.near($0, -1) } == true
                && secondFastNight?.hrvZScore.map { ActivityDetailTests.near($0, 0) } == true
                && lastFastNight?.hrvZScore.map { ActivityDetailTests.near($0, 1) } == true,
            "The HRV z-scores are against a baseline of 70 ms with a spread of 10, so 60/70/80 read "
                + "−1, 0 and +1 — pinned from the window's own arithmetic rather than from a second "
                + "implementation of it")

        assertTest(
            firstFastNight?.restingHeartRateZScore.map { ActivityDetailTests.near($0, 1) } == true
                && secondFastNight?.restingHeartRateZScore.map { ActivityDetailTests.near($0, -1) } == true
                && lastFastNight?.restingHeartRateZScore.map { ActivityDetailTests.near($0, 0) } == true,
            "…and resting heart rate, against its own baseline of 60 with a spread of 10, moves the "
                + "**opposite way on the same nights** — 70/50/60 read +1, −1 and 0 — which is what "
                + "makes one shared axis meaningful rather than decorative")

        assertTest(
            firstFastNight?.respiratoryRateZScore.map { ActivityDetailTests.near($0, 1) } == true
                && secondFastNight?.respiratoryRateZScore.map { ActivityDetailTests.near($0, -1) } == true
                && lastFastNight?.respiratoryRateZScore.map { ActivityDetailTests.near($0, 0) } == true,
            "…and respiratory rate, against 15 with a spread of 3, reads +1, −1 and 0 — the third "
                + "quantity drawn on the same one ruler")

        assertTest(
            lastFastNight?.rawText(for: .hrv) == "80.0 ms"
                && lastFastNight?.rawText(for: .restingHeartRate) == "60 bpm"
                && lastFastNight?.rawText(for: .respiratoryRate) == "15.0 rpm",
            "…and each bar's real magnitude reaches a reader through `rawText`, since a z-score is "
                + "dimensionless and a chart of σ alone would never say a night's HRV was 80 ms "
                + "(\(lastFastNight?.rawText(for: .hrv) ?? "nil"))")

        // The mean's key absence rule, asserted in **both** directions: a placeholder night is not a
        // night, and a fast whose only covered row is one has no score rather than a score of zero.
        let partlyMeasured = FastingRecovery.summary(
            for: namedFast,
            history: [
                ActivityDetailTests.night(1, score: 44, hrv: 60, rhr: 70),
                // `hasMeasurement` is `hrvValueMs > 0`, so this is the row a build before the
                // no-placeholder change would have written: a reserved score beside no reading.
                ActivityDetailTests.night(2, score: 0, hrv: 0, rhr: 0),
                ActivityDetailTests.night(3, score: 90, hrv: 80, rhr: 60),
            ])
        assertTest(
            partlyMeasured?.meanScore == 67 && partlyMeasured?.scoredNightCount == 2
                && partlyMeasured?.nights.count == 2,
            "…and **a placeholder night is not a night**: 44 and 90 average to 67 over two, where "
                + "counting the unmeasured middle row in would print a yellow 45 over three — the trap "
                + "`CLAUDE.md` records for the Home ring (\(ActivityDetailTests.shown(partlyMeasured?.meanScore)) over "
                + "\(ActivityDetailTests.shown(partlyMeasured?.scoredNightCount)))")

        assertTest(
            FastingRecovery.summary(
                for: namedFast, history: [ActivityDetailTests.night(2, score: 0, hrv: 0, rhr: 0)]) == nil,
            "…and a fast whose only covered row is a placeholder has **no score**, not a score of zero: "
                + "`nil` is this app's whole vocabulary for *nothing was measured*, and a `0` here would "
                + "draw a hard red 0% over a night nothing recorded")

        // A mean is not a score the formula produced, so which tier 66.5 lands on is a decision rather
        // than arithmetic. Both fixtures are chosen so a **truncating** mean gives a different *tier*,
        // not merely a different digit — which is what makes them discriminating rather than cosmetic.
        let roundsUpGreen = FastingRecovery.summary(
            for: namedFast,
            history: [ActivityDetailTests.night(1, score: 66, hrv: 70, rhr: 60), ActivityDetailTests.night(2, score: 67, hrv: 70, rhr: 60)])
        assertTest(
            roundsUpGreen?.meanScore == 67
                && roundsUpGreen?.meanScore.map { RecoveryMetric.RecoveryState(score: $0) == .green }
                    == true,
            "A mean of 66.5 rounds to 67 and is therefore **green**, where `Int(mean)` would print a "
                + "yellow 66 — the rounding happens before the tiering, so the figure and the colour "
                + "beside it can never disagree about which side of a boundary the nights were on "
                + "(\(ActivityDetailTests.shown(roundsUpGreen?.meanScore)))")

        let roundsUpYellow = FastingRecovery.summary(
            for: namedFast,
            history: [ActivityDetailTests.night(1, score: 33, hrv: 70, rhr: 60), ActivityDetailTests.night(2, score: 34, hrv: 70, rhr: 60)])
        assertTest(
            roundsUpYellow?.meanScore == 34
                && roundsUpYellow?.meanScore.map { RecoveryMetric.RecoveryState(score: $0) == .yellow }
                    == true,
            "…and the same at the other boundary: 33.5 rounds to 34, which is **yellow** where a "
                + "truncating mean prints 33 and calls the same two nights red "
                + "(\(ActivityDetailTests.shown(roundsUpYellow?.meanScore)))")

        // MARK: - Two HRV quantities never share a baseline

        // The window is built so the pooled answer and the correct one differ in **sign** and not merely
        // in digits: the SDNN days sit *above* the newest night, so pooling drags the mean over it and a
        // +1σ night reads −0.5σ. A defect that is only visible as a moved decimal is one a chart can
        // absorb without looking wrong.
        let mixedHistory = [
            ActivityDetailTests.night(-6, score: 50, hrv: 110, rhr: 40, metric: .sdnn),
            ActivityDetailTests.night(-5, score: 50, hrv: 120, rhr: 40, metric: .sdnn),
            ActivityDetailTests.night(-4, score: 50, hrv: 130, rhr: 40, metric: .sdnn),
            ActivityDetailTests.night(-3, score: 50, hrv: 60, rhr: 60, metric: .rmssd),
            ActivityDetailTests.night(-2, score: 50, hrv: 70, rhr: 60, metric: .rmssd),
            ActivityDetailTests.night(-1, score: 50, hrv: 80, rhr: 60, metric: .rmssd),
            ActivityDetailTests.night(2, score: 50, hrv: 95, rhr: 60, metric: .sdnn),
            ActivityDetailTests.night(3, score: 50, hrv: 80, rhr: 60, metric: .rmssd),
        ]
        // Named for what it is rather than `mixedSummary`: §19's `ActivityBaseline` block above already
        // holds that name, and a redeclaration here would be a compile error rather than a wrong answer.
        let mixedHRVSummary = FastingRecovery.summary(for: namedFast, history: mixedHistory)
        let sdnnNight = mixedHRVSummary?.nights.first
        let rmssdNight = mixedHRVSummary?.nights.last

        assertTest(
            mixedHRVSummary?.nights.count == 2 && mixedHRVSummary?.hrvMetric == .rmssd,
            "The newest covered night is RMSSD, so that is the quantity in force — "
                + "`MetricWeek.hrvBaselineMetric`'s rule, and the one thing that makes the pooled "
                + "z-score meaningful (\(ActivityDetailTests.shown(mixedHRVSummary?.hrvMetric)))")

        assertTest(
            sdnnNight.map { $0.hrvMetric == .sdnn && $0.hrvZScore == nil } == true,
            "…and **the nights are narrowed too, not only the window**. An SDNN night has no reading on "
                + "the RMSSD scale every other bar of the chart is drawn against, so it draws no HRV bar "
                + "— the same answer an absent reading gives, which is why the chart needs no third state")

        assertTest(
            rmssdNight.map { $0.hrvZScore.map { ActivityDetailTests.near($0, 1) } == true } == true,
            "…and the RMSSD night's z is against the **RMSSD days alone** — 60/70/80, mean 70, σ 10, so "
                + "80 reads +1. Pooling the three SDNN days in would give a mean of 95 and read this "
                + "night as −0.52, a below-baseline night drawn as an above-baseline one "
                + "(\(ActivityDetailTests.shown(rmssdNight?.hrvZScore)))")

        assertTest(
            rmssdNight.map { $0.restingHeartRateZScore.map { ActivityDetailTests.near($0, 0.9129) } == true } == true,
            "…and **resting heart rate is not narrowed**, because it is the same measurement whichever "
                + "variability figure was recorded. Its window is the whole six days — 40/40/40/60/60/60, "
                + "mean 50, σ 10.95 — so a night at 60 reads 0.91; narrowed to the RMSSD days it would "
                + "be a flat 60/60/60 and read 0.0, which is the pooling defect in this type's other "
                + "direction (\(ActivityDetailTests.shown(rmssdNight?.restingHeartRateZScore)))")

        // MARK: - The respiratory rate's count gate

        // RR is the one of the three with **no cold-start pair anywhere in this app** — `HRVMetric` has
        // one and `RecoveryScoring` has RHR's, but RR has neither — so an ungated
        // `BaselineStatisticsMath.baseline` call would fall back to a mean of 0 with a spread of 1 and
        // pin every bar to the clamp. The gate is the count, and the reading stays on the night so the
        // chart can tell *nothing to compare it against* from *nothing was measured*.
        let thinRRSummary = FastingRecovery.summary(
            for: namedFast,
            history: [
                ActivityDetailTests.night(-5, score: 50, hrv: 60, rhr: 50),
                ActivityDetailTests.night(-4, score: 50, hrv: 70, rhr: 60),
                ActivityDetailTests.night(-3, score: 50, hrv: 80, rhr: 70),
                ActivityDetailTests.night(1, score: 60, hrv: 70, rhr: 60, rr: 15),
            ])
        let thinRRNight = thinRRSummary?.nights.first
        assertTest(
            thinRRNight.map { $0.respiratoryRate == 15 && $0.respiratoryRateZScore == nil } == true,
            "Two respiratory readings in the window is below the three-day floor, so the **bar is "
                + "withheld while the reading stays**. `nil` there means *nothing to compare it "
                + "against*, which is a different sentence from *nothing was measured*, and the two "
                + "draw differently")

        assertTest(
            thinRRNight.map { $0.rawText(for: .respiratoryRate) == "15.0 rpm" } == true,
            "…and the raw figure still reaches a reader through `rawText`, so a withheld bar costs the "
                + "chart a mark and not the night its measurement "
                + "(\(thinRRNight?.rawText(for: .respiratoryRate) ?? "nil"))")

        // MARK: - The clamp, reached through `BaselineStatisticsMath.zScore`

        // `RecoveryMetric.restingHeartRate` is a non-optional `Int` carrying a reserved `0` on a row
        // written before the no-placeholder change, and the night gate is `hasMeasurement` — which reads
        // **HRV**, not the rate — so a `0` is reachable in the data this block is handed. The clamp to
        // ±4 lives only inside `zScore`, and an inline division is the way it gets lost.
        let reservedRate = FastingRecovery.summary(
            for: namedFast,
            history: [
                ActivityDetailTests.night(-5, score: 50, hrv: 60, rhr: 50),
                ActivityDetailTests.night(-4, score: 50, hrv: 70, rhr: 60),
                ActivityDetailTests.night(-3, score: 50, hrv: 80, rhr: 70),
                ActivityDetailTests.night(1, score: 60, hrv: 70, rhr: 0),
            ])
        let reservedRateNight = reservedRate?.nights.first
        assertTest(
            reservedRateNight.map { $0.restingHeartRateZScore.map { ActivityDetailTests.near($0, -4) } == true } == true,
            "A reserved `0` bpm against a baseline of 60 with a spread of 10 is six σ below it, and it "
                + "reads **−4** because the clamp inside `BaselineStatisticsMath.zScore` is the only "
                + "thing that puts a bound on it. An inline `(0 − 60) / 10` would draw a bar six σ long "
                + "off a four-σ axis — a mark outside its own frame, which is a claim nothing measured "
                + "(\(ActivityDetailTests.shown(reservedRateNight?.restingHeartRateZScore)))")

        // MARK: - The σ axis

        assertTest(
            FastingRecoveryAxis.standard.upperBound == 4
                && FastingRecoveryAxis.standard.gridLines == [1, 2, 3],
            "The scale runs from the baseline up to **4σ**, ruled at 1, 2 and 3, for every fast this "
                + "app will ever draw. A z-score is already dimensionless, so +2σ is the same height on "
                + "one user's chart as on another's — the whole property normalising buys, and the one a "
                + "fitted axis would destroy while looking more careful. `4` is "
                + "`BaselineStatisticsMath.maximumAbsoluteZScore`, the top of the ladder every input has "
                + "already been clamped to (\(FastingRecoveryAxis.standard.upperBound.formattedOneDecimal()), "
                + "ruled at \(FastingRecoveryAxis.standard.gridLines))")

        assertTest(
            FastingRecoveryAxis.standard.fraction(FastingRecoveryAxis.baselineLine) == 0,
            "…and **the baseline is the frame's foot**, because nothing is drawn below it: a quantity "
                + "that fell contributes no length, so a lower half would be half a frame reserved for a "
                + "mark that is never drawn — and it is why this axis holds one bound and not two")

        let wideAxis = FastingRecoveryAxis.fit([6])
        assertTest(
            wideAxis.upperBound == 6,
            "…and a 6σ column widens it to `0...6`, in whole σ: the axis is fitted to the **stacked** "
                + "excursion, which is a sum of up to three clamped readings and therefore reaches past "
                + "the range one z-score can occupy (\(wideAxis.upperBound.formattedOneDecimal()))")

        assertTest(
            wideAxis.gridLines == [1, 2, 3, 4, 5],
            "…and its lines are **derived from the bound** rather than listed, so a widened axis is "
                + "ruled at its own width instead of carrying the standard scale's three into a frame "
                + "that no longer means the same thing by them (\(wideAxis.gridLines))")

        assertTest(
            FastingRecoveryAxis.fit([3.5]) == .standard,
            "…and a night **inside** the standard range leaves the scale alone rather than fitting to "
                + "the reading, so two fasts of ordinary nights are measured against one ruler "
                + "(\(FastingRecoveryAxis.fit([3.5]).upperBound.formattedOneDecimal()))")

        assertTest(
            !FastingRecoveryAxis.standard.gridLines.contains(FastingRecoveryAxis.baselineLine)
                && FastingRecoveryAxis.standard.gridLines.allSatisfy { $0 > 0 },
            "…and `0` is **not among the gridlines**. The chart strokes `0` itself as the labelled rule "
                + "every column stands on, so a scale that also listed it would draw that line twice "
                + "(\(FastingRecoveryAxis.standard.gridLines))")

        assertTest(
            FastingRecoveryAxis.fit([]) == .standard
                && FastingRecoveryAxis.fit([.nan]) == .standard
                && FastingRecoveryAxis.fit([-3, -1]) == .standard,
            "…and a chart with nothing to plot — or nothing that **rose** — falls back to the standard "
                + "scale rather than to an infinite one. The guard is on finiteness and on sign "
                + "together, because every comparison against a `NaN` is false and a fall is not a height")

        // The margin is a scale, and these are the two rules that make it read as one. It carries a label
        // per line rather than two at the frame's corners: the corners name `±4σ`, the pair a reader has no
        // use for, while the lines between them — what a bar is actually read against — went unlabelled.
        assertTest(
            FastingRecoveryAxis.standard.gridLines.map(FastingRecoveryChartView.tickLabel)
                == ["+1σ", "+2σ", "+3σ"]
                && FastingRecoveryChartView.tickLabel(1.5) == "+1.5σ",
            "**Every gridline's value prints**, so the right margin is a run a reader can count down "
                + "rather than two numbers at the frame's corners "
                + "(\((FastingRecoveryAxis.standard.gridLines.map(FastingRecoveryChartView.tickLabel))))")

        assertTest(
            FastingRecoveryChartView.tickLabel(FastingRecoveryAxis.baselineLine) == "0",
            "…and the baseline's own tick is a bare `0` with **no sign and no glyph**, because neither "
                + "`+0σ` nor `−0σ` is true of a line that is neither above the mean nor below it — and "
                + "because at the foot of a scale the bare figure is what a reader expects to find there "
                + "(\(FastingRecoveryChartView.tickLabel(FastingRecoveryAxis.baselineLine)))")

        // **The property that makes the column a scale is even spacing, and it is the one a clamp
        // breaks.** The tempting clamp is at the floor: the frame's bottom edge *is* the baseline, so the
        // `0` label centres on the bar area's last pixel and hangs half its own height into the date
        // strip. Nudging it up to sit inside the frame moves that one label and leaves the other three,
        // which is exactly what this catches — a scale whose figures drift off the lines they name is
        // worse than one whose last figure overhangs, and nothing is overlapped either way, since the
        // date strip is `plotWidth` wide and this column is outside it.
        let labelYs = (FastingRecoveryAxis.standard.gridLines + [FastingRecoveryAxis.baselineLine])
            .map { FastingRecoveryChartView.axisLabelY(value: $0, axis: .standard) }
            .sorted()
        let labelSteps = zip(labelYs, labelYs.dropFirst()).map { $1 - $0 }
        assertTest(
            labelSteps.count == 3 && labelSteps.allSatisfy { abs($0 - labelSteps[0]) < 0.0001 }
                && FastingRecoveryChartView.axisLabelY(
                    value: FastingRecoveryAxis.baselineLine, axis: .standard)
                    == FastingRecoveryChartView.barAreaHeight,
            "…and the four labels are **evenly spaced** from the floor to the top of the frame, so the "
                + "margin reads as one scale rather than as four numbers — a clamp on the lowest one, the "
                + "obvious way to hold it inside the bar area, is precisely what breaks that "
                + "(steps \(labelSteps.map { Double($0) }))")

        // **The date strip has to be as tall as the label it holds, and it was not.** The label is a
        // `VStack` of a `10` pt weekday over an `11` pt day number — two line boxes, `12` and `14` — and it
        // is centred in the strip, so a strip shorter than `26` spills it out of *both* ends at once: the
        // weekday's ascenders pushed up **through** the baseline rule the columns stand on, the day number
        // down into the legend. The strip was `18`, which is the state the screenshots caught — the days
        // sitting on the rule rather than under it — and nothing in this repo could see it, because the
        // overflow is a `body`'s arrangement and the runner has no renderer. So the strip is derived from
        // its two line boxes rather than picked, and the placement is asserted as a containment.
        let dateLabelTop = FastingRecoveryChartView.dateLabelCentreY
            - FastingRecoveryChartView.dateLabelTextHeight / 2
        let dateLabelBottom = FastingRecoveryChartView.dateLabelCentreY
            + FastingRecoveryChartView.dateLabelTextHeight / 2
        assertTest(
            FastingRecoveryChartView.dateLabelTextHeight >= 12 + 14
                && dateLabelTop >= FastingRecoveryChartView.dateStripInset - 0.0001,
            "**The date label starts below the baseline rule**, by the strip's own inset — a two-line label "
                + "in a strip sized for one line is drawn *on* the rule the columns stand on, which is what "
                + "`18` against `26` did (top \(Double(dateLabelTop)), text height "
                + "\(Double(FastingRecoveryChartView.dateLabelTextHeight)))")

        assertTest(
            dateLabelBottom <= FastingRecoveryChartView.dateLabelHeight + 0.0001
                && FastingRecoveryChartView.dateLabelHeight
                    == FastingRecoveryChartView.dateStripInset
                        + FastingRecoveryChartView.dateLabelTextHeight,
            "…and the day number under it finishes **inside the strip**, so the label is contained at both "
                + "ends rather than centred in a box too short for it — the strip being the inset plus the "
                + "text and nothing else (bottom \(Double(dateLabelBottom)), strip "
                + "\(Double(FastingRecoveryChartView.dateLabelHeight)))")

        // The margin's spacing is a scale too, and a unit step stops being one on the charts the merged
        // column produces. A stacked night can reach `3 × maximumAbsoluteZScore`, so a bound of 12 is
        // reachable and a unit step would rule eleven lines down a 132-point column — one every eleven
        // points, which is a grey block rather than a scale. The step doubles where the lines stop fitting,
        // and the guard is a **count** rather than a bound: keyed to the bound it would fire at 5, where a
        // unit step draws four comfortable lines.
        assertTest(
            FastingRecoveryAxis.fit([5]).gridLines == [1, 2, 3, 4]
                && FastingRecoveryAxis.fit([12]).gridLines == [2, 4, 6, 8, 10]
                && FastingRecoveryAxis.fit([12]).gridLines.count < 11,
            "**The margin's step coarsens where the lines stop fitting**, so a widened axis stays a scale "
                + "rather than becoming a grey block: a bound of 5 is still ruled at every σ, and the "
                + "`3 × 4σ` bound a three-segment column can reach doubles the step to two and draws five "
                + "lines where a unit step would draw eleven "
                + "(\(FastingRecoveryAxis.fit([12]).gridLines))")

        // MARK: - The merged column

        // Declared here rather than beside the sentence below, because the chart's own value is what both
        // blocks read: the columns, the axis, the legend's entries and the sentence all come off this one
        // series, which is the property that keeps a picture and its caption from describing two different
        // sets of nights.
        let fastingSeries = fastingSummary.flatMap { FastingRecoveryChartSeries(summary: $0) }

        // The chart drew three bars side by side per night until the user asked for one merged column —
        // *"how about a merged chart for all 3, the lower one goes the less it shows on the bar"* — and
        // then for two changes on top of that: *"make the bars 3 shades of blue, and if they go negative
        // just shrink it essentially"*. Merging changes three things the grouped chart got for free. A
        // column's extent is now a **sum** rather than a single value, so the axis has to be fitted to
        // that sum or the picture is measured against a ruler too short for it. A segment's length is still
        // its own excursion, so a quantity that barely moved really does show less of the bar. And the
        // order the segments stack in has to come from somewhere, because three pieces inside one column
        // cannot be told apart by position the way three bars side by side could. Each of those is a block
        // below.

        assertTest(
            FastingRecoveryChartSeries.Point.stackTotal(
                of: [.hrv: 1, .restingHeartRate: 1, .respiratoryRate: -2]) == 2
                && FastingRecoveryChartSeries.Point.stackTotal(
                    of: [.hrv: -1, .restingHeartRate: -1, .respiratoryRate: -2]) == 0,
            "A column's extent is the **sum of the excursions that rose**, so the two quantities that "
                + "went up add and the one that went down is not netted off against them — netting would "
                + "draw a night that moved two ways as a night that barely moved — and a night on which "
                + "**everything fell** has no extent at all "
                + "(\(FastingRecoveryChartSeries.Point.stackTotal(of: [.hrv: 1, .restingHeartRate: 1, .respiratoryRate: -2]))), "
                + "and \(FastingRecoveryChartSeries.Point.stackTotal(of: [.hrv: -1, .restingHeartRate: -1, .respiratoryRate: -2])) for a night that only fell)")

        assertTest(
            FastingRecoveryChartSeries.Point.stackTotal(
                of: [.hrv: Double.infinity, .restingHeartRate: 2]) == 2
                && FastingRecoveryChartSeries.Point.stackTotal(
                    of: [.hrv: -Double.infinity, .restingHeartRate: -2]) == 0
                && FastingRecoveryChartSeries.Point.stackTotal(of: [.hrv: .nan]) == 0,
            "…and a non-finite z is **dropped rather than summed**. Every comparison against a `NaN` is "
                + "false, so it would take the column's whole extent with it — and the axis fitted to "
                + "that column, and therefore every other column drawn on that axis, with it")

        // **The axis is fitted to the columns and not to the z-scores inside them**, and this is the
        // assertion the merge turns on. Three quantities at +3σ, +4σ and +3σ stack into a column reaching
        // +10σ; an axis fitted to the individual z-scores tops out at 4 and draws that stack two and a
        // half frames tall. The fixture's literals are hand-checkable the way this section's baselines
        // are: 60/70/80 has a sample spread of exactly 10, so 100 is +3σ, and the resting-rate window
        // 50/60/70 doubles as the clamp's edge — 100 is +4σ, reached exactly.
        let stackedSummary = FastingRecovery.summary(
            for: namedFast,
            history: [
                ActivityDetailTests.night(-5, score: 50, hrv: 60, rhr: 50, rr: 12),
                ActivityDetailTests.night(-4, score: 50, hrv: 70, rhr: 60, rr: 15),
                ActivityDetailTests.night(-3, score: 50, hrv: 80, rhr: 70, rr: 18),
                ActivityDetailTests.night(1, score: 40, hrv: 100, rhr: 100, rr: 24),
            ])
        let stackedSeries = stackedSummary.flatMap { FastingRecoveryChartSeries(summary: $0) }
        let stackedPoint = stackedSeries?.points.first

        assertTest(
            stackedPoint?.zScores[.hrv].map { ActivityDetailTests.near($0, 3) } == true
                && stackedPoint?.zScores[.restingHeartRate].map { ActivityDetailTests.near($0, 4) } == true
                && stackedPoint?.zScores[.respiratoryRate].map { ActivityDetailTests.near($0, 3) } == true,
            "…on a night that really does reach those three, measured through the pipeline rather than "
                + "handed in: +3σ HRV, +4σ resting rate and +3σ respiratory rate "
                + "(\(ActivityDetailTests.shown(stackedPoint?.zScores[.hrv])), "
                + "\(ActivityDetailTests.shown(stackedPoint?.zScores[.restingHeartRate])), "
                + "\(ActivityDetailTests.shown(stackedPoint?.zScores[.respiratoryRate])))")

        assertTest(
            stackedSeries?.axis.upperBound == 10,
            "**The scale is fitted to the columns and not to the σ inside them.** Those three excursions "
                + "stack to +10σ, so the axis has to reach 10 — `fit([3, 4, 3])` gives 4 and draws the "
                + "column off the top of the frame, which is a picture measured against a ruler too short "
                + "for it (\(ActivityDetailTests.shown(stackedSeries?.axis.upperBound)))")

        let stackedAxis = stackedSeries?.axis ?? .standard
        let stackedHeight = FastingRecoveryChartView.segments(
            for: stackedPoint ?? ActivityDetailTests.point([:]), metrics: stackedSeries?.metrics ?? [], axis: stackedAxis
        ).map(\.height).reduce(0, +)

        assertTest(
            ActivityDetailTests.near(Double(stackedHeight),
                 Double(FastingRecoveryChartView.segmentHeight(zScore: 10, axis: stackedAxis))),
            "…and the segments of one column therefore **sum to the height of a single segment at their "
                + "total** — the identity that makes a stack equal to its own extent, and the one a fit "
                + "taken from the individual z-scores breaks: under the standard `0...4` those same three "
                + "sum to 330 points above the floor where the whole frame is 132 "
                + "(\(Double(stackedHeight)) against "
                + "\(Double(FastingRecoveryChartView.segmentHeight(zScore: 10, axis: stackedAxis))))")

        assertTest(
            FastingRecoveryChartView.segmentHeight(zScore: -2, axis: .standard) == 0
                && FastingRecoveryChartView.segmentHeight(zScore: 0, axis: .standard) == 0
                && FastingRecoveryChartView.segmentHeight(zScore: 2, axis: .standard)
                    < FastingRecoveryChartView.segmentHeight(zScore: 3, axis: .standard),
            "**A fall shrinks the bar rather than dipping below the rule.** A reading at or under its "
                + "baseline has no length on this drawing — the column simply shows less of that quantity "
                + "— and the height grows only as a reading rises, since a column that grew as one fell "
                + "would say the opposite of what the chart is for "
                + "(\(Double(FastingRecoveryChartView.segmentHeight(zScore: -2, axis: .standard))) for −2σ, "
                + "\(Double(FastingRecoveryChartView.segmentHeight(zScore: 3, axis: .standard))) for +3σ)")

        /// How far each column's stack reaches up from the floor, in points.
        func columnHeights(
            _ points: [FastingRecoveryChartSeries.Point], _ axis: FastingRecoveryAxis
        ) -> [CGFloat] {
            points.map { point in
                FastingRecoveryChartView.segments(
                    for: point, metrics: FastingMetric.allCases, axis: axis
                ).map(\.height).reduce(0, +)
            }
        }

        let heights = columnHeights(fastingSeries?.points ?? [], fastingSeries?.axis ?? .standard)
            + columnHeights(stackedSeries?.points ?? [], stackedAxis)

        assertTest(
            !heights.isEmpty
                && heights.allSatisfy { $0 >= 0 && $0 <= FastingRecoveryChartView.barAreaHeight + 0.0001 },
            "…and **every column fits inside the bar area** — the standard three-night fixture and the "
                + "widened one alike. The frame's top edge *is* the axis's top bound, so a stack reaching "
                + "past it would be a segment drawn outside the scale it is read against "
                + "(\(heights.map { Double($0) }))")

        // The stacking order is not decoration. Three bars side by side could be told apart by position
        // alone; three segments inside one column cannot, so a reader has the colours and the legend and
        // nothing else. The rule that makes the reading mechanical is that the **first quantity listed
        // that rose** is the one stacked furthest from the rule — so a column reads bottom-to-top against
        // the legend's own order.
        let firstNightPoint = fastingSeries?.points.first
        let firstNightSegments = firstNightPoint.map {
            FastingRecoveryChartView.segments(
                for: $0, metrics: fastingSeries?.metrics ?? [], axis: fastingSeries?.axis ?? .standard)
        } ?? []

        assertTest(
            firstNightSegments.map(\.metric) == [.restingHeartRate, .respiratoryRate],
            "The segments come back in the **legend's own order** whatever order they are stacked in, so "
                + "a caller — the drawing, or a block here — can read them positionally against the "
                + "legend's entries; and on this night, whose HRV fell a σ, there are **two of them and "
                + "not three**: the quantity that fell is not a short segment, it is no segment "
                + "(\(firstNightSegments.map(\.metric)))")

        assertTest(
            firstNightSegments.map(\.isTopmost) == [true, false]
                && ActivityDetailTests.near(Double(firstNightSegments.first?.offsetFromFloor ?? -1),
                        Double(FastingRecoveryChartView.segmentHeight(zScore: 1, axis: .standard)))
                && ActivityDetailTests.near(Double(firstNightSegments.last?.offsetFromFloor ?? -1), 0)
                && firstNightSegments.filter(\.isTopmost).count == 1,
            "…and on a night of −1σ HRV, +1σ resting rate and +1σ respiratory rate the first that rose "
                + "takes the far end: the resting rate sits a segment's length up from the floor with the "
                + "respiratory rate between it and the baseline. **Exactly one segment is rounded** — the "
                + "top of the stack — which is what makes a column read as one bar divided rather than as "
                + "a run of chips (\(firstNightSegments.map { Double($0.offsetFromFloor) }))")

        // A quantity sitting on the baseline, one that fell, and one with no reading are the same picture
        // and the chart must not manufacture a stub for any of them: "your HRV held at baseline" is a real
        // answer, and a minimum segment height would draw it as a small move as well as drawing a missing
        // reading as one. All three contribute nothing, and a night with none rising contributes no
        // column.
        let partialSegments = FastingRecoveryChartView.segments(
            for: ActivityDetailTests.point([.hrv: 0, .restingHeartRate: -2, .respiratoryRate: .nan]),
            metrics: FastingMetric.allCases,
            axis: .standard)

        assertTest(
            partialSegments.isEmpty
                && FastingRecoveryChartView.segments(
                    for: ActivityDetailTests.point([:]), metrics: FastingMetric.allCases, axis: .standard).isEmpty,
            "A quantity **exactly on the baseline**, one that fell, a non-finite one and a missing one "
                + "all draw no segment, and a night with none rising draws no column at all. There is no "
                + "minimum segment height, deliberately: a floor would state a reading the night did not "
                + "take, and on a scale whose whole subject is the distance from a mean, a quantity that "
                + "did not move has no distance to draw (\(partialSegments.map(\.metric)))")

        // The colours are the app's own three tokens, and this block is what keeps a fourth palette from
        // arriving by hand. This chart has had three: the reference screen's borrowed swatches, which the
        // user rejected as making *"no sense"*, then the app's three verdict accents, and now three shades
        // of one blue. Both halves of the assertion are decisions rather than restatements — three
        // distinct values, and a ramp that is **not** the verdict scale, since a z-score is a distance from
        // the user's own mean and an HRV that fell is not a red night.
        let metricColors = FastingMetric.allCases.map(\.color)

        assertTest(
            Set(metricColors).count == 3
                && Set(metricColors) == Set([
                    Theme.fastingChartHRV, Theme.fastingChartRestingHeartRate,
                    Theme.fastingChartRespiratoryRate,
                ])
                && Set(metricColors).isDisjoint(
                    with: [Theme.recoveryGreen, Theme.recoveryYellow, Theme.recoveryRed]),
            "The three segment fills are `Theme`'s fasting-chart ramp — **three shades of one blue** — "
                + "and they are three distinct values that are **none of them a verdict colour**: a chart "
                + "whose two segments shared a colour would draw a column nothing can decompose, and a "
                + "ramp that reused the recovery accents would put that scale on a chart whose subject is "
                + "a distance from a mean (\(metricColors.count) fills, \(Set(metricColors).count) distinct)")

        // MARK: - The sentence under the chart

        // Composed from the same z-scores the bars are drawn from, so it cannot describe a different set
        // of nights than the picture above it — the reference's `Normalized Trends` reads as a summary of
        // the drawing, and a sentence written independently would be free to disagree with it the first
        // time either moved.
        assertTest(
            fastingSeries?.points.count == 3
                && fastingSeries?.metrics == [.hrv, .restingHeartRate, .respiratoryRate],
            "Three nights draw three columns and the legend carries all three quantities, in "
                + "`FastingMetric.allCases` order "
                + "(\(fastingSeries?.points.count.description ?? "nil"))")

        assertTest(
            fastingSeries?.sentence == "HRV climbed above your baseline, resting heart rate held at "
                + "your baseline and respiratory rate held at your baseline.",
            "With three nights the sentence compares the **last column against the first** per quantity, "
                + "and the verbs are `climbed` / `held` / `fell` — a move, because two or more columns "
                + "have a direction where one does not (\(fastingSeries?.sentence ?? "nil"))")

        assertTest(
            fastingSeries?.spokenSentence.hasPrefix("3 nights, ") == true
                && fastingSeries?.spokenSentence.hasSuffix(fastingSeries?.sentence ?? "") == true,
            "…and the spoken form names the span and the count before handing over to the same "
                + "sentence, so VoiceOver hears the two things the columns encode structurally and then "
                + "the directions (\(fastingSeries?.spokenSentence ?? "nil"))")

        // One night states a position, and the vocabularies are different words rather than the same
        // word on a shorter chart: a single reading has nothing to have moved from.
        let singleNightSummary = FastingRecovery.summary(
            for: namedFast,
            history: [
                ActivityDetailTests.night(-5, score: 50, hrv: 60, rhr: 70, rr: 18),
                ActivityDetailTests.night(-4, score: 50, hrv: 70, rhr: 60, rr: 15),
                ActivityDetailTests.night(-3, score: 50, hrv: 80, rhr: 50, rr: 12),
                ActivityDetailTests.night(1, score: 60, hrv: 60, rhr: 70, rr: 18),
            ])
        let singleNightSeries = singleNightSummary.flatMap { FastingRecoveryChartSeries(summary: $0) }
        assertTest(
            singleNightSeries?.points.count == 1
                && singleNightSeries?.sentence == "HRV finished below your baseline, resting heart rate "
                    + "finished above your baseline and respiratory rate finished above your baseline.",
            "…and with **one** night every clause changes to `finished` — `climbed` / `fell` would claim "
                + "a direction from a single reading, which is a trend this arithmetic never looked at. "
                + "The three positions are the same either way, which is what keeps the two vocabularies "
                + "a change of verb rather than a change of rule "
                + "(\(singleNightSeries?.sentence ?? "nil"))")

        assertTest(
            FastingRecoveryChartSeries.Position(zScore: 0.5) == .at
                && FastingRecoveryChartSeries.Position(zScore: -0.5) == .at
                && FastingRecoveryChartSeries.Position(zScore: 0.50001) == .above
                && FastingRecoveryChartSeries.Position(zScore: nil) == nil,
            "The threshold is a **strict** half a σ, so a night sitting exactly on it reads `held at` — "
                + "the honest word for a bar that short, since below half a σ a move and a night's own "
                + "noise are the same picture on this chart. A `nil` z is not a position at all")

        // MARK: - The two absence states, which are different sentences

        // `nil` from `summary` means the fast covered no measured night. `nil` from the **series** means
        // it covered nights the baseline was too thin to compare. Telling a user with four nights of
        // readings that there were none would be a lie about their own data, so the page says two
        // different things and this block is what keeps them apart.
        let thinBaseline = FastingRecovery.summary(
            for: namedFast,
            history: [
                ActivityDetailTests.night(-2, score: 50, hrv: 60, rhr: 60),
                ActivityDetailTests.night(-1, score: 50, hrv: 70, rhr: 60),
                ActivityDetailTests.night(1, score: 60, hrv: 80, rhr: 60),
            ])
        assertTest(
            thinBaseline?.nights.count == 1 && thinBaseline?.baselineObservationCount == 2,
            "Two days of history is below the three-day floor, so the night is covered and the "
                + "comparison is not — the two counts are carried separately for exactly this state "
                + "(\(thinBaseline?.baselineObservationCount.description ?? "nil") days)")

        assertTest(
            thinBaseline.flatMap { FastingRecoveryChartSeries(summary: $0) } == nil,
            "…and a summary in that state yields **no chart**, which is what puts the *not enough "
                + "history* sentence in the chart's slot rather than an empty frame or, worse, a frame "
                + "of bars drawn against a fabricated baseline")

        assertTest(
            FastingRecovery.summary(
                for: ActivityDetailTests.fast(from: ActivityDetailTests.day(0, hour: 21), to: ActivityDetailTests.day(3, hour: 11)),
                history: [ActivityDetailTests.night(-9, score: 50, hrv: 60, rhr: 60)]) == nil,
            "…while a fast that covered no measured night is `nil` from `summary` itself — 152 of the "
                + "bundled 170, which is a fact about two fixture files' date ranges and must not read "
                + "as an error")

        // MARK: - The gate holds the ordinary layout

        let measuredSession = ActivityDetailTests.session(
            "Basketball", startOffset: 0, durationSeconds: 3_600, strain: 12.4, steps: 812)
        assertTest(
            !ActivityFigure.isFast(measuredSession)
                && ActivityFigure.strainText(for: measuredSession) == "12.4"
                && ActivityFigure.headlineText(for: measuredSession) == "12.4",
            "A session that measured a strain keeps the page it had — two stat columns, its own strain "
                + "figure and its steps — and its figure is the strain and not the duration "
                + "(\(ActivityFigure.headlineText(for: measuredSession)))")

        assertTest(
            ActivityDetailViewModel.fastingBadgeText(nightCount: 1) == "OVER 1 NIGHT"
                && ActivityDetailViewModel.fastingBadgeText(nightCount: 4) == "OVER 4 NIGHTS",
            "The badge states the **basis** and not a claim. The reference's `METABOLICALLY IMPROVED` "
                + "needs a glucose or ketone sensor this app does not have — `biodata.json`'s "
                + "`glucose_data` holds zero rows in every file on this machine — so what is left to say "
                + "honestly is what the figure above it was averaged over")

        // MARK: - The stop-fasting line

        // `FastingRecoveryGuidance` is the sentence under the chart, banded **67 / 50** where
        // `RecoveryState` bands the same figure 67 / 34. That divergence is the user's own decision and
        // the first assertion below is where it is recorded rather than left to be discovered: between 34
        // and 50 the figure above the sentence is *yellow* — `fastingScoreColor` reads `RecoveryState` —
        // and the words under it are a stop signal. The paragraph therefore draws in no band colour at
        // all, which is why nothing here asserts a colour.

        assertTest(
            FastingRecoveryGuidance.Band(score: 50) == .stop
                && FastingRecoveryGuidance.Band(score: 51) == .caution
                && FastingRecoveryGuidance.Band(score: 66) == .caution
                && FastingRecoveryGuidance.Band(score: 67) == .steady
                && FastingRecoveryGuidance.Band(score: 100) == .steady
                && FastingRecoveryGuidance.Band(score: 0) == .stop
                && FastingRecoveryGuidance.Band(score: -5) == .stop,
            "The band table's four edges, and the severe band as the fallback for anything below the "
                + "floor — the same shape `RecoveryState.init(score:)` takes when it sends an out-of-band "
                + "value to `.red`. A negative or nonsense score must not land on *nothing to see here* "
                + "(50 → \(FastingRecoveryGuidance.Band(score: 50)), 51 → "
                + "\(FastingRecoveryGuidance.Band(score: 51)), 66 → "
                + "\(FastingRecoveryGuidance.Band(score: 66)), 67 → "
                + "\(FastingRecoveryGuidance.Band(score: 67)))")

        assertTest(
            RecoveryMetric.RecoveryState(score: 45) == .yellow
                && FastingRecoveryGuidance.Band(score: 45) == .stop
                && RecoveryMetric.RecoveryState(score: 50) == .yellow
                && FastingRecoveryGuidance.Band(score: 50) == .stop,
            "**The second band table, recorded rather than hidden**: a 45% fast draws a yellow figure "
                + "above and a `Stop signal.` under it, because a fast is itself a stressor and the reading "
                + "that means *maintain* on an ordinary day does not mean it on day four of not eating. The "
                + "colour is `RecoveryState`'s and the words are this type's — the alternative, a 45% fast "
                + "green on Home and yellow here, would be the worse fault")

        assertTest(
            RecoveryMetric.RecoveryState(score: 67) == .green
                && FastingRecoveryGuidance.Band(score: 67) == .steady
                && RecoveryMetric.RecoveryState(score: 33) == .red
                && FastingRecoveryGuidance.Band(score: 33) == .stop,
            "…and the two tables agree at both ends they are meant to share, so the divergence is one "
                + "deliberate band in the middle and not a second scale that drifted everywhere: at 67 both "
                + "say the fast can carry on, at 33 both say it cannot")

        // The fast's own state, which is what decides the sentence's tense. **Half-open at both ends**:
        // a fast that has just begun is running, one that ended at exactly `now` is not.
        let runningFast = ActivityDetailTests.fast(from: ActivityDetailTests.day(0, hour: 21), to: ActivityDetailTests.day(3, hour: 11))
        assertTest(
            ActivityFigure.isInProgress(runningFast, now: ActivityDetailTests.day(0, hour: 21))
                && ActivityFigure.isInProgress(runningFast, now: ActivityDetailTests.day(1))
                && ActivityFigure.isInProgress(runningFast, now: ActivityDetailTests.day(3, hour: 10))
                && !ActivityFigure.isInProgress(runningFast, now: ActivityDetailTests.day(0, hour: 20))
                && !ActivityFigure.isInProgress(runningFast, now: ActivityDetailTests.day(3, hour: 11))
                && !ActivityFigure.isInProgress(runningFast, now: ActivityDetailTests.day(4)),
            "`startedAt <= now` and `now < endedAt`, so the two instants on the fast's own boundary are "
                + "decided the way `WorkoutSession.covers(_:)` decides them: running at the moment it "
                + "starts, and **not** running at the moment it ends — the same half-open convention "
                + "`fastingEndText`'s `11:59 PM` arm rests on")

        assertTest(
            ActivityFigure.fastingEndText(for: runningFast, on: ActivityDetailTests.day(1), now: ActivityDetailTests.day(1)) == "ACTIVE"
                && ActivityFigure.fastingEndText(for: runningFast, on: ActivityDetailTests.day(1), now: ActivityDetailTests.day(4)) == "11:59 PM"
                && ActivityFigure.fastingEndText(for: runningFast, on: ActivityDetailTests.day(3), now: ActivityDetailTests.day(4)) == nil,
            "…and the extraction that made it a function is behaviour-preserving across all three of the "
                + "rule's arms: the day the fast is running on prints `ACTIVE`, a day it ran *through* "
                + "prints that day's own last minute once the fast has stopped, and only the day it really "
                + "ended on falls through to `nil` — the caller's instruction to print the session's own "
                + "end clock")



        assertTest(
            FastingRecoveryGuidance.nightPhrase(nightCount: 1, isInProgress: false) == "this night"
                && FastingRecoveryGuidance.nightPhrase(nightCount: 1, isInProgress: true) == "the night so far"
                && FastingRecoveryGuidance.nightPhrase(nightCount: 4, isInProgress: false) == "these 4 nights"
                && FastingRecoveryGuidance.nightPhrase(nightCount: 4, isInProgress: true) == "the 4 nights so far",
            "`1 nights` is the reason the noun phrase is a function, and the two arms differ by more than "
                + "the numeral: a running fast says *the night so far* because it may have more, a finished "
                + "one says *this night* because it will not "
                + "(\(FastingRecoveryGuidance.nightPhrase(nightCount: 1, isInProgress: false)))")

        let guidanceBodies = [
            FastingRecoveryGuidance.sentence(band: .steady, score: 40, nightCount: 4, isInProgress: false),
            FastingRecoveryGuidance.sentence(band: .steady, score: 40, nightCount: 4, isInProgress: true),
            FastingRecoveryGuidance.sentence(band: .caution, score: 40, nightCount: 4, isInProgress: false),
            FastingRecoveryGuidance.sentence(band: .caution, score: 40, nightCount: 4, isInProgress: true),
            FastingRecoveryGuidance.sentence(band: .stop, score: 40, nightCount: 4, isInProgress: false),
            FastingRecoveryGuidance.sentence(band: .stop, score: 40, nightCount: 4, isInProgress: true),
        ]
        let causalWords = ["cost", "caused", "because", "due to", "led to", "as a result"]
        assertTest(
            guidanceBodies.allSatisfy { $0.contains("40%") }
                && guidanceBodies.allSatisfy { body in
                    !causalWords.contains { body.lowercased().contains($0) }
                },
            "All six arms name the user's own figure and **none of them claims the fast produced it**. This "
                + "app has no glucose and no ketone sensor, so *the fast cost you recovery* would be the "
                + "same fabrication the z-score sentence above is forbidden — what the line may say is what "
                + "the measured nights showed, and the action it names is a response to that reading rather "
                + "than a diagnosis of it. (Forbidden: \(causalWords.joined(separator: ", ")))")

        assertTest(
            FastingRecoveryGuidance.sentence(band: .stop, score: 28, nightCount: 4, isInProgress: true)
                == "Your recovery has averaged 28% over the 4 nights so far. This is the signal to end the fast."
                && FastingRecoveryGuidance.sentence(band: .stop, score: 28, nightCount: 4, isInProgress: false)
                    == "Your recovery averaged 28% across these 4 nights — a fast that runs it this low is "
                        + "one to end earlier.",
            "**The arm that carries the whole feature, and the one that has to change with the fast's "
                + "state.** A running fast is told to stop; a fast that already ended cannot be, and every "
                + "fast on a real install has ended — all 170 bundled ones have — so the instruction is "
                + "turned to the *next* fast rather than dropped, because *end the fast* printed under a "
                + "fast that stopped three days ago is advice the reader cannot take")

        assertTest(
            FastingRecoveryGuidance.sentence(band: .steady, score: 74, nightCount: 4, isInProgress: true)
                == "Your recovery is at 74% over the 4 nights so far. Nothing here says to stop."
                && FastingRecoveryGuidance.sentence(band: .caution, score: 60, nightCount: 3, isInProgress: false)
                    == "Your recovery averaged 60% across these 3 nights — worth watching if you fast this "
                        + "long again.",
            "…and the other two bands name their own action rather than the stop one: a holding fast is "
                + "told there is nothing to act on, a slipping one is told to watch the length. A single "
                + "sentence for both would make the middle band redundant, which is why the middle band "
                + "exists at all")

        let steadyStatement = FastingRecoveryGuidance.statement(
            score: 74, nightCount: 4, isInProgress: false)
        assertTest(
            steadyStatement.band == .steady
                && steadyStatement.leadIn == FastingRecoveryGuidance.Band.steady.leadIn
                && steadyStatement.body
                    == FastingRecoveryGuidance.sentence(
                        band: .steady, score: 74, nightCount: 4, isInProgress: false)
                && FastingRecoveryGuidance.statement(score: 45, nightCount: 2, isInProgress: false).band == .stop,
            "`statement(score:…)` chooses the band through `Band(score:)` and builds its body through "
                + "`sentence(band:…)` rather than re-deriving either, so a caller holding a score cannot "
                + "hold half a statement — and the lead-in is forwarded from the band, so the words the "
                + "view draws bold live in exactly one place "
                + "(\(steadyStatement.leadIn) / \(steadyStatement.body))")
    }
}
