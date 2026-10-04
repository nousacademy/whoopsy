import Foundation
import Whoopsy

enum MetricWeekTests {
    static func run() async throws {
        do {
            // ── The day's asleep total, and why it is a field rather than a derivation ───────────────
            //
            // This is the assertion that pins the reason `MetricDay.asleepSeconds` exists at all. The
            // reference's own worst night is the case: `sleepPerformance` is the two durations' ratio
            // rounded to a whole percent, and recovering either duration from it is lossy by up to half a
            // percent of the need — three minutes on a nine-hour one. A chart deriving its point that way
            // would draw a night two minutes short of the one the card above it prints, on one screen.
            let referenceNight = TypicalRangeTests.durationed(dayOffset: 0, asleep: 27180, need: 33420)
            let lossyWeek = MetricWeek(endingOn: TypicalRangeTests.weekAnchor, sleep: [referenceNight])
            let lossyDay = lossyWeek.days.last
            assertTest(
                lossyDay?.asleepSeconds == 27180 && lossyDay?.sleepNeedSeconds == 33420
                    && lossyDay?.sleepPerformance == 81,
                "A night's asleep total is read off the same `sleeps` row as its need and its "
                    + "performance — 7h33m against 9h17m reads back as 27180 seconds, 33420 seconds and "
                    + "81 percent, which are the reference's own figures (got "
                    + "\(lossyDay?.asleepSeconds ?? -1) / \(lossyDay?.sleepNeedSeconds ?? -1) / "
                    + "\(lossyDay?.sleepPerformance ?? -1))")
            if let asleep = lossyDay?.asleepSeconds, let need = lossyDay?.sleepNeedSeconds,
               let performance = lossyDay?.sleepPerformance {
                assertTest(
                    Int((need * Double(performance) / 100).rounded()) == 27070 && asleep == 27180,
                    "…and the ratio cannot give that total back: 81 percent of the same need is 27070 "
                        + "seconds, which is 7h31m where the night holds 7h33m. That two-minute gap is "
                        + "the whole reason the field is stored rather than derived")
            }
            assertTest(
                MetricWeek(endingOn: TypicalRangeTests.weekAnchor).days.allSatisfy { $0.asleepSeconds == nil },
                "A day with no classified night carries no asleep total, which is the same absence "
                    + "`sleepNeedSeconds` has and is what the chart's `nil` reads through")

        }
    }
}
