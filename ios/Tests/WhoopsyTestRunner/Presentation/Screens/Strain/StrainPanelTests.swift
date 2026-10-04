import Foundation
import Whoopsy

// MARK: - 16. The strain page's panel

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum StrainPanelTests {
    static func run() async throws {
        // MARK: The strain page's panel

        // Re-declared per file rather than threaded from the v13 block: `Calendar.current` is a
        // pure value, so a fresh one here is the same value that block holds. §6.2's rule about
        // not recreating shared things is about accumulating state — a database, a repository,
        // a session — and a calendar has none to lose.
        let calendar = Calendar.current
        let panelDB = LocalDatabaseManager(inMemory: true)
        let panelWorkouts = GRDBWorkoutRepository(db: panelDB)
        let panelStrain = GRDBStrainRepository(db: panelDB)
        let panelSteps = GRDBStepRepository(db: panelDB)
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        func anchorOffset(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
        }

        /// One workout on `day`, starting at `hour` and running `minutes`, carrying `zonePercents`.
        ///
        /// `nil` percents model a session this app recorded itself — the live path writes no zone block,
        /// which is the state the card has to draw a dash for.
        func panelSession(
            day: Date, hour: Int, minutes: Int, zonePercents: [Double]?
        ) -> WorkoutSession {
            let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
            return WorkoutSession(
                id: UUID(),
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(minutes) * 60),
                strain: 5.0,
                averageHeartRate: 120,
                maxHeartRate: 160,
                route: [],
                splits: [],
                source: WhoopExportImporter.sourceLabel,
                hrZonePercents: zonePercents)
        }

        let panelViewModel = await MainActor.run {
            StrainViewModel(
                calculate: CalculateStrainUseCase(
                    biometricRepository: EmptyBiometricStore(),
                    strainRepository: panelStrain,
                    userProfileRepository: GRDBUserProfileRepository(db: panelDB)),
                repository: panelStrain,
                workoutRepository: panelWorkouts,
                stepRepository: panelSteps)
        }

        /// `StrainDetailView.formatDuration`, reproduced here because it is private to the card and the
        /// runner has no renderer — the same reason `SleepEfficiencyCard`'s strings are asserted as
        /// statics rather than through a screenshot.
        let panelDuration: (Double) -> String = { $0.rounded().formattedCompactHoursMinutes() }

        do {
            // Three days strictly before the anchor, each with one workout. Their zone time is what the
            // anchor's two rows are read against, and the day the anchor is on is deliberately not in its
            // own baseline: including it would move the 1–3 mean from 1,500 s to 1,635 s, so this is the
            // assertion that fails if `baselineWindow(before:in:)`'s anchor is ever dropped.
            //
            // The middle day's block is all zeroes on purpose. It is a measured workout that never reached
            // zone 1 — 45 rows of the bundled export are exactly that — and it must contribute a real
            // `0` to the mean rather than dropping out of the window as an absence.
            try await panelWorkouts.save(
                panelSession(day: anchorOffset(-11), hour: 9, minutes: 60,
                    zonePercents: [60, 20, 10, 5, 5]))       // 1–3: 3,240 s   4–5:   360 s
            try await panelWorkouts.save(
                panelSession(day: anchorOffset(-12), hour: 9, minutes: 30,
                    zonePercents: [0, 0, 0, 0, 0]))          // 1–3:     0 s   4–5:     0 s
            try await panelWorkouts.save(
                panelSession(day: anchorOffset(-13), hour: 9, minutes: 30,
                    zonePercents: [50, 10, 10, 20, 10]))     // 1–3: 1,260 s   4–5:   540 s

            // The anchor's own day: **two** workouts, which is the case the day sum exists for.
            try await panelWorkouts.save(
                panelSession(day: anchor, hour: 10, minutes: 30,
                    zonePercents: [50, 20, 10, 5, 0]))       // 1–3: 1,440 s   4–5:    90 s
            try await panelWorkouts.save(
                panelSession(day: anchor, hour: 18, minutes: 20,
                    zonePercents: [25, 25, 0, 25, 25]))      // 1–3:   600 s   4–5:   600 s

            await panelViewModel.load(for: anchor)
            let workouts = await MainActor.run { panelViewModel.workouts }
            let zoneTime = await MainActor.run { panelViewModel.zoneTime }
            let zone1to3Baseline = await MainActor.run { panelViewModel.zone1to3Baseline }
            let zone4to5Baseline = await MainActor.run { panelViewModel.zone4to5Baseline }

            assertTest(
                workouts.count == 2,
                "The day's two workouts both read back, earliest first — the array, not an optional, "
                    + "because several sessions on one day is normal (got \(workouts.count))")
            assertTest(
                zoneTime?.zone1to3Seconds == 2_040 && zoneTime?.zone4to5Seconds == 690,
                "…and the panel's two rows are the day's **sum** over them: 1,440 + 600 = 2,040 s in "
                    + "zones 1–3 and 90 + 600 = 690 s in 4–5. A reader that took only the first session "
                    + "would print 1,440 and 90 (got \(zoneTime?.zone1to3Seconds ?? -1) and "
                    + "\(zoneTime?.zone4to5Seconds ?? -1))")
            assertTest(
                panelDuration(zoneTime?.zone1to3Seconds ?? 0) == "0:34"
                    && panelDuration(zoneTime?.zone4to5Seconds ?? 0) == "0:11",
                "…drawn as `0:34` and `0:11` — the two rows' figures through the card's own formatter, "
                    + "which rounds to the minute before printing: the figure is WHOOP's percentage of a "
                    + "span, so its resolution is minutes at best")
            assertTest(
                zone1to3Baseline == 1_500 && zone4to5Baseline == 300,
                "…against the window's mean over the three days before it — 1,500 s and 300 s, not the "
                    + "1,635 s that including the anchor's own two workouts would produce. The all-zero "
                    + "day is inside that mean as a real 0, which is what keeps a day of no zone 1–3 time "
                    + "in the window rather than out of it (got \(zone1to3Baseline ?? -1) and "
                    + "\(zone4to5Baseline ?? -1))")

            let panelMarker = MetricChange.between(
                current: zoneTime?.zone1to3Seconds, previous: zone1to3Baseline,
                higherIsBetter: true, formatted: panelDuration)
            assertTest(
                panelMarker?.verdict == .better && panelMarker?.direction == .up,
                "A day above its baseline draws the better verdict and an up marker — more zone time is "
                    + "the good direction, which is what `higherIsBetter` is passed for rather than left "
                    + "to the view")
            assertTest(
                panelMarker?.previousText == panelDuration(1_500),
                "…and the marker's second column is the baseline's own digits through the card's one "
                    + "formatter, so the figure compared and the figure printed are one string")

            // **The duration formatter's rounding is why the comparison is made on it.** 1,504 s and
            // 1,500 s are four seconds apart and both print `0:25`; a row drawing `0:25` over `0:25` with
            // an up arrow beside it is a row contradicting itself, so the verdict is `.same` and the
            // glyph is the neutral one. This is the case a raw-seconds comparison gets wrong.
            let roundedMarker = MetricChange.between(
                current: 1_504, previous: 1_500, higherIsBetter: true, formatted: panelDuration)
            assertTest(
                roundedMarker?.verdict == .same && roundedMarker?.direction == nil
                    && roundedMarker?.previousText == "0:25",
                "Two figures that print alike are the same as far as the screen is concerned: 1,504 s "
                    + "against 1,500 s is `.same` with no direction, because `MetricChange` compares the "
                    + "**formatted** pair and both read `0:25`")

            // A day whose only workout is one this app recorded itself — the shape of every session the
            // live path writes. It carries no zone block, so both rows draw a dash while the card itself is
            // still drawn, because the day does hold a workout. That is the user's rule: fill a row from
            // the CSV where the field exists and dash it where it does not.
            //
            // It is put on a day that *has* a baseline, deliberately. Withholding the second column here is
            // the card's own `zoneTime != nil` guard doing it and not a missing mean, and the two are
            // indistinguishable from a dash alone — the thin day below is the case where the mean is
            // genuinely absent, and asserting both pins which half withholds what.
            let noBlock = anchorOffset(-1)
            try await panelWorkouts.save(
                panelSession(day: noBlock, hour: 9, minutes: 30, zonePercents: nil))
            await panelViewModel.load(for: noBlock)
            let noBlockZoneTime = await MainActor.run { panelViewModel.zoneTime }
            let noBlockWorkouts = await MainActor.run { panelViewModel.workouts }
            let noBlockBaseline = await MainActor.run { panelViewModel.zone1to3Baseline }
            assertTest(
                noBlockWorkouts.count == 1 && noBlockZoneTime == nil,
                "A day the app recorded itself holds a workout and no zone time — the live path writes no "
                    + "percentages, so there is nothing for the two rows to read")
            assertTest(
                noBlockBaseline == 1_500,
                "…while the view model still computes a mean for it, 1,500 s over the three days inside "
                    + "its own 30-day window — so the card's second column is withheld by `zone1to3Baseline`'s "
                    + "own `zoneTime != nil` guard and not by a missing baseline. Asserting the pair pins "
                    + "which half withholds what, which a dash on its own cannot: this day has a workout and "
                    + "a baseline and draws two dashes, and the thin day below has a figure and no baseline")

            // Two days of zone data behind it: below `minimumBaselineDays`, so the mean is withheld while
            // the day's own figure stands. The day's own workout is saved with them — without it the day
            // would be empty and the assertion below would pass for the wrong reason, which is the shape
            // the step fixture this replaced had.
            let thin = anchorOffset(-20)
            try await panelWorkouts.save(
                panelSession(day: thin, hour: 9, minutes: 30, zonePercents: [40, 20, 10, 20, 10]))
            for offset in [-21, -22] {
                try await panelWorkouts.save(
                    panelSession(day: anchorOffset(offset), hour: 9, minutes: 30,
                        zonePercents: [50, 10, 10, 20, 10]))
            }
            await panelViewModel.load(for: thin)
            let thinZoneTime = await MainActor.run { panelViewModel.zoneTime }
            let thinBaseline = await MainActor.run { panelViewModel.zone1to3Baseline }
            assertTest(
                thinZoneTime != nil && thinBaseline == nil,
                "A day with two days of zone data behind it shows its own figure and withholds the mean — "
                    + "`minimumBaselineDays` is three, and a mean of two printed as 'your average' would "
                    + "present a pair of workouts as a baseline")

            // A day with no workout at all: the card is **absent**, not four dashes. This is the gate the
            // user set — no workout, no panel — and it is the one assertion here that stands in for a
            // screenshot the runner cannot take.
            let restDay = anchorOffset(-6)
            await panelViewModel.load(for: restDay)
            let restWorkouts = await MainActor.run { panelViewModel.workouts }
            assertTest(
                restWorkouts.isEmpty,
                "A day with no workout reads back an empty array, which is what hides the card: the four "
                    + "rows describe a workout, so a day without one has nothing for them to say")

            // A measured `0:00` is drawn as `0:00` and is **not** the same as an absent block — the pair
            // the bundled file's 45 all-zero rows depend on.
            await panelViewModel.load(for: anchorOffset(-12))
            let zeroZoneTime = await MainActor.run { panelViewModel.zoneTime }
            assertTest(
                zeroZoneTime != nil && zeroZoneTime?.zone1to3Seconds == 0
                    && panelDuration(zeroZoneTime?.zone1to3Seconds ?? 0) == "0:00",
                "A workout that never reached zone 1 is a real `0:00` rather than a dash: the day's zone "
                    + "block exists and reads zero, which is a different answer from no block at all")
            assertTest(
                WorkoutZoneTime.aggregate([panelSession(day: restDay, hour: 9, minutes: 30, zonePercents: nil)]) == nil,
                "…and the aggregate is `nil` when none of the day's workouts carries a block, in either "
                    + "direction: a sum over an empty set would produce the `0:00` that means *measured "
                    + "and never in zone 1* where the truth is *unmeasured*")

            assertTest(
                MetricChange.between(
                    current: nil, previous: 1_500, higherIsBetter: true,
                    formatted: panelDuration) == nil
                    && MetricChange.between(
                        current: 2_040, previous: nil, higherIsBetter: true,
                        formatted: panelDuration) == nil,
                "A row with a missing side draws no marker at all, in either direction: `MetricChange`'s "
                    + "`nil` is reserved for a missing side, which is what keeps a dashed row from "
                    + "carrying a comparison of nothing — and it is why the card's one unproduced row, "
                    + "`STRENGTH ACTIVITY TIME`, is a literal at the call site with no marker to draw")

            // MARK: The card's STEPS row
            //
            // The fourth row is the one figure on this card **this app measured itself** — the two zone
            // rows above it are WHOOP's own numbers out of a CSV, and `STRENGTH ACTIVITY TIME` has no
            // producer at all. It reads `stepCounts`, the strap's accelerometer, through
            // `StrainViewModel.steps`/`.stepsBaseline`.
            //
            // **Nothing here is evidence about a strap.** No database on this machine holds a
            // `stepCounts` row and the export carries no steps, so these rows are written by the test —
            // they prove the read, the gate and the window, and nothing about whether a strap answers.
            // The reference's `5,049` over `5,169` is unreachable without one.
            //
            // `StrainDetailView.format` is private and locale-dependent in its grouping separator, so it
            // is reproduced here as a closure and **never asserted against a string literal** — only ever
            // compared with itself, which is exactly what `MetricChange` does with it. Asserting
            // `"8,431"` would be a test that fails on a device whose locale groups with a space.
            let panelCount: (Double) -> String = { $0.formatted(.number.grouping(.automatic)) }

            // Three measured days behind everything below, well clear of the workout days so the window
            // each assertion reads is the one stated in its message.
            for (offset, count) in [(-42, 8_000), (-41, 7_000), (-40, 6_000)] {
                try await panelSteps.saveStepCount(
                    StepCount(
                        date: anchorOffset(offset), stepCount: count, measuredSeconds: 3_600))
            }
            // The anchor's neighbour: a measured day of walking.
            try await panelSteps.saveStepCount(
                StepCount(date: anchorOffset(-1), stepCount: 8_431, measuredSeconds: 5_400))
            // A **measured** day of no walking — worn, and unwalked. A real `0`, not a dash.
            try await panelSteps.saveStepCount(
                StepCount(date: anchorOffset(-3), stepCount: 0, measuredSeconds: 3_600))
            // A row holding no measured span, which no writer produces but the entity documents as
            // constructible and its readers are expected to refuse. It carries a large count on purpose:
            // a reader that went through the row rather than through `hasMeasurement` would pull 9,999
            // into the mean below and print 6,199 where the answer is 5,250.
            try await panelSteps.saveStepCount(
                StepCount(date: anchorOffset(-2), stepCount: 9_999, measuredSeconds: 0))

            await panelViewModel.load(for: anchorOffset(-1))
            let stepsDay = await MainActor.run { panelViewModel.steps }
            let stepsBaseline = await MainActor.run { panelViewModel.stepsBaseline }
            assertTest(
                stepsDay == 8_431,
                "The STEPS row's figure is the day's stored count — read back through the repository, "
                    + "which is the whole path this app has for it (got "
                    + "\(stepsDay.map(String.init) ?? "nil"))")
            assertTest(
                stepsBaseline == 5_250,
                "…and its second column is the window's mean over the four measured days before it: "
                    + "8,000, 7,000, 6,000 and the **measured zero**, which is 21,000 ÷ 4 = 5,250. Both "
                    + "halves of that are load-bearing: the zero is inside the mean as a real reading "
                    + "rather than dropped as an absence, and the unmeasured row *inside the same "
                    + "window* contributes nothing — counting its 9,999 would print 6,199, which is a "
                    + "figure assembled out of a span nothing measured "
                    + "(got \(stepsBaseline.map(String.init) ?? "nil"))")

            // The marker, which is the assertion that `higherIsBetter: true` is the direction this row is
            // read in — more steps is the good way round, and the reference draws its own below-average
            // day with a down marker.
            assertTest(
                MetricChange.between(
                    current: Double(8_431), previous: Double(5_250),
                    higherIsBetter: true, formatted: panelCount)?.verdict == .better
                    && MetricChange.between(
                        current: 0, previous: Double(7_000),
                        higherIsBetter: true, formatted: panelCount)?.verdict == .worse,
                "A day above its step average draws the better verdict and one below draws worse — "
                    + "including the measured `0`, which is compared as a figure rather than left with "
                    + "no marker at all, which is what a missing side gets")

            // The measured zero, which is the case the whole `measuredSeconds` field exists for — and the
            // window's lower edge, since exactly three measured days behind it is a mean.
            await panelViewModel.load(for: anchorOffset(-3))
            let zeroSteps = await MainActor.run { panelViewModel.steps }
            let zeroStepsBaseline = await MainActor.run { panelViewModel.stepsBaseline }
            assertTest(
                zeroSteps == 0 && zeroStepsBaseline == 7_000,
                "A measured day of no walking reaches the row as a real `0`, read against a mean of "
                    + "21,000 ÷ 3 = 7,000 — which is `minimumBaselineDays` exactly, so the floor is "
                    + "crossed here and not one day later. It is the counterpart of every other absence "
                    + "rule in this app: the strap was worn and the user did not walk, which is a "
                    + "different answer from a strap that was on the charger (got "
                    + "\(zeroSteps.map(String.init) ?? "nil") and "
                    + "\(zeroStepsBaseline.map(String.init) ?? "nil"))")

            // An unmeasured row, beside a window that does hold a mean. Asserting the pair pins which
            // half withholds what, which a dash on its own cannot — the same shape as the zone block's
            // no-block day above.
            await panelViewModel.load(for: anchorOffset(-2))
            let unmeasuredSteps = await MainActor.run { panelViewModel.steps }
            let unmeasuredBaseline = await MainActor.run { panelViewModel.stepsBaseline }
            assertTest(
                unmeasuredSteps == nil && unmeasuredBaseline == 5_250,
                "A row with no measured span draws a dash even though it holds a count, and the mean "
                    + "beside it is still computed — so the card's second column is withheld by "
                    + "`stepsBaseline`'s own `viewModel.steps != nil` guard and not by a missing baseline "
                    + "(got \(unmeasuredSteps.map(String.init) ?? "nil") and "
                    + "\(unmeasuredBaseline.map(String.init) ?? "nil"))")

            // A day with no row at all, which is the strap path's ordinary absence — a day it was not
            // worn writes nothing rather than writing a zero.
            await panelViewModel.load(for: anchorOffset(-4))
            let absentSteps = await MainActor.run { panelViewModel.steps }
            assertTest(
                absentSteps == nil,
                "…and a day with no `stepCounts` row at all draws the same dash from the other side: "
                    + "`getStepCount` answers `nil` rather than a reserved-zero row, which is the absence "
                    + "shape every metric in this app now shares (got "
                    + "\(absentSteps.map(String.init) ?? "nil"))")

            // The floor's other edge. Three measured days is a mean — asserted just above on the measured
            // zero's own day — and one day is not.
            await panelViewModel.load(for: anchorOffset(-41))
            let thinSteps = await MainActor.run { panelViewModel.steps }
            let thinStepsBaseline = await MainActor.run { panelViewModel.stepsBaseline }
            assertTest(
                thinSteps == 7_000 && thinStepsBaseline == nil,
                "A day with a single measured day behind it shows its own figure and withholds the mean: "
                    + "`minimumBaselineDays` is three, and one day printed as 'your average' would "
                    + "present a single day's walking as a baseline (got "
                    + "\(thinSteps.map(String.init) ?? "nil") and "
                    + "\(thinStepsBaseline.map(String.init) ?? "nil"))")
        } catch {
            assertTest(false, "The panel's reads threw: \(error)")
        }
    }
}
