import Foundation

/// Shares of a total, in whole percent, **summing to exactly 100**.
///
/// **The rule is largest remainder** — each share takes its floor, and the seats left over go to the
/// largest fractional parts — and it exists because these figures are printed *beside the total they
/// are shares of*, so a column that summed to 99 or 101 would contradict itself on screen. That is not
/// a corner: the export stores whole minutes, so the exact shares land on fractions more often than
/// not. The eight-hour night this app used to fabricate — `4.2 / 1.8 / 1.6 / 0.4` hours, rows of
/// which are still in `sleeps` — is `52.5 / 22.5 / 20 / 5`, which naive rounding prints as
/// `53 + 23 + 20 + 5 = 101`.
///
/// It lives in `Core` rather than on either card's own scoring type because **two cards now print a
/// column of shares against a printed total** — the sleep screen's typical range, whose four stages
/// divide the night, and its stress card, whose three bands divide the scored span. One rule with two
/// callers, rather than the same arithmetic written twice and drifting.
///
/// Ties break by position, so the result is reproducible rather than dependent on how a dictionary or
/// a sort happened to order equal remainders. The two properties a caller may rely on, and both are
/// asserted: every percent is within one of its exact share, and they sum to exactly 100 whenever the
/// total is positive.
public enum WholePercentMath {
    /// Whole percents for a set of shares, or `nil` when there is no total to divide by.
    ///
    /// `nil` — not a row of zeroes — for an empty input, for any negative or non-finite share, and for
    /// a total of zero. A caller with nothing to divide has no shares, and a `0%` row would be a claim
    /// about a span that was never scored.
    ///
    /// The input is durations rather than fractions so callers need not divide first and lose the
    /// remainder they are about to be ranked by; any positive-scaled quantity works, since only the
    /// ratios matter.
    public static func wholePercents(ofSeconds seconds: [TimeInterval]) -> [Int]? {
        guard !seconds.isEmpty, seconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let total = seconds.reduce(0, +)
        guard total > 0 else { return nil }

        let exact = seconds.map { $0 / total * 100 }
        var whole = exact.map { Int($0.rounded(.down)) }

        // Every share lost at most one to its floor, so what is missing is at most one per row.
        let unallocated = 100 - whole.reduce(0, +)
        guard unallocated > 0 else { return whole }

        let byRemainder = exact.indices.sorted { left, right in
            let leftRemainder = exact[left] - Double(whole[left])
            let rightRemainder = exact[right] - Double(whole[right])
            if leftRemainder != rightRemainder { return leftRemainder > rightRemainder }
            return left < right
        }
        for index in byRemainder.prefix(unallocated) { whole[index] += 1 }
        return whole
    }
}
