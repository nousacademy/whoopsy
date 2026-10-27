import Foundation

/// Which signal decided that the wrist was still enough for a night to exist.
///
/// **A stored row records the rule that produced it**, and for a night this app classifies there are
/// now two rules producing the same *kind* of answer from different evidence:
///
/// - `motion` — 30-second `R21` motion epochs, which exist only while a phone was connected and
///   recording. The stronger source: 100 Hz per axis, so a still window is genuinely still.
/// - `samples` — the accelerometer carried by every `R18` record (`mean acceleration X/Y/Z`, three
///   `f32` in g), folded into the same 30-second windows as `1 + mean |Δa|`. The weaker source: one
///   mean vector per second, so a brief movement inside a second is averaged before it is seen.
///
/// **Why the distinction has to be stored rather than inferred.** The strap does not bank `R21` in
/// flash [measured 2026-10-26], so every phone-away night that produces a session comes from the
/// sample spine. A row that recorded only `stager-v1` would make the two indistinguishable — the same
/// night would look equally supported whichever evidence carried it, which is the provenance defect
/// `strains.algorithm` and `sleeps.algorithm` exist to prevent. noop draws the same line with an
/// `hrOnly` flag on its sessions.
///
/// **It does not affect staleness.** `SleepAlgorithm` still answers "is this night's rule current",
/// because both spines are the same stage model; this says only which sensor fed it. A reader that
/// wants "how well supported is this night" reads this, and a reader that wants "does it need
/// re-running" reads `algorithm` + `scored_through`.
public enum SleepStillnessSpine: String, CaseIterable, Sendable {
    /// `R21` motion epochs recorded live, while the phone was connected.
    case motion

    /// The accelerometer carried by drained `R18` records — see `SampleStillnessMath`.
    case samples

    /// **Both, window by window** — `motion` where the phone was recording and `samples` where it was
    /// not. The overnight measurement of 2026-10-27 is why this exists: a phone connected for two
    /// evening hours and away for the night gave the classifier 242 `R21` epochs, all of them awake,
    /// and the earlier all-or-nothing rule read that as "motion is present, so the samples say
    /// nothing" — 13 hours of `R18` stillness was discarded and the night was refused. The sources
    /// are evidence about *different windows*, so the choice belongs to the window, not to the night.
    case merged

    /// The stored spelling, or `nil` for a row written before `v38` or by a producer that has no
    /// spine at all (an imported night).
    public init?(stored: String?) {
        guard let stored, let value = SleepStillnessSpine(rawValue: stored) else { return nil }
        self = value
    }
}
