import Foundation

/// One protocol-diagnostic line, in a shape a sink can carry off the phone.
///
/// **The attributes are metadata, and that is a rule rather than a convention.** No heartbeat value,
/// no R-R interval, no oxygen candidate and no sample timestamp may be put in this dictionary — the
/// sink that forwards it is a third-party network service, and the Anonymous diagnostics toggle's
/// caption promises that turning it on never uploads a biometric. Counts, frame types, payload
/// lengths, sequence numbers and outcome names are what the hardware questions need, and the raw
/// values stay in `Documents/spo2-candidate.txt`.
public struct DiagnosticsEvent: Equatable, Sendable {
    public let name: String
    public let attributes: [String: String]

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }
}

/// Where diagnostics go when a build has somewhere to send them.
///
/// A conforming sink is installed once, from the app target, and is inert until `setEnabled(true)`.
/// `record` may be called from the BLE queue, so an implementation must be thread-safe and must not
/// block that queue on a network call.
public protocol DiagnosticsSink: Sendable {
    func record(_ event: DiagnosticsEvent)
    func setEnabled(_ isEnabled: Bool)
}

/// The one seam between the app's protocol code and a remote diagnostics service.
///
/// **This type names no vendor, and that is the layer rule.** `WhoopBLEManager` lives in the data
/// layer and emits here; the Sentry implementation lives in the iOS app target, where the SDK could
/// be linked, and an unconfigured build installs nothing. So `swift build` on the host and the
/// 2,700-assertion suite compile this file and never compile the SDK — the same arrangement
/// `#if canImport(MapboxMaps)` uses for the offline map.
///
/// **Absence is the default and it is silent.** No sink means `record` returns immediately, which is
/// what a fresh clone, an unconfigured install and every preview get. There is no queue that grows
/// while nobody is listening.
public enum Diagnostics {

    /// `NSLock` rather than an actor because `record` is called from the BLE queue and from the
    /// main actor, and neither may `await`. The sink is copied out before it is called, so a sink
    /// that installs another sink cannot deadlock this one.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var sink: (any DiagnosticsSink)?
    }

    private static let state = State()

    /// Installs the sink, or clears it with `nil`.
    public static func install(_ sink: (any DiagnosticsSink)?) {
        state.lock.lock()
        state.sink = sink
        state.lock.unlock()
    }

    /// Forwards the toggle. A build with no sink ignores it.
    public static func setEnabled(_ isEnabled: Bool) {
        state.lock.lock()
        let sink = state.sink
        state.lock.unlock()
        sink?.setEnabled(isEnabled)
    }

    /// Records one event. A build with no sink — every build without a DSN — does nothing.
    public static func record(_ name: String, _ attributes: [String: String] = [:]) {
        state.lock.lock()
        let sink = state.sink
        state.lock.unlock()
        sink?.record(DiagnosticsEvent(name: name, attributes: attributes))
    }
}
