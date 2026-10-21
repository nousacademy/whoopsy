import Foundation
import Whoopsy

// MARK: - 16. The diagnostics hub

/// A file of §16's body, called by `StepTests.run()` after `StrapEventDecoderTests`.
///
/// **What it proves is the seam, not the vendor.** `Diagnostics` is the only coupling between the
/// BLE layer and whatever carries a line off the phone — `SentryDiagnostics` is the app target's
/// implementation and neither compiles on the host nor is asserted here. What is asserted is that an
/// installed sink receives exactly the event the caller built, that `install(nil)` really removes it,
/// that the toggle is forwarded, and that a replacement wins rather than both hearing the call.
///
/// **The metadata rule is a design rule and not something this file can see.** No assertion here can
/// tell a heart rate from a payload length — the rule lives in the call sites, each of which passes
/// counts and names only, and in `DiagnosticsEvent`'s own doc comment.
enum DiagnosticsTests {
    static func run() async throws {
        /// A sink that keeps what it was handed, thread-safe because `Diagnostics.record` is called
        /// from the BLE queue in production and this file records from the runner's task.
        final class SpySink: DiagnosticsSink, @unchecked Sendable {
            private let lock = NSLock()
            private var events: [DiagnosticsEvent] = []
            private var enabledStates: [Bool] = []

            func record(_ event: DiagnosticsEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            func setEnabled(_ isEnabled: Bool) {
                lock.lock()
                enabledStates.append(isEnabled)
                lock.unlock()
            }

            var recorded: [DiagnosticsEvent] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }

            var forwardedStates: [Bool] {
                lock.lock()
                defer { lock.unlock() }
                return enabledStates
            }
        }

        // A clean starting point: the suite runs in one process and an earlier section may have
        // installed nothing, but this file must not depend on that.
        Diagnostics.install(nil)

        // MARK: Delivery

        let first = SpySink()
        Diagnostics.install(first)
        Diagnostics.record("connect_pass", ["generation": "whoop5", "realtimeArm": "sent"])

        assertTest(
            first.recorded == [
                DiagnosticsEvent(
                    name: "connect_pass",
                    attributes: ["generation": "whoop5", "realtimeArm": "sent"])
            ],
            "an installed sink receives the event verbatim, name and attributes")

        Diagnostics.record("drain_concluded")
        assertTest(
            first.recorded.last == DiagnosticsEvent(name: "drain_concluded"),
            "an event with no attributes arrives as one with an empty dictionary, not as a missing one")

        // MARK: The toggle

        Diagnostics.setEnabled(true)
        Diagnostics.setEnabled(false)
        assertTest(
            first.forwardedStates == [true, false],
            "setEnabled forwards each call in order, so the switch reaches the sink both ways")

        // MARK: Replacement

        let second = SpySink()
        Diagnostics.install(second)
        let afterFirst = first.recorded.count
        let firstStates = first.forwardedStates.count

        Diagnostics.record("proprietary_frame", ["payloadBytes": "12"])
        Diagnostics.setEnabled(true)

        assertTest(
            first.recorded.count == afterFirst && first.forwardedStates.count == firstStates,
            "a replaced sink hears nothing more — neither a record nor the toggle")
        assertTest(
            second.recorded == [
                DiagnosticsEvent(name: "proprietary_frame", attributes: ["payloadBytes": "12"])
            ],
            "the replacement receives what was emitted after it was installed")
        assertTest(
            second.forwardedStates == [true],
            "the replacement receives the toggle from the point it was installed")

        // MARK: Removal

        Diagnostics.install(nil)
        let secondAfterRemoval = second.recorded.count
        Diagnostics.record("strap_event", ["event": "13"])
        Diagnostics.setEnabled(false)

        assertTest(
            second.recorded.count == secondAfterRemoval && second.forwardedStates == [true],
            "install(nil) clears the hub: an unconfigured build records and toggles into nothing")

        // Leave the process-wide hub as it was found, so this file adds no state a later section
        // could observe.
        Diagnostics.install(nil)
    }
}
