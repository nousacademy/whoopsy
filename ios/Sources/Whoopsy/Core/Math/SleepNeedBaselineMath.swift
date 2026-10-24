import Foundation

/// The age bands that contextualise a night's Sleep Need baseline.
///
/// **The baseline itself is learned from the person's own prior nights** —
/// `personalBaselineSeconds(for:age:)` — and this table is population context, not the answer. It
/// supplies the cold-start value before seven prior nights exist, a floor below the learned value,
/// and a ceiling above it. `SleepNeedMath` owns the fitted strain coefficient and takes the baseline
/// as an argument; this type is the only place that answers where that baseline comes from.
///
/// The bands are the National Sleep Foundation's 2015 consensus recommendation, still the reference
/// range used by WHOOP's own public guidance:
///
/// | Age | Recommendation | Cold-start midpoint |
/// | :--- | :--- | ---: |
/// | under 18 | 8–10 h (teens 14–17) | 9.0 h |
/// | 18–64 | 7–9 h | 8.0 h |
/// | 65+ | 7–8 h | 7.5 h |
///
/// Each point value is the **midpoint** of its band, and an absent age returns the adult midpoint.
/// The 65+ row is the one that moves the cold-start number: a 7.5-hour baseline is a population
/// statement about older adults, not a claim about a particular one. Once the person has a history,
/// their own stored needs decide, and the band only stops the learned value leaving the population
/// range.
///
/// `UserProfile.age` clamps at 14, so the under-18 arm is effectively 14–17.
public enum SleepNeedBaselineMath {

    /// One prior night as the personal-baseline estimator needs it.
    ///
    /// `needSeconds` is the night's stored need and `previousDayStrain` is the Strain of the cycle
    /// that preceded it, the same lag `SleepNeedMath` uses. A night with no strain row is not used:
    /// its need is the bare baseline, but this estimator cannot tell that from a night whose strain
    /// was simply unmeasured.
    public struct NeedNight: Equatable, Sendable {
        public let needSeconds: TimeInterval
        public let previousDayStrain: Double?

        public init(needSeconds: TimeInterval, previousDayStrain: Double?) {
            self.needSeconds = needSeconds
            self.previousDayStrain = previousDayStrain
        }
    }

    /// How many prior nights the personal baseline needs before it is trusted.
    ///
    /// Seven is the same cold-start floor `SleepNeedMath`'s debt neighbour and NOOP's personal-need
    /// estimator use: a mean over three nights is a fact about three nights, not a baseline.
    public static let personalMinimumNights = 7

    /// How many of the most recent prior nights the median is taken over.
    ///
    /// Twenty-eight is one circadian month and the window the export's need fit was validated over;
    /// a wider window blurs a genuine change in baseline, a narrower one lets a hard week move it.
    public static let personalWindowNights = 28

    /// The most a personal baseline may reach, in hours.
    public static let maximumPersonalHours = 9.5

    /// How far back the caller reads `sleeps` and `strains` to find the personal window.
    ///
    /// Six months rather than fifty-six days, because 28 **nights** can span a long recording gap and
    /// the personal baseline is a trait rather than a nightly value: a two-month break should not
    /// silently reset the learner to the age band. The debt model keeps its own 30-day read by
    /// narrowing the same result — one query, two windows.
    public static let baselineHistoryLookbackDays = 180

    /// The last age that takes the adolescent band.
    public static let adolescentMaxAge = 17

    /// The first age that takes the older-adult band.
    public static let olderAdultMinAge = 65

    /// The under-18 midpoint: teens are recommended 8–10 h.
    public static let adolescentHours = 9.0

    /// The 18–64 midpoint: adults are recommended 7–9 h.
    public static let adultHours = 8.0

    /// The 65+ midpoint: older adults are recommended 7–8 h.
    public static let olderAdultHours = 7.5

    /// The baseline, in hours, for an age in whole years.
    ///
    /// - Parameter age: The user's age, or `nil` when no birth date has been supplied.
    /// - Returns: 9.0 below 18, 7.5 at 65 and over, and 8.0 otherwise — including `nil`.
    public static func baselineHours(forAge age: Int?) -> Double {
        guard let age else { return adultHours }
        if age <= adolescentMaxAge { return adolescentHours }
        if age >= olderAdultMinAge { return olderAdultHours }
        return adultHours
    }

