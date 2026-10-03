import Foundation

/// The profile page's state: the facts this app reads off the user, and the write that persists them.
///
/// ## What is on the page, and the rule that changed
///
/// This type used to carry three fields, and its doc comment argued that the mockup's other rows were
/// **left off deliberately** under the repo's no-control-without-a-destination rule: `heightCm`,
/// `birthDate`, `name` and `gender` have no reader in `Sources/`, so collecting them would be a promise
/// the app does not keep.
///
/// **That rule was mis-stated, and this page is where the correction is written down.** The rule the app
/// actually holds is not *collect nothing unread* — it is **do not let the app invent a number and report
/// it back as the user's**. They are different sentences, and the four fields this page now collects are
/// the case that separates them: `178.0 cm`, `"Athlete"` and a birth date *28 years before `now`* were
/// values this app wrote down about the user, and `v20` deleted all three. A height the user types is the
/// opposite of that — the user is the sensor.
///
/// The honest cost, stated rather than buried: **those four fields feed no model.** They are saved and
/// read back onto the form and nothing else in this app consumes them. They are declared facts held, not
/// measurements drawn from.
///
/// | Field | Who reads it | If it is unset |
/// | :--- | :--- | :--- |
/// | weight | `StrainAccumulatorMath.estimateCalories` | every calorie figure is `—` rather than scaled by a body this app invented |
/// | max heart rate | `StrainAccumulatorMath.computeZones`, `Vo2MaxMath.heartRateRatioEstimate` | the zone table is built from the wrong ceiling and the VO₂ estimate from the wrong numerator |
/// | resting heart rate | the same zone table, and `RecoveryScoring`'s cold start | the same, from the other end |
/// | name, birthday, gender, height | **nothing** | nothing — they are held, and that is all |
///
/// ### Why this is a real change and not a formality
///
/// **Nothing has ever written to `user_profiles`.** `saveUserProfile` had no call site before this
/// page — verified by `grep -rn "saveUserProfile" Sources/` — so `GRDBUserProfileRepository.getUserProfile()`
/// has always taken its no-row branch, and every zone table, every VO₂ max estimate and every calorie
/// figure this app has ever drawn came from that branch's two constants. Saving here is what makes
/// them the user's numbers instead. The figures they produce will therefore *move* the first time a
/// real maximum heart rate is entered, which is the change working and not a regression.
///
/// ## The dirty gate is a value, not eight flags
///
/// `private var seeded: ProfileFormSnapshot?` holds the form as `load()` rendered it, and `current` is
/// the same eight boxes as they stand. `hasUnsavedChanges` is their inequality — see
/// `ProfileFormSnapshot` for why the comparison is over **text** and why that is `MetricChange`'s rule
/// rather than a shortcut.
@MainActor @Observable public final class ProfileViewModel {

    // MARK: - The form's eight boxes

    /// The `FIRST NAME` box's draft text. Empty means "not supplied".
    public var nameText = ""

    /// The `BIRTHDAY` control's value, or `nil` when nothing has been chosen.
    ///
    /// **Kept at `startOfDay`** so a picked date compares equal to the stored one it was seeded from; see
    /// `ProfileFormSnapshot`. A `DatePicker` cannot express "no date", so the view draws a dash until this
    /// is non-`nil` rather than showing an invented one — the whole argument for `v20` deleting the
    /// `-28`-year default.
    public var birthday: Date?

    /// The `GENDER` picker's selection, or `nil` when the row has not been answered.
    public var gender: UserProfile.Gender?

    /// The `HEIGHT` box — whole feet under `.imperial`, centimetres under `.metric`.
    public var heightText = ""

    /// The second `HEIGHT` box, inches — empty under `.metric` and under `.imperial` when the user means
    /// a whole number of feet.
    public var inchesText = ""

    /// The `WEIGHT` box's draft text, in the unit on screen. Empty means "no weight supplied", not "zero".
    public var weightText = ""

    /// The maximum-heart-rate field's draft text.
    public var maxHeartRateText = ""

    /// The resting-heart-rate field's draft text.
    public var restingHeartRateText = ""

    // MARK: - State

    /// Whether the stored profile has been read yet, so the form is not drawn over blanks.
    public private(set) var hasLoaded = false

    /// What the last save did, for the form's footer. Empty until the user saves.
    public private(set) var status = ""

    /// Which system the two body boxes are drawn in and parsed in.
    ///
    /// **Resolved once here and passed down as a value**, which is `ActivityRoute.Unit`'s own contract —
    /// *"resolving the unit is the view's job … and the value takes it as an argument so every assertion
    /// can drive both systems explicitly."* The enum lives in `Presentation` and the preference it comes
    /// from lives in `Domain` as a `Bool?`, so there is no layering problem to solve: this is the view
    /// model, which is where the repo already does this resolution.
    public private(set) var unit: ActivityRoute.Unit = ActivityRoute.Unit.forLocale(.current)

