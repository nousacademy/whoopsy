import Foundation
import Whoopsy

// MARK: - 18. The accumulator, the band scale and the calorie estimate

/// A file of §18's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `LiveSessionTests.run()` calls it, in the order the section ran it in.

enum LiveSessionAccumulatorTests {
    static func run() async throws {
        // ---- The five bands, defined once ----

        assertTest(
            StrainAccumulatorMath.zoneReserveBandLabels
                == ["50-59%", "60-69%", "70-79%", "80-89%", "90-100%"],
            "The live screen's five band labels are the five bands: "
                + "\(StrainAccumulatorMath.zoneReserveBandLabels)")

        // The labels are *derived*, and this is the assertion that keeps them derived: `computeZones`
        // builds its bpm edges from the same array, so a band edge moved in one place and not the other
        // fails here rather than printing `50-59%` over a 55% boundary.
        assertTest(
            StrainAccumulatorMath.zoneReserveBandLabels.count
                == StrainAccumulatorMath.zoneReserveFractions.count,
            "…one label per fraction, so the two arrays cannot describe different numbers of bands")

        let zones190 = StrainAccumulatorMath.computeZones(maxHR: 190, restHR: 60)
        let derivedLowerEdges = StrainAccumulatorMath.zoneReserveFractions.map {
            Int((60.0 + 130.0 * $0.lower).rounded())
        }
        assertTest(
            zones190.map(\.lowerBpm) == derivedLowerEdges,
            "…and the zone table's lower edges are those fractions of the reserve ("
                + "\(zones190.map(\.lowerBpm)) against \(derivedLowerEdges))")

        // Zone 5's ceiling is `maxHR` itself and not `rest + reserve × 1.00`, because `computeZones`
        // floors the reserve at 20 bpm and `rest + 20` would overshoot the maximum on a narrow one.
        assertTest(
            zones190.last?.upperBpm == 190,
            "…with the top band closing at `maxHR` rather than at a widened reserve's end "
                + "(\((zones190.last?.upperBpm).map(String.init) ?? "nil"))")

        // ---- The accumulator's arithmetic ----
        //
        // Every number below is the session figure's whole justification, and the two conventions in it
        // are inherited from `CalculateStrainUseCase` rather than invented here — see the type's doc
        // comment. They are pinned as literals so that changing either fails loudly here instead of
        // moving a figure on a screen nothing can check.

        // A clean origin, so `t0 + index × 0.25` is exact in binary and the throttle's `>= 1.0` test
        // sits on a boundary a float cannot blur. A real `Date()` is ~7.9 × 10⁸ seconds and adding a
        // quarter to it drops the fraction's last digits.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        var accumulator = LiveSessionAccumulator(zones: zones190, restingHeartRate: 60, weightKg: nil)

        assertTest(
            accumulator.snapshot.strain == nil,
            "A session with no samples has no strain — `nil` and not `0.0`, which would be the claim "
                + "that it measured a resting body")
        assertTest(
            accumulator.snapshot.calories == nil,
            "…and no calories, because there is neither a weight nor an elapsed span to divide by")

        // 160 bpm against a 190/60 profile is zone 3: 151…164 bpm, weight 4.5.
        accumulator.accept(heartRate: 160, at: t0, isOnBody: true)
        let firstSample = accumulator.snapshot
        assertTest(
            firstSample.measuredSeconds == 1.0,
            "The session's first sample is credited exactly `1.0` second — the day model's convention "
                + "for a sample with no predecessor, not a difference against the session's start "
                + "(\(firstSample.measuredSeconds))")
        assertTest(
            firstSample.zoneSeconds[2] == 1.0,
            "…and that second lands in zone 3, which is where 160 bpm sits on a 190/60 table "
                + "(\(firstSample.zoneSeconds))")

        // The cap that makes a gap five seconds rather than ten. Dropping `min(5.0, …)` is the change
        // this assertion exists to catch, and it would double every figure on a strap that notifies
        // every ten seconds.
        accumulator.accept(heartRate: 160, at: t0.addingTimeInterval(10), isOnBody: true)
        let afterGap = accumulator.snapshot
        assertTest(
            afterGap.measuredSeconds == 6.0,
            "A sample ten seconds after its predecessor contributes `5.0`, not `10.0` — a strap that "
                + "stopped notifying was not measuring, but the body did not stop existing "
                + "(\(afterGap.measuredSeconds))")

        // A sample below zone 1: it is time the session really spent, and it belongs to no band.
        accumulator.accept(heartRate: 50, at: t0.addingTimeInterval(20), isOnBody: true)
        let belowZone1 = accumulator.snapshot
        assertTest(
            belowZone1.measuredSeconds == 11.0 && belowZone1.zoneSeconds.reduce(0, +) == 6.0,
            "A sample below zone 1 adds to the measured span and to no band — 11 s measured against 6 s "
                + "in zones (\(belowZone1.measuredSeconds) / \(belowZone1.zoneSeconds.reduce(0, +)))")
        assertTest(
            belowZone1.zonePercents.reduce(0, +) < 100,
            "…so the five percentages sum to strictly less than 100, which is what forbids "
                + "`WholePercentMath.wholePercents(ofSeconds:)` here — that helper makes a column sum to "
                + "exactly 100, and would claim the five bands covered a session they did not "
                + "(\(belowZone1.zonePercents.reduce(0, +))%)")
        assertTest(
            belowZone1.zonePercents[2] == 55.0,
            "…and zone 3 is 6 of those 11 seconds, rounded to a whole percent "
                + "(\(belowZone1.zonePercents[2]))")

        // ---- The band scale's position ----
        //
        // This is the one thing on the session screen that reads the zone table for something other than
        // a duration: where the current heart rate sits on the five bands laid end to end, which is the
        // mark `HeartRateBandScaleView` draws. The scale's two ends are read off the table rather than
        // recomputed from `zoneReserveFractions`, and that is the property these pin — on a 190/60 profile
        // the reserve is 130 bpm, so zone 1's floor is 125 and zone 5's ceiling is `maxHR`, 190, giving a
        // 65 bpm span. A reader that re-derived the span from the fractions would place the same mark,
        // which is exactly why the ends are asserted against the table's own numbers.

        assertTest(
            StrainAccumulatorMath.bandScalePosition(forHeartRate: 125, zones: zones190) == 0,
            "The scale's left edge is zone 1's own floor: 125 bpm on a 190/60 table is position 0 "
                + "(\(StrainAccumulatorMath.bandScalePosition(forHeartRate: 125, zones: zones190)))")
        assertTest(
            StrainAccumulatorMath.bandScalePosition(forHeartRate: 190, zones: zones190) == 1,
            "…and its right edge is zone 5's ceiling, which `computeZones` sets to `maxHR` itself rather "
                + "than to the widened reserve's end "
                + "(\(StrainAccumulatorMath.bandScalePosition(forHeartRate: 190, zones: zones190)))")
        assertTest(
            abs(StrainAccumulatorMath.bandScalePosition(forHeartRate: 151, zones: zones190) - 0.4) < 1e-12,
            "…and zone 3 opens at 26 of those 65 bpm, so its floor sits at 0.4 of the scale "
                + "(\(StrainAccumulatorMath.bandScalePosition(forHeartRate: 151, zones: zones190)))")

        assertTest(
            belowZone1.bandScalePosition == 0,
            "A reading at rest is below zone 1 by construction, so its mark is clamped to the left edge "
                + "rather than drawn off the scale — the ordinary case, not an edge "
                + "(\(belowZone1.bandScalePosition.map { "\($0)" } ?? "nil"))")

        assertTest(
            accumulator.snapshot.bandScalePosition != nil
                && LiveSessionAccumulator(zones: zones190, restingHeartRate: 60, weightKg: nil)
                    .snapshot.bandScalePosition == nil,
            "…and the mark is absent exactly when the reading is — `nil` before any sample, a number "
                + "once one arrives — so a session that has heard from no strap draws no mark rather than "
                + "one at zero, which is what a worn strap at rest draws")

        assertTest(
            StrainAccumulatorMath.bandScalePosition(forHeartRate: 150, zones: []) == 0,
            "…and a table that cannot define a scale answers 0 rather than dividing by its own zero, "
                + "which `computeZones` never produces and a caller must not be able to reach")

        // `nil` and `0.0` are different answers, and this is the pair that says so.
        var subZoneOnly = LiveSessionAccumulator(zones: zones190, restingHeartRate: 60, weightKg: nil)
        assertTest(subZoneOnly.snapshot.strain == nil, "…`nil` before any sample")
        subZoneOnly.accept(heartRate: 50, at: t0, isOnBody: true)
        assertTest(
            subZoneOnly.snapshot.strain == 0.0,
            "…and exactly `0.0` after a sample that never reached zone 1, which is a measurement of a "
                + "session that stayed under the first band (\(subZoneOnly.snapshot.strain.map { "\($0)" } ?? "nil"))")

        // The calorie denominator. `CalculateStrainUseCase` passes `count / 60` — a duration fabricated
        // from the number of samples — which is right on a 1 Hz stream and wrong on any other. Here the
        // two are four times apart, so a fork back to the count fails.
        var calorieAccumulator = LiveSessionAccumulator(
            zones: zones190, restingHeartRate: 60, weightKg: 75.0)
        for index in 0..<6 {
            calorieAccumulator.accept(
                heartRate: 160, at: t0.addingTimeInterval(Double(index) * 10), isOnBody: true)
        }
        let calorieSnapshot = calorieAccumulator.snapshot
        assertTest(
            calorieSnapshot.measuredSeconds == 26.0,
            "Six samples ten seconds apart measured 26 seconds — `1.0 + 5 × 5.0` "
                + "(\(calorieSnapshot.measuredSeconds))")

        // 7.35 kcal/min is `(160 − 60) × 0.014 × 75 × 0.07`; over 26 s of a minute that is 3.185.
        let expectedCalories = 7.35 * (26.0 / 60.0)
        assertTest(
            abs((calorieSnapshot.calories ?? -1) - expectedCalories) < 1e-9,
            "…and the calorie figure is scaled by that span, not by a sample count "
                + "(\(calorieSnapshot.calories.map { "\($0)" } ?? "nil") against \(expectedCalories))")
        assertTest(
            (calorieSnapshot.calories ?? 0)
                > (StrainAccumulatorMath.estimateCalories(
                    heartRate: 160, durationMinutes: 6.0 / 60.0, weightKg: 75.0, restingHR: 60) ?? 0),
            "…which is strictly *above* what six samples as `count / 60` minutes would give — the two "
                + "coincide only on a stream that notifies once a second")

        // The waveform's buffer survives the screen, and it is bounded.
        var waveform = LiveSessionAccumulator(zones: zones190, restingHeartRate: 60, weightKg: nil)
        for index in 0..<(LiveSessionAccumulator.recentHeartRateCapacity + 5) {
            waveform.accept(
                heartRate: 100 + index % 3, at: t0.addingTimeInterval(Double(index)), isOnBody: true)
        }
        let waveSnapshot = waveform.snapshot
        assertTest(
            waveSnapshot.recentHeartRates.count == LiveSessionAccumulator.recentHeartRateCapacity,
            "The trace holds a bounded window rather than the whole session "
                + "(\(waveSnapshot.recentHeartRates.count) of \(LiveSessionAccumulator.recentHeartRateCapacity))")
        assertTest(
            waveSnapshot.recentHeartRates.first == 102,
            "…and it drops from the front, so the five oldest readings are gone and the sixth leads "
                + "(\(waveSnapshot.recentHeartRates.first.map(String.init) ?? "nil"))")

        let beforeRefusal = waveSnapshot.sampleCount
        waveform.accept(heartRate: 0, at: t0.addingTimeInterval(500), isOnBody: true)
        assertTest(
            waveform.snapshot.sampleCount == beforeRefusal,
            "A reading of `0` bpm is refused rather than recorded — no strap reports one, so it is a "
                + "decode artefact, and admitting it would drag the average down and credit the session "
                + "with seconds no sensor produced")

        assertTest(
            waveSnapshot.isOnBody == true,
            "…and the body flag is the sample's own, carried through rather than defaulted")
        var offBody = LiveSessionAccumulator(zones: zones190, restingHeartRate: 60, weightKg: nil)
        assertTest(
            offBody.snapshot.isOnBody == nil,
            "A session that has read nothing knows nothing about the strap: `nil`, not `true` — a "
                + "defaulted `true` is the fabrication class `WhoopDevice.batteryPercentage` documents")
        offBody.accept(heartRate: 100, at: t0, isOnBody: false)
        assertTest(
            offBody.snapshot.isOnBody == false,
            "…and once a sample arrives it is the sample's answer, not this app's assumption")

        // ---- The calorie estimate's absence ----
        //
        // `estimateCalories` is the one quantity in this app that multiplies by the user's body, so an
        // unset weight has to be an absence and a session at rest has to be a real zero. The two are
        // different sentences on the screen and this is the pair that keeps them apart.

        assertTest(
            StrainAccumulatorMath.estimateCalories(
                heartRate: 120, durationMinutes: 10, weightKg: nil, restingHR: 60) == nil,
            "No body weight means no calorie figure — `nil` rather than a number scaled by a body this "
                + "app invented, which is what the profile page exists to supply")
        assertTest(
            StrainAccumulatorMath.estimateCalories(
                heartRate: 60, durationMinutes: 10, weightKg: 75.0, restingHR: 60) == 0.0,
            "…while a session at exactly resting heart rate burns a real `0.0` active calories — the "
                + "floor is on the *rate*, so a measured session is never an absence")
    }
}
