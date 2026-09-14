import Foundation

/// One night's stage split, each stage read against what is typical for this user.
///
/// It is the sleep detail screen's **typical-range card** in value form: four rows of
/// *tonight's share* over the band that share is normally in, plus the two stages WHOOP calls
/// restorative summed and read against their own mean. `RecoveryScoring` is the same shape one
/// quantity over — a pure scoring helper rather than a use case, holding the arithmetic a screen
/// would otherwise have to spell out for itself.
///
/// **Every threshold here is this app's own, because WHOOP publishes no stage boundaries at all.**
/// The window and the count floor are the two exceptions, and both are *reused* rather than restated:
/// `RecoveryScoring.baselineWindowDays` and `RecoveryScoring.minimumBaselineDays`, the same pair the
/// Recovery screen's baselines are built from, so the two screens cannot come to disagree about how
/// much history a baseline needs. The band's shape — the middle 50% of prior nights — follows WHOOP's
/// published *comparison* for REM (its charts quote a mean with a 25th–75th percentile range) and its
/// boundaries are ours. This is the same bargain `SleepBand`, `SleepNeedMath` and `StressMath` each
/// document: a figure this app computes will not match the WHOOP app's on the same night.
public enum SleepStageRangeScoring {

    /// The order the card draws its rows in, which is `SleepStageType`'s own declaration order.
    ///
    /// Read from `allCases` rather than written out, on `SleepBandBar`'s reasoning: a fifth stage
    /// added to the enum should appear on this card without anyone remembering to come back here, and
    /// a hand-written list would drop it silently. The coincidence that the declarations happen to be
    /// in the reference's order is not what the order is resting on.
    public static var stages: [SleepStageType] { SleepStageType.allCases }

    /// The band's ends, as fractions — the middle half of prior nights, which is the comparison WHOOP
    /// publishes for a stage's duration. Named rather than inlined so the suite can pin the definition
    /// the card is drawn from, and so a reader can see that this is a *quartile* band and not the
    /// mean ± something.
    public static let lowerPercentile = 0.25
    public static let upperPercentile = 0.75

    /// The band one stage's share normally sits in, in **percentage points of the night**.
    ///
    /// The unit is percentage points and not minutes, and that is forced rather than chosen: the
    /// card's bar is drawn on a 0–100% scale so that the four rows are comparable with each other,
    /// which means the band drawn on that bar has to be on the same scale. WHOOP quotes its own REM
    /// middle-50% in minutes; a reader comparing the two figures should expect a different unit and
    /// not a bug.
    public struct Typical: Equatable, Sendable {
        /// The 25th percentile. Never greater than `highPercent`.
        public let lowPercent: Double
        /// The 75th percentile.
        public let highPercent: Double

        public init(lowPercent: Double, highPercent: Double) {
            self.lowPercent = lowPercent
            self.highPercent = highPercent
        }
    }

    /// One stage: what it was tonight, and what is normal for it.
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { stage.rawValue }

        public let stage: SleepStageType

        /// Tonight's own duration in this stage.
        public let seconds: TimeInterval

        /// Tonight's share of the sleep period, as a whole percent. The four rows sum to exactly 100.
        public let percent: Int

        /// The band, or `nil` when the window was too thin to produce one. `nil` means *not measured*,
        /// which is why the card draws no markers rather than markers at zero.
        public let typical: Typical?