    /// The profile as it was read, carried so a save rewrites the whole row.
    ///
    /// `saveUserProfile` is INSERT-or-UPDATE over the whole record rather than a patch, so a save built
    /// from only the edited fields would blank the others. This is the merge's other half — and it is also
    /// what a unit switch re-renders the body boxes from, so a switch can never write a rounded value back.
    private var stored: UserProfile?

    /// The form as `load()` left it — the left-hand side of every dirty comparison.
    private var seeded: ProfileFormSnapshot?

    private let repository: any UserProfileRepository
    private let preferences: any AppPreferencesRepository

    public init(
        repository: any UserProfileRepository,
        preferences: any AppPreferencesRepository
    ) {
        self.repository = repository
        self.preferences = preferences
    }

    // MARK: - Reading

    /// The eight boxes as they stand, which is what `SAVE`'s gate compares.
    public var current: ProfileFormSnapshot {
        ProfileFormSnapshot(
            nameText: nameText,
            birthday: birthday.map { $0.startOfDay },
            gender: gender,
            heightText: heightText,
            inchesText: inchesText,
            weightText: weightText,
            maxHeartRateText: maxHeartRateText,
            restingHeartRateText: restingHeartRateText
        )
    }

    /// Whether anything on the form differs from what is stored.
    ///
    /// **`false` before the row has been read**, deliberately: `hasLoaded` gates the button separately, and
    /// a dirty flag computed against a seed that does not exist yet would light up over a form showing
    /// nothing but the initialiser's blanks.
    public var hasUnsavedChanges: Bool {
        guard let seeded else { return false }
        return current.isDirty(against: seeded)
    }

    public func load() async {
        do {
            let profile = try await repository.getUserProfile()
            let loaded = await preferences.load()
            // `nil` is *nobody has chosen*, not *imperial* — the `—`-not-`0` rule applied to a preference.
            // Falling through to the locale is what makes a fresh install show the system the phone uses,
            // the same answer the activity route card derives, so the two cannot disagree by default.
            unit = loaded.usesMetricUnits.map { $0 ? .metric : .imperial }
                ?? ActivityRoute.Unit.forLocale(.current)
            stored = profile
            seed(from: profile)
            hasLoaded = true
        } catch {
            status = "The profile could not be read."
        }
    }

    // MARK: - The unit toggle

    /// Switches the system the two body boxes are drawn in, persists it, and re-renders them.
    ///
    /// **It persists immediately and is deliberately not part of `hasUnsavedChanges`**, because it is a
    /// preference rather than a fact about the body: it writes `AppPreferences` and `SAVE` writes
    /// `user_profiles`, so the two are two stores with no shared transaction. This is every other
    /// preference toggle in the app's shape.
    ///
    /// ## Which value the boxes are re-rendered from, and why it is two rules and not one
    ///
    /// A box the user **has not touched** is re-rendered from the **stored canonical value**. That is the
    /// load-bearing half: `192.0` lb is `87.0897` kg and prints back as `192.0`, but a stored `87.14` kg
    /// prints as `87.1` and *`87.1` parses back as `87.09`* — so re-rendering from the text on screen would
    /// let two taps on a segmented control write a different body than the form started with, silently,
    /// and `ProfileUnits`' header records that as the property the seed exists to hold. Reading from the
    /// stored value makes the round trip a no-op, so the form comes out of a switch **clean** and no save
    /// is offered.
    ///
    /// A box the user **has typed in** is converted from what they typed, and this half is not an
    /// optimisation either: re-seeding it from the stored value would silently discard the edit — a user
    /// who types a new weight and then notices the unit is wrong would lose the number without being told.
    /// The conversion runs through the same `ProfileUnits` entry point a save uses, so the edit is
    /// interpreted in the unit it was typed in and re-expressed in the new one. If it does not parse at
    /// all, the stored value is the fallback, which is the same answer as the untouched branch.
    public func select(unit newUnit: ActivityRoute.Unit) async {
        guard newUnit != unit, let profile = stored else { return }

        let previousUnit = unit
        let previousSeed = seeded
        unit = newUnit

        // The seed first, so the boxes below are compared against the form as an unedited switch would
        // leave it — which is exactly what `hasUnsavedChanges` has to mean from here on.
        seeded = ProfileFormSnapshot.rendering(profile, in: newUnit)

        let typedWeight = weightText != previousSeed?.weightText
        let typedHeight = heightText != previousSeed?.heightText
            || inchesText != previousSeed?.inchesText

        let weightKg = (typedWeight
            ? ProfileUnits.weightKilograms(from: weightText, in: previousUnit)
            : nil) ?? profile.weightKg
        let heightCm = (typedHeight
            ? ProfileUnits.heightCentimetres(
                fromHeightText: heightText, inchesText: inchesText, in: previousUnit)
            : nil) ?? profile.heightCm

        let height = ProfileUnits.heightTexts(forCentimetres: heightCm, in: newUnit)
        heightText = height.height
        inchesText = height.inches
        weightText = ProfileUnits.weightText(forKilograms: weightKg, in: newUnit)

        var updated = await preferences.load()
        updated.usesMetricUnits = newUnit == .metric
        await preferences.save(updated)
    }

