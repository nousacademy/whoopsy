import Foundation

/// Fat-free mass estimated from height, weight and sex — the only way this app can supply one of the
/// nine healthspan inputs without a body-composition scale.
///
/// **It is a regression, not a measurement, and the app treats it as three regressions rather than
/// one.** Boer (1984), Hume (1966) and James (1976) are all still in use for clinical dosing, and they
/// disagree with each other by several kilograms on the same person — 80 kg at 180 cm is 61.4 kg by
/// Boer, 57.8 by Hume and 62.7 by James. Publishing the median of the three with its range is the
/// honest form of that disagreement; picking one and printing it bare would claim a precision none of
/// them has.
///
/// **The error is systematic at the extremes.** These regressions assume an average body composition
/// for a given height and weight, so they overestimate fat-free mass in someone carrying a lot of fat
/// and underestimate it in a heavily muscled or very lean person. The published standard error is of
/// the order of 4–6 kg, which is why the estimate is never drawn as a bare number.
///
/// **Sex is its own two-case enum and not the profile's `Gender`.** `Core` imports only `Foundation`
/// and cannot name a `Domain` type; more importantly the mapping is a decision the caller has to make
/// deliberately — this type only accepts `male` and `female`, so a profile that says neither cannot
/// reach it by accident.
public enum LeanBodyMassMath {

    /// The two sexes these regressions were fitted on.
    public enum Sex: Sendable {
        case male
        case female
    }

    /// One estimate: a median and the range the three formulas span.
    public struct Estimate: Equatable, Sendable {
        /// The middle of the three formulas' answers, in kilograms.
        public let medianKg: Double
        /// The lowest of the three, in kilograms.
        public let lowKg: Double
        /// The highest of the three, in kilograms.
        public let highKg: Double
        /// How many formulas produced a usable answer — `3` unless one was refused by a gate.
        public let formulaCount: Int

        /// The spread the formulas disagree over, in kilograms.
        public var spreadKg: Double { highKg - lowKg }
    }

    /// Plausible body inputs. Outside these the regressions are extrapolating past their data.
    public static let weightRangeKg: ClosedRange<Double> = 25...250
    public static let heightRangeCm: ClosedRange<Double> = 120...220

    /// The fraction of body weight fat-free mass must fall between. Below 30 % is a body that cannot
    /// stand; above 85 % is a body with almost no fat, which the formulas reach only when their inputs
    /// have left the range they were fitted on.
    public static let plausibleFraction: ClosedRange<Double> = 0.30...0.85

    /// Estimates fat-free mass from the three published formulas, or `nil` when the inputs are missing
    /// or implausible.
    ///
    /// - Parameters:
    ///   - weightKg: body weight in kilograms.
    ///   - heightCm: standing height in centimetres.
    ///   - sex: the sex the regressions were fitted on.
    public static func estimate(
        weightKg: Double?,
        heightCm: Double?,
        sex: Sex?
    ) -> Estimate? {
        guard
            let weightKg, let heightCm, let sex,
            weightRangeKg.contains(weightKg),
            heightRangeCm.contains(heightCm)
        else { return nil }

        let candidates: [Double]
        switch sex {
        case .male:
            candidates = [
                // Boer (1984).
                0.407 * weightKg + 0.267 * heightCm - 19.2,
                // Hume (1966).
                0.32810 * weightKg + 0.33929 * heightCm - 29.5336,
                // James (1976).
                1.1 * weightKg - 128 * pow(weightKg / heightCm, 2),
            ]
        case .female:
            candidates = [
                // Boer (1984).
                0.252 * weightKg + 0.473 * heightCm - 48.3,
                // Hume (1966).
                0.29569 * weightKg + 0.41813 * heightCm - 43.2933,
                // James (1976).
                1.07 * weightKg - 148 * pow(weightKg / heightCm, 2),
            ]
        }

        let usable = candidates
            .filter { $0.isFinite }
            .filter { plausibleFraction.contains($0 / weightKg) }
            .sorted()
        guard !usable.isEmpty else { return nil }

        return Estimate(
            medianKg: usable[usable.count / 2],
            lowKg: usable[0],
            highKg: usable[usable.count - 1],
            formulaCount: usable.count)
    }
}
