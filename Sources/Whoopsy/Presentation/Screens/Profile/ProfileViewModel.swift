import Foundation

/// The profile page's state: the three facts this app reads off the user, and the write that persists
/// them.
///
/// **These three are the ones with a destination**, which is why they are the ones on the page. The
/// rule is the repo's "no control without a destination" — a field that writes a column nothing reads
/// is a promise the app does not keep — and `grep` settles it rather than taste:
///
/// | Field | Who reads it | If it is unset |
/// | :--- | :--- | :--- |
/// | weight | `StrainAccumulatorMath.estimateCalories` | every calorie figure is `—` rather than scaled by a body this app invented |
/// | max heart rate | `StrainAccumulatorMath.computeZones`, `Vo2MaxMath.heartRateRatioEstimate` | the zone table is built from the wrong ceiling and the VO₂ estimate from the wrong numerator |
/// | resting heart rate | the same zone table, and `RecoveryScoring`'s cold start | the same, from the other end |
///
/// `heightCm`, `birthDate`, `name` and `baselineHrvRmssd` have **no reader anywhere in `Sources/`** —
/// `UserProfile.age` included, whose only would-be consumer was `estimateCalories`' dead `age:`
/// parameter and which was deleted with it. They are therefore not on the page, and the omission is
/// the rule rather than an oversight: `UserProfile`'s defaults for them (`178 cm`, a `-28`-year date,
/// `"Athlete"`) are values this app writes down and nothing ever reads.
///
/// ### Why this is a real change and not a formality
///
/// **Nothing has ever written to `user_profiles`.** `saveUserProfile` had no call site before this
/// page — verified by `grep -rn "saveUserProfile" Sources/` — so `GRDBUserProfileRepository.getUserProfile()`
/// has always taken its no-row branch, and every zone table, every VO₂ max estimate and every calorie
/// figure this app has ever drawn came from that branch's two constants. Saving here is what makes
/// them the user's numbers instead. The figures they produce will therefore *move* the first time a
/// real maximum heart rate is entered, which is the change working and not a regression.
@MainActor @Observable public final class ProfileViewModel {

    /// The weight field's draft text. Empty means "no weight supplied", not "zero".
    public var weightText = ""

    /// The maximum-heart-rate field's draft text.
    public var maxHeartRateText = ""

    /// The resting-heart-rate field's draft text.
    public var restingHeartRateText = ""

    /// Whether the stored profile has been read yet, so the form is not drawn over blanks.
    public private(set) var hasLoaded = false

    /// What the last save did, for the form's footer. Empty until the user saves.
    public private(set) var status = ""

    /// The profile as it was read, carried so a save rewrites the whole row.
    ///
    /// `saveUserProfile` is INSERT-or-UPDATE over the whole record rather than a patch, so a save built
    /// from only the edited fields would blank the others. This is the merge's other half.
    private var stored: UserProfile?

    private let repository: any UserProfileRepository

    public init(repository: any UserProfileRepository) {
        self.repository = repository
    }

    public func load() async {
        do {
            let profile = try await repository.getUserProfile()
            stored = profile
            weightText = ProfileDraft.text(forWeightKg: profile.weightKg)
            maxHeartRateText = "\(profile.maxHeartRate)"
            restingHeartRateText = "\(profile.restingHeartRate)"
            hasLoaded = true
        } catch {
            status = "The profile could not be read."
        }
    }

    /// Validates the three fields and writes them.
    ///
    /// **A refused save writes nothing at all**, rather than writing the fields that parsed and leaving
    /// the rest. A half-applied form is the worst of the three outcomes: the user sees an error, the
    /// row changed anyway, and which half moved is not on the screen.
    ///
    /// Weight's absence is not a refusal — an empty weight field is the user saying they have not
    /// supplied one, and it saves as `nil`, which is what makes the field clearable.
    public func save() async {
        guard let stored else {
            status = "The profile has not loaded yet."
            return
        }

        let weightText = self.weightText
        let weight: Double?
        if weightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            weight = nil
        } else if let parsed = ProfileDraft.weight(from: weightText) {
            weight = parsed
        } else {
            status = "Weight must be between "
                + "\(Int(ProfileDraft.weightRangeKg.lowerBound)) and "
                + "\(Int(ProfileDraft.weightRangeKg.upperBound)) kg."
            return
        }

        guard let maxHeartRate = ProfileDraft.heartRate(
            from: maxHeartRateText, in: ProfileDraft.maxHeartRateRange)
        else {
            status = "Maximum heart rate must be between "
                + "\(ProfileDraft.maxHeartRateRange.lowerBound) and "
                + "\(ProfileDraft.maxHeartRateRange.upperBound) bpm."
            return
        }

        guard let restingHeartRate = ProfileDraft.heartRate(
            from: restingHeartRateText, in: ProfileDraft.restingHeartRateRange)
        else {
            status = "Resting heart rate must be between "
                + "\(ProfileDraft.restingHeartRateRange.lowerBound) and "
                + "\(ProfileDraft.restingHeartRateRange.upperBound) bpm."
            return
        }

        // A resting rate at or above the maximum would make `computeZones`' reserve negative and every
        // band boundary meaningless — and `max(20, …)` inside it would hide that rather than refuse it.
        // The two fields are validated against each other because neither's own range can see this.
        guard restingHeartRate < maxHeartRate else {
            status = "Resting heart rate must be below maximum heart rate."
            return
        }

        let updated = UserProfile(
            id: stored.id,
            name: stored.name,
            birthDate: stored.birthDate,
            maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate,
            baselineHrvRmssd: stored.baselineHrvRmssd,
            baselineRhr: stored.baselineRhr,
            targetSleepHours: stored.targetSleepHours,
            weightKg: weight,
            heightCm: stored.heightCm
        )

        do {
            try await repository.saveUserProfile(updated)
            self.stored = updated
            // Read back into the field so an entry that normalised (`"075"`, `"75.00"`) shows what was
            // actually stored rather than staying on screen looking like it was saved verbatim.
            self.weightText = ProfileDraft.text(forWeightKg: weight)
            status = weight == nil
                ? "Saved. Calorie figures stay blank until a weight is entered."
                : "Saved."
        } catch {
            status = "The profile could not be saved."
        }
    }
}
