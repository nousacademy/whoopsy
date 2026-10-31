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
    /// 180 is three flashes a second — the bottom edge of the band a flashing surface should stay out
    /// of — and it is the one number to lower if the square ever feels harsh. The gauge's tick labels
    /// read it, so the control and the cap cannot disagree.
    public static let maximumRate: Double = 180

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
}
