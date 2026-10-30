import Foundation

/// The counter path's continuation and ledger, as it survives a relaunch.
///
/// **Why this exists at all: `stepCounts` cannot be split.** The table has no provenance column —
/// deliberately, because one day is routinely fed by two transports — so a stored total cannot say
/// how much of it came from the strap's counter and how much from the peak detector. Recomputing a
/// total from that row alone would therefore rebase the wrong number, which is the failure this type
/// prevents: the ledger is written before the row, and on relaunch it is the truth the row is
/// recomputed from.
///
/// It is **not a measurement and not a preference**. It is filter state in the sense
/// `StepAccumulator`'s gravity window would be if it were persisted — the difference is that a
/// counter is meaningless without its previous value, so losing this state across a relaunch would
/// lose a real delta rather than one second of filter warm-up.
///
/// The continuation fields (`lastCounter`, `lastSeconds`, `lastSoftware`) belong to the stream rather
/// than the day: a delta can cross midnight, and the day it is credited to is the later sample's. The
/// `day` field names the day the two totals below belong to; a state for another day is ignored.
///
/// **One day is stored, and it is the most recent counter-covered one.** A drain spanning midnight
/// leaves the earlier day's row already written but its ledger in memory only. That is safe rather
/// than convenient: the drain is chronological, so a day the cursor has passed receives no further
/// records, and the row it wrote is the total. The alternative is a second persisted day for a case a
/// single connection does not normally produce.
public struct StepCounterState: Codable, Equatable, Sendable {

    /// The day the totals below are for, snapped to `startOfDay`.
    public let day: Date

    /// Locomotion ticks credited to that day by the counter.
    public let counterSteps: Int

    /// Seconds of counter coverage credited to that day.
    public let counterMeasuredSeconds: TimeInterval

    /// Steps the peak detector counted **after** the counter's coverage ended, for that day.
    public let tailSteps: Int

    /// Measured seconds for that tail.
    public let tailMeasuredSeconds: TimeInterval

    /// The last counter value read, whatever day it was stamped.
    public let lastCounter: UInt16?

    /// That record's instant, on the same scale `StepCounterAccumulator` accepts.
    public let lastSeconds: Double?

    /// Which counter that record carried.
    public let lastSoftware: Bool?

    /// Whether any record so far carried an activity class.
    public let hasSeenClass: Bool

    /// The newest instant the strap's counter has vouched for on `day`, or `nil` for a state written
    /// before this field existed.
    ///
    /// **This is what stops the live tail counting a window the counter also counts.** The tail is the
    /// peak detector running on live motion, and the counter is the strap's own pedometer over banked
    /// records — the same steps, seen twice, if the tail is allowed to run over instants the counter
    /// has already covered. Measured 2026-10-30 on the owner's 5.0: a ledger holding `counterSteps`
    /// a counter and a tail whose totals together claimed — a day
    /// cannot have been measured for longer than it has existed, which is the arithmetic proof that
    /// the two producers were covering the same hours.
    public let coveredThrough: Date?

    public init(
        day: Date,
        counterSteps: Int,
        counterMeasuredSeconds: TimeInterval,
        tailSteps: Int,
        tailMeasuredSeconds: TimeInterval,
        coveredThrough: Date? = nil,
        lastCounter: UInt16?,
        lastSeconds: Double?,
        lastSoftware: Bool?,
        hasSeenClass: Bool
    ) {
        self.day = day
        self.counterSteps = counterSteps
        self.counterMeasuredSeconds = counterMeasuredSeconds
        self.tailSteps = tailSteps
        self.tailMeasuredSeconds = tailMeasuredSeconds
        self.lastCounter = lastCounter
        self.lastSeconds = lastSeconds
        self.lastSoftware = lastSoftware
        self.hasSeenClass = hasSeenClass
        self.coveredThrough = coveredThrough
    }
}

/// The one read and one write the counter path needs across a launch.
///
/// Synchronous because its implementation is `UserDefaults`, and because the only caller is an actor
/// that already serialises its own access — an `async` signature here would make every write an
/// await for a store that cannot block.
public protocol StepCounterStateStore: Sendable {

    /// The last saved state, or `nil` when nothing has been saved — which is a fresh install rather
    /// than an error.
    func load() -> StepCounterState?

    /// Replaces the saved state.
    func save(_ state: StepCounterState)

    /// Removes it. The caller uses this when the state names a day too old to be useful rather than
    /// leaving a stale continuation to be misread.
    func clear()
}
