import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The tiers, the month grid, and Home's own days

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeRingsAndCalendarTests {
    static func run() async throws {
        // Re-declared per file rather than threaded: `Calendar.current` is a pure value,
        // so a fresh one here is the same value the section's other files hold.
        let calendar = Calendar.current

        // ---- The recovery tier boundaries, which are what colour the Home ring ----
        //
        // Green 67–100, yellow 34–66, red 0–33, per `docs/ALGORITHMS.md` §"Recovery Tiers". Pinned here
        // because an off-by-one at 66/67 is invisible on screen — the two colours are adjacent either
        // way — and because the ring, the Recovery tab's gauge, its HRV card and its trend chart all
        // read these boundaries through `RecoveryMetric.state`.

        for (score, expected) in [(100, "Green"), (67, "Green"), (66, "Yellow"), (34, "Yellow"),
                                  (33, "Red"), (0, "Red")] {
            let metric = RecoveryMetric(score: score, hrvValueMs: 60, restingHeartRate: 55)
            assertTest(
                metric.state.rawValue == expected,
                "\(score)% recovery is \(expected) — a boundary that decides the ring's colour")
        }

        // The pair that keeps a placeholder off the screen as a red ring. `state` says `.red` for the
        // `score: 0` row a day with no strap data stores, so `state` alone cannot be what a view gates
        // on — `hasMeasurement` is, and `HomeDashboardView.recoveryValue` is `nil` for it, which is what
        // draws no fill at all.
        let placeholder = RecoveryMetric(score: 0, hrvValueMs: 0, restingHeartRate: 0)
        assertTest(
            placeholder.state == .red && !placeholder.hasMeasurement,
            "An unmeasured day's placeholder row is `.red` with no measurement — so a view that drew its "
                + "colour would show an unworn night as a hard 0% red recovery")

        // `state` must *be* `RecoveryState(score:)`, not a second switch that agrees today. The coach
        // message path holds a bare score and goes through the initialiser, so a metric whose `state`
        // drifted from it would put "you are primed" on a day the ring draws red.
        for score in [0, 20, 33, 34, 50, 66, 67, 85, 100] {
            let metric = RecoveryMetric(score: score, hrvValueMs: 60, restingHeartRate: 55)
            assertTest(
                metric.state == RecoveryMetric.RecoveryState(score: score),
                "\(score)% agrees between `RecoveryMetric.state` and `RecoveryState(score:)` — one "
                    + "boundary table, read by the ring and by the coach message alike")
        }

        // The mapping itself, which is the one thing a boundary assertion cannot see: a switch whose
        // cases all returned the same token would satisfy every assertion above and paint a 10% day
        // green. Three distinct colours, and each on its own token, is the whole contract.
        assertTest(
            RecoveryMetric.RecoveryState.green.color != RecoveryMetric.RecoveryState.yellow.color
                && RecoveryMetric.RecoveryState.yellow.color != RecoveryMetric.RecoveryState.red.color
                && RecoveryMetric.RecoveryState.green.color != RecoveryMetric.RecoveryState.red.color,
            "The three tiers render as three different colours — not one token behind three cases")
        assertTest(
            RecoveryMetric.RecoveryState.green.color == Theme.recoveryGreen
                && RecoveryMetric.RecoveryState.red.color == Theme.recoveryRed,
            "…each on its own token, so no case can be mis-wired to another tier's colour")

        // ---- The arrow Home's panels and the Recovery breakdown both draw ----
        //
        // `MetricChange` is one definition shared by two screens, so its three decisions have to be pinned
        // here rather than at either use site: whether a comparison is worth drawing at all, which way the
        // glyph points, and what colour that carries. The colour assertions are the "one rule, one
        // definition" guard — a copy of this in a view is what would drift, and the direction-versus-
        // verdict split (up is green for HRV and *worse* for resting heart rate) is the part a copy gets
        // wrong first.
        //
        // The verdict is three states, and the middle one is the reason the colour cannot be derived from
        // the direction: a figure equal to its average has no direction to point, so it draws a dot and
        // carries a colour no arrow ever uses. That case used to be `nil` — "nothing to compare" — which
        // conflated *no measurement* with *no movement*, two different answers the screen must render
        // differently. `nil` is now reserved for a missing side.
        let whole: (Double) -> String = { String(format: "%.0f", $0) }

        // Measured on the simulator: a resting heart rate of 52 against a mean of 52.4 drew a down
        // triangle between two figures both printed as `52`. The digits on screen are the whole of the
        // evidence a reader has, so an arrow between two identical ones is a row contradicting itself —
        // and this is the case a raw `current != previous` comparison lets through.
        let printedAlike = MetricChange.between(
            current: 52, previous: 52.4, higherIsBetter: false, formatted: whole)
        assertTest(
            printedAlike?.verdict == .same && printedAlike?.direction == nil
                && printedAlike?.previousText == "52",
            "A comparison whose two figures print the same is a *dot*, not an arrow — 52 against a mean "
                + "of 52.4 is genuinely below it, but the row would read `52 ▼ 52`")
        assertTest(
            MetricChange.between(current: 52.0, previous: 52.0, higherIsBetter: true, formatted: whole)?
                .verdict == .same,
            "…and two genuinely equal values reach the same verdict by the same gate, which is the rule "
                + "this extends rather than replaces")
        assertTest(
            MetricChange.between(current: 52, previous: 52.4, higherIsBetter: true, formatted: whole)?
                .symbolName == "circle.fill",
            "…and the equal case draws `circle.fill`, so a row that has not moved renders as one "
                + "without a direction glyph that would contradict its own two figures")
        assertTest(
            MetricChange.color(for: .same) == Theme.recoveryYellow
                && MetricChange.color(for: .same) != MetricChange.color(for: .better)
                && MetricChange.color(for: .same) != MetricChange.color(for: .worse),
            "The middle verdict is its own token — a dot sharing the up-arrow's green would report a "
                + "figure sitting on its average as an improvement")

        let rise = MetricChange.between(current: 59, previous: 52, higherIsBetter: true, formatted: whole)
        assertTest(
            rise?.direction == .up && rise?.previousText == "52" && rise?.symbolName
                == "arrowtriangle.up.fill",
            "A rise carries the upward direction and the baseline it beat, formatted by the caller")
        assertTest(
            MetricChange.between(current: 14.9, previous: 15.8, higherIsBetter: true, formatted: {
                String(format: "%.1f", $0)
            })?.direction == .down,
            "…and a fall points down — the direction is literal and never inverted by what is good")

        // The verdict, which is *not* a property of the direction: the same up arrow is green for HRV and
        // red for resting heart rate. Two calls, one differing argument, two colours — a view that read
        // `direction` and picked its own token could not satisfy this pair.
        assertTest(
            MetricChange.between(current: 59, previous: 52, higherIsBetter: true, formatted: whole)?
                .color == Theme.recoveryGreen
                && MetricChange.between(current: 52, previous: 59, higherIsBetter: true, formatted: whole)?
                    .color == Theme.recoveryRed,
            "For a figure where higher is better, a rise is green and a fall is red")
        assertTest(
            MetricChange.between(current: 52, previous: 59, higherIsBetter: false, formatted: whole)?
                .color == Theme.recoveryGreen
                && MetricChange.between(current: 59, previous: 52, higherIsBetter: false, formatted: whole)?
                    .color == Theme.recoveryRed,
            "…and for resting heart rate the same two arrows carry the opposite verdicts, so the colour "
                + "cannot be read off the direction alone")
        assertTest(
            MetricChange.between(current: 59, previous: 52, higherIsBetter: true, formatted: whole)?.direction
                == MetricChange.between(current: 59, previous: 52, higherIsBetter: false, formatted: whole)?
                    .direction,
            "…though both still point the same way, which is what keeps the glyph literal while the "
                + "colour carries the judgement")
        assertTest(
            MetricChange.between(current: 59, previous: nil, higherIsBetter: true, formatted: whole) == nil
                && MetricChange.between(current: nil, previous: 52, higherIsBetter: true, formatted: whole)
                    == nil,
            "A day with no baseline behind it — or no figure of its own — draws nothing at all, which is "
                + "what keeps a cold start from printing a movement against a constant, and what keeps "
                + "`nil` meaning `unmeasured` rather than `unchanged`")

        // ---- The calendar's key, off the same ranges the tiers band on ----
        //
        // A key whose printed boundary disagrees with the initialiser that bands the colours is worse
        // than no key at all: it is a lie about what the colours mean, told in the one place a user goes
        // to learn them. `<34%` and `>66%` are the trap — they read as "the same number", but one is
        // yellow's *lower* bound and the other is yellow's *upper*.
        assertTest(
            RecoveryMetric.RecoveryState(score: RecoveryMetric.RecoveryState.greenRange.lowerBound) == .green
                && RecoveryMetric.RecoveryState(
                    score: RecoveryMetric.RecoveryState.greenRange.lowerBound - 1) == .yellow,
            "The tier initialiser bands on the ranges the key prints: green's floor is green, and one "
                + "below it is yellow")
        assertTest(
            RecoveryMetric.RecoveryState(score: RecoveryMetric.RecoveryState.yellowRange.lowerBound)
                == .yellow
                && RecoveryMetric.RecoveryState(
                    score: RecoveryMetric.RecoveryState.yellowRange.lowerBound - 1) == .red,
            "…and yellow's floor is yellow and one below it red, so neither printed bound can move "
                + "without the initialiser moving with it")

        let legend = RecoveryTierLegend.entries
        assertTest(
            legend.map(\.state) == [.red, .yellow, .green],
            "The key lists all three tiers, one entry each — the three the reference key carries")
        assertTest(
            legend.map(\.text) == ["<34%", "34% - 66%", ">66%"],
            "…and prints exactly the reference key's three labels")
        assertTest(
            legend[0].text == "<\(RecoveryMetric.RecoveryState.yellowRange.lowerBound)%"
                && legend[1].text == "\(RecoveryMetric.RecoveryState.yellowRange.lowerBound)% - "
                    + "\(RecoveryMetric.RecoveryState.greenRange.lowerBound - 1)%"
                && legend[2].text == ">\(RecoveryMetric.RecoveryState.greenRange.lowerBound - 1)%",
            "…read off the ranges rather than typed here, so the labels and the tiers above can only "
                + "move together")

        // ---- TODAY and the forward stop, which are rules about a date rather than about data ----
        //
        // Both live in `DayBarRules` rather than in the bar's body for one reason: the runner has no
        // renderer, so a rule written into a `View` is a rule nothing here can assert. `now` is a
        // parameter for the same reason — an assertion that can only be written against `Date()` is an
        // assertion that says something different tomorrow.
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon)!

        assertTest(
            DayBarRules.label(for: Date()) == "TODAY",
            "The day bar's centre reads TODAY on the day the app opens on")
        assertTest(
            DayBarRules.label(for: calendar.startOfDay(for: Date()), now: noon) == "TODAY",
            "…and TODAY is decided by the calendar day, not by the instant — midnight this morning is "
                + "still today at noon, which a raw `Date` comparison would call a different day")
        assertTest(
            DayBarRules.label(for: yesterday, now: noon) != "TODAY"
                && DayBarRules.label(for: tomorrow, now: noon) != "TODAY",
            "…while neither neighbour is TODAY")
        assertTest(
            DayBarRules.label(for: yesterday, now: noon) != DayBarRules.label(for: tomorrow, now: noon)
                && DayBarRules.label(for: tomorrow, now: noon)
                    == tomorrow.formattedShortDate().uppercased(),
            "…and a day that is not today prints its own date, uppercased — the label the bar showed "
                + "before this change, not a constant")

        assertTest(
            !DayBarRules.canStepForward(from: noon, now: noon),
            "The forward chevron is stopped on today, where there is nothing ahead to show")
        assertTest(
            !DayBarRules.canStepForward(from: tomorrow, now: noon),
            "…and stopped on a day already in the future, which is the input `!isToday` alone gets "
                + "wrong: it reports `true` there and lets the bar walk further forward")
        assertTest(
            DayBarRules.canStepForward(from: yesterday, now: noon),
            "…and it still moves forward from yesterday, so the stop is a bound and not a blanket")

        // ---- The month grid: the header row and the leading blanks are one rotation ----
        //
        // The invariant is structural — column `i` is always `weekdaySymbols[i]`, and the 1st sits in
        // the column whose symbol is its own weekday. The sweep is every month of five years rather than
        // one convenient month, because each way for the two to drift apart is a different month: a
        // `firstWeekday` that is not Sunday, a leap February, a 31-day month beginning on the calendar's
        // own first weekday, and a month containing a DST transition. One month exercises one of those,
        // and would pass with the natural-looking `blanks = weekdayOfFirst - 1` that `MonthGrid` exists
        // to avoid.
        do {
            var monthsChecked = 0
            var shapeFailures: [String] = []
            var dayCountFailures: [String] = []
            var spacingFailures: [String] = []
            var headerFailures: [String] = []
            var anchorFailures: [String] = []

            for year in 2023...2027 {
                for month in 1...12 {
                    guard let anchor = calendar.date(from: DateComponents(year: year, month: month, day: 15)),
                          let grid = MonthGrid.make(for: anchor, calendar: calendar)
                    else {
                        shapeFailures.append("\(year)-\(month): no grid at all")
                        continue
                    }
                    monthsChecked += 1
                    let name = "\(year)-\(month)"

                    if grid.cells.count % 7 != 0 || grid.weekdaySymbols.count != 7
                        || grid.leadingBlanks >= 7
                        || grid.cells.prefix(while: { $0 == nil }).count != grid.leadingBlanks {
                        shapeFailures.append(
                            "\(name): \(grid.cells.count) cells, \(grid.leadingBlanks) blanks, "
                                + "\(grid.weekdaySymbols.count) symbols")
                    }

                    let drawn = grid.cells.compactMap { $0 }
                    if drawn.count != grid.days.count || Set(grid.days).count != grid.days.count {
                        dayCountFailures.append(
                            "\(name): \(grid.days.count) days, \(Set(grid.days).count) distinct, "
                                + "\(drawn.count) drawn")
                    }

                    // `byAdding: .day` and never `addingTimeInterval(86_400)`: a month with a DST
                    // transition in it is exactly where the second form repeats or skips a day number.
                    for offset in 1..<grid.days.count
                    where calendar.dateComponents(
                        [.day], from: grid.days[offset - 1], to: grid.days[offset]).day != 1 {
                        spacingFailures.append("\(name): day \(offset + 1) is not one day after day \(offset)")
                        break
                    }

                    for (index, cell) in grid.cells.enumerated() {
                        guard let day = cell else { continue }
                        let expected = calendar.shortWeekdaySymbols[
                            calendar.component(.weekday, from: day) - 1]
                        if grid.weekdaySymbols[index % 7] != expected {
                            headerFailures.append(
                                "\(name): \(day.formattedShortDate()) sits under "
                                    + "\(grid.weekdaySymbols[index % 7]) but is a \(expected)")
                            break
                        }
                    }

                    // The caller passes the day the app is on, not the 1st, so any day of the month has
                    // to anchor the same grid — otherwise paging to a month and selecting a day inside
                    // it would redraw the month differently.
                    if let midMonth = calendar.date(
                        from: DateComponents(year: year, month: month, day: 28)),
                        MonthGrid.make(for: midMonth, calendar: calendar) != grid {
                        anchorFailures.append(name)
                    }
                }
            }

            assertTest(
                monthsChecked == 60,
                "A grid was built for all 60 months of 2023–2027 — the sweep itself is the assertion")
            assertTest(
                shapeFailures.isEmpty,
                "Every grid is a whole number of weeks with fewer than 7 leading blanks, and those blanks "
                    + "are exactly the nils before the 1st — first failure: \(shapeFailures.first ?? "none")")
            assertTest(
                dayCountFailures.isEmpty,
                "…and every day of the month is drawn exactly once — first failure: "
                    + "\(dayCountFailures.first ?? "none")")
            assertTest(
                spacingFailures.isEmpty,
                "…each one calendar day after the last, through two DST transitions a year — which is "
                    + "what `byAdding: .day` buys and an 86 400-second step would not — first failure: "
                    + "\(spacingFailures.first ?? "none")")
            assertTest(
                headerFailures.isEmpty,
                "…and each day sits under the column whose weekday symbol is its own. This is the "
                    + "assertion that catches the header and the blanks drifting apart — first failure: "
                    + "\(headerFailures.first ?? "none")")
            assertTest(
                anchorFailures.isEmpty,
                "…and any day of the month anchors the same grid, since the caller passes the selected "
                    + "day rather than the 1st — first failure: \(anchorFailures.first ?? "none")")

            // The rotation itself, which the sweep above cannot see on this machine: `Calendar.current`
            // is Sunday-first here, so `firstWeekday - 1` is 0 and the buggy `blanks = weekdayOfFirst - 1`
            // agrees with the correct form — every assertion above passes with it. Driving a Monday-first
            // calendar through the same invariant is what exercises the rotation, and `MonthGrid.make`
            // takes the calendar as a parameter precisely so that is possible.
            var mondayFirst = Calendar(identifier: .gregorian)
            mondayFirst.firstWeekday = 2
            mondayFirst.timeZone = calendar.timeZone

            var rotationFailures: [String] = []
            for month in 1...12 {
                guard let anchor = mondayFirst.date(from: DateComponents(year: 2026, month: month, day: 15)),
                      let grid = MonthGrid.make(for: anchor, calendar: mondayFirst)
                else {
                    rotationFailures.append("2026-\(month): no grid")
                    continue
                }
                if grid.weekdaySymbols.first != mondayFirst.shortWeekdaySymbols[1] {
                    rotationFailures.append(
                        "2026-\(month): header starts at \(grid.weekdaySymbols.first ?? "none")")
                }
                for (index, cell) in grid.cells.enumerated() {
                    guard let day = cell else { continue }
                    let expected = mondayFirst.shortWeekdaySymbols[
                        mondayFirst.component(.weekday, from: day) - 1]
                    if grid.weekdaySymbols[index % 7] != expected {
                        rotationFailures.append(
                            "2026-\(month): \(day.formattedShortDate()) sits under "
                                + "\(grid.weekdaySymbols[index % 7]) but is a \(expected)")
                        break
                    }
                }
            }
            assertTest(
                rotationFailures.isEmpty,
                "Under a Monday-first calendar the header and the blanks rotate together, so the 1st still "
                    + "sits under its own weekday — the half of the rule a Sunday-first locale cannot "
                    + "exercise — first failure: \(rotationFailures.first ?? "none")")

            // …and `firstWeekday` is genuinely read rather than a Sunday-first grid handed back whatever
            // calendar is passed, which would satisfy every invariant above and still mislabel the
            // columns. February 2026 begins on a Sunday, so the two conventions must disagree about it.
            if let sundayAnchor = calendar.date(from: DateComponents(year: 2026, month: 2, day: 15)),
               let mondayAnchor = mondayFirst.date(from: DateComponents(year: 2026, month: 2, day: 15)),
               let sundayGrid = MonthGrid.make(for: sundayAnchor, calendar: calendar),
               let mondayGrid = MonthGrid.make(for: mondayAnchor, calendar: mondayFirst) {
                assertTest(
                    sundayGrid.weekdaySymbols != mondayGrid.weekdaySymbols
                        && sundayGrid.leadingBlanks != mondayGrid.leadingBlanks
                        && sundayGrid.leadingBlanks == 0 && mondayGrid.leadingBlanks == 6,
                    "February 2026 lays out differently under the two conventions — no blanks when the "
                        + "week starts on the day it begins, six when it starts the day after")
            }
        }

        // ---- The month the calendar reads, and the window it reads it with ----
        //
        // `getRecoveryHistory` bounds its window at BOTH ends and runs from `endingOn - days`, so a
        // window one day too wide pulls in a neighbouring month's row and the grid becomes free to paint
        // a day that nothing measured. That is invisible on screen — a tinted cell looks like any other
        // — so the neighbours are asserted absent rather than merely left unasserted.
        do {
            let monthDB = LocalDatabaseManager(inMemory: true)
            let monthRepository = GRDBRecoveryRepository(db: monthDB)

            let anchor = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
            let firstOfMonth = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
            let lastOfMonth = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
            let previousMonth = calendar.date(byAdding: .day, value: -1, to: firstOfMonth)!
            let nextMonth = calendar.date(byAdding: .day, value: 1, to: lastOfMonth)!
            let gatedDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!

            // 80 is green and 20 is red, so a row arriving from the wrong month is not merely present —
            // it is a *different colour*, which is what makes its absence worth asserting.
            for (date, score) in [(firstOfMonth, 80), (lastOfMonth, 20),
                                  (previousMonth, 80), (nextMonth, 20)] {
                try await monthRepository.saveRecovery(
                    RecoveryMetric(date: date, score: score, hrvValueMs: 60, restingHeartRate: 55))
            }
            // The row that must not appear. A placeholder is what an older build wrote for a day the
            // strap was not worn; `hasMeasurement` is a reader's only way to tell it from a real 0%, and
            // the calendar greys that day rather than painting it hard red.
            try await monthRepository.saveRecovery(
                RecoveryMetric(date: gatedDay, score: 0, hrvValueMs: 0, restingHeartRate: 0))

            let monthViewModel = await MainActor.run {
                HomeViewModel(
                    recoveryRepository: monthRepository,
                    sleepRepository: GRDBSleepRepository(db: monthDB),
                    strainRepository: GRDBStrainRepository(db: monthDB),
                    workoutRepository: GRDBWorkoutRepository(db: monthDB),
                    receptiveInactivityRepository: GRDBReceptiveInactivityRepository(db: monthDB),
                    userProfileRepository: GRDBUserProfileRepository(db: monthDB),
                    stepRepository: GRDBStepRepository(db: monthDB),
                    analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                        biometricRepository: GRDBBiometricRepository(db: monthDB)))
            }

            await monthViewModel.loadMonth(containing: anchor)

            let month = await MainActor.run {
                (tiers: monthViewModel.monthTiers, isLoading: monthViewModel.isLoadingMonth,
                 error: monthViewModel.errorMessage)
            }

            assertTest(
                month.tiers[firstOfMonth.startOfDay] == .green
                    && month.tiers[lastOfMonth.startOfDay] == .red,
                "The calendar's map carries the displayed month's measured days, each in its own tier")
            assertTest(
                month.tiers[previousMonth.startOfDay] == nil && month.tiers[nextMonth.startOfDay] == nil,
                "…and neither neighbour: `days: <span between the month's own bounds>, endingOn: <the "
                    + "month's last day>` covers exactly the month, so July 31 and September 1 are absent "
                    + "rather than tinted")
            assertTest(
                month.tiers[gatedDay.startOfDay] == nil,
                "A legacy placeholder row is absent from the map rather than `.red`, so the calendar "
                    + "greys an unworn day — keying on the row existing would paint it a hard 0%")
            assertTest(
                month.tiers.count == 2,
                "…and the map holds the month's two measured days and nothing besides")
            assertTest(
                !month.isLoading && month.error == nil,
                "…and the read finishes clean, so the grid is not left dimmed under a load that ended")

            // A month the export never covered is not an error and not a load that never finishes. That
            // is the mistake `isLoading` exists to avoid: testing `tiers.isEmpty` to decide would spin
            // forever on a month with nothing in it, which is most of them on a fresh install.
            await monthViewModel.loadMonth(
                containing: calendar.date(from: DateComponents(year: 2020, month: 1, day: 15))!)
            let emptyMonth = await MainActor.run {
                (tiers: monthViewModel.monthTiers, isLoading: monthViewModel.isLoadingMonth,
                 error: monthViewModel.errorMessage)
            }
            assertTest(
                emptyMonth.tiers.isEmpty && !emptyMonth.isLoading && emptyMonth.error == nil,
                "A month with nothing stored is an empty grid — not an error, and not a load still "
                    + "running")
        } catch {
            assertTest(false, "The month calendar's read threw: \(error)")
        }

        // ---- Home's rings and tiles on a day with nothing stored ----

        do {
            let emptyDay = calendar.date(byAdding: .day, value: -400, to: Date())!.startOfDay

            // A fresh in-memory database, rather than the one the workout block above wrote into: this
            // block only ever reads a day 400 days back, which neither database has a row on, so the two
            // are the same answer here. `repository` is the same wiring `HomeViewModel` gets in the app.
            let db = LocalDatabaseManager(inMemory: true)
            let repository = GRDBWorkoutRepository(db: db)

            // `HomeViewModel` is `@MainActor`, like every ViewModel here, so it is built and read on the
            // main actor and only plain `Sendable` values cross back out.
            let viewModel = await MainActor.run {
                HomeViewModel(
                    recoveryRepository: GRDBRecoveryRepository(db: db),
                    sleepRepository: GRDBSleepRepository(db: db),
                    strainRepository: GRDBStrainRepository(db: db),
                    workoutRepository: repository,
                    receptiveInactivityRepository: GRDBReceptiveInactivityRepository(db: db),
                    userProfileRepository: GRDBUserProfileRepository(db: db),
                    stepRepository: GRDBStepRepository(db: db),
                    analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                        biometricRepository: GRDBBiometricRepository(db: db)))
            }

            await viewModel.load(for: emptyDay)

            let snapshot = await MainActor.run {
                (
                    hasRecovery: viewModel.recovery != nil,
                    hasSleep: viewModel.sleep != nil,
                    hasStrain: viewModel.strain != nil,
                    workoutCount: viewModel.workouts.count,
                    steps: viewModel.steps,
                    hasStress: viewModel.stress != nil,
                    stressWindows: viewModel.stressDay?.windows.count,
                    restorativeSeconds: viewModel.restorativeSleepSeconds,
                    error: viewModel.errorMessage
                )
            }

            assertTest(!snapshot.hasRecovery, "A day with nothing stored has no recovery behind the ring")
            assertTest(!snapshot.hasSleep, "…no sleep session, so no performance and no restorative hours")
            assertTest(!snapshot.hasStrain, "…no strain")
            assertTest(snapshot.workoutCount == 0, "…and no recorded activities")
            assertTest(snapshot.steps == nil, "…and HealthKit answers `nil` rather than 0 steps")
            assertTest(!snapshot.hasStress, "…and no stress score")
            assertTest(
                snapshot.stressWindows == nil,
                "…and no series either, so the Stress Monitor chart draws nothing at all rather than a "
                    + "flat line at zero — an unmeasured day is not a calm one")
            assertTest(
                snapshot.restorativeSeconds == nil,
                "Deep + REM is `nil`, not 0 — the tile's dash and its 0:00 are different claims")
            assertTest(
                snapshot.error == nil,
                "…and none of that is an error to report: an empty day is a day with nothing on it")
        }

        // ---- Home on an IMPORTED day, which is the day a fresh install actually has ----
        //
        // The empty-day block above proves the dashes. This is its counterpart and the one that was
        // missing: a fresh install fills its history through the Settings import, so the first day Home
        // can show a number for is an *imported* one — and until this ran, nothing asserted that Home
        // populates from it at all. Every failure here is one a user would describe as "data isn't
        // populating in the simulator", which is exactly how it was found.
        //
        // The export ends 2026-08-22, so it is also the reason a fresh install opens on a dash: Home's
        // default day is *today*, and today is not in the file.
        do {
            let csvURL = whoopExportURL()
            guard FileManager.default.fileExists(atPath: csvURL.path) else {
                assertTest(false, "The bundled export is missing at \(csvURL.path)")
                return
            }

            let importedDB = LocalDatabaseManager(inMemory: true)
            let recoveryRepository = GRDBRecoveryRepository(db: importedDB)
            let sleepRepository = GRDBSleepRepository(db: importedDB)
            let strainRepository = GRDBStrainRepository(db: importedDB)

            _ = try await WhoopExportImporter(
                recoveryRepository: recoveryRepository,
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                napRepository: GRDBNapRepository(db: importedDB),
                workoutRepository: GRDBWorkoutRepository(db: importedDB),
                userProfileRepository: GRDBUserProfileRepository(db: importedDB),
                calendar: calendar
            ).importExport(at: csvURL)

            // The last day carrying all three, read rather than hardcoded.
            //
            // Not simply the last sleep day, which is the shape §12 already warns about: the export's
            // partial cycles make the three tables' last days differ — a sleep day near the end has no
            // strain row — so demanding all three from one arbitrarily chosen day asserts a fact about
            // the file's tail rather than about Home. This picks the day a user would actually page to
            // and see populated. §11 still owns the day keys; nothing here hardcodes a date.
            func days(_ dates: [Date]) -> Set<Date> { Set(dates.map(\.startOfDay)) }
            let recoveryDays = days(try await recoveryRepository.getRecoveryHistory(days: 4000).map(\.date))
            let sleepDays = days(try await sleepRepository.getSleepHistory(days: 4000).map(\.date))
            let strainDays = days(try await strainRepository.getStrainHistory(days: 4000).map(\.date))

            guard let importedDay = recoveryDays.intersection(sleepDays).intersection(strainDays).max() else {
                assertTest(false, "The import wrote a day carrying a recovery, a night and a strain")
                return
            }
            assertTest(
                true,
                "The import wrote \(recoveryDays.count) recoveries, \(sleepDays.count) nights and "
                    + "\(strainDays.count) strains; the most recent day carrying all three is the one "
                    + "Home is loaded with")

            let home = await MainActor.run {
                HomeViewModel(
                    recoveryRepository: recoveryRepository,
                    sleepRepository: sleepRepository,
                    strainRepository: strainRepository,
                    workoutRepository: GRDBWorkoutRepository(db: importedDB),
                    receptiveInactivityRepository: GRDBReceptiveInactivityRepository(db: importedDB),
                    userProfileRepository: GRDBUserProfileRepository(db: importedDB),
                    stepRepository: GRDBStepRepository(db: importedDB),
                    analyzeStress: AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore()),
                    manage: ManageBLEConnectionUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true)),
                    streamUseCase: StreamBiometricsUseCase(
                        bleRepository: WhoopBLEDeviceRepositoryImpl(useMock: true),
                        biometricRepository: GRDBBiometricRepository(db: importedDB)))
            }

            await home.load(for: importedDay)

            let imported = await MainActor.run {
                (
                    score: home.recovery?.hasMeasurement == true ? home.recovery?.score : nil,
                    sleep: home.sleep?.sleepPerformancePercentage,
                    strain: home.strain?.score,
                    restorative: home.restorativeSleepSeconds,
                    steps: home.steps,
                    hasStress: home.stress != nil,
                    stressWindows: home.stressDay?.windows.count,
                    activities: home.workouts.count,
                    weekSlots: home.metricWeek?.days.count,
                    weekEndsOn: home.metricWeek?.endingOn,
                    weekStrainNils: home.metricWeek?.days.filter { $0.strain == nil }.count,
                    weekRestingHeartRate: home.metricWeek?.day(for: importedDay)?.restingHeartRate,
                    weekSleepNeed: home.metricWeek?.day(for: importedDay)?.sleepNeedSeconds,
                    weekRestingHeartRateBaseline: home.metricWeek?.restingHeartRateBaseline,
                    weekSleepNeedBaseline: home.metricWeek?.sleepNeedBaselineSeconds
                )
            }

            assertTest(
                imported.score != nil,
                "An imported day puts a measured recovery behind the Home ring, so the ring takes its "
                    + "tier colour instead of a dash")
            assertTest(
                imported.sleep != nil,
                "…and a sleep performance, so the SLEEP ring has a value ("
                    + "\(imported.sleep.map { "\($0)%" } ?? "nil"))")
            assertTest(imported.strain != nil, "…and WHOOP's own strain for the day")
            assertTest(
                imported.restorative != nil,
                "…and deep + REM for the RESTORATIVE SLEEP tile ("
                    + "\(imported.restorative.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

            // The two that stay dashes, asserted for the same reason: the import is the only input a
            // fresh install has, and it carries neither step counts nor an R-R series. A number here
            // would mean something had started inventing one.
            assertTest(
                imported.steps == nil,
                "…but STEPS stays a dash: the export has no step counts, and HealthKit is the only source")
            assertTest(
                !imported.hasStress,
                "…and STRESS MONITOR stays a dash: the export carries no R-R intervals to score")
            assertTest(
                imported.stressWindows == nil,
                "…and its chart is absent rather than empty, on every one of the \(recoveryDays.count) "
                    + "imported days — the export has no R-R series at all")
            // A covering read cannot move this, and not for the reason the row total suggests:
            // `importExport(at:)` parses **cycles only** and never reaches `importWorkoutRows`, so
            // this database holds no `workouts` rows at all and the count is `0` under either read. The
            // three cross-midnight export rows (2026-08-18, 2023-11-30, 2023-08-23) are never written
            // here in the first place. Leaving the assertion byte-identical is the point: `importedDay` is
            // *derived* — the newest day carrying a recovery, a night and a strain — so this stays true of
            // a future export rather than describing one date someone pinned.
            assertTest(
                imported.activities == 0,
                "…and ACTIVITIES holds only the sleep row — the import writes no workouts")

            // The two new panels and the chart, on the days that actually have data behind them. Unlike
            // the stress chart, these are populated from the export — which is the whole reason they were
            // built against a measured column count rather than against the mockup.
            assertTest(
                imported.weekSlots == MetricWeek.dayCount && imported.weekEndsOn == importedDay.startOfDay,
                "Home's week is seven slots ending on the day it loaded (got "
                    + "\(imported.weekSlots.map { "\($0)" } ?? "nil") slots)")
            assertTest(
                imported.weekStrainNils == 0,
                "…and every one of those seven imported days carries a measured strain, so the chart's "
                    + "line is unbroken across it (nil slots: "
                    + "\(imported.weekStrainNils.map { "\($0)" } ?? "nil"))")
            assertTest(
                imported.weekRestingHeartRate != nil,
                "…and the loaded day has a resting heart rate for its panel ("
                    + "\(imported.weekRestingHeartRate.map { "\($0) bpm" } ?? "nil"))")
            assertTest(
                imported.weekRestingHeartRateBaseline != nil,
                "…with a 7-day mean to print under it ("
                    + "\(imported.weekRestingHeartRateBaseline.map { "\($0) bpm" } ?? "nil"))")
            assertTest(
                imported.weekSleepNeed != nil && imported.weekSleepNeedBaseline != nil,
                "…and the SLEEP NEEDED panel has both a need and a mean: the import stores WHOOP's own "
                    + "`Sleep need (min)`, so this is not this app's 8-hour constant ("
                    + "\(imported.weekSleepNeed.map { $0.formattedCompactHoursMinutes() } ?? "nil") over "
                    + "\(imported.weekSleepNeedBaseline.map { $0.formattedCompactHoursMinutes() } ?? "nil"))")

            // The v7 backfill's predicate, against the real export. The migrator runs before any row
            // exists, so the migration cannot assert this for itself — but the premise it rests on is a
            // property of the data, and it is measured here rather than assumed. It was assumed once and
            // was wrong: `strainScore = 0` looks like the placeholder's signature and is not, because
            // WHOOP scores days at exactly 0.0 of its own accord.
            let importedStrains = try await strainRepository.getStrainHistory(days: 4000)
            assertTest(
                importedStrains.allSatisfy(\.hasMeasurement),
                "All \(importedStrains.count) imported strain rows read back as measurements")
            assertTest(
                importedStrains.allSatisfy { $0.averageHeartRate > 0 },
                "…and every one carries a heart rate, which is what makes the backfill's predicate safe: "
                    + "the empty branch writes no heart rate at all")
            let measuredZeros = importedStrains.filter { $0.score == 0.0 }
            assertTest(
                !measuredZeros.isEmpty && measuredZeros.allSatisfy(\.hasMeasurement),
                "…including the \(measuredZeros.count) days WHOOP itself scored exactly 0.0, which a "
                    + "backfill keyed on the score alone would have marked unmeasured")
        } catch {
            assertTest(false, "Home on an imported day threw: \(error)")
        }
    }
}
