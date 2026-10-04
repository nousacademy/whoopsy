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

        let zeroStrain = StrainAccumulatorMath.calculateStrainScore(from: 0.0)
        assertTest(zeroStrain == 0.0, "0 accumulated load yields 0.0 strain")

        let modStrain = StrainAccumulatorMath.calculateStrainScore(from: 50_000.0)
        assertTest(modStrain >= 10.0 && modStrain <= 20.0, "Moderate load produces expected strain (\(modStrain))")

        let extremeStrain = StrainAccumulatorMath.calculateStrainScore(from: 1_000_000.0)
        assertTest(extremeStrain <= 21.0 && extremeStrain >= 20.9, "Extreme load caps at 21.0 scale ceiling (\(extremeStrain))")
    }
}
