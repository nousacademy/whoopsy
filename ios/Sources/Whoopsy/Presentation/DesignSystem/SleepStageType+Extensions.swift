import SwiftUI

/// A sleep stage's colour, for every screen that draws one.
///
/// **This file exists because the mapping was about to have a second copy.** It lived as a `private
/// func color(_:)` inside `HypnogramChartView`, which made it look like a view detail rather than the
/// app's single answer to "what colour is Deep" — and the typical-range card on the sleep detail
/// screen needs exactly that answer. A card carrying its own four-case switch would have been the
/// second definition, which is the drift `RecoveryState.color`'s own doc comment records happening
/// twice ("Home drawing `recoveryGreen` unconditionally while the Recovery tab tiered it"). So the
/// mapping is lifted here and `HypnogramChartView` now reads through it — the same consolidation
/// `SleepBand+Extensions.swift` performs for the band scale, and the shape
/// `RecoveryState+Extensions.swift` establishes.
///
/// The tokens are unchanged and are the ones the hypnogram has always drawn: the four `Theme.sleep*`
/// values. Nothing here re-picks a colour, so no screen moves. The four are deliberately **not**
/// ranked — `awake` is not "bad" and `deep` is not "good", because a stage is a category rather than
/// a score, which is why this is a plain switch and not a gradient.
extension SleepStageType {
    public var color: Color {
        switch self {
        case .awake: return Theme.sleepAwake
        case .light: return Theme.sleepLight
        case .deep: return Theme.sleepDeep
        case .rem: return Theme.sleepRem
        }
    }
}