        public init(stage: SleepStageType, seconds: TimeInterval, percent: Int, typical: Typical?) {
            self.stage = stage
            self.seconds = seconds
            self.percent = percent
            self.typical = typical
        }
    }

    /// The card's whole content.
    ///
    /// **One condition, three carriers.** `nightCount == 0` ⟺ every `row.typical == nil` ⟺
    /// `typicalRestorativeSeconds == nil`. They are the same fact — the window held fewer than
    /// `minimumBaselineDays` usable nights — seen from three places, and the equivalence is asserted
    /// rather than assumed so a fourth carrier cannot be added without one of them disagreeing.
    public struct Summary: Equatable, Sendable {
        /// In `stages` order.
        public let rows: [Row]

        /// How many nights the bands were taken over — the *usable* ones, so a stored row with no
        /// sleep period is not counted. `0` when no band could be produced.
        public let nightCount: Int

        /// The window's mean restorative sleep (deep + REM), or `nil` below the count floor.
        ///
        /// **A mean and not a band**, which is why the card's footer row carries a number and no bar.
        /// Restorative sleep is a *sum of two stages*, so its quartiles would be a band of a sum
        /// drawn on the same 0–100% scale as four bands of shares — a different quantity on a
        /// different denominator, and a second kind of mark on one card is how a reader comes to
        /// compare two things that are not comparable.
        public let typicalRestorativeSeconds: TimeInterval?

        /// Tonight's own restorative sleep — `SleepSession.restorativeSleepSeconds`, carried rather
        /// than re-summed by the card.
        ///
        /// **It is the entity's own property and not a sum of the rows above**, even though the two are
        /// equal on every night: the definition of which stages are restorative is a fact about the
        /// stages, and a card filtering `rows` for `.deep` and `.rem` would be the second place that
        /// fact is written down. It is a stored property rather than a `Summary` computed one for the
        /// same reason — the `session` is in hand where this is built and nowhere afterwards.
        public let restorativeSeconds: TimeInterval

        public init(
            rows: [Row],
            nightCount: Int,
            restorativeSeconds: TimeInterval,
            typicalRestorativeSeconds: TimeInterval?
        ) {
            self.rows = rows
            self.nightCount = nightCount
            self.restorativeSeconds = restorativeSeconds
            self.typicalRestorativeSeconds = typicalRestorativeSeconds
        }

        /// The card's `DURATION` figure: the four rows added up.
        ///
        /// **Written as the sum of the rows rather than as the session's own property**, because that
        /// identity is the thing the card asserts on screen — the figure printed at the top right is
        /// the total the four durations beneath it are shares of, and a reader adding the column up
        /// must reach it. The two are equal by construction (`sleepPeriodSeconds` is the same four
        /// fields), so this is not a second answer to a question the entity already answers; it is the
        /// one the card draws, stated where the card can be held to it.
        public var durationSeconds: TimeInterval { rows.reduce(0) { $0 + $1.seconds } }
    }

    /// One night against the nights before it, or `nil` when there is no night to describe.
    ///
    /// `nil` in exactly one case: a session whose sleep period is zero, so there is no share to take
    /// and four `0%` rows would be a picture of a night rather than the absence of one. The card is
    /// then not drawn at all — not drawn empty, and not drawn full of dashes — which is the rule the
    /// Stress chart follows when it has no windows.
    ///
    /// **`priorNights` is trusted to be the window and is not re-filtered by date.** Windowing is
    /// `RecoveryScoring.baselineWindow(before:in:)` at the caller, exactly as `RecoveryScoring.baselines`
    /// trusts its own `history` — one definition of "the window", shared with the screen that prints
    /// the same baselines. The only filter applied here is the one this type owns: a night with no
    /// sleep period cannot contribute a share, so counting it would both manufacture a baseline out of
    /// nights that have none and drag the restorative mean toward zero.
    public static func summary(for session: SleepSession, priorNights: [SleepSession]) -> Summary? {
        let durations = stages.map { session.seconds(of: $0) }
        guard let percents = wholePercents(ofSeconds: durations) else { return nil }

        let window = priorNights.filter { $0.sleepPeriodSeconds > 0 }
        let bands = typicalBands(in: window)

        let rows = zip(stages, durations).enumerated().map { index, pair in
            Row(
                stage: pair.0,
                seconds: pair.1,
                percent: percents[index],
                typical: bands[pair.0])
        }

        return Summary(
            rows: rows,
            nightCount: bands.isEmpty ? 0 : window.count,
            restorativeSeconds: session.restorativeSleepSeconds,
            typicalRestorativeSeconds: bands.isEmpty
                ? nil
                : BaselineStatisticsMath.mean(window.map(\.restorativeSleepSeconds)))
    }

    /// Whole percents for a set of durations, **summing to exactly 100**, or `nil` when there is no
    /// total to divide by.
    ///
    /// **The rule is largest remainder** — each share takes its floor, and the seats left over go to
    /// the largest fractional parts — and it exists because the card prints the four percentages
    /// *and* the total they are shares of, so a column that summed to 99 or 101 would contradict
    /// itself on screen. That is not a corner: the export stores whole minutes, so the exact shares
    /// land on fractions more often than not. The eight-hour night this app used to fabricate —
    /// `4.2 / 1.8 / 1.6 / 0.4` hours, rows of which are still in `sleeps` — is `52.5 / 22.5 / 20 / 5`,
    /// which naive rounding prints as `53 + 23 + 20 + 5 = 101`.
    ///
    /// Ties break by position, so the result is reproducible rather than dependent on how a
    /// dictionary or a sort happened to order equal remainders. The two properties a caller may rely
    /// on, and both are asserted: every percent is within one of its exact share, and the four sum to
    /// exactly 100 whenever the total is positive.
    ///
    /// Public because it is the rule the card's column is drawn from and this repo's suite has no
    /// renderer — a rule written into a `View` is a rule nothing here can assert, which is why
    /// `DayBarRules` is a type of its own for the same reason.
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

    /// The band for each stage, or an empty map when the window is too thin to be a baseline.
    ///
    /// The floor is `RecoveryScoring.minimumBaselineDays`, forwarded rather than restated: two nights
    /// do have a quartile, and calling it a typical range is the judgement, made once for the whole
    /// app. A stage that could not produce a finite band is simply absent from the map, which the row
    /// renders as no markers rather than as a band at zero.
    private static func typicalBands(in window: [SleepSession]) -> [SleepStageType: Typical] {
        guard window.count >= RecoveryScoring.minimumBaselineDays else { return [:] }

        var bands: [SleepStageType: Typical] = [:]
        for stage in stages {
            let shares = window.map { session -> Double in
                session.seconds(of: stage) / session.sleepPeriodSeconds * 100
            }
            guard let low = BaselineStatisticsMath.percentile(shares, at: lowerPercentile),
                  let high = BaselineStatisticsMath.percentile(shares, at: upperPercentile)
            else { continue }
            bands[stage] = Typical(lowPercent: min(low, high), highPercent: max(low, high))
        }
        return bands
    }
}
