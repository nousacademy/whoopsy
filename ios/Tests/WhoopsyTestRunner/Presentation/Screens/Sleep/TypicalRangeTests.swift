import Foundation
import SwiftUI
import Whoopsy

// MARK: - 15. The typical range

/// §15 — the sleep detail screen's typical-range card.
///
/// Three kinds of thing are asserted here, and they are separate on purpose. The **arithmetic** the
/// card's percent column is made of; the **layout rule** its bars are drawn from; and the **absence
/// rules** that decide when there is no card, no dashed markers and no comparison. The runner has no
/// renderer, so no assertion below says anything about the drawing — what it says is that every number
/// and every decision the drawing is made of is right, which is the reason `SleepStageRangeScoring` and
/// `TypicalRangeBarLayout` are types rather than bodies.
///
/// The export block at the end is the only part that touches the real file, and every assertion in it
/// is a **property** rather than a count of nights: a device time zone that merges two day keys
/// narrows it without weakening it, which is the shape §11 asks new assertions here to take.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum TypicalRangeTests {
    static func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.0001 }

    // Fixed day offsets from today, so nothing here says something different tomorrow. The priors are
    // built so the four deep shares are 20/25/30/35% of an eight-hour night: the quartiles are then
    // hand-computable, and both are exact in binary, so they can be pinned as literals rather than to
    // a tolerance.
    static func night(
        dayOffset: Int,
        light: TimeInterval,
        deep: TimeInterval,
        rem: TimeInterval,
        awake: TimeInterval,
        need: TimeInterval = 8 * 3600
    ) -> SleepSession {
        let day = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!)
        let onset = day.addingTimeInterval(-8 * 3600)
        return SleepSession(
            date: day,
            startTime: onset,
            endTime: onset.addingTimeInterval(light + deep + rem + awake),
            targetSleepNeedSeconds: need,
            lightSleepSeconds: light,
            deepSleepSeconds: deep,
            remSleepSeconds: rem,
            awakeSeconds: awake)
    }

    /// An eight-hour night whose deep share is `deepPercent` and whose light and REM split the rest.
    static func prior(dayOffset: Int, deepPercent: Double) -> SleepSession {
        let deep = 28800 * deepPercent / 100
        let half = (28800 - deep) / 2
        return night(
            dayOffset: dayOffset, light: half, deep: deep, rem: half, awake: 0)
    }

    static let priors = [
        prior(dayOffset: 40, deepPercent: 20),
        prior(dayOffset: 30, deepPercent: 25),
        prior(dayOffset: 20, deepPercent: 30),
        prior(dayOffset: 10, deepPercent: 35),
    ]

    // 1h awake / 4h light / 1.5h deep / 1.5h REM — an eight-hour night whose exact shares are
    // 12.5 / 50 / 18.75 / 18.75. Two seats are spare and both go to the 18.75s.
    static let target = night(
        dayOffset: 0, light: 14400, deep: 5400, rem: 5400, awake: 3600)

    static let empty = night(dayOffset: 5, light: 0, deep: 0, rem: 0, awake: 0)

    // The reference's own night, read straight off the mockup: 7:33 asleep against a 9:17 need, and
    // 1:44 of debt. Two blocks are built on it — the need split's arithmetic and the two bars drawn
    // from that split — and both began as locals inside one `run()`, which is why the three figures
    // and the breakdown they make are here rather than written out again in each.
    static let needSeconds = TimeInterval(557 * 60)     // 9:17
    static let asleepSeconds = TimeInterval(453 * 60)   // 7:33
    static let debtSeconds = TimeInterval(104 * 60)     // 1:44

    /// The split those three figures make, through the real initialiser.
    ///
    /// Computed rather than stored, so each block gets its own value and neither can hand the other a
    /// mutated one. Every `breakdown(...)` guard below still has to unwrap it: a `nil` here is the
    /// mockup's own night failing to produce a split, which is a failure and not a fixture to paper
    /// over with `?? []` — an empty `parts` still yields a layout with the right two fractions, so the
    /// bar assertion would pass while the thing it is about had gone.
    static var breakdown: SleepNeedBreakdown.Breakdown? {
        SleepNeedBreakdown.breakdown(
            needSeconds: needSeconds, debtSeconds: debtSeconds, hasWhoopNeed: true)
    }

    /// The anchor the four week charts below are built on — today, snapped, so nothing here says
    /// something different tomorrow.
    static var weekAnchor: Date { Calendar.current.startOfDay(for: Date()) }

    /// A night with a stated time asleep and a stated need, both in seconds, and no other stage time —
    /// so `totalTimeAsleepSeconds` is exactly the `asleep` handed in.
    ///
    /// It is written out here rather than forwarding to `night(dayOffset:…)` above, because that name is
    /// shadowed from the stress block onwards by that block's own `night(high:medium:low:)`. A nested
    /// `func` shadowing an outer one is no longer what keeps the two apart — the split into files is —
    /// but the reason the two fixtures are built independently is unchanged.
    static func durationed(dayOffset: Int, asleep: TimeInterval, need: TimeInterval) -> SleepSession {
        let day = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!)
        let onset = day.addingTimeInterval(-8 * 3600)
        return SleepSession(
            date: day,
            startTime: onset,
            endTime: onset.addingTimeInterval(asleep),
            targetSleepNeedSeconds: need,
            lightSleepSeconds: asleep,
            deepSleepSeconds: 0,
            remSleepSeconds: 0,
            awakeSeconds: 0)
    }

    static func run() async throws {
        try await BaselineStatisticsMathTests.run()
        try await WholePercentMathTests.run()
        try await TypicalRangeBarTests.run()
        try await SleepStageRangeScoringTests.run()
        try await SleepStageTypeTests.run()
        try await SleepTypicalRangeCardTests.run()
        try await HoursOfSleepChartSeriesTests.run()
        try await SleepViewModelTests.run()
        try await SleepNightHeadingTests.run()
        try await SleepNeedBreakdownTests.run()
        try await SleepNeedBarTests.run()
        try await SleepNeedCardTests.run()
        try await SleepConsistencyMathTests.run()
        try await SleepConsistencyChartTests.run()
        try await SleepConsistencyScoringTests.run()
        try await SleepConsistencyCardTests.run()
        try await SleepEfficiencyCardTests.run()
        try await AnalyzeSleepStressUseCaseTests.run()
        try await HoursVsNeededWeekTests.run()
        try await MetricWeekTests.run()
        try await RestorativeSleepWeekTests.run()
        try await TimeInBedWeekTests.run()
    }
}