    // MARK: - Writing

    /// Validates the form and writes it.
    ///
    /// **A refused save writes nothing at all**, rather than writing the fields that parsed and leaving
    /// the rest. A half-applied form is the worst of the three outcomes: the user sees an error, the row
    /// changed anyway, and which half moved is not on the screen. It also leaves `hasUnsavedChanges`
    /// `true`, so the button stays live under the sentence explaining the refusal.
    ///
    /// **Blank is an absence for three of the seven fields and a real zero for a fourth**, and the
    /// asymmetry is deliberate: a blank weight, height pair or name is the user saying they have not
    /// supplied one and saves as `nil`, which is what makes each clearable — while a blank *inches* box
    /// beside `5` is `5'0"`, because `5'` and `5'0"` are one height.
    public func save() async {
        guard let stored else {
            status = "The profile has not loaded yet."
            return
        }

        let unit = self.unit

        let weightText = self.weightText
        let weight: Double?
        if weightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            weight = nil
        } else if let parsed = ProfileUnits.weightKilograms(from: weightText, in: unit) {
            weight = parsed
        } else {
            // Printed in the unit the user typed in, which is the one thing `weightRangeLb` exists for.
            // No parser reads it, so it cannot become a second opinion about the same body.
            let band = unit == .imperial ? ProfileUnits.weightRangeLb : ProfileDraft.weightRangeKg
            let suffix = unit == .imperial ? "lb" : "kg"
            status = "Weight must be between "
                + "\(Int(band.lowerBound.rounded())) and "
                + "\(Int(band.upperBound.rounded())) \(suffix)."
            return
        }

        let height: Double?
        if heightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inchesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            height = nil
        } else if let parsed = ProfileUnits.heightCentimetres(
            fromHeightText: heightText, inchesText: inchesText, in: unit) {
            height = parsed
        } else {
            status = unit == .metric
                ? "Height must be between "
                    + "\(Int(ProfileDraft.heightRangeCm.lowerBound)) and "
                    + "\(Int(ProfileDraft.heightRangeCm.upperBound)) cm."
                : "Height must be whole feet with under 12 inches."
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

        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)

        let updated = UserProfile(
            id: stored.id,
            name: name.isEmpty ? nil : name,
            birthDate: birthday.map { $0.startOfDay },
            maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate,
            // **All three of these have no column.** They are carried through so a save does not blank
            // them in the entity that is handed back to the repository, and they are always the
            // entity's own defaults — do not "simplify" them out of the initialiser on that basis.
            baselineHrvRmssd: stored.baselineHrvRmssd,
            baselineRhr: stored.baselineRhr,
            targetSleepHours: stored.targetSleepHours,
            weightKg: weight,
            heightCm: height,
            gender: gender
        )

        do {
            try await repository.saveUserProfile(updated)
            self.stored = updated
            seed(from: updated)
            // Read back into the boxes so an entry that normalised (`"075"`, `"75.00"`, `5'12"`) shows
            // what was actually stored rather than staying on screen looking like it was saved verbatim.
            status = weight == nil
                ? "Saved. Calorie figures stay blank until a weight is entered."
                : "Saved."
        } catch {
            status = "The profile could not be saved."
        }
    }

    // MARK: - Seeding

    /// Renders the form from a profile and records that rendering as the clean state.
    ///
    /// The two lines are one operation: a seed computed anywhere other than from the text actually put in
    /// the boxes would make `hasUnsavedChanges` answer a question about a form nobody is looking at.
    private func seed(from profile: UserProfile) {
        let snapshot = ProfileFormSnapshot.rendering(profile, in: unit)
        nameText = snapshot.nameText
        birthday = snapshot.birthday
        gender = snapshot.gender
        heightText = snapshot.heightText
        inchesText = snapshot.inchesText
        weightText = snapshot.weightText
        maxHeartRateText = snapshot.maxHeartRateText
        restingHeartRateText = snapshot.restingHeartRateText
        seeded = snapshot
    }
}
