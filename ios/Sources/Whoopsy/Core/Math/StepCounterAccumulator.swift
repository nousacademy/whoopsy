import Foundation

/// The delta rule for the strap's own cumulative pedometer, one `R18` record at a time.
///
/// This is **not a totals holder**. It owns only the continuation — which counter value, instant and
/// source the previous record had — and answers what one record contributes. The day's totals belong
/// to `TrackStepsUseCase`'s ledger, because a record can arrive for yesterday while today's live
/// motion is running and a per-day accumulator would have to choose a day for a delta that spans
/// neither.
///
/// ## A delta is not a step, and five rules stand between the two
///
/// The counter climbs for motion that is not locomotion, wraps at 65,536, restarts on a reboot, and
/// can change which counter it is reporting. So a difference contributes only when:
///
/// - **the class says locomotion** — `1` walk or `2` run, once any record in this process has carried
///   a class at all. A strap whose firmware does not classify counts under the counter-only rule
///   rather than being thrown away;
/// - **the delta is positive and below `maximumStepDelta`** — zero is a still wrist, and 512 or more
///   is a wrap, a reboot or a drain's own gap, not 512 steps between two records a second apart;
/// - **the rate is human** — at most `maximumStepsPerSecond` for the elapsed time;
/// - **the counter source did not change** — a switch from the hardware pedometer to the software
///   override is a change of instrument, and subtracting one from the other invents steps;
/// - **time moved forward** — a repeated or out-of-order timestamp has no interval to divide by.
///
/// The wrap itself is not an error: `(current − previous) & 0xFFFF` turns `65,500 → 20` into `56`,
/// which is the real increment. The absolute guard is what separates a wrap from a discontinuity —
/// a wrap is small, a reboot is not.
///
/// ## Coverage is a separate answer from ticks
///
/// An interval can be trustworthy without being a step: a still-classed record with a delta of zero
/// is real coverage of a wrist that did not move. So `Outcome` carries both — the ticks to add and
/// the seconds of coverage the interval earns — and an interval that failed the absolute or rate
/// guard earns **neither**, because a gap is not coverage either.
///
/// ## What the remaining error is, stated plainly
///
/// **The counter counts motion ticks, and this counts one tick as one step.** NOOP's implementation
/// offers a per-user divisor for exactly that reason; its default is `1.0` and its own note is that
/// the `u16` fix is what made the figure sane. This app has no capture to fit a divisor against, so
/// it takes the default and `docs/ALGORITHMS.md` §7 says the number is one a walk on hardware would
/// calibrate. A scale invented here would be a fabricated constant, which is worse than a known one.
///
/// It takes primitives rather than a `StepCounterSample`, for `StepAccumulator`'s reason: this
/// is `Core` and imports only `Foundation`, while the decoded record is a `Domain` entity one layer
/// up.
///
/// **A different strap's counter is not distinguished from the last one's.** The sample carries no
/// device identity, so if the user switches straps between launches the first delta compares two
/// straps' counters — it is almost always larger than `maximumStepDelta` and is dropped, and the
/// continuation resumes from that record. One interval can be lost, not a day; adding a device id to
/// the state would close it and is not worth a second persisted field until something needs one.
public struct StepCounterAccumulator: Sendable {

    /// What one record contributed.
    public struct Outcome: Sendable, Equatable {
        /// Locomotion ticks to add to the day's count. Zero is common and is not an error.
        public let countedTicks: Int

        /// Seconds of the interval the counter vouches for. Zero when the interval is a gap.
        public let measuredSeconds: TimeInterval

        /// Whether the interval was trustworthy enough to count as coverage — the rule `measuredSeconds`
        /// is computed from, exposed so a caller can tell "a still wrist" from "a gap".
        public let isCoverageInterval: Bool

        public static let none = Outcome(
            countedTicks: 0, measuredSeconds: 0, isCoverageInterval: false)

        public init(countedTicks: Int, measuredSeconds: TimeInterval, isCoverageInterval: Bool) {
            self.countedTicks = countedTicks
            self.measuredSeconds = measuredSeconds
            self.isCoverageInterval = isCoverageInterval
        }
    }

    /// The largest increment that can be one interval's worth of steps.
    ///
    /// **An absolute guard, independent of the rate rule below.** A delta of 512 is what a wrap or a
    /// reboot looks like; a walk between two records never reaches it. NOOP calls this the
    /// sync-gap boundary and drops the delta rather than crediting a capped 511, which is the
    /// difference between losing a gap's steps and inventing them.
    public static let maximumStepDelta: Int = 512

    /// The most steps an interval may contain per second of its own span.
    ///
    /// Four is 240 steps a minute, above a sprint's cadence. The rule refuses a delta that survived
    /// the absolute guard but is still too large for the time it spans.
    public static let maximumStepsPerSecond: Double = 4.0

