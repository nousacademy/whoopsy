import Foundation

/// The rule a flashing square follows: how often it lights for a chosen rate, and for how much of each
/// period.
///
/// **It is here, and it is pure, so the flashing is assertable.** The view that draws the square is a
/// `TimelineView` re-reading the clock sixty times a second; a rule that exists only inside that
/// closure can only be checked by watching it, and a flash is exactly the kind of thing a screenshot
/// cannot show — two frames either side of a rate change look identical whether the rate was applied
/// or not. `SleepOnsetMath` and `StressOnsetMath` live beside it for the same reason: the rule is
/// separated from the drawing so the suite can pin it.
///
/// **Nothing here measures anything.** The rate is the owner's own report, matched by eye against a
/// felt rhythm; this type only turns that number into an on/off pattern.
public enum PulseTiming {

    /// The fastest rate the gauge offers, in pulses per minute.
    ///
    /// 500 is eight and a third a second — **inside the 3–30 Hz band a flashing surface is normally
    /// kept out of** — and the owner asked for the range, so the control offers it. The hazard is
    /// answered by changing the drawing rather than lowering the ceiling: past `flashingCeiling` the
    /// square stops flashing and a band of light travels around its edge once per pulse, which still
    /// shows the speed and has no flash in it at all. The gauge's tick labels read this constant, so
    /// the control and the cap cannot disagree.
    public static let maximumRate: Double = 500

    /// The fastest rate the square **flashes** at, in pulses per minute.
    ///
    /// Three flashes a second, and the edge of what a person can resolve as separate events. At or
    /// below it the square goes white to yellow; above it the flashing would fuse into a shimmer, so
    /// the drawing changes to the travelling band instead — the owner's own call, *"spin instead of
    /// flash"*, and the reason the range can be 500 without a strobe in it.
    public static let flashingCeiling: Double = 180

    /// The share of each period the square is lit for.
    ///
    /// Under one half, so the dark is the longer half and the flash reads as a flash rather than as a
    /// lit square that briefly rests.
    public static let dutyCycle: Double = 0.4

    /// Where `seconds` falls in the current period, in `0..<1`.
    ///
    /// A rate of zero has no period, so the phase is answered as zero rather than as a division by it
    /// — and `isLit` below is what turns that answer into *never lit*.
    public static func phase(at seconds: TimeInterval, ratePerMinute: Double) -> Double {
        guard ratePerMinute > 0 else { return 0 }
        let period = 60 / ratePerMinute
        let whole = (seconds / period).rounded(.down)
        return seconds / period - whole
    }

    /// Whether the square is yellow at `seconds`.
    ///
    /// **A rate of zero is never lit**, and that is the gauge's zero doing what the owner asked of it:
    /// *"if i put it to zero no flashes at all"*. Zero is also the draft's word for *no reading given*,
    /// so a square that glowed at zero would be the app answering a question nobody asked.
    public static func isLit(at seconds: TimeInterval, ratePerMinute: Double) -> Bool {
        guard ratePerMinute > 0 else { return false }
        return phase(at: seconds, ratePerMinute: ratePerMinute) < dutyCycle
    }

    /// The period one pulse takes, in seconds — `60 / rate`. Zero for a rate of zero.
    public static func period(ratePerMinute: Double) -> TimeInterval {
        guard ratePerMinute > 0 else { return 0 }
        return 60 / ratePerMinute
    }

    /// The same rate in hertz — oscillations a second, `rate / 60`. Zero for a rate of zero.
    ///
    /// The sheet prints both, because the two units answer different questions: pulses a minute is what
    /// a person matches a felt rhythm against, and hertz is what the same number is called everywhere
    /// else — in audio, in body rhythms, and in every other place a rate of repetition is written down.
    public static func hertz(ratePerMinute: Double) -> Double {
        max(ratePerMinute, 0) / 60
    }

    /// The hertz figure as the screens print it — one decimal place, no unit.
    ///
    /// **One formatter for the two places that show it**, the sheet's readout and the Home row, because
    /// a number printed two ways is two numbers a reader has to reconcile. The unit is left to the
    /// caller: the sheet writes `1.1 Hz` beside the rate, and the row writes `1.1Hz` as its own figure.
    public static func formattedHertz(ratePerMinute: Int) -> String {
        String(format: "%.1f", hertz(ratePerMinute: Double(ratePerMinute)))
    }

    /// How long until the next pulse begins, in seconds — the wait the sounder sleeps before its click.
    ///
    /// **The wait is measured from the same phase the square is lit from**, so the click and the yellow
    /// cannot drift apart: both are answers to "where is the clock in this period". A wait of zero would
    /// fire a second click for the pulse that just sounded, so the answer is never zero — it is floored
    /// at a millisecond, which is a spin guard rather than a musical choice.
    public static func secondsUntilNextPulse(at seconds: TimeInterval, ratePerMinute: Double) -> TimeInterval {
        guard ratePerMinute > 0 else { return 0 }
        let period = 60 / ratePerMinute
        let remaining = (1 - phase(at: seconds, ratePerMinute: ratePerMinute)) * period
        return max(remaining, 0.001)
    }

    /// Whether the square is drawn as a travelling band rather than a flash.
    ///
    /// **This is the whole of the photosensitivity mitigation, and it is the reason the ceiling can be
    /// 500 at all.** A white/yellow switch at eight a second is in the band that can trigger a
    /// seizure; the same rate drawn as a band going round an edge has no flash in it, and at 8 turns a
    /// second it still reads unmistakably as *fast*.
    public static func isTravelling(ratePerMinute: Double) -> Bool {
        ratePerMinute > flashingCeiling
    }
}
