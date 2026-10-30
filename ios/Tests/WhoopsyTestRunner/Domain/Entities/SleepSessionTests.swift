import Foundation
import Whoopsy

// MARK: - 15. What a publisher may treat as "the same night"

/// `SleepSession.drawsSame(as:)`, the comparison `RefreshNightsUseCase` publishes on.
///
/// **`Equatable` is the thing this exists because of, and the entity says so.** A classification mints
/// a fresh `id` and a fresh id for every stage segment, and its `scoredThrough` watermark is *meant* to
/// advance — so two reads of an unchanged night compare unequal. The consequence, measured 2026-10-27,
/// was that every morning re-classification published a "new" night and redrew Home's ring for a figure
/// that had not changed. These assertions pin the comparison that replaced it: identity is the drawing,
/// not the row.
enum SleepSessionTests {
    static func run() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let end = start.addingTimeInterval(7 * 3600)

        func session(
            deep: TimeInterval = 2 * 3600,
            segmentEnd: Date? = nil,
            scoredThrough: Date? = nil,
            spine: SleepStillnessSpine? = .samples
        ) -> SleepSession {
            SleepSession(
                startTime: start,
                endTime: end,
                lightSleepSeconds: 4 * 3600,
                deepSleepSeconds: deep,
                remSleepSeconds: 3600,
                awakeSeconds: 600,
                disturbanceCount: 3,
                sleepStages: [
                    SleepStageSegment(
                        startTime: start,
                        endTime: segmentEnd ?? start.addingTimeInterval(3600),
                        stage: .deep)
                ],
                stillnessSpine: spine,
                algorithm: .current,
                scoredThrough: scoredThrough ?? end)
        }

        let a = session(scoredThrough: end)
        let b = session(scoredThrough: end.addingTimeInterval(600))
        assertTest(
            a.id != b.id && a.scoredThrough != b.scoredThrough && a.drawsSame(as: b),
            "Two classifications of one night draw the same thing even though their ids and their "
                + "watermarks differ — which is exactly why `Equatable` could not be the publisher's "
                + "test")

        assertTest(
            !a.drawsSame(as: session(deep: 3 * 3600)),
            "…and a stage total that moved is a different drawing, so the ring is told")

        assertTest(
            !a.drawsSame(as: session(segmentEnd: start.addingTimeInterval(1800))),
            "…as is a stage boundary that moved, compared without the segment's own id")

        assertTest(
            !a.drawsSame(as: session(spine: .motion)),
            "…and a night that was re-supported by the other spine is a different provenance, not a "
                + "silent replacement")
    }
}
