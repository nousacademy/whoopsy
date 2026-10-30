import Foundation

/// The sentence under the sleep page's two headline figures: the night's **restorative share** in
/// words, graded against the guidance WHOOP publishes for it.
///
/// **It is the reference's sentence, re-grounded on this app's own numbers.** The reference reads
/// *"REM and deep sleep accounted for less than 35% of your total time in bed, which is less than
/// optimal for restorative sleep"*; the 35% is its own copy, and the figure this app draws its ring
/// from is `SleepScoreScoring`'s restorative term, whose published anchor is
/// `restorativeGuidanceLowerPercent`–`restorativeTargetPercent` (40–50 % of sleep). A sentence that
/// graded 40 % as optimal against 35 % would contradict the ring two elements below it, so the
/// thresholds are read from that type rather than copied from the reference image.
///
/// **The denominator is sleep, not time in bed**, because that is the one the ring's restorative term
/// uses (`SleepScoreScoring` divides by `asleep`). The reference counts time in bed; this app counts
/// sleep. Two denominators for one share would put the sentence and the score at odds on a night with
/// a long awake stretch, which is exactly the night a reader would check one against the other.
///
/// `nil` on a night with no sleep at all — a session with zero asleep has no share to take, and the
/// page draws no sentence rather than a sentence about `0 %`.
public enum SleepStageShareMessage {

    /// The guidance, as one string, so the sentence cannot say "40–50" in one arm and "50" in another.
    static var guidanceText: String {
        "\(Int(SleepScoreScoring.restorativeGuidanceLowerPercent))–"
            + "\(Int(SleepScoreScoring.restorativeTargetPercent))%"
    }

    /// The night's share in words, or `nil` when there is no sleep to take a share of.
    public static func sentence(
        restorativeSeconds: TimeInterval,
        asleepSeconds: TimeInterval
    ) -> String? {
        guard asleepSeconds > 0, restorativeSeconds >= 0 else { return nil }
        let share = Int((restorativeSeconds / asleepSeconds * 100).rounded())
        let lead = "REM and deep sleep accounted for \(share)% of your sleep, "

        if Double(share) < SleepScoreScoring.restorativeGuidanceLowerPercent {
            return lead + "below the \(guidanceText) range that published guidance calls optimal for "
                + "restorative sleep."
        }
        if Double(share) > SleepScoreScoring.restorativeTargetPercent {
            return lead + "above the \(guidanceText) range that published guidance calls optimal for "
                + "restorative sleep."
        }
        return lead + "inside the \(guidanceText) range that published guidance calls optimal for "
            + "restorative sleep."
    }
}
