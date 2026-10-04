import Foundation
import Whoopsy

enum SleepNeedBarTests {
    static func run() async throws {
        // ── The two bars, on one scale ───────────────────────────────────────────────────────────────
        //
        // The mockup's own night — 7:33 asleep against a 9:17 need — and the split of it the segments
        // are drawn from. All four live on the section's own `TypicalRangeTests`, because the split's
        // arithmetic above is built on the same figures. The guard is kept here rather than folded into
        // the statics so that a night which stopped producing a split fails loudly: an empty `parts`
        // still yields a layout with the right two fractions, so the assertion below would pass with
        // the thing it is about having gone.
        guard let breakdown = TypicalRangeTests.breakdown else {
            assertTest(false, "The mockup's own night produced no breakdown to draw the segments from")
            return
        }

        assertTest(
            SleepNeedBarLayout(
                asleepSeconds: TypicalRangeTests.asleepSeconds,
                needSeconds: TypicalRangeTests.needSeconds, parts: breakdown.parts)
                .map { abs($0.asleepFraction - 27180.0 / 33420.0) < 0.000001 && $0.needFraction == 1 }
                == true,
            "The sleep bar spans `asleep ÷ need` of the need bar, which is the ratio the card heads "
                + "itself with — so the picture cannot contradict the 81% printed above it")

        assertTest(
            SleepNeedBarLayout(
                asleepSeconds: 453 * 60, needSeconds: TypicalRangeTests.needSeconds, parts: breakdown.parts
            ).map { $0.asleepFraction * 100 } .map { abs($0 - 81.33) < 0.01 } == true,
            "…and that ratio is the unrounded one, 81.33% against the `81` the entity prints — the bar is "
                + "not drawn to the rounded integer, which would step in whole percent")

        if let layout = SleepNeedBarLayout(
            asleepSeconds: TypicalRangeTests.asleepSeconds, needSeconds: TypicalRangeTests.needSeconds, parts: breakdown.parts) {
            assertTest(
                layout.segments.count == 2
                    && layout.segments.first?.startFraction == 0
                    && layout.segments.last?.endFraction == layout.needFraction,
                "The segments are contiguous from the track's left edge to the need bar's own end — a "
                    + "hairline of track showing between two abutting parts would read as a third part")

            assertTest(
                abs((layout.segments.first?.endFraction ?? 0)
                    - (layout.segments.last?.startFraction ?? 1)) < 0.000001,
                "…and each part ends exactly where the next begins, so the two cannot overlap by a "
                    + "rounding error and draw one figure twice")

            assertTest(
                abs((layout.segments.last?.widthFraction ?? 0) - 6240.0 / 33420.0) < 0.000001,
                "The debt's width is its share of the need, 1:44 of 9:17 — the split is on the need's own "
                    + "scale and not on an arbitrary fraction of the track")
        } else {
            assertTest(false, "The mockup's own night produced no bar layout")
        }

        // The over-sleep case. Fifteen of the export's nights carry more stage time than need, and on
        // those the **need** bar is the short one. Drawing them equal would say the night exactly met its
        // need, which is the one thing it did not do.
        assertTest(
            SleepNeedBarLayout(asleepSeconds: 10 * 3600, needSeconds: 8 * 3600)
                .map { $0.asleepFraction == 1 && abs($0.needFraction - 0.8) < 0.000001 } == true,
            "A night that overslept its need draws the sleep bar full and the need bar short, rather than "
                + "clamping both to the same length")

        // No split, no segments — and still a layout, which is the whole reason `parts` defaults to `[]`.
        // The bars are answerable for any night with a need in it, whether or not its composition is.
        assertTest(
            SleepNeedBarLayout(asleepSeconds: TypicalRangeTests.asleepSeconds, needSeconds: TypicalRangeTests.needSeconds)
                .map { $0.segments.isEmpty && $0.needFraction == 1 } == true,
            "A night whose row supports no split still gets a layout — with no segments — so a missing "
                + "breakdown cannot take the two bars down with it")

        assertTest(
            SleepNeedBarLayout(asleepSeconds: TypicalRangeTests.asleepSeconds, needSeconds: 0) == nil,
            "A non-positive need has no track to draw on, and a caller with no layout draws no card "
                + "rather than an empty one")

        assertTest(
            SleepNeedBarLayout(
                asleepSeconds: TypicalRangeTests.asleepSeconds,
                needSeconds: TypicalRangeTests.needSeconds,
                parts: [SleepNeedBreakdown.Part(component: .debt, seconds: -1)]) == nil,
            "A negative part is refused at the layout too, so a corrupt split cannot draw a bar running "
                + "backwards off the left edge of the track")

    }
}
