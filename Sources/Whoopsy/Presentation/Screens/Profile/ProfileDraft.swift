import Foundation

/// The profile form's parsing and its bounds, as pure functions.
///
/// It is a separate type rather than three `static` members on `ProfileViewModel` for the reason
/// `DayBarRules` and `MonthGrid` are separate from the views that draw them: this is the rule that
/// keeps a mistyped body weight out of a reported calorie figure, and a rule written inside a
/// `@MainActor @Observable` view model is a rule the test runner has to build a main-actor object to
/// reach. Here it is three free functions over `String`, so `§18` drives them directly.
///
/// **A blank field is an absence, not an error.** An empty weight parses to `nil`, which is what
/// clears it — the repository's own documentation says a `nil` weight is a real value rather than
/// "leave the old one alone", because a save that quietly preserved it would make the field
/// unclearable. Out-of-range text is refused with a message instead, which is the different case:
/// `20 kg` parses and `2 kg` does not, and neither is the same as saying nothing.
///
/// The bounds are wide on purpose. They are not a judgement about bodies — they are the range outside
/// which the input is a typo, and the cost of admitting one is a calorie figure multiplied by a body
/// that does not exist. A weight of `400 kg` is not a plausible maximum so much as the point past
/// which a decimal separator has clearly gone missing.
public enum ProfileDraft {

    /// The plausible band for a body weight in kilograms.
    public static let weightRangeKg: ClosedRange<Double> = 20...400

    /// The plausible band for a maximum heart rate.
    ///
    /// Known human maxima run to about 220 and the age-predicted formulas never leave 150–210, so this
    /// is a typo guard rather than a physiological claim.
    public static let maxHeartRateRange: ClosedRange<Int> = 100...250

    /// The plausible band for a resting heart rate.
    ///
    /// Its floor is below any real resting rate precisely because it should not be: a value under 30 is
    /// an ellipsis, not a measurement, and the Karvonen zones this feeds are built from it.
    public static let restingHeartRateRange: ClosedRange<Int> = 30...120

    /// A blank field is `nil`; a number inside `weightRangeKg` is itself; anything else is `nil`.
    ///
    /// Trims before parsing, because a `TextField` bound to a `String` hands over whatever was typed
    /// and a trailing space is not an error a user can see.
    public static func weight(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `Double("75,5")` is `nil`, which is correct here: this app's locale-agnostic entry expects a
        // period, and a comma would otherwise be silently dropped rather than refused.
        guard let value = Double(trimmed), weightRangeKg.contains(value) else { return nil }
        return value
    }

    /// A blank field is `nil`; an integer inside `range` is itself; anything else is `nil`.
    public static func heartRate(from text: String, in range: ClosedRange<Int>) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), range.contains(value) else { return nil }
        return value
    }

    /// The text a weight field starts with — `""` when nothing has been supplied.
    ///
    /// One decimal place, through the app's own convention rather than `"\(weightKg)"`, which prints a
    /// bare `75.0` for a round number and `62.5` for the halves while `Double`'s own description would
    /// print `75.0` and `62.5` too but `62.49999999999999` for a value that arrived from a sum. The
    /// field shows the number the app will store, to the precision it stores it at.
    public static func text(forWeightKg weightKg: Double?) -> String {
        weightKg.map { $0.formattedOneDecimal() } ?? ""
    }
}
