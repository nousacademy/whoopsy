import SwiftUI

extension SleepNeedBreakdown.Component {
    /// The one place a need component becomes a `Color`.
    ///
    /// It cannot be a property on the enum: that type is in `Domain`, which imports only `Foundation`
    /// and cannot name a `Color`. This is the shape `RecoveryState+Extensions.swift` establishes and
    /// `SleepStageType+Extensions.swift` copies, and it is what keeps the need card's bar segments and
    /// its legend swatches from being coloured in two places — the same failure that had Home drawing
    /// every recovery ring green while the Recovery tab tiered it.
    ///
    /// The two greys are **picked rather than measured**, and this is the one colour decision in the
    /// app that is. Every other token in `Theme` was sampled off a reference screenshot with the P3 →
    /// sRGB conversion written down beside it; the screenshot this card was built from is not a file on
    /// disk, so there is nothing here to sample. What the tokens encode is the reference's *ordering* —
    /// the base term is the darker of the two and the debt the lighter — which is the part of the
    /// choice a reader can actually see, and the exact tones are free to move.
    public var color: Color {
        switch self {
        case .minimumAndStrain: return Theme.sleepNeedBaseline
        case .debt: return Theme.sleepNeedDebt
        }
    }
}

extension SleepNeedBreakdown.Component {
    /// Whether the card prints this part with a leading `+`.
    ///
    /// The reference's convention, and it is doing work: its `Healthy Minimum` is unsigned and its
    /// `Recent Strain` and `Sleep Debt` carry a `+`, so a reader can see at a glance which figures are
    /// the night's base requirement and which are added on top of it.
    ///
    /// **The first part is unsigned here, and that is not a guess about what is in it.** It does
    /// contain a strain term — it is `baseline + recent strain`, which is why it is named for both —
    /// but it is drawn as the remainder of the need once the debt is taken out: it is what the night
    /// would have needed had the user been in perfect sleep credit. Signing a term that has had a
    /// subtraction applied to it would claim it was added to something the card does not draw.
    public var isIncrement: Bool {
        switch self {
        case .minimumAndStrain: return false
        case .debt: return true
        }
    }
}
