import SwiftUI

/// A fasting zone's fill, and which of the two inks its letters take.
///
/// The zone itself and its boundaries are `FastingZone` in `Domain`, which imports only `Foundation`
/// and so cannot name a `Color` — the same split, and the same reason, as
/// `RecoveryState+Extensions.swift` and `SleepStageType+Extensions.swift` above it. This file is the
/// app's **only** zone-to-`Color` mapping: a second copy would be the drift those two files record,
/// where one value drawn on two screens comes to mean two different things.
///
/// The tokens are the five `Theme.fastingZone*` fills. Nothing here re-picks a colour, so there is no
/// judgement in this file — only the assignment the user specified, plus the ink rule that keeps the
/// letters legible on the two pale fills.
extension FastingZone {

    /// Which ink the letters take on this zone's fill.
    ///
    /// **This exists as a named, assertable value rather than only as `inkColor`.** The decision worth
    /// pinning is *which fills are pale* — that is what the user chose, and it is what a screenshot of
    /// a single zone cannot see — but the mapping to a token cannot be asserted at all: a test
    /// comparing `inkColor` against `Theme.zonePillInkOnPale` would only prove that the switch returns
    /// the arm it returns, which is the "expected value computed by the code under test" trap
    /// `CLAUDE.md` records. Stating the depth separately keeps the decision honest and the token
    /// mapping trivial, and §20 asserts the five depths.
    ///
    /// The split is not a taste call: yellow and white are the two fills where white letters measure
    /// **1.5:1** and **1.0:1** — the second being literally invisible — against **12.2:1** and
    /// **18.4:1** for the near-black ink. See the fill tokens' comment in `Theme` for the full table.
    public enum InkDepth: Sendable {
        /// A fill dark enough to carry white letters.
        case onDeep

        /// A fill light enough that white letters would disappear into it.
        case onPale
    }

    public var inkDepth: InkDepth {
        switch self {
        case .anabolic, .catabolic, .deepKetosis: return .onDeep
        case .fatBurning, .ketosis: return .onPale
        }
    }

    /// The letters' colour on this zone's fill.
    public var inkColor: Color {
        switch inkDepth {
        case .onDeep: return Theme.zonePillInkOnDeep
        case .onPale: return Theme.zonePillInkOnPale
        }
    }

    /// The pill's fill.
    ///
    /// The five colours are the user's specification and are drawn in the scale's own order — red,
    /// orange, yellow, white, blue/violet, anabolic through deep ketosis. **Two of them are
    /// deliberately not the app's existing verdict colours**: `recoveryRed` and `recoveryYellow` mean
    /// *worse* and *unchanged* on a recovery ring, and a zone is a category rather than a score.
    public var color: Color {
        switch self {
        case .anabolic: return Theme.fastingZoneAnabolic
        case .catabolic: return Theme.fastingZoneCatabolic
        case .fatBurning: return Theme.fastingZoneFatBurning
        case .ketosis: return Theme.fastingZoneKetosis
        case .deepKetosis: return Theme.fastingZoneDeepKetosis
        }
    }
}
