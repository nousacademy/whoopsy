import Foundation

/// Where a night begins and ends, found from the classified epochs themselves.
///
/// This is the strap path's onset detector, and it exists because the strap path had none. A session's
/// boundaries used to be `samples.first.timestamp` and `samples.last.timestamp` — the edges of the
/// **read window** (9 PM → 10 AM), not of the night — so a strap worn from 7 PM reported a night that
/// began at 7 PM. The export path has always carried a real pair (WHOOP's `Sleep onset` → `Wake
/// onset`, read verbatim), which is the pair the `TIME IN BED` card plots; this type is what makes the
/// strap a producer of the same quantity rather than a second kind of thing.
///
/// ## The rule
///
/// **Onset is the start of the first run of consecutive non-awake epochs whose own wall-clock span
/// reaches ten minutes; wake is the end of the last such run.** A night with no qualifying run is
/// absent — the caller writes no row, on the discipline `AnalyzeSleepUseCase.minimumEpochSamples`
/// already establishes.
///
/// The quantity this produces is polysomnography's **sleep period time** (first-asleep →
/// last-asleep, `SPT` = total sleep + wake inside it), which is what `SleepSession.sleepPeriodSeconds`
/// already names, and what WHOOP's own `Sleep onset` → `Wake onset` pair carries. Awake epochs
/// *between* the two ends are kept: they are WASO, and they are the correct content of the span.
/// Awake epochs outside it are the trim.
///
/// ## Where the ten minutes comes from
///
/// The actigraphy convention is the `SO1`/`SO5`/`SO10`-min family — the first epoch of 1, 5 or 10
/// consecutive minutes scored sleep — and the ten-minute form is the most commonly applied operational
/// definition. Busa et al. 2022, *Sensors* 22(13):5041, drove all three against polysomnography and
/// found the choice produced **no significant difference** in any sleep variable, so the length is not
/// load-bearing and the standard form is shipped without a fitting exercise. That is the same doctrine
/// that puts `SleepNeedMath` at 6.40 over a marginally luckier 7.0 and `SleepDebtMath` at the
/// reproducible argmin: a citable value is worth more than a tuned one.
///
/// WHOOP's sleep-intention filing (US20240206803A1, granted US12575786B2) corroborates the *structure*
/// — a waking event ends a sleep period only when the wearer intends to stay awake, as distinct from
/// "transitory stirring or other intermittent activity" — while disclosing **no threshold, no variable
/// and no model**. So the shape is borrowed and nothing numeric is.
///
/// **AASM's own definition is deliberately not used.** It scores sleep onset as the first epoch of any
/// sleep stage, which is a definition for *polysomnography* — epochs scored by a technologist reading
/// EEG. This classifier is a threshold on a wrist accelerometer and a heart rate, and importing a
/// definition across measurement modalities is how a rule acquires authority it has not earned. The
/// actigraphy literature is the right literature for an actigraphy classifier.
///
/// ## What it cannot see, which is the half that matters
///
/// `accelerationMagnitude` is `|a|` in Gs, so a motionless strap reads ≈1.0 G rather than 0, and the
/// classifier's awake test is `avgAccel > 1.25 || avgEpochHR > restHR × 1.25`. **A still, wakeful
/// person therefore classifies as asleep.** So the trim removes movement- and heart-rate-elevated edge
/// time — an active evening on the couch — and cannot remove an hour of lying awake reading a phone.
///
/// **No run length fixes this**, and it is worth being exact about why: quiet wakefulness is a
/// *sustained* run of non-awake epochs, so it satisfies `SO1`, `SO5` and `SO10` alike. The guard buys
/// robustness against a brief misclassification — one epoch of standing still in an otherwise awake
/// evening — and buys nothing against the dominant error. This is the same low wake specificity
/// (29–52%) the validation literature reports for every wrist-worn device, and it is recorded in
/// `ALGORITHMS.md` §4 rather than left to be inferred from a passing test run.
public enum SleepOnsetMath {

    /// One classified epoch, as the caller's classifier produced it.
    ///
    /// The timestamps are the whole of what the run is measured against, and that is deliberate: a
    /// stride of 30 *samples* is not 30 seconds, it is whatever those samples spanned. `Epoch` carries
    /// real instants so a run is measured in wall time, which is the only unit in which "ten minutes of
    /// sleep" means anything.
    public struct Epoch: Sendable, Equatable {
        public let start: Date
        public let end: Date

        /// Whether the classifier placed this epoch in sleep. Every stage but `.awake` is asleep:
        /// light, deep and REM are three kinds of sleep rather than three degrees of wakefulness.
        public let isAsleep: Bool

        public init(start: Date, end: Date, isAsleep: Bool) {
            self.start = start
            self.end = end
            self.isAsleep = isAsleep
        }
    }

    /// How long a run of sleep must last before it counts as the night having begun: ten minutes.
    ///
    /// Cited rather than fitted — see the type's comment for the `SO10` convention, the Busa et al.
    /// finding that the 1/5/10-minute choice moves no sleep variable, and why the AASM definition is
    /// not the one used here.
    public static let minimumSleepRunSeconds: TimeInterval = 600

    /// The night's detected span, or `nil` when no run of sleep reaches `minimumSleepRunSeconds`.
    ///
    /// **`epochs` must be in chronological order**, as the classifier produces them: "consecutive"
    /// here means consecutive in the array, and the caller is what makes that consecutive in time.
    ///
    /// `nil` is the documented word for *no night was found*, and a caller must treat it as absent
    /// rather than as an empty span — a night with a start and no end is not a shorter night. See
    /// `SleepSession.sleepPeriodSeconds` for the same distinction drawn one layer up.
    public static func sleepPeriod(of epochs: [Epoch]) -> (onset: Date, wake: Date)? {
        // Every maximal run of consecutive asleep epochs, kept only if its own span qualifies.
        var runs: [(onset: Date, wake: Date)] = []
        var index = 0

        while index < epochs.count {
            guard epochs[index].isAsleep else {
                index += 1
                continue
            }

            let onset = epochs[index].start
            var wake = epochs[index].end
            var cursor = index + 1
            while cursor < epochs.count, epochs[cursor].isAsleep {
                wake = epochs[cursor].end
                cursor += 1
            }

            // The run's span is its own first start to its own last end — not the sum of its epoch
            // durations, which the classifier counts at a nominal 30 seconds each and which therefore
            // says nothing about how long the run actually held.
            if wake.timeIntervalSince(onset) >= minimumSleepRunSeconds {
                runs.append((onset: onset, wake: wake))
            }

            index = cursor
        }

        // The first qualifying run opens the night and the last one closes it. Short runs and awake
        // epochs *between* them stay inside the span; everything outside it is the trim.
        guard let first = runs.first, let last = runs.last else { return nil }
        return (onset: first.onset, wake: last.wake)
    }
}
