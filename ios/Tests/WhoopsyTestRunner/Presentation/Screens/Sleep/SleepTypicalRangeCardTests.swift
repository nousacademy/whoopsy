import Foundation
import Whoopsy

enum SleepTypicalRangeCardTests {
    static func run() async throws {
        // ── 7. What a listener hears ─────────────────────────────────────────────────────────────────
        //
        // The strings are built outside the view for the reason the whole file is: nothing here has a
        // renderer, so an accessibility label assembled inside a `body` is a string no assertion can read.
        let deepRow = SleepStageRangeScoring.Row(
            stage: .deep, seconds: 5580, percent: 20,
            typical: SleepStageRangeScoring.Typical(lowPercent: 15.4, highPercent: 22.6))
        assertTest(
            SleepTypicalRangeCard.spokenStageRow(deepRow)
                == "Deep / SWS, 20 percent of the night, 1h 33m, typical 15 to 23 percent",
            "A stage row is announced with its share and its band, and its duration is spoken as a "
                + "duration rather than as the `1:33` printed on the screen")

        let unbandedRow = SleepStageRangeScoring.Row(
            stage: .rem, seconds: 5580, percent: 20, typical: nil)
        assertTest(
            SleepTypicalRangeCard.spokenStageRow(unbandedRow)
                == "REM, 20 percent of the night, 1h 33m, no typical range yet",
            "…and a row with no band says so rather than falling silent, since 'we cannot say what is "
                + "typical for you yet' is an answer")

        assertTest(
            SleepTypicalRangeCard.spokenRestorativeRow(seconds: 9960, typicalSeconds: 11820)
                == "Restorative sleep, 2h 46m, typical 3h 17m",
            "The footer is announced as a duration and the mean it is read against — the pair the "
                + "reference prints as 2:46 ▼ 3:17")
        assertTest(
            SleepTypicalRangeCard.spokenRestorativeRow(seconds: 9960, typicalSeconds: nil)
                == "Restorative sleep, 2h 46m, no typical range yet",
            "…with no comparison claimed when the window produced no mean")

    }
}
