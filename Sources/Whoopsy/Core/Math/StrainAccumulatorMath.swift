import Foundation

/// Non-linear Borg-scale cardiovascular Strain integrator (0.0 to 21.0 scale).
public enum StrainAccumulatorMath {
    /// Calibrated scaling constant for the 21.0 exponential curve
    public static let strainScalingFactor: Double = 0.000045

    /// Computes Heart Rate Zone boundaries using the Karvonen formula.
    public static func computeZones(maxHR: Int, restHR: Int) -> [HeartRateZone] {
        let hrr = Double(max(20, maxHR - restHR))
        let rest = Double(restHR)

        return [
            HeartRateZone(
                index: .zone1,
                lowerBpm: Int((rest + hrr * 0.50).rounded()),
                upperBpm: Int((rest + hrr * 0.60).rounded())
            ),
            HeartRateZone(
                index: .zone2,
                lowerBpm: Int((rest + hrr * 0.60).rounded()),
                upperBpm: Int((rest + hrr * 0.70).rounded())
            ),
            HeartRateZone(
                index: .zone3,
                lowerBpm: Int((rest + hrr * 0.70).rounded()),
                upperBpm: Int((rest + hrr * 0.80).rounded())
            ),
            HeartRateZone(
                index: .zone4,
                lowerBpm: Int((rest + hrr * 0.80).rounded()),
                upperBpm: Int((rest + hrr * 0.90).rounded())
            ),
            HeartRateZone(
                index: .zone5,
                lowerBpm: Int((rest + hrr * 0.90).rounded()),
                upperBpm: maxHR
            )
        ]
    }

    /// Converts accumulated weighted seconds load into a 0.0 - 21.0 strain score.
    public static func calculateStrainScore(from accumulatedLoad: Double) -> Double {
        guard accumulatedLoad > 0 else { return 0.0 }
        let rawScore = 21.0 * (1.0 - exp(-strainScalingFactor * accumulatedLoad))
        return (rawScore * 10.0).rounded() / 10.0
    }

    /// Calculates load addition for a given heart rate sustained for `durationSeconds`.
    public static func loadDelta(for bpm: Int, zones: [HeartRateZone], durationSeconds: TimeInterval) -> (zone: HeartRateZoneIndex?, load: Double) {
        for zone in zones {
            if bpm >= zone.lowerBpm && bpm <= zone.upperBpm {
                let load = zone.index.strainWeight * durationSeconds
                return (zone.index, load)
            }
        }
        if let maxZone = zones.last, bpm > maxZone.upperBpm {
            return (.zone5, HeartRateZoneIndex.zone5.strainWeight * durationSeconds)
        }
        return (nil, 0.0)
    }

    /// Estimates active calorie expenditure from HR, duration, age, and weight.
    public static func estimateCalories(
        heartRate: Int,
        durationMinutes: Double,
        age: Int,
        weightKg: Double,
        restingHR: Int
    ) -> Double {
        guard heartRate > restingHR else { return 0.0 }
        // Keytel et al. HR calorie equation (kJ to kcal: / 4.184)
        let vo2Rate = (Double(heartRate) - Double(restingHR)) * 0.014 * weightKg
        let kcalPerMinute = max(0.5, vo2Rate * 0.07)
        return kcalPerMinute * durationMinutes
    }
}
