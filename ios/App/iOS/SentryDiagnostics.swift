import Foundation
import Whoopsy

#if canImport(Sentry)
import Sentry
#endif

/// Installs the remote diagnostics sink, or leaves the app with none.
///
/// **This file is the only place the app knows the vendor's name, and that is the layer rule.**
/// `WhoopBLEManager` reports protocol facts into `Diagnostics` in the package, which names no SDK;
/// the Sentry client lives here, in the app target, where the package is linked. So `make build` on
/// the host and the 2,700-assertion suite compile `Diagnostics.swift` and never compile this — the
/// same arrangement `#if canImport(MapboxMaps)` uses in `offlineMaps`. A host build takes the
/// fallback below, which installs nothing and therefore behaves exactly like an unconfigured install.
///
/// **No DSN, no sink, and nothing is logged about it.** A fresh clone expands `WHOOPSYSentryDSN` to
/// an empty string, so this installs nothing and every `Diagnostics.record` in the data layer returns
/// immediately. The DSN is a deployment's own value and lives in the **gitignored**
/// `ios/App/Config/Whoopsy.local.xcconfig`, beside the Mapbox and sync secrets — a public repository
/// carries the empty default and the `#include?`, never one operator's project key.
///
/// **What is sent is metadata, and the switch that sends it is the user's.** The sink forwards
/// `DiagnosticsEvent` attributes verbatim and those are counts, frame types, sequence numbers,
/// payload lengths and outcome names by construction — no heart rate, R-R interval, oxygen candidate
/// or sample timestamp is ever put in one. The Anonymous diagnostics toggle
/// (`AppPreferences.analyticsEnabled`, off by default) is the switch: the SDK is not started until it
/// is on, and turning it off closes the client rather than filtering afterwards.
enum SentryDiagnostics {

    /// Installs the sink and applies the toggle. Returns whether a sink was installed at all.
    ///
    /// Called once from `WhoopsyApp.init`, which runs before the first view and therefore before any
    /// protocol code can emit.
    @discardableResult
    static func install(dsn rawDSN: String?, analyticsEnabled: Bool) -> Bool {
        guard let dsn = normalized(rawDSN) else { return false }
        #if canImport(Sentry)
        let sink = SentryDiagnosticsSink(dsn: dsn)
        Diagnostics.install(sink)
        Diagnostics.setEnabled(analyticsEnabled)
        return true
        #else
        // The SDK is absent from the host build, so there is nothing to forward to. `_ = dsn` keeps
        // the parameter meaningful in both arms rather than changing this signature per platform.
        _ = dsn
        _ = analyticsEnabled
        return false
        #endif
    }

    /// Trims the value an xcconfig expansion produces and treats an empty one as absent.
    ///
    /// An unset `$(WHOOPSY_SENTRY_DSN)` does not disappear from `Info.plist` — it expands to `""` —
    /// so `object(forInfoDictionaryKey:)` answers a non-`nil` empty string and a `guard let` on the
    /// result alone would install a sink that could never send.
    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

#if canImport(Sentry)

/// Forwards `Diagnostics` to Sentry's structured logs, and starts the client only while the toggle
/// is on.
///
/// **The lock is not for Sentry, it is for the two callers that use this without agreeing on a
/// thread.** `record` arrives on the BLE queue and `setEnabled` on the main actor, and the pair of
/// `isEnabled`/`isStarted` has to move together — a `record` that read `isEnabled == true` midway
/// through a stop would log into a client that had just been closed. The lock covers the two flags
/// and is released before the Sentry call, which is itself thread-safe and may touch the network.
///
/// **`SentrySDK.start` and `close` are the toggle, not `enableLogs` re-assignment.** Options are
/// fixed at start; flipping a field afterwards changes nothing. Closing is what stops the queue and
/// the transport, so an install with the toggle off opens no socket at all.
private final class SentryDiagnosticsSink: DiagnosticsSink, @unchecked Sendable {

    private let dsn: String
    private let lock = NSLock()
    private var isEnabled = false
    private var isStarted = false

    init(dsn: String) {
        self.dsn = dsn
    }

    deinit {
        if isStarted {
            SentrySDK.close()
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        let wasEnabled = self.isEnabled
        self.isEnabled = isEnabled
        lock.unlock()

        if isEnabled, !wasEnabled {
            startIfNeeded()
        } else if !isEnabled, wasEnabled {
            stopIfNeeded()
        }
    }

    func record(_ event: DiagnosticsEvent) {
        lock.lock()
        let enabled = isEnabled
        lock.unlock()
        guard enabled else { return }

        // `info` rather than `debug`: the archive a sideloaded build produces is read days later, and
        // Sentry's default log retention drops the lower levels first.
        SentrySDK.logger.info(event.name, attributes: event.attributes)
    }

    /// Start once. `enableLogs` is the structured-log switch added in 8.55 and stable from 9.0; the
    /// rest are defaults stated rather than assumed — no PII, no performance tracing, no extra user
    /// or device context beyond what the crash report carries.
    private func startIfNeeded() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        SentrySDK.start { options in
            options.dsn = self.dsn
            options.enableLogs = true
            options.sendDefaultPii = false
        }
    }

    private func stopIfNeeded() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        lock.unlock()

        SentrySDK.close()
    }
}

#endif