    /// The elapsed time at which the rate allowance stops scaling.
    ///
    /// `maximumStepDelta / maximumStepsPerSecond` = 128 s, derived rather than chosen: past this the
    /// absolute guard is the tighter rule.
    public static let longGapSeconds: Double = Double(maximumStepDelta) / maximumStepsPerSecond

    /// The most measured time one record's gap may contribute, in seconds.
    ///
    /// **A cap, because a gap is not coverage.** Five seconds is several records at the 1 Hz R18
    /// cadence, so an ordinary interval contributes its own span; a drain that skipped an hour
    /// contributes five seconds and not an hour.
    public static let maximumCoverageGapSeconds: TimeInterval = 5.0

    /// The classes that mean locomotion.
    public static let locomotionClasses: Set<UInt8> = [1, 2]

    private var lastCounter: UInt16?
    private var lastSeconds: Double?
    private var lastWasSoftware: Bool?

    /// Whether any record so far has carried an activity class.
    ///
    /// **Once true it stays true**, which is the streaming form of NOOP's "if the whole window is
    /// unclassed" rule. A process that begins on a legacy record counts it, and from the first
    /// classified record onward the gate applies.
    private var hasSeenClass: Bool

    /// The continuation, for the store a relaunch resumes from.
    public var previousCounter: UInt16? { lastCounter }
    public var previousSeconds: Double? { lastSeconds }
    public var previousWasSoftware: Bool? { lastWasSoftware }
    public var hasSeenActivityClass: Bool { hasSeenClass }

    public init(
        previousCounter: UInt16? = nil,
        previousSeconds: Double? = nil,
        previousWasSoftware: Bool? = nil,
        hasSeenClass: Bool = false
    ) {
        self.lastCounter = previousCounter
        self.lastSeconds = previousSeconds
        self.lastWasSoftware = previousWasSoftware
        self.hasSeenClass = hasSeenClass
    }

    /// Accepts one record and reports what it contributed.
    ///
    /// - Parameters:
    ///   - counter: The record's cumulative counter.
    ///   - seconds: The record's own instant, on any consistent scale — only differences are read.
    ///   - activityClass: The strap's class for this record, or `nil` when it carried none or a code
    ///     outside `0...2`.
    ///   - softwareOverride: Whether this record's counter came from the software override.
    public mutating func accept(
        counter: UInt16,
        seconds: Double,
        activityClass: UInt8?,
        softwareOverride: Bool
    ) -> Outcome {
        if activityClass != nil { hasSeenClass = true }

        guard let previousCounter = lastCounter,
              let previousSeconds = lastSeconds,
              let previousSoftware = lastWasSoftware
        else {
            // The first record has no predecessor, so it contributes nothing — but it is still the
            // one that fixes the continuation every later delta is measured from.
            lastCounter = counter
            lastSeconds = seconds
            lastWasSoftware = softwareOverride
            return .none
        }

        let elapsed = seconds - previousSeconds
        // A repeated or out-of-order record is dropped **without advancing the continuation**.
        // Advancing it would make the next genuine delta span from the duplicate and lose or invent
        // the steps in between; leaving it makes the next record measure from the last accepted one.
        guard elapsed > 0 else { return .none }

        lastCounter = counter
        lastSeconds = seconds
        lastWasSoftware = softwareOverride

        // A change of instrument is not a step and not coverage. Neither counter is wrong; they are
        // different counters, and the interval between them is not an interval of either.
        guard softwareOverride == previousSoftware else { return .none }

        let delta = Int(counter &- previousCounter) & 0xFFFF
        // A gap carries neither ticks nor coverage: the app cannot say the strap was watched, and it
        // cannot say 512 steps happened. NOOP drops it rather than crediting a capped 511.
        guard delta < Self.maximumStepDelta else { return .none }

        let rateAllowance = elapsed >= Self.longGapSeconds
            ? Self.maximumStepDelta - 1
            : Int(Self.maximumStepsPerSecond * elapsed)
        guard delta <= rateAllowance else { return .none }

        let coverage = min(elapsed, Self.maximumCoverageGapSeconds)

        // A still-classed interval is coverage with no steps — a measured day of no walking is a
        // real `0`, and the class gate decides the count, not whether the strap was watched.
        if hasSeenClass {
            guard let activityClass, Self.locomotionClasses.contains(activityClass) else {
                return Outcome(countedTicks: 0, measuredSeconds: coverage, isCoverageInterval: true)
            }
        }

        return Outcome(countedTicks: delta, measuredSeconds: coverage, isCoverageInterval: true)
    }
}
