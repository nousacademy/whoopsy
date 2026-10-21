import Foundation
import Whoopsy

// MARK: - 4. Strain & Zone Accumulator

/// The section's body. Driven from top level by `runSynchronousSections(_:)`.
enum StrainAccumulatorMathTests {
    static func run() {
        let zones = StrainAccumulatorMath.computeZones(maxHR: 190, restHR: 50)
        assertTest(zones.count == 5, "Computed 5 distinct Heart Rate Zones")
        assertTest(zones[0].lowerBpm == 120, "Zone 1 threshold calculated via HRR: \(zones[0].lowerBpm)")
        assertTest(zones[4].upperBpm == 190, "Zone 5 ceiling equals Max HR")

        // ---- The day curve ----

        let zeroStrain = StrainAccumulatorMath.calculateStrainScore(from: 0.0)
        assertTest(zeroStrain == 0.0, "0 accumulated load yields 0.0 strain")

        let modStrain = StrainAccumulatorMath.calculateStrainScore(from: 50_000.0)
        assertTest(modStrain == 8.8, "Moderate day load produces expected strain (\(modStrain))")

        let quietDayStrain = StrainAccumulatorMath.calculateStrainScore(from: 57_600.0)
        assertTest(quietDayStrain == 9.8, "A 16-hour quiet day (57,600 weighted seconds) scores near "
            + "WHOOP's no-workout mean (\(quietDayStrain))")

        let extremeStrain = StrainAccumulatorMath.calculateStrainScore(from: 1_000_000.0)
        assertTest(extremeStrain <= 21.0 && extremeStrain >= 20.9, "Extreme load caps at 21.0 scale ceiling (\(extremeStrain))")

        // ---- The session curve ----

        let zeroSession = StrainAccumulatorMath.calculateSessionStrainScore(from: 0.0)
        assertTest(zeroSession == 0.0, "0 session load yields 0.0 strain")

        let hardSession = StrainAccumulatorMath.calculateSessionStrainScore(from: 2709.0)
        assertTest(hardSession == 6.7, "A 301 s zone-4 session (9.0 × 301 load) scores on the session "
            + "curve (\(hardSession))")

        let walkSession = StrainAccumulatorMath.calculateSessionStrainScore(from: 1200.0)
        assertTest(walkSession == 4.6, "A 20-minute above-resting walk (1,200 load) scores a positive "
            + "figure rather than the day curve's ~0.3 (\(walkSession))")

        // ---- The low-intensity band ----
        //
        // `loadDelta` now takes a resting heart rate: above resting but below zone 1's floor earns
        // weight 1.0 with no zone, at or below resting earns nothing, and the five bands are unchanged.

        let lowBand = StrainAccumulatorMath.loadDelta(
            for: 100, zones: zones, restingHeartRate: 50, durationSeconds: 10)
        assertTest(lowBand.zone == nil && lowBand.load == 10.0,
            "A rate above resting but below zone 1 (100 bpm on a 190/50 table) credits weight 1.0 "
                + "load with no zone (\(lowBand))")

        let atRest = StrainAccumulatorMath.loadDelta(
            for: 50, zones: zones, restingHeartRate: 50, durationSeconds: 10)
        assertTest(atRest.zone == nil && atRest.load == 0.0,
            "A rate at resting adds no load (\(atRest))")

        let belowRest = StrainAccumulatorMath.loadDelta(
            for: 40, zones: zones, restingHeartRate: 50, durationSeconds: 10)
        assertTest(belowRest.zone == nil && belowRest.load == 0.0,
            "A rate below resting adds no load (\(belowRest))")

        let zone1Floor = StrainAccumulatorMath.loadDelta(
            for: 120, zones: zones, restingHeartRate: 50, durationSeconds: 10)
        assertTest(zone1Floor.zone == .zone1 && zone1Floor.load == 10.0,
            "Zone 1's floor is still zone 1, not the low band (\(zone1Floor))")

        let aboveMax = StrainAccumulatorMath.loadDelta(
            for: 200, zones: zones, restingHeartRate: 50, durationSeconds: 10)
        assertTest(aboveMax.zone == .zone5 && aboveMax.load == 160.0,
            "A rate above maxHR is still scored as zone 5 (\(aboveMax))")
    }
}
