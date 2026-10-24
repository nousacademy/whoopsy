import Foundation

/// One R18 record's cumulative motion counter, its activity class and its source.
///
/// **The strap's own pedometer, as a measurement rather than a stream of acceleration.** A 5.0/MG
/// banks an `R18` record roughly once a second, and that record carries a `u16` counter that climbs
/// while the strap moves. Its absolute value means nothing on its own — it wraps at 65,536 and can
/// restart — so a count is the sum of wrap-aware *differences* between consecutive samples. That is
/// `StepCounterAccumulator`'s job, not this value's.
///
/// ## Why this is a Domain entity and not a wire type
///
/// `MotionBatch`'s argument, applied to the other step source: the counter is a property of the
/// strap's own sensor, and `WhoopBLEDeviceRepository` — a `Domain` protocol — can only expose it if it
/// lives on this side of the line. Nothing here is wire-shaped: no offset, no length, no `Data`.
///
/// ## The three fields beside the counter are all ways a delta is not a step
///
/// - `activityClass` is the strap's own classification of the record — `0` still, `1` walk, `2` run —
///   and the counter climbs for non-locomotion movement too. Anything outside `0...2` is **`nil` here
///   rather than passed through as a number**, so a caller cannot mistake a reserved code for a class.
/// - `counterIsSoftware` says which counter `counter` is. The firmware can override the hardware
///   pedometer with a software count; when it does, byte 57 carries the software value and the
///   hardware one moves elsewhere. **A change of source is not a step**, so the accumulator drops the
///   delta across a switch rather than subtracting two different counters.
/// - `timestamp` is the strap's own unix stamp, because a banked record is the one input with no
///   arrival-time substitute. The decoder refuses a stamp before 2020, which is the `v24` repair's
///   cutoff: a strap whose RTC was lost stamps history in 2000, and a counter filed under that day
///   would be steps no screen can draw.
///
/// None of the three is optional in the sense of "the record may not carry it" — an `R18` record is
/// fixed-length and carries all of them. They are the decoded form, and a record that cannot be read
/// at all is `nil` from the decoder rather than a partially filled sample.
public struct StepCounterSample: Sendable, Equatable {

    /// The instant the strap stored the record, from its own clock.
    public let timestamp: Date

    /// The cumulative counter's value at that instant. Meaningless without the previous sample.
    public let counter: UInt16

    /// The strap's activity class for this record: `0` still, `1` walk, `2` run, `nil` for any other
    /// code — see the type's comment.
    public let activityClass: UInt8?

    /// Whether byte 57 held the software counter rather than the hardware pedometer.
    public let counterIsSoftware: Bool

    public init(
        timestamp: Date,
        counter: UInt16,
        activityClass: UInt8?,
        counterIsSoftware: Bool
    ) {
        self.timestamp = timestamp
        self.counter = counter
        self.activityClass = activityClass
        self.counterIsSoftware = counterIsSoftware
    }
}
