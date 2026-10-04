import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The Home screen's sources

/// The Home screen's four new data sources, each asserted at the layer that can get it wrong.
///
/// The screen itself is not asserted here — it is a view, and its dashes follow from these values
/// being `nil`. What is asserted is that they *are* `nil` when there is nothing behind them, because
/// every one of these four has a plausible-looking wrong answer available: a fabricated `100` for a
/// disconnected strap's battery, a `0` for a day with no steps, a `0.0` for a day with no stress
/// score, and an in-memory array that loses a workout at the next launch.
///
/// The blocks live in sibling files, one per topic, cut at this section's own `// ---- Title ----`
/// boundaries and moved verbatim — so the counterpart of a Home source file sits beside this one and
/// this file says only which of them run, and in what order.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
enum HomeSourceTests {
    static func run() async throws {
        try await HomeActivityMenuTests.run()
        try await HomeRecordedWorkoutTests.run()
        try await HomeMetricSourceTests.run()
        try await HomeDeviceSettingsTests.run()
        try await HomeStressMonitorTests.run()
        try await HomeRingsAndCalendarTests.run()
        try await HomeMetricWeekTests.run()
        try await HomeReceptiveInactivitiesTests.run()
    }
}
