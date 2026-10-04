import Foundation
import Whoopsy

enum SleepConsistencyCardTests {
    static func run() async throws {
        // ── 10. The card's own words ─────────────────────────────────────────────────────────────────
        //
        // The legend is the one place on this screen where the reference's word is deliberately not
        // used, so the word is asserted rather than left to a screenshot: nothing in this app produces a
        // recommendation, and `OPTIMAL BED/WAKETIME` would be a claim it cannot honour.
        assertTest(
            SleepConsistencyCard.legendLabel == "Avg Bed/Waketime"
                && !SleepConsistencyCard.legendLabel.localizedCaseInsensitiveContains("optimal"),
            "The rules are labelled an average and not WHOOP's `optimal` — they are the mean of the same "
                + "four nights the score above them reads, and this app computes no target "
                + "(got \(SleepConsistencyCard.legendLabel))")

        do {
            let calendar = Calendar.current
            let base = calendar.startOfDay(for: Date())
            func spokenNight(_ dayOffset: Int, onset: (Int, Int), wake: (Int, Int)) -> SleepSession {
                let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
                return SleepSession(
                    date: day,
                    startTime: calendar.date(
                        bySettingHour: onset.0, minute: onset.1, second: 0, of: day)!,
                    endTime: calendar.date(
                        bySettingHour: wake.0, minute: wake.1, second: 0, of: day)!
                )
            }

            let anchor = spokenNight(0, onset: (23, 54), wake: (7, 56))
            let history = (1...4).map { spokenNight($0, onset: (23, 0), wake: (7, 0)) } + [anchor]

            if let summary = SleepConsistencyScoring.summary(
                for: anchor, history: history, score: 91, typicalScore: 88.4) {
                let spoken = SleepConsistencyCard.spoken(for: summary)
                assertTest(
                    spoken.contains("Sleep Consistency, 91 percent")
                        && spoken.contains("typical 88 percent"),
                    "The card is announced with its figure and its comparison — the mean rounds at the "
                        + "spoken form rather than in the model, so a 88.4 says 88 "
                        + "(got \(spoken))")
                assertTest(
                    spoken.contains("11:54 PM") && spoken.contains("7:56 AM")
                        && spoken.contains("11 PM") && spoken.contains("7 AM")
                        && spoken.contains("4 nights"),
                    "…and then with the chart it cannot see: the night's own two boundaries, then the "
                        + "two averages the rules draw, then how many nights those were taken over "
                        + "(got \(spoken))")
            } else {
                assertTest(false, "The spoken-description fixture produced no summary")
            }
        }

    }
}
