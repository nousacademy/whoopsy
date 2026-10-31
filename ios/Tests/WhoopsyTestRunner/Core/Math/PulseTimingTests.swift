import Foundation
import Whoopsy

// MARK: - 26. The pulse metronome's timing

/// §26's body: the rule behind the flashing square inside `ADD RECEPTIVE INACTIVITY`.
///
/// **This is the section because the thing it asserts cannot be seen.** Two screenshots of a flashing
/// square either side of a rate change are identical whether the rate was applied or not, and a square
/// that never lit at all would look exactly like one that flashed at a rate the camera missed — so the
/// rule lives in `PulseTiming` and the view reads it, rather than the other way round.
enum PulseTimingTests {
    static func run() async throws {
        // ---- A zero rate is not a slow rate, it is no flashes at all ----
        //
        // The owner's own words are *"if i put it to zero no flashes at all"*, and zero is also the
        // draft's word for *no reading given*. A square that glowed at zero would be the app answering
        // a question nobody asked, and a `period` computed by division would be infinite rather than
        // an answer.
        //
        // Sampled across a whole minute at a fine step, because a rule that returned `false` for the
        // first instant and `true` later would pass a single-sample assertion.
        let darkSamples = stride(from: 0.0, through: 60.0, by: 0.01)
            .filter { PulseTiming.isLit(at: $0, ratePerMinute: 0) }
        assertTest(
            darkSamples.isEmpty,
            "A rate of zero never lights the square — sampled \(Int(60 / 0.01) + 1) instants over a "
                + "minute and found \(darkSamples.count) lit")
        assertTest(
            PulseTiming.period(ratePerMinute: 0) == 0,
            "…and a rate of zero has no period rather than an infinite one, because the division that "
                + "would produce it is the division that must not happen")

        // ---- Each rate's period, pinned as literals ----
        //
        // The three grid labels the gauge draws. If `maximumRate` ever moves, the third literal is what
        // stops the top of the control describing a rate the rule does not use.
        assertTest(
            PulseTiming.period(ratePerMinute: 60) == 1,
            "60 pulses a minute is one pulse a second (got \(PulseTiming.period(ratePerMinute: 60)))")
        assertTest(
            PulseTiming.period(ratePerMinute: 120) == 0.5,
            "…120 a minute is one every half second (got \(PulseTiming.period(ratePerMinute: 120)))")
        assertTest(
            PulseTiming.period(ratePerMinute: PulseTiming.maximumRate) == 0.12,
            "…and the gauge's ceiling of 500 a minute is eight and a third flashes a second — inside the "
                + "band a flashing surface is usually kept out of, which is why the drawing fades above "
                + "180 rather than switching (got \(PulseTiming.period(ratePerMinute: PulseTiming.maximumRate)))")

        // ---- The photosensitivity ramp ----
        //
        // The ceiling is the owner's, and the mitigation is that the flash weakens as it quickens: full
        // strength up to three flashes a second, then a linear fall to `minimumFlashOpacity` at 500.
        // Asserted at both ends and in the middle, because a ramp that never left 1 would look exactly
        // like a working one on a screenshot of a slow rate.
        assertTest(
            PulseTiming.flashOpacity(ratePerMinute: 0) == 1
                && PulseTiming.flashOpacity(ratePerMinute: PulseTiming.fullContrastRate) == 1,
            "The flash is at full strength up to 180/min, which is the last rate drawn as a hard switch")
        assertTest(
            PulseTiming.flashOpacity(ratePerMinute: PulseTiming.maximumRate)
                == PulseTiming.minimumFlashOpacity,
            "…and at the ceiling it is faded to the minimum rather than switching at full contrast "
                + "(\(PulseTiming.flashOpacity(ratePerMinute: PulseTiming.maximumRate)))")
        let ramp = [200.0, 300.0, 400.0, 500.0].map { PulseTiming.flashOpacity(ratePerMinute: $0) }
        assertTest(
            zip(ramp, ramp.dropFirst()).allSatisfy { $0 > $1 },
            "…falling monotonically between them, so no rate is drawn stronger than a slower one "
                + "(\(ramp))")

        // ---- The duty cycle, asserted as a window rather than as a colour ----
        //
        // `isLit` must be on for the first 40% of a period and off for the rest, at a rate whose
        // period is a clean second. Both edges are asserted: a duty cycle of 0 or 1 would pass a
        // sample from the middle of the window.
        let oneSecond = 60.0
        assertTest(
            PulseTiming.isLit(at: 0, ratePerMinute: oneSecond)
                && PulseTiming.isLit(at: 0.39, ratePerMinute: oneSecond),
            "The first 40% of a period is lit")
        assertTest(
            !PulseTiming.isLit(at: 0.41, ratePerMinute: oneSecond)
                && !PulseTiming.isLit(at: 0.99, ratePerMinute: oneSecond),
            "…and the rest of it is dark, so the square is off for longer than it is on")
        assertTest(
            PulseTiming.dutyCycle > 0 && PulseTiming.dutyCycle < 1,
            "The duty cycle is strictly between nothing and everything, so no rate is permanently lit "
                + "or permanently dark (\(PulseTiming.dutyCycle))")

        // ---- The phase wraps without a jump ----
        //
        // The one property a clock-driven pattern has to have: at the period boundary the phase returns
        // to zero rather than continuing, or the square drifts a period out of step every second. The
        // step is compared against the same step inside a period, so the assertion is about the wrap
        // and not about the sample spacing.
        let period = PulseTiming.period(ratePerMinute: oneSecond)
        let beforeBoundary = PulseTiming.phase(at: period - 0.001, ratePerMinute: oneSecond)
        let afterBoundary = PulseTiming.phase(at: period + 0.001, ratePerMinute: oneSecond)
        assertTest(
            beforeBoundary > 0.99 && afterBoundary < 0.01,
            "The phase returns to zero at a period boundary rather than running past it "
                + "(\(beforeBoundary) before, \(afterBoundary) after)")
        let insidePeriod = PulseTiming.phase(at: 0.501, ratePerMinute: oneSecond)
            - PulseTiming.phase(at: 0.500, ratePerMinute: oneSecond)
        assertTest(
            abs(insidePeriod - 0.001) < 1e-9,
            "…and inside a period it advances by the elapsed fraction of that period, so the two "
                + "sides of the wrap are the same clock read twice (\(insidePeriod))")

        // ---- The same rate in hertz ----
        //
        // The sheet prints both, and the conversion is the one thing about it that could be wrong
        // silently: `rate / 60`, with zero kept as zero rather than a negative from a stray input.
        assertTest(
            PulseTiming.hertz(ratePerMinute: 60) == 1
                && PulseTiming.hertz(ratePerMinute: 120) == 2,
            "60 pulses a minute is one hertz and 120 is two")
        assertTest(
            abs(PulseTiming.hertz(ratePerMinute: PulseTiming.maximumRate) - 500.0 / 60.0) < 1e-12,
            "…and the ceiling is eight and a third hertz, which is what the readout prints "
                + "(\(PulseTiming.hertz(ratePerMinute: PulseTiming.maximumRate)))")
        assertTest(
            PulseTiming.hertz(ratePerMinute: 0) == 0,
            "…and a rate of zero is zero hertz rather than a negative or a division by it")

        // A rate above the ceiling cannot come from the gauge, but the rule is not the place that
        // refuses it — the draft and the entity clamp — so this only pins that the math still answers
        // rather than dividing into nonsense.
        assertTest(
            PulseTiming.period(ratePerMinute: 360) == 1.0 / 6.0,
            "The rule answers any positive rate, because the clamp belongs to the control and not to "
                + "the arithmetic (\(PulseTiming.period(ratePerMinute: 360)))")
    }
}
