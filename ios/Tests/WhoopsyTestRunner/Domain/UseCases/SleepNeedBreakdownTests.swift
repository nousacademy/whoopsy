import Foundation
import Whoopsy

enum SleepNeedBreakdownTests {
    static func run() async throws {
        // ── 8. Hours against the need ────────────────────────────────────────────────────────────────
        //
        // The reference's `HOURS VS. NEEDED` card, in the three kinds of thing it is made of: the split's
        // arithmetic, the bar layout that split is drawn on, and the two absences. The card itself is a
        // `View` and this runner has no renderer, which is why `SleepNeedBreakdown` and
        // `SleepNeedBarLayout` are values rather than bodies — exactly as `SleepStageRangeScoring` and
        // `TypicalRangeBarLayout` are for the card above it.
        //
        // The fixtures are the **mockup's own numbers**, so the literals below are the figures a reader
        // can read straight off the reference: 7:33 asleep against a 9:17 need is 81%, and the need's
        // debt is 1:44. Pinning them is what makes this block a check on the card rather than on a
        // fixture nobody has seen.
        //
        // They — the need, the debt and the split the two make — are statics on the section's own
        // `TypicalRangeTests` rather than locals here, because the bar block is built on the same three
        // figures. They began as locals in one `run()` and are now one definition rather than two that
        // could drift; `asleepSeconds` sits there too, read by the bar block alone.
        guard let breakdown = TypicalRangeTests.breakdown
        else {
            assertTest(false, "A night with a stored need and a stored debt produced no breakdown")
            return
        }

        assertTest(
            breakdown.seconds(of: .debt) == TypicalRangeTests.debtSeconds,
            "The debt's part is the stored column **at face value** — the fit over all 910 imported "
                + "nights recovers it as an additive term at coefficient 0.98, so subtracting it is "
                + "recovering WHOOP's own other two terms rather than inventing a third quantity")

        assertTest(
            breakdown.seconds(of: .minimumAndStrain) == TypicalRangeTests.needSeconds - TypicalRangeTests.debtSeconds
                && breakdown.seconds(of: .minimumAndStrain) == TimeInterval(453 * 60),
            "…and the other part is `need − debt`, 7:33 — an arithmetic identity of two stored columns, "
                + "so the two parts sum to the printed total on every night rather than approximately")

        assertTest(
            breakdown.parts.reduce(0) { $0 + $1.seconds } == breakdown.needSeconds,
            "**The identity the card prints**: the box's two figures add up to the need above them, "
                + "which is the check a reader can make on the screen itself")

        assertTest(
            breakdown.parts.count == 2
                && breakdown.parts.map(\.component) == [.minimumAndStrain, .debt],
            "Two rows and not the reference's three: it splits its base term into Healthy Minimum and "
                + "Recent Strain, and no column of this export carries either of them separately")

        assertTest(
            SleepNeedBreakdown.Component.minimumAndStrain.displayName
                == "Healthy Minimum + Recent Strain"
                && SleepNeedBreakdown.Component.debt.displayName == "Sleep Debt",
            "The first row is named for **both** of WHOOP's terms, because it holds both — a row called "
                + "`Healthy Minimum` over a figure that also carries strain would be a mislabelled reading")

        assertTest(
            !SleepNeedBreakdown.Component.minimumAndStrain.isIncrement
                && SleepNeedBreakdown.Component.debt.isIncrement,
            "Only the debt is printed with a leading `+`: the first part is the remainder after the debt "
                + "is taken out, so signing it would claim it was added to something the card does not draw")

        // ── The split's guards, each one a different column state ────────────────────────────────────
        //
        // `0` and `nil` are different answers for the debt and this is the block that says so. A night in
        // perfect sleep credit carries a stored `0` and **does** have a breakdown — the term is present
        // and contributes nothing — while a night whose row was written before `v10` carries `nil` and
        // has none. Reading the second as the first is the fabrication every absence rule here forbids.
        assertTest(
            SleepNeedBreakdown.breakdown(needSeconds: TypicalRangeTests.needSeconds, debtSeconds: 0, hasWhoopNeed: true)
                .map { $0.parts.count == 2 && $0.seconds(of: .debt) == 0
                    && $0.seconds(of: .minimumAndStrain) == TypicalRangeTests.needSeconds } == true,
            "A stored debt of **zero** is an ordinary night in perfect sleep credit, not an absence: the "
                + "breakdown exists and the whole need is the base term")

        assertTest(
            SleepNeedBreakdown.breakdown(needSeconds: TypicalRangeTests.needSeconds, debtSeconds: nil, hasWhoopNeed: true)
                == nil,
            "A row with no debt column — every imported night before `v10` — has **no** breakdown, so the "
                + "card draws its bars and no box rather than a box reading 0:00")

        assertTest(
            SleepNeedBreakdown.breakdown(needSeconds: TypicalRangeTests.needSeconds, debtSeconds: -60, hasWhoopNeed: true)
                == nil,
            "A negative debt is a corrupt row rather than a night in credit, and it is refused rather "
                + "than drawn as a negative segment")

        assertTest(
            SleepNeedBreakdown.breakdown(
                needSeconds: TypicalRangeTests.needSeconds, debtSeconds: TypicalRangeTests.needSeconds + 60, hasWhoopNeed: true) == nil,
            "…and so is a debt larger than the need it is a part of, which would draw a part longer than "
                + "the whole. Unreachable on this export — measured, `need − debt` spans 228…523 min "
                + "across all 910 imported nights — so this is a guard against a future writer, and it is "
                + "asserted rather than left as a claim")

        assertTest(
            SleepNeedBreakdown.breakdown(needSeconds: 0, debtSeconds: 0, hasWhoopNeed: true) == nil,
            "A night with no need has nothing to be a part of, and no bars to draw the parts on")

        // ── The gate, which is why `hasWhoopNeed` is a parameter at all ───────────────────────────────
        //
        // **Every guard above is about the stored pair; this one is about which producer wrote it.** A
        // strap night carries a need and a debt exactly as an imported one does — `AnalyzeSleepUseCase`
        // computes the debt with `SleepDebtMath` and stores it — so `debt != nil` never separated the two
        // producers and the card's box was drawn on strap nights too. It must not be: WHOOP's need is a
        // total containing its debt term, and `SleepNeedMath`'s deliberately omits it (`docs/ALGORITHMS.md`
        // §4), so on a strap night `need − debt` is a base requirement short by the whole deficit, printed
        // under a row named for terms that need never had. The pair below is otherwise perfectly
        // splittable, which is the point — the flag alone is what withholds it.
        assertTest(
            SleepNeedBreakdown.breakdown(
                needSeconds: TypicalRangeTests.needSeconds, debtSeconds: TypicalRangeTests.debtSeconds, hasWhoopNeed: false) == nil,
            "A need this app computed carries **no** breakdown however ordinary its debt looks: the debt "
                + "is not a term of that need, so `Healthy Minimum + Recent Strain` over `need − debt` "
                + "would understate the base requirement by the deficit and add the deficit back")

    }
}
