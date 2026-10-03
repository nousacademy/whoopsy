import Foundation

/// The profile form's unit conversions, as pure functions — `ProfileDraft`'s sibling, for its reason.
///
/// **This is the only place in the app where a unit is converted.** Nothing else here has ever needed
/// to: every stored figure is canonical, and the one unit decision the app made before this —
/// `ActivityRoute.Unit` — only chooses a *label* to print over a distance that is already in metres.
/// The profile form is different, because `WEIGHT` and `HEIGHT` are typed in by a person in whatever
/// system they think in, so the canonical value arrives second and something has to do the arithmetic.
///
/// ## The bug this file exists to not ship
///
/// `ProfileDraft.weightRangeKg` is `20...400` — **in kilograms**. If an imperial entry is validated
/// before it is converted, `192` is accepted as **192 kg**: inside the range, so nothing refuses it,
/// the form saves, and `StrainAccumulatorMath.estimateCalories` scales a calorie figure by a body nearly
/// twice the user's. It passes every check the app currently has, on a screen with no error on it.
///
/// The fix is a guard's *position* and nothing else: `weightKilograms(from:in:)` converts first and
/// checks the band against the canonical kilograms. Assertion 5 in §18 is the case that separates the
/// two orders — `30` lb is 13.6 kg and is refused **only** because the band was applied after the
/// multiplication, since both orders accept `192`.
///
/// ## The canonical value is never rounded; only the printed text is
///
/// `178.0` cm draws as `5'10.1"` and parses back as `178.054` cm. That is half a display step, it is
/// the same property `ProfileDraft.text(forWeightKg:)` already has, and it is stated rather than hidden
/// — an `==` round trip in the other direction would be a claim this arithmetic cannot support. What
/// keeps it from ever being *written* is the form's dirty gate: re-seeding the boxes from the stored
/// value when the unit changes produces text identical to the text already in them, so the form stays
/// clean and no save is offered. See `ProfileFormSnapshot`.
///
/// ## `ActivityRoute.Unit` is the vocabulary, and there is no second enum
///
/// It is already `Sendable`, already has `forLocale(_:)`, and its own doc comment states the rule this
/// feature honours: *"Resolving the unit is the view's job … and the value takes it as an argument so
/// every assertion can drive both systems explicitly."* The preference behind it is a `Bool?` in
/// `Domain` and the enum is in `Presentation`, which is not a layering problem to solve: the resolution
/// happens in the view model, and the value takes the answer as a parameter.
public enum ProfileUnits {

    /// The international avoirdupois pound, exactly, as the 1959 agreement fixes it.
    ///
    /// Written to its full nine digits rather than as the `0.4536` a reader half-remembers, because the
    /// round trip assertion is an *inverse* test: `pounds(fromKilograms:)` divides by this same
    /// constant, so the two are exact inverses by construction, and any shorter literal or any
    /// independently-written `2.20462` would break that and fail.
    public static let kilogramsPerPound = 0.45359237

    /// The international inch, exactly — the same 1959 agreement, one twelfth of a foot.
    public static let centimetresPerInch = 2.54

    /// Twelve, and named rather than inlined for the same reason the other two are: it is a *definition*
    /// of the foot, and `5'13"` being refused is only expressible if the inch band knows what a foot is.
    public static let inchesPerFoot = 12.0

    /// `ProfileDraft.weightRangeKg` restated in pounds.
    ///
    /// **Derived and never written down**, so the app has one weight band rather than two that agree
    /// today. Its only job is to let an error message print in the unit the user typed — no parser reads
    /// it, which is the whole point: a second band would be a second opinion about the same body.
    public static var weightRangeLb: ClosedRange<Double> {
        (ProfileDraft.weightRangeKg.lowerBound / kilogramsPerPound)
            ... (ProfileDraft.weightRangeKg.upperBound / kilogramsPerPound)
    }

    // MARK: - The two conversions, and their exactness

    /// Pounds to kilograms, exactly.
    public static func kilograms(fromPounds pounds: Double) -> Double {
        pounds * kilogramsPerPound
    }

    /// Kilograms to pounds — the exact inverse of the line above, because it divides by the same
    /// constant rather than multiplying by a rounded `2.20462`.
    public static func pounds(fromKilograms kilograms: Double) -> Double {
        kilograms / kilogramsPerPound
    }

    /// Feet and inches to centimetres.
    ///
    /// Takes the two parts separately rather than a single decimal foot, because `6.2` ft is `6'2.4"`
    /// and no single numeric box can say `6' 2"` — which is the user's own reason for the two-box form.
    public static func centimetres(fromFeet feet: Double, inches: Double) -> Double {
        (feet * inchesPerFoot + inches) * centimetresPerInch
    }

    /// Centimetres to whole feet and a fractional remainder of inches.
    ///
    /// **Truncated feet, not rounded**, so the remainder is never negative and never reads `-0.4"`. The
    /// remainder is what the inches box shows and it carries a decimal place, which is what makes the
    /// round trip exact for every height on the display grid.
    public static func feetInches(fromCentimetres centimetres: Double) -> (feet: Int, inches: Double) {
        let totalInches = centimetres / centimetresPerInch
        let feet = (totalInches / inchesPerFoot).rounded(.down)
        return (Int(feet), totalInches - feet * inchesPerFoot)
    }

