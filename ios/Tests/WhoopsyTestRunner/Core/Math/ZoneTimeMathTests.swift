import Foundation
import Whoopsy

/// §4's zone-time block: the one fold behind the live session, the day's Strain and the activity
/// page's five rows.
///
/// **It exists to catch a third copy.** The interval rule — the first sample is `1` second, a longer
/// gap is capped at `5`, and the interval belongs to the *current* sample's zone — used to live in
/// `LiveSessionAccumulator.accept` and `StrainDayMath.compute` as two transcriptions that agreed by
/// inspection. The cross-check at the bottom feeds one stream to both this type and the accumulator
/// and compares the answers, which is the assertion that fails the moment someone re-derives it.
enum ZoneTimeMathTests {

    static func run() {
        let zones = StrainAccumulatorMath.computeZones(maxHR: 190, restHR: 60)
        // On that table: zone 1 is 125–138, zone 3 is 151–164, and 160 bpm sits in zone 3.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        // ---- The interval ----

        assertTest(
            ZoneTimeMath.intervalSeconds(previousTimestamp: nil, timestamp: t0)
                == ZoneTimeMath.firstSampleSeconds,
            "A stream's first sample is credited exactly `1.0` second — a single reading is still a "
                + "measurement of that instant, and starting at zero would lose it")

        assertTest(
            ZoneTimeMath.intervalSeconds(
                previousTimestamp: t0, timestamp: t0.addingTimeInterval(3)) == 3,
            "…and an ordinary interval is the gap between the two readings")

        assertTest(
            ZoneTimeMath.intervalSeconds(
                previousTimestamp: t0, timestamp: t0.addingTimeInterval(10)) == 5,
            "…while a gap longer than five seconds is credited as five, not ten: a strap that stopped "
                + "notifying was not measuring the gap, and spreading it over the reading that follows "
                + "would invent time at a rate nobody observed")

        // ---- One sample's contribution ----

        let delta = ZoneTimeMath.delta(
            heartRate: 160,
            previousTimestamp: t0,
            timestamp: t0.addingTimeInterval(10),
            zones: zones,
            restingHeartRate: 60)
        assertTest(
            delta.zone == .zone3 && delta.durationSeconds == 5 && delta.load == 22.5,
            "A sample's interval is credited to the **current** sample's band — the reading is what "
                + "claims those seconds — and its load is that band's weight times the capped duration "
                + "(\(String(describing: delta.zone)), \(delta.durationSeconds), \(delta.load))")

        // ---- A completed stream ----

        // 160 bpm at t0, a zero reading 2 s later, then 160 bpm again at t+10.
        let samples = [
            BiometricSample(timestamp: t0, heartRate: 160),
            BiometricSample(timestamp: t0.addingTimeInterval(2), heartRate: 0),
            BiometricSample(timestamp: t0.addingTimeInterval(10), heartRate: 160),
        ]
        let totals = ZoneTimeMath.totals(samples: samples, zones: zones, restingHeartRate: 60)
        assertTest(
            totals?.zoneSeconds == [0, 0, 6, 0, 0] && totals?.measuredSeconds == 6
                && totals?.sampleCount == 2,
            "A `0` bpm reading is **refused** and leaves the previous timestamp where it was, so the "
                + "next real reading spans the interval the artefact sat inside: 1 s + 5 s in zone 3, "
                + "counted twice, not three times "
                + "(\(String(describing: totals?.zoneSeconds)), "
                + "\(String(describing: totals?.measuredSeconds)))")

        let belowZoneOne = ZoneTimeMath.totals(
            samples: [
                BiometricSample(timestamp: t0, heartRate: 100),
                BiometricSample(timestamp: t0.addingTimeInterval(1), heartRate: 100),
            ],
            zones: zones,
            restingHeartRate: 60)
        assertTest(
            belowZoneOne?.zoneSeconds == [0, 0, 0, 0, 0]
                && belowZoneOne?.measuredSeconds == 2,
            "Time above resting but below zone 1 is **measured and belongs to no band** — the five "
                + "band times sum to less than the span on exactly this case, which is the rule the "
                + "footnote on the page restates "
                + "(\(String(describing: belowZoneOne?.measuredSeconds)))")

        assertTest(
            ZoneTimeMath.totals(samples: [], zones: zones, restingHeartRate: 60) == nil,
            "An empty stream answers `nil` rather than five zeroes: a session with no samples has no "
                + "zone time, which is different from having measured none")

        assertTest(
            ZoneTimeMath.totals(
                samples: samples,
                zones: Array(zones.prefix(4)),
                restingHeartRate: 60) == nil,
            "…and a table that is not five bands long answers `nil`, because it cannot name the bands "
                + "it would be folded into")

        // ---- The cross-check: one rule, not two ----

        // The same stream through the live accumulator, which carries its own copy of the previous
        // timestamp and its own refusal. If someone forks the interval rule again, these two answers
        // part company here.
        var accumulator = LiveSessionAccumulator(
            zones: zones, restingHeartRate: 60, weightKg: nil)
        for sample in samples {
            accumulator.accept(
                heartRate: sample.heartRate, at: sample.timestamp, isOnBody: sample.isOnBody)
        }
        let snapshot = accumulator.snapshot
        assertTest(
            totals?.zoneSeconds == snapshot.zoneSeconds
                && totals?.measuredSeconds == snapshot.measuredSeconds
                && totals?.sampleCount == snapshot.sampleCount,
            "The completed-stream fold and the live accumulator agree **exactly** on the same stream — "
                + "the assertion that catches a third transcription of the rule "
                + "(\(String(describing: totals?.zoneSeconds)) against \(snapshot.zoneSeconds))")
    }
}
