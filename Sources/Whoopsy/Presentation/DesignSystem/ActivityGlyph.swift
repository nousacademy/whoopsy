import Foundation

/// The glyph an activity's own name draws in the `ACTIVITIES` card's leading chip, named so it can be
/// asserted.
///
/// It lives here rather than inline in `HomeDashboardView`'s body for `DayBarRules`' reason: the test
/// runner has no renderer, and **a wrong SF Symbol name is not an error** — it draws an empty chip, so
/// a typo in this table is invisible to the compiler, invisible in a screenshot of a different row, and
/// only caught by an assertion over the names the file actually holds. §17 drives every one.
///
/// **The input is a name, not a workout.** `WorkoutSession` is a Domain type and Domain imports only
/// `Foundation`, so it cannot know an SF Symbol; the mapping from a producer's string to a drawing is
/// the presentation layer's, exactly as `SleepStageType.color` and `RecoveryState.color` are.
///
/// **Every symbol below is iOS 13–16, and that is a constraint rather than an accident.** The
/// deployment target is 17.0, and SF Symbols has since added `figure.ice.skating`, `figure.indoor.rowing`
/// and `figure.indoor.soccer` — all iOS 18, all of which would draw nothing on this build. `Ice Skating`
/// therefore takes `figure.skating`, which has meant the same thing since iOS 16.
public enum ActivityGlyph {

    /// The fallback's symbol, and the one the card drew for **every** workout before this table
    /// existed. That is the point of choosing it: a name this table does not hold renders exactly as it
    /// did, so an unrecognised activity is a missing nicety rather than a regression.
    public static let fallback = "figure.run"

    /// The name → symbol table, keyed by the lowercased and trimmed name.
    ///
    /// The 21 keys are `workouts.csv`'s own distinct `Activity name` values — measured, 673 of 673 rows
    /// non-empty — and between them they cover 464 of the file's 673 rows. `Activity` (197 rows) and
    /// `Other` (11) are deliberately **not** here and take the fallback: WHOOP's two words for an
    /// activity it did not categorise are not activities, and giving them a glyph of their own would
    /// claim a distinction the file does not make.
    private static let symbols: [String: String] = [
        "walking": "figure.walk",
        "yoga": "figure.yoga",
        "dance": "figure.dance",
        "basketball": "figure.basketball",
        "manual labor": "hammer.fill",
        "hiking": "figure.hiking",
        "american football": "figure.american.football",
        "mountain biking": "figure.outdoor.cycle",
        "running": "figure.run",
        // SF Symbols has no trampoline; gymnastics is the nearest named movement, and it is a
        // nearest-neighbour rather than the sport.
        "trampoline": "figure.gymnastics",
        "martial arts": "figure.martial.arts",
        "tennis": "figure.tennis",
        "soccer": "figure.soccer",
        "swimming": "figure.pool.swim",
        "boxing": "figure.boxing",
        "volleyball": "figure.volleyball",
        // `figure.ice.skating` is iOS 18 and the target is 17.0 — see the type comment.
        "ice skating": "figure.skating",
        "yard work/gardening": "leaf.fill",
    ]

    /// The symbol for `name`, or `fallback` when there is none to draw.
    ///
    /// `nil` is the ordinary case rather than an error path: it is every session this app recorded
    /// itself and every row written before `v15`. `Paintball` is the one name in the bundled file with
    /// no entry, and it takes the fallback like any other.
    ///
    /// Matched lowercased and trimmed so a future export that changes the casing of a name — or pads a
    /// cell — still lands, which is the one normalisation this table can make without guessing.
    ///
    /// **The normalisation is `ActivityName.normalised`, not a copy of it.** The activity detail page
    /// groups a session with its own history by that same rule, so a fold written twice here would let
    /// the page decide two sessions were different activities while this table drew them the same
    /// glyph — or the reverse. The forwarding direction is Presentation → Domain, which is the one this
    /// app's dependency rule allows.
    public static func symbol(for name: String?) -> String {
        guard let key = ActivityName.normalised(name) else { return fallback }
        return symbols[key] ?? fallback
    }
}