    // MARK: - Entry: what the user typed, in the system they typed it in

    /// The weight a `WEIGHT` box holds, as canonical kilograms, or `nil` for a blank or implausible one.
    ///
    /// **The metric path delegates to `ProfileDraft.weight`** rather than re-implementing the trimming,
    /// the comma refusal and the band beside it: two copies of that rule would be free to drift, and
    /// `ProfileDraft` is where it is argued. The imperial path is the one that has to exist here, and it
    /// is written so that the only difference between the two branches is the multiplication.
    ///
    /// Trims before parsing for `ProfileDraft`'s reason: a `TextField` bound to a `String` hands over
    /// whatever was typed, and a trailing space is not an error a user can see.
    public static func weightKilograms(from text: String, in unit: ActivityRoute.Unit) -> Double? {
        guard unit == .imperial else { return ProfileDraft.weight(from: text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let entered = Double(trimmed) else { return nil }
        let kilograms = kilograms(fromPounds: entered)
        // **The band is checked on the converted value and the position of this guard is the fix.**
        // Checking `entered` instead is the bug in this file's header, and it is invisible: both orders
        // accept every figure a user is likely to type.
        guard ProfileDraft.weightRangeKg.contains(kilograms) else { return nil }
        return kilograms
    }

    /// The height two boxes hold, as canonical centimetres, or `nil` for a blank or implausible pair.
    ///
    /// **The two boxes are not the same kind of field, and this is the asymmetry to keep.** A blank
    /// inches box is a real `0` — `5'` and `5'0"` are one height, and refusing the shorter spelling
    /// would be refusing a way of writing a number this app already stores — while a blank *feet* box
    /// is an absence, because there is no height that one box alone describes. That is deliberately
    /// unlike the weight field, where blank is an absence and `0` is not a value at all.
    ///
    /// **Inches at or above twelve are refused rather than carried into the feet box.** Carrying looks
    /// friendlier and rewrites a field the user did not type in — and it is not caught by the canonical
    /// band either: `5'13"` is 198.12 cm, comfortably inside `60...250`, so this per-field test is the
    /// only thing standing between the form and a height six inches wrong.
    ///
    /// Under `.metric` the form draws one box holding centimetres, and `inchesText` is empty because
    /// there is no second box to type in. It is a parameter rather than a second function so the two
    /// systems share one entry point, one band and one absence rule.
    public static func heightCentimetres(
        fromHeightText heightText: String,
        inchesText: String,
        in unit: ActivityRoute.Unit
    ) -> Double? {
        switch unit {
        case .metric:
            let trimmed = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let centimetres = Double(trimmed) else { return nil }
            guard ProfileDraft.heightRangeCm.contains(centimetres) else { return nil }
            return centimetres

        case .imperial:
            let feetText = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
            let inchesField = inchesText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feetText.isEmpty, let feet = Double(feetText), feet >= 0 else { return nil }

            let inches: Double
            if inchesField.isEmpty {
                inches = 0
            } else {
                guard let parsed = Double(inchesField), parsed >= 0, parsed < inchesPerFoot else { return nil }
                inches = parsed
            }

            let centimetres = centimetres(fromFeet: feet, inches: inches)
            guard ProfileDraft.heightRangeCm.contains(centimetres) else { return nil }
            return centimetres
        }
    }

    // MARK: - Drawing: what the boxes start with

    /// The weight box's text for a stored value, in the unit on screen.
    ///
    /// One decimal place through the app's own formatter, so the field shows the number the app would
    /// store, to the precision it stores it at — `ProfileDraft.text(forWeightKg:)`'s rule, with the
    /// conversion in front of it. The metric branch forwards to that function rather than repeating it.
    public static func weightText(forKilograms kilograms: Double?, in unit: ActivityRoute.Unit) -> String {
        guard let kilograms else { return "" }
        guard unit == .imperial else { return ProfileDraft.text(forWeightKg: kilograms) }
        return pounds(fromKilograms: kilograms).formattedOneDecimal()
    }

    /// The height boxes' text for a stored value, in the unit on screen.
    ///
    /// Under `.metric` the pair is `(centimetres, "")` — the second box is not drawn, and an empty
    /// string is what a box that is not drawn holds. Under `.imperial` it is whole feet and the inches
    /// remainder, each a string the same parser above will accept back.
    public static func heightTexts(
        forCentimetres centimetres: Double?,
        in unit: ActivityRoute.Unit
    ) -> (height: String, inches: String) {
        guard let centimetres else { return ("", "") }
        guard unit == .imperial else { return (centimetres.formattedOneDecimal(), "") }
        let parts = feetInches(fromCentimetres: centimetres)
        return ("\(parts.feet)", parts.inches.formattedOneDecimal())
    }
}
