import Foundation

/// Non-linear Borg-scale cardiovascular Strain integrator (0.0 to 21.0 scale).
public enum StrainAccumulatorMath {
    /// Calibrated scaling constant for the 21.0 exponential curve
    public static let strainScalingFactor: Double = 0.000045

    /// The heart-rate-**reserve** fraction each zone spans, in `HeartRateZoneIndex` order.
    ///
    /// **This is the one definition of the five bands.** `computeZones` builds its bpm boundaries from
    /// this array rather than from five inline pairs, and the live session screen labels its band row
    /// (`50-59%` … `90-100%`) from the same array — so a band edge cannot be moved in one place and
    /// left behind in the other, which is the drift `WholePercentMath` and this repo's other
    /// extractions exist to prevent. `docs/ALGORITHMS.md` §2 is the third reader and carries the same five
    /// pairs as prose; change all three together.
    ///
    /// The percentages are of **heart rate reserve** (`maxHR − restHR`), which is why they are not
    /// percentages of `maxHR`: zone 1 starts at 50% of the reserve above resting, not at 50% of 190.
    /// See `docs/ALGORITHMS.md` §2 for why this grid is this app's substitution rather than WHOOP's own
    /// boundaries — WHOOP's filings describe the user's anaerobic and creatine-phosphate thresholds,
    /// which no consumer strap reports.
    public static let zoneReserveFractions: [(lower: Double, upper: Double)] = [
        (0.50, 0.60),
        (0.60, 0.70),
        (0.70, 0.80),
        (0.80, 0.90),
        (0.90, 1.00),
    ]

    /// The same five bands as the live session screen prints them — `50-59%` … `90-100%`.
    ///
    /// **Derived from `zoneReserveFractions` rather than written beside it**, so an edge that moves
    /// moves its label and the two cannot describe different bands. It lives here rather than in the
    /// screen's `body` for `WholePercentMath`'s reason: a display rule written into a `View` is a rule
    /// the test runner — which has no renderer — cannot assert.
    ///
    /// The top of each band prints as `upper − 1` because the percentages name a **half-open**
    /// interval: `50-59%` is 50% up to but not including 60%, and printing `50-60%` beside `60-69%`
    /// would show 60 in two bands. The last band is the exception, and it is not an inconsistency —
    /// its ceiling *is* the reserve, which is `maxHR`, so nothing lies above it to exclude and it
    /// closes at `100%` rather than at `99%`.
    public static let zoneReserveBandLabels: [String] = zoneReserveFractions.map { band in
        let lower = Int((band.lower * 100).rounded())
        let upper = band.upper >= 1.0 ? 100 : Int((band.upper * 100).rounded()) - 1
        return "\(lower)-\(upper)%"
    }

    /// Where a heart rate sits on the five-band reserve scale, as a `0…1` fraction of the scale's
    /// width.
    ///
    /// **The scale is the five bands laid end to end**, which is what makes its two ends zone 1's own
    /// floor and zone 5's ceiling — and both are read off the zone table rather than recomputed from
    /// `zoneReserveFractions`, so a profile whose reserve falls under `computeZones`'s 20 bpm floor
    /// places its mark on the same scale its bands were drawn against. A second derivation here is the
    /// drift this type's other extractions exist to prevent.
    ///
    /// **The clamp is the ordinary case and not an edge.** A heart rate at rest is below zone 1's
    /// floor by construction, so a worn strap at rest draws its mark at the scale's left edge; the
    /// right edge is `maxHR`. The figure printed above the bar is the reading — this is only where on
    /// the scale it falls.
    ///
    /// `0` is returned for a table that cannot define a scale, which is unreachable through
    /// `computeZones` (it always produces five bands over a non-zero reserve) and is here so a caller
    /// cannot divide by the zero.
    public static func bandScalePosition(forHeartRate bpm: Int, zones: [HeartRateZone]) -> Double {
        guard
            let first = zones.first,
            let last = zones.last,
            last.upperBpm > first.lowerBpm
        else { return 0 }

        let span = Double(last.upperBpm - first.lowerBpm)
        return min(1.0, max(0.0, Double(bpm - first.lowerBpm) / span))
    }

    /// Computes Heart Rate Zone boundaries using the Karvonen formula.
    public static func computeZones(maxHR: Int, restHR: Int) -> [HeartRateZone] {
        let hrr = Double(max(20, maxHR - restHR))
        let rest = Double(restHR)

        return zip(HeartRateZoneIndex.allCases, zoneReserveFractions).map { index, band in
            HeartRateZone(
                index: index,
                lowerBpm: Int((rest + hrr * band.lower).rounded()),
                // Zone 5's ceiling is `maxHR` itself rather than `rest + hrr × 1.00`. The two are the
                // same number except when `maxHR − restHR` falls under the 20 bpm floor above, where
                // the reserve is widened and `rest + 20` overshoots the maximum. Kept as a special case
                // so the floor cannot move the top band's edge.
                upperBpm: index == .zone5 ? maxHR : Int((rest + hrr * band.upper).rounded())
            )
        }
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

    /// Estimates active calorie expenditure from heart rate, duration and body weight.
    ///
    /// **This is this app's own approximation and not a published equation.** It was previously
    /// labelled a *"Keytel et al. HR calorie equation (kJ to kcal: / 4.184)"*, and none of that was
    /// true of the body: no Keytel coefficient appeared in it and the stated `÷ 4.184` conversion never
    /// happened. The arithmetic is an oxygen-uptake-delta heuristic — a heart rate above resting,
    /// scaled by `0.014` mL·kg⁻¹·beat⁻¹ and a `0.07` kcal-per-minute factor — and the real Keytel
    /// regressions are sex-specific and take both age and weight, which this app has no basis for
    /// choosing between. Calling it Keytel made an unvalidated constant read as a citation, which is
    /// why `docs/ALGORITHMS.md` now carries a calorie section stating what the formula actually is.
    ///
    /// **Returns `nil` when no weight has been supplied**, rather than substituting one. The figure is
    /// reported to the user as their own expenditure, so a defaulted body weight would be an invented
    /// measurement about them — the same fabrication class as a dash drawn as a zero. The weight comes
    /// from `UserProfile.weightKg`, which the profile page fills in and `user_profiles.weightKg` stores
    /// as of `v16`; until the user supplies one, every calorie figure in this app is correctly absent.
    ///
    /// **A `0.0` here is a real reading, not an absence.** At or below resting heart rate the session
    /// accrued no *active* calories, which is a measurement the strap can genuinely produce — the
    /// caller distinguishes it from the `nil` above.
    ///
    /// The `max(0.5, …)` floor is deliberate and its premise is that a session only exists while the
    /// strap is being worn: a worn strap at rest is still a body, so the resting metabolic term is real
    /// rather than a fabricated minimum.
    public static func estimateCalories(
        heartRate: Int,
        durationMinutes: Double,
        weightKg: Double?,
        restingHR: Int
    ) -> Double? {
        guard let weightKg else { return nil }
        guard heartRate > restingHR else { return 0.0 }
        let vo2Rate = (Double(heartRate) - Double(restingHR)) * 0.014 * weightKg
        let kcalPerMinute = max(0.5, vo2Rate * 0.07)
        return kcalPerMinute * durationMinutes
    }
}
