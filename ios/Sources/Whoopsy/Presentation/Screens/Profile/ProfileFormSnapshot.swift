import Foundation

/// The BIOMETRICS form's eight boxes, as one value — which is what makes `SAVE`'s gate a comparison rather than
/// eight `@State` copies of "was this touched".
///
/// It is `ProfileUnits`' and `ProfileDraft`'s sibling, and it exists for their stated reason: the runner
/// has no renderer, so a rule written into a `body` is a rule nothing can assert. "Is this form dirty" is
/// the rule behind the mockup's greyed `SAVE`, and here it is a value the suite drives directly.
///
/// ## It holds text and nothing else
///
/// **No unit, no canonical number, no `UserProfile`.** The fields are the characters in the boxes, which
/// is the whole of the evidence the reader has — `MetricChange`'s rule, applied to a form: two figures
/// that print alike *are* the same as far as the screen is concerned, so typing `75` over a seeded `75.0`
/// is a change the button must see. Holding canonical values here would make the comparison an equality
/// between two parsed `Double`s and would let a difference the user cannot see — a half-display-step
/// rounding, a normalised `"075"` — leave `SAVE` dark over a form that looks edited.
///
/// The unit is deliberately absent for a second reason: it is a **preference**, and switching it is not a
/// change to the body. Re-rendering both boxes from the stored canonical value produces text identical to
/// what is already in them, so a unit switch leaves this equal to the seed and `SAVE` stays dark — which
/// is the property `ProfileUnits`' header records as the thing keeping display rounding out of storage.
///
/// ## The birthday is held at `startOfDay`
///
/// A `DatePicker` hands back an instant carrying the current clock time, and a stored birth date read back
/// carries a different one, so a picked-then-unpicked birthday would compare unequal to itself. It is
/// `ActivityEditDraft`'s minute-write guard one resolution coarser, and here it is not an optimisation but
/// the difference between the form working and `SAVE` being permanently live.
///
/// **A `nil` birthday is a real state**, not a zero: it is a field nobody has filled in, and the form has
/// to be able to tell that from one the user set. What it must never become is a fabricated date — see
/// `UserProfile.birthDate` for the default `v20` deleted.
public struct ProfileFormSnapshot: Equatable, Sendable {

    /// The `FIRST NAME` box.
    public var nameText: String

    /// The `BIRTHDAY` control's value, at `startOfDay`, or `nil` when nothing has been chosen.
    public var birthday: Date?

    /// The `GENDER` picker's selection, or `nil`.
    public var gender: UserProfile.Gender?

    /// The `HEIGHT` box — whole feet under `.imperial`, centimetres under `.metric`.
    ///
    /// **One slot for two quantities, and the name says so.** It is not `feetText`: under `.metric` this
    /// holds `177.8`, and a member called `feet` holding a centimetre count is the "a name that lies about
    /// a quantity" fault this repo records against `Point.bpm` under the hours-of-sleep chart. The unit in
    /// force is what says which quantity is in it, and `ProfileUnits.heightCentimetres(fromHeightText:…)`
    /// is the only reader that has to care.
    public var heightText: String

    /// The second `HEIGHT` box — inches under `.imperial`, and **empty under `.metric`**, where there is no
    /// second box to type in.
    public var inchesText: String

    /// The `WEIGHT` box, in whichever unit is on screen.
    public var weightText: String

    /// The `MAX HEART RATE` box.
    public var maxHeartRateText: String

    /// The `RESTING HEART RATE` box.
    public var restingHeartRateText: String

    public init(
        nameText: String,
        birthday: Date? = nil,
        gender: UserProfile.Gender? = nil,
        heightText: String,
        inchesText: String,
        weightText: String,
        maxHeartRateText: String,
        restingHeartRateText: String
    ) {
        self.nameText = nameText
        self.birthday = birthday
        self.gender = gender
        self.heightText = heightText
        self.inchesText = inchesText
        self.weightText = weightText
        self.maxHeartRateText = maxHeartRateText
        self.restingHeartRateText = restingHeartRateText
    }

    /// The form as it stands for a stored profile, in the unit on screen.
    ///
    /// **This is the seed, and the view model calls it from exactly two places**: `load()`, and the unit
    /// toggle. That single constructor *is* the unit-switch rule — there is no second spelling of "what
    /// this profile looks like in metric" for the two call sites to drift apart on.
    ///
    /// It reads through `ProfileUnits` for both body fields rather than formatting them here, so the
    /// conversion, the band and the one-decimal display rule stay in one file.
    public static func rendering(_ profile: UserProfile, in unit: ActivityRoute.Unit) -> ProfileFormSnapshot {
        let height = ProfileUnits.heightTexts(forCentimetres: profile.heightCm, in: unit)
        return ProfileFormSnapshot(
            nameText: profile.name ?? "",
            birthday: profile.birthDate.map { $0.startOfDay },
            gender: profile.gender,
            heightText: height.height,
            inchesText: height.inches,
            weightText: ProfileUnits.weightText(forKilograms: profile.weightKg, in: unit),
            maxHeartRateText: "\(profile.maxHeartRate)",
            restingHeartRateText: "\(profile.restingHeartRate)"
        )
    }

    /// Whether the form has moved from the state it was seeded in.
    ///
    /// The `SAVE` button's gate, and nothing else reads it. A refused save leaves this `true`, which is
    /// the point: the status sentence needs a form that is still live to explain itself against.
    public func isDirty(against seeded: ProfileFormSnapshot) -> Bool {
        self != seeded
    }
}
