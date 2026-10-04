import Foundation
import Whoopsy

enum BaselineStatisticsMathTests {
    static func run() async throws {
        // ── 1. The percentile ────────────────────────────────────────────────────────────────────────
        //
        // Pinned against literals rather than against a second implementation, and the literals are
        // reproducible outside this codebase: the definition is R's `quantile(type = 7)` and NumPy's
        // default, so a changed interpolation method fails here instead of agreeing with itself.
        assertTest(
            TypicalRangeTests.near(BaselineStatisticsMath.percentile([1, 2, 3, 4], at: 0.25) ?? .nan, 1.75),
            "p25 of 1…4 is 1.75 — linear interpolation at position 0.75 between the 1st and 2nd")
        assertTest(
            TypicalRangeTests.near(BaselineStatisticsMath.percentile([1, 2, 3, 4], at: 0.5) ?? .nan, 2.5),
            "…p50 is 2.5, the midpoint the interpolated form and the median agree on")
        assertTest(
            TypicalRangeTests.near(BaselineStatisticsMath.percentile([1, 2, 3, 4], at: 0.75) ?? .nan, 3.25),
            "…and p75 is 3.25 — 0.25 of the way from the 3rd to the 4th, not a third of the way")

        // The two ends are the order statistics themselves, which is what makes a one-night window
        // degenerate rather than wrong.
        assertTest(
            BaselineStatisticsMath.percentile([4, 1, 3, 2], at: 0) == 1
                && BaselineStatisticsMath.percentile([4, 1, 3, 2], at: 1) == 4,
            "p0 is the minimum and p100 the maximum, whatever order the caller handed them in")

        // The degenerate inputs. n=1 returns itself at every fraction — the count floor at the call site
        // is what stops a single night becoming its own typical range, not this function.
        assertTest(
            BaselineStatisticsMath.percentile([7], at: 0.25) == 7
                && BaselineStatisticsMath.percentile([7], at: 0.9) == 7,
            "One observation is its own percentile at every fraction")
        assertTest(
            TypicalRangeTests.near(BaselineStatisticsMath.percentile([10, 20], at: 0.25) ?? .nan, 12.5)
                && TypicalRangeTests.near(BaselineStatisticsMath.percentile([10, 20], at: 0.75) ?? .nan, 17.5),
            "Two observations interpolate at a quarter and three quarters of their gap")

        // `nil`, and never `0`: a percentile of nothing is not zero, and a zero here would draw a 0–0%
        // typical range on a night whose window held nothing.
        assertTest(
            BaselineStatisticsMath.percentile([], at: 0.5) == nil,
            "An empty window has no percentile — `nil` rather than a `0` that would draw as a range")
        assertTest(
            BaselineStatisticsMath.percentile([1, 2, .nan, 3], at: 0.25).map { TypicalRangeTests.near($0, 1.5) } == true,
            "A NaN is dropped rather than sorted, so the interpolation runs over the three real values "
                + "and p25 is 1.5")
        assertTest(
            BaselineStatisticsMath.percentile([1, 2, 3], at: .nan) == nil,
            "A non-finite fraction is `nil` — the guard that keeps a NaN from poisoning every comparison")

        // The caller's array is the caller's. Sorting in place would reorder a history a caller still
        // needs in its own order — which the repository reads are, oldest-first.
        let unsorted = [4.0, 1.0, 3.0, 2.0]
        _ = BaselineStatisticsMath.percentile(unsorted, at: 0.5)
        assertTest(
            unsorted == [4, 1, 3, 2],
            "…and the array handed in is not reordered — the sort is on a copy")

    }
}
