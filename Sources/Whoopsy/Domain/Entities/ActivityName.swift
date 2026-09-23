import Foundation

/// When two activity names are the same name.
///
/// `WorkoutSession.activityName` is a **label**, not a measurement, and it arrives from a file with no
/// vocabulary behind it: `workouts.csv` writes `Basketball`, `Yoga` and WHOOP's own abstention word
/// `Activity`, and nothing constrains its casing or its surrounding whitespace. Two sessions are the
/// same activity when their names agree after trimming and lowercasing, and this is the one place that
/// rule is written down.
///
/// **It has two readers and they must not disagree.** `ActivityBaseline.window(for:in:)` groups a
/// session with its own history by this rule, and `ActivityGlyph.symbol(for:)` keys its SF Symbol table
/// by it — so a table that folded case while the window did not would draw one glyph for a set of
/// sessions the page had already decided were two different activities. `ActivityGlyph` forwards here
/// rather than carrying its own copy for exactly that reason.
///
/// It lives in `Domain/Entities/` rather than beside either reader because `ActivityGlyph` is a
/// presentation type (Domain imports only `Foundation` and cannot know an SF Symbol) while the window is
/// a scoring rule, and the normalisation is neither: it is a fact about the string WHOOP writes.
public enum ActivityName {

    /// The name as it is compared, or `nil` when there is no name to compare.
    ///
    /// `nil` in and `nil` out, and `""` — or a cell holding only spaces — normalises to `nil` as well:
    /// an absent name and a blank one are the same absence, and treating the blank as a distinct key
    /// would give a file's stray empty cell an activity of its own.
    ///
    /// The fold is `lowercased()` and not `folding(options: .caseInsensitive)`, deliberately: this is
    /// the comparison the glyph table has always made, and a locale-sensitive fold would move the
    /// matching for a Turkish dotless `i` — a change to a shipped mapping that nothing on screen would
    /// announce.
    public static func normalised(_ name: String?) -> String? {
        guard let key = name?.trimmingCharacters(in: .whitespaces).lowercased(), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Whether two names denote the same activity.
    ///
    /// **Two absent names match each other**, and that is the rule applied rather than an oversight: a
    /// session written before `v15` carries no name at all, and every one of those is an uncategorised
    /// activity in exactly the way WHOOP's own `Activity` rows are — so they form one group, on the same
    /// terms as any other name. A caller wanting "named activities only" filters on the optional, which
    /// is the distinction that actually exists.
    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        normalised(lhs) == normalised(rhs)
    }
}
