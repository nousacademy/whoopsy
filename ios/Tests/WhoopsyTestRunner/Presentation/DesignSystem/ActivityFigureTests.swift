import Foundation
import Whoopsy

// MARK: - 20. The two figures a session prints

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.
enum ActivityFigureTests {
    static func run() async throws {
        // MARK: - C. The two figures a session prints

        let fast = ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 16 * 3600 + 40 * 60)
        let measured = ZeroFastingImportTests.session("Basketball", strain: 5.2, durationSeconds: 3600)
        let zeroStrain = ZeroFastingImportTests.session("Basketball", strain: 0.0, durationSeconds: 3600)

        assertTest(
            ActivityFigure.strainText(for: fast) == "—",
            "A session with no strain prints the dash on the activity detail page's `ACTIVITY STRAIN` cell "
                + "— and `nil` is the only input that reaches it, since `v18` is what made the column "
                + "nullable (got \(ActivityFigure.strainText(for: fast)))")
        assertTest(
            ActivityFigure.strainText(for: zeroStrain) == "0.0",
            "…while a **measured** `0.0` prints `0.0` and not the dash. The two are different answers and "
                + "collapsing them is the fabrication: `LiveSessionAccumulator` produces exactly `0.0` for "
                + "a session it watched that never left zone 1, so a reader that dashed it would hide a "
                + "real reading (got \(ActivityFigure.strainText(for: zeroStrain)))")
        assertTest(
            ActivityFigure.strainText(for: measured) == "5.2",
            "…and an ordinary strain prints to one decimal, which is the formatter every other figure on "
                + "that page uses (got \(ActivityFigure.strainText(for: measured)))")

        assertTest(
            ActivityFigure.headlineText(for: fast) == "16:40",
            "Home's headline for a fast is the session's **own length** — `formattedCompactHoursMinutes`, "
                + "the same formatter the `SLEEP` row above it uses, so a fast and a night read as the "
                + "same kind of quantity under the same kind of word (got "
                + "\(ActivityFigure.headlineText(for: fast)))")
        assertTest(
            ActivityFigure.headlineText(for: measured) == "5.2",
            "…and for a session something measured it is the strain, unchanged from before `v18`, so this "
                + "type moved no figure that already had a producer (got "
                + "\(ActivityFigure.headlineText(for: measured)))")
        assertTest(
            ActivityFigure.headlineText(for: ZeroFastingImportTests.session("Fast", strain: 7.4)) == "7.4",
            "**The gate is the data and not the label.** A session *named* `Fast` that carries a strain "
                + "prints the strain, because what decides this figure is whether a sensor measured "
                + "something rather than what the session is called — the regression most likely to be "
                + "introduced here, since a name-keyed rule reads as the obvious simplification and lies "
                + "the first time an activity is both (got "
                + "\(ActivityFigure.headlineText(for: ZeroFastingImportTests.session("Fast", strain: 7.4))))")
        assertTest(
            ActivityFigure.headlineText(for: ZeroFastingImportTests.session("Activity", strain: nil, durationSeconds: 90)) == "0:01",
            "…and an unmeasured session of under a minute still prints a figure rather than a dash, which "
                + "is why this rule has no dash branch: a `WorkoutSession` always has a span (got "
                + "\(ActivityFigure.headlineText(for: ZeroFastingImportTests.session("Activity", strain: nil, durationSeconds: 90))))")
    }
}
