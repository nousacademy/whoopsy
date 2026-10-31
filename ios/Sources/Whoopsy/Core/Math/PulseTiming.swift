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
    /// 500 is eight and a third flashes a second — **inside the 3–30 Hz band a flashing surface is
    /// normally kept out of** — and the owner asked for the range, so the control offers it. The
    /// hazard is mitigated by `flashOpacity(ratePerMinute:)` rather than by a lower ceiling: above
    /// `fullContrastRate` the square's colour change is progressively softened, so the top of the
    /// gauge shimmers instead of strobing at full white-on-dark contrast. The gauge's tick labels read
    /// this constant, so the control and the cap cannot disagree.
    public static let maximumRate: Double = 500

    /// The fastest rate drawn at full contrast, in pulses per minute.
    ///
    /// Three flashes a second. Below this the square goes white to yellow at full strength; above it
    /// the yellow is faded towards the white, reaching `minimumFlashOpacity` at `maximumRate`.
    public static let fullContrastRate: Double = 180

    /// How faint the flash is at `maximumRate`. Still visible as a change, and a fraction of the
    /// luminance swing the full-contrast flash makes.
    public static let minimumFlashOpacity: Double = 0.35

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

    /// How strongly the yellow is drawn at `ratePerMinute`.
    ///
    /// `1` up to `fullContrastRate`, then falling linearly to `minimumFlashOpacity` at
    /// `maximumRate`. **This is the photosensitivity mitigation, and it is the reason the ceiling can
    /// be 500 at all**: a full-contrast white/yellow switch at eight flashes a second is in the band
    /// that can trigger a seizure, while the same pattern at a third of the luminance change is a
    /// shimmer. The rate the owner reads is unaffected — only the strength of the drawing is.
    public static func flashOpacity(ratePerMinute: Double) -> Double {
        guard ratePerMinute > fullContrastRate else { return 1 }
        let span = maximumRate - fullContrastRate
        guard span > 0 else { return minimumFlashOpacity }
        let fraction = min((ratePerMinute - fullContrastRate) / span, 1)
        return 1 - fraction * (1 - minimumFlashOpacity)
    }
}
