import Foundation
import SwiftUI
import Whoopsy

enum SleepStageTypeTests {
    static func run() async throws {
        // ── 6. The two mappings the card draws through ───────────────────────────────────────────────
        //
        // The stage-to-colour switch was lifted out of `HypnogramChartView` so this card could not be a
        // second definition of it. This is the assertion that fails if anyone writes a second one: the
        // four tokens the hypnogram has always drawn, unchanged, reachable from one place.
        assertTest(
            SleepStageType.awake.color == Theme.sleepAwake
                && SleepStageType.light.color == Theme.sleepLight
                && SleepStageType.deep.color == Theme.sleepDeep
                && SleepStageType.rem.color == Theme.sleepRem,
            "`SleepStageType.color` is the app's one stage-to-token mapping, and it is the hypnogram's")

    }
}
