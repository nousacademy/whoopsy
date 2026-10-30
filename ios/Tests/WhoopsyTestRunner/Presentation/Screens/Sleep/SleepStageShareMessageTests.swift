import Foundation
import Whoopsy

enum SleepStageShareMessageTests {
    static func run() async throws {
        // ── 8. The restorative-share sentence ────────────────────────────────────────────────────────
        //
        // The reference's sentence, re-grounded on this app's own threshold. What matters here is that
        // it grades against `SleepScoreScoring`'s published guidance and not against the reference
        // image's `35%` — a sentence that called 40% "less than optimal" would contradict the ring on
        // the same screen, whose restorative term treats 40–50% as the target.
        let asleep = TimeInterval(6 * 3600 + 19 * 60)   // 6:19

        let below = SleepStageShareMessage.sentence(
            restorativeSeconds: asleep * 0.25, asleepSeconds: asleep)
        assertTest(
            below == "REM and deep sleep accounted for 25% of your sleep, below the 40–50% range that published guidance "
                + "calls optimal for restorative sleep.",
            "A night a quarter restorative is below the guidance, and the guidance quoted is "
                + "`SleepScoreScoring`'s own pair rather than a literal (got \(below ?? "nil"))")

        let inside = SleepStageShareMessage.sentence(
            restorativeSeconds: asleep * 0.45, asleepSeconds: asleep)
        assertTest(
            inside?.contains("45% of your sleep, inside the 40–50% range") == true,
            "…42–50% is *inside* the range rather than below or above it, which is the arm the "
                + "reference image has no sentence for")

        let above = SleepStageShareMessage.sentence(
            restorativeSeconds: asleep * 0.60, asleepSeconds: asleep)
        assertTest(
            above?.contains("60% of your sleep, above the 40–50% range") == true,
            "…and a heavily restorative night is not told it is short of anything")

        // The denominator is *sleep*, not time in bed — the one the ring's restorative term divides by,
        // so the sentence and the score cannot disagree on a night with a long awake stretch.
        let withAwake = SleepStageShareMessage.sentence(
            restorativeSeconds: asleep * 0.45, asleepSeconds: asleep * 2)
        assertTest(
            withAwake?.contains("23% of your sleep") == true,
            "…compared with sleep, so a night spent half of it awake at the same restorative total "
                + "reads as 23% rather than 45% (\(withAwake ?? "nil"))")

        // A night with nothing slept has no share to take, and the page draws no sentence rather than
        // one about 0% — the same "no measurement, no claim" rule the rest of the screen follows.
        assertTest(
            SleepStageShareMessage.sentence(restorativeSeconds: 0, asleepSeconds: 0) == nil,
            "A session with no sleep produces no sentence at all")

        // The bounds themselves, pinned so a change to either constant is a deliberate edit and not a
        // drift that silently re-grades every night's copy.
        assertTest(
            SleepScoreScoring.restorativeGuidanceLowerPercent == 40
                && SleepScoreScoring.restorativeTargetPercent == 50,
            "The guidance the sentence quotes is WHOOP's published 40–50% of sleep")
        assertTest(
            SleepScoreScoring.restorativeGuidanceLowerPercent
                < SleepScoreScoring.restorativeTargetPercent,
            "…and the two are ordered, which is what makes `below`/`inside`/`above` three arms rather "
                + "than two")
    }
}
