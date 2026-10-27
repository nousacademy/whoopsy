import Foundation
import Whoopsy

// MARK: - 16. The strap's own counter

/// The delta rule for the R18 counter: wrap, reboot, class, rate, source and coverage.
///
/// **Nothing here is evidence about a real counter.** The offsets are NOOP's reverse-engineering and
/// no strap on this machine has produced one; these fixtures are differences a hand calculator can
/// check, and the hardware question is `docs/BLE_PROTOCOL.md` §7's capture.
enum StepCounterAccumulatorTests {

    static func run() async throws {
        func count(
            _ samples: [(seconds: Double, counter: UInt16, class: UInt8?, software: Bool)]
        ) -> (ticks: Int, measured: TimeInterval) {
            var accumulator = StepCounterAccumulator()
            var ticks = 0
            var measured: TimeInterval = 0
            for sample in samples {
                let outcome = accumulator.accept(
                    counter: sample.counter,
                    seconds: sample.seconds,
                    activityClass: sample.class,
                    softwareOverride: sample.software)
                ticks += outcome.countedTicks
                measured += outcome.measuredSeconds
            }
            return (ticks, measured)
        }


        /// The counter rule with the accelerometer attached — the second opinion on the strap's class.
        func countMoving(
            _ samples: [(seconds: Double, counter: UInt16, class: UInt8?, acceleration: AccelerationVector?)]
        ) -> (ticks: Int, measured: TimeInterval) {
            var accumulator = StepCounterAccumulator()
            var ticks = 0
            var measured: TimeInterval = 0
            for sample in samples {
                let outcome = accumulator.accept(
                    counter: sample.counter,
                    seconds: sample.seconds,
                    activityClass: sample.class,
                    softwareOverride: false,
                    acceleration: sample.acceleration)
                ticks += outcome.countedTicks
                measured += outcome.measuredSeconds
            }
            return (ticks, measured)
        }

        let steady = count([
            (0, 100, 1, false), (1, 102, 1, false), (2, 104, 1, false),
            (3, 106, 1, false), (4, 108, 1, false),
        ])
        assertTest(
            steady.ticks == 8 && steady.measured == 4,
            "A one-hertz walk of four two-tick intervals counts eight ticks over four covered "
                + "seconds — and the first record contributes nothing, because a counter's value "
                + "means nothing without the one before it (\(steady))")

        let wrap = count([
            (0, 65_534, 1, false), (1, 65_535, 1, false), (2, 2, 1, false), (3, 4, 1, false),
        ])
        assertTest(
            wrap.ticks == 6,
            "A counter that wraps 65,535 → 2 contributes three ticks, not −65,533: the delta is "
                + "`(current − previous) & 0xFFFF`, which is the whole reason the field is read as a "
                + "u16 rather than summed byte by byte (\(wrap.ticks))")

        let jump = count([
            (0, 100, 1, false), (1, 102, 1, false), (2, 700, 1, false), (3, 702, 1, false),
        ])
        assertTest(
            jump.ticks == 4 && jump.measured == 2,
            "A 598-tick jump is dropped as a reboot or drain boundary, and so is the interval it "
                + "spans: a gap is neither steps nor coverage. The two real two-tick intervals "
                + "survive on either side (\(jump))")

        let single = count([(0, 5_000, 1, false)])
        assertTest(
            single.ticks == 0 && single.measured == 0,
            "One record is not an interval: no previous counter, no delta and no measured time")

        let fast = count([(0, 100, 1, false), (1, 107, 1, false)])
        let slower = count([(0, 100, 1, false), (2, 107, 1, false)])
        assertTest(
            fast.ticks == 0 && slower.ticks == 7,
            "Seven ticks in one second is refused as a discontinuity; the same seven over two "
                + "seconds is a plausible burst — the rate gate divides by the interval's own span "
                + "(fast \(fast), slower \(slower))")

        let classed = count([
            (0, 100, 0, false), (1, 102, 0, false), (2, 104, 1, false),
            (3, 106, 2, false), (4, 108, nil, false),
        ])
        assertTest(
            classed.ticks == 4 && classed.measured == 4,
            "Once any record carries a class, only walk (1) and run (2) deltas count: the two "
                + "still-classed deltas and the unknown-classed one are refused, while all four "
                + "intervals remain coverage — a still wrist is a measured day of no walking, not an "
                + "unmeasured one (\(classed))")

        let legacy = count([(0, 100, nil, false), (1, 102, nil, false), (2, 104, nil, false)])
        assertTest(
            legacy.ticks == 4,
            "A stream that never carries a class counts every plausible delta — the legacy fallback "
                + "for firmware that does not classify, which a fixed decision at construction could "
                + "not express (\(legacy.ticks))")

        let switched = count([
            (0, 100, 1, false), (1, 102, 1, true), (2, 104, 1, true),
        ])
        assertTest(
            switched.ticks == 2 && switched.measured == 1,
            "A switch from the hardware pedometer to the software override contributes no steps and "
                + "no coverage: the two counters are different instruments, and the interval between "
                + "them belongs to neither. The next interval counts normally (\(switched))")

        let outOfOrder = count([
            (0, 100, 1, false), (2, 104, 1, false), (1, 999, 1, false), (3, 108, 1, false),
        ])
        assertTest(
            outOfOrder.ticks == 8 && outOfOrder.measured == 3,
            "An out-of-order record is dropped without advancing the continuation, so the next "
                + "genuine delta is measured from the last good record rather than from the "
                + "duplicate — the alternative loses or invents the steps in between (\(outOfOrder))")

        let longGap = count([(0, 100, 1, false), (30, 102, 1, false)])
        assertTest(
            longGap.ticks == 2 && longGap.measured == 5,
            "A small delta across a thirty-second gap counts, because the strap's counter is "
                + "cumulative and the movement happened — but the interval claims only five seconds "
                + "of coverage, the cap that stops a drain gap from claiming the time it skipped "
                + "(\(longGap))")

        let boundary = count([(0, 0, 1, false), (200, 511, 1, false)])
        let over = count([(0, 0, 1, false), (200, 512, 1, false)])
        assertTest(
            boundary.ticks == 511 && over.ticks == 0,
            "The absolute guard is exclusive: 511 ticks across a long gap is counted, 512 is the "
                + "wrap/reboot boundary and is dropped — which is what separates a wrap from a "
                + "discontinuity rather than crediting a capped 511 to a reboot")


        // MARK: The accelerometer's second opinion on the strap's class

        /// A wrist at `x` g on the given axis, with the other two carrying gravity's remainder.
        func axis(_ x: Double) -> AccelerationVector {
            AccelerationVector(x: x, y: 0, z: 0.97)
        }

        /// One walk-classed record: two ticks per second, with whatever acceleration the case needs.
        typealias MovingRow = (
            seconds: Double, counter: UInt16, class: UInt8?, acceleration: AccelerationVector?
        )
        func row(_ second: Int, _ acceleration: AccelerationVector?) -> MovingRow {
            (seconds: Double(second), counter: UInt16(second * 2), class: 1, acceleration: acceleration)
        }
        func rows(_ count: Int, _ acceleration: (Int) -> AccelerationVector?) -> [MovingRow] {
            (0..<count).map { row($0, acceleration($0)) }
        }

        // Forty seconds of sustained walking: the wrist swings 0.3 g every second, so nearly every
        // second of the thirty-second window is *active*.
        let walking = countMoving(rows(40) { $0.isMultiple(of: 2) ? axis(0.0) : axis(0.3) })
        assertTest(
            walking.ticks == 78,
            "A locomotion class over a wrist that **swings every second** counts every interval: "
                + "thirty-nine of them, two ticks each — the same answer the class rule alone gives "
                + "(\(walking.ticks))")

        // The defect: the strap says walk, the wrist rolls once in forty seconds and is otherwise still.
        let rolling = countMoving(rows(40) { $0 == 20 ? axis(0.9) : axis(0.05) })
        assertTest(
            rolling.ticks == 20,
            "…while the **same class over a wrist that rolled once** stops counting after the gate's "
                + "ten-second minimum: a roll contributes two active seconds to a thirty-second "
                + "window, which is not walking. Only the ten intervals before the history existed "
                + "are counted — this is the 300-steps-before-getting-up defect (\(rolling.ticks))")

        // Silence is not stillness: no accelerometer means the class rule decides, as before.
        let unmeasured = countMoving(rows(40) { _ in nil })
        assertTest(
            unmeasured.ticks == 78,
            "A record with **no usable acceleration is not gated** — the class rule stays the "
                + "fallback, exactly as it is for a strap whose firmware classifies nothing, "
                + "because a decode gap must not become a dead pedometer (\(unmeasured.ticks))")

        // The class gate still comes first: a still-classed record counts nothing whatever the wrist did.
        let stillClass = countMoving(
            (0..<40).map { second in
                (seconds: Double(second), counter: UInt16(second * 2),
                 class: UInt8(0),
                 acceleration: second.isMultiple(of: 2) ? axis(0.0) : axis(0.3))
            })
        assertTest(
            stillClass.ticks == 0,
            "…and a still class over a moving wrist counts nothing either, so the two gates are "
                + "independent and both have to pass")

        let resumed = StepCounterAccumulator(
            previousCounter: 4_000, previousSeconds: 1_700_000_000, previousWasSoftware: false)
        var resumedMutable = resumed
        let first = resumedMutable.accept(
            counter: 4_002, seconds: 1_700_000_001, activityClass: 1, softwareOverride: false)
        assertTest(
            first.countedTicks == 2,
            "A continuation seeded from a stored counter contributes the first interval after a "
                + "relaunch rather than losing it — the delta is the whole reason the state store "
                + "exists (\(first.countedTicks))")
    }
}