    /// The baseline in seconds, which is what `SleepNeedMath.sleepNeedSeconds` takes.
    public static func baselineSeconds(forAge age: Int?) -> TimeInterval {
        baselineHours(forAge: age) * 3600
    }

    /// The recommendation band behind `baselineHours(forAge:)`, for a caller that wants to print the
    /// range rather than its midpoint.
    ///
    /// The `nil` age returns the adult band rather than `nil`, because `baselineHours(forAge: nil)`
    /// already returns the adult midpoint; a band that disagreed with the point value would be two
    /// answers to one question.
    public static func bandHours(forAge age: Int?) -> ClosedRange<Double> {
        guard let age else { return 7.0 ... 9.0 }
        if age <= adolescentMaxAge { return 8.0 ... 10.0 }
        if age >= olderAdultMinAge { return 7.0 ... 8.0 }
        return 7.0 ... 9.0
    }

    /// The baseline learned from this person's own prior nights, with age as population context only.
    ///
    /// **The estimator inverts the need model rather than learning from achieved sleep.** Each prior
    /// night that carries a strain row implies a baseline of
    /// `need − clamp(strain, 0…21) × 6.40 min`; the median of those implied baselines over the last
    /// `personalWindowNights` (28) is the personal baseline. The median is robust to a single hard
    /// week, and it is taken over **stored needs**, not over the hours actually slept: a chronic
    /// under-sleeper's achieved sleep is below their need, and learning from it would erase the very
    /// deficit the need exists to express. That is the self-referential trap the debt model already
    /// documents, applied to the baseline.
    ///
    /// Age is context here, not the answer. The age band supplies three things and nothing else:
    ///
    /// - the **cold-start value**, `baselineSeconds(forAge:)`, until `personalMinimumNights` (7)
    ///   prior nights with a strain row exist;
    /// - a **floor**, the band's lower bound (7 h for adults and older adults, 8 h for teens), so a
    ///   run of short measured needs cannot drag a personal baseline below the population minimum;
    /// - a **cap**, `maximumPersonalHours` (9.5 h), so a corrupt implied baseline cannot become the
    ///   target.
    ///
    /// Calibrated over the bundled export's 902 nights that carry a preceding strain day and at
    /// least seven prior nights: the median-of-28 estimator has **MAE 24.89 min** against WHOOP's
    /// own `Sleep need (min)`, where the fixed 8-hour baseline scores **26.74**. The learned
    /// baseline averages 479.9 min — the population midpoint is where this person's own history
    /// lands, which is the expected result and not a reason to keep the constant: a different
    /// history is free to move.
    ///
    /// - Parameter nights: Prior nights, oldest first. The most recent `personalWindowNights` are
    ///   used; the caller should exclude the night being scored.
    /// - Parameter age: The user's age, or `nil`; used only for the cold-start value and the floor.
    public static func personalBaselineSeconds(
        for nights: [NeedNight],
        age: Int?
    ) -> TimeInterval {
        let recent = nights.suffix(personalWindowNights)
        let implied = recent.compactMap { night -> Double? in
            guard night.needSeconds > 0, night.needSeconds.isFinite else { return nil }
            guard let strain = night.previousDayStrain, strain.isFinite else { return nil }
            let bounded = max(0, min(SleepNeedMath.maximumStrain, strain))
            let baseline = night.needSeconds
                - bounded * SleepNeedMath.strainMinutesPerPoint * 60
            guard baseline > 0, baseline.isFinite else { return nil }
            return baseline
        }

        guard implied.count >= personalMinimumNights,
            let median = BaselineStatisticsMath.percentile(implied, at: 0.5)
        else {
            return baselineSeconds(forAge: age)
        }

        let floor = bandHours(forAge: age).lowerBound * 3600
        let cap = maximumPersonalHours * 3600
        return min(cap, max(floor, median))
    }
}
