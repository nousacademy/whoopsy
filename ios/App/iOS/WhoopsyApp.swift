import SwiftUI
import Whoopsy

// **The only `#if canImport` in this file, and it is here for the reason `Package.swift` excludes
// `App/Map/` at all.** Mapbox Maps is an iOS-only binary artifact and cannot be a dependency of the
// package — which also declares `.macOS(.v14)` for the host executable and the 1,700-assertion test
// runner. So `App/Map/` is compiled only by this Xcode target, and this import is the one line that
// has to know whether the SDK was actually linked.
//
// It guards the *import*, and the same condition guards the call site below rather than being trusted
// to agree with it: a build whose package failed to resolve gets `UnavailableOfflineMaps` — the card
// this page drew before the feature existed — with no crash and no half-configured SDK.
#if canImport(MapboxMaps)
import MapboxMaps
#endif

/// The executable entry point for the Whoopsy iOS Application on iPhone 12+.
@main
struct WhoopsyApp: App {
    @State private var environment: AppEnvironment

    init() {
        let isXcodeCanvas = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        _environment = State(initialValue: AppEnvironment(
            container: isXcodeCanvas
                ? .preview
                : DIContainer(useMockBLE: false, offlineMaps: Self.offlineMaps)
        ))
    }

    /// The offline map this build can offer, decided once and before anything else touches the SDK.
    ///
    /// **`configure()` runs first, and the ordering is load-bearing rather than tidy.**
    /// `MapboxOptions.accessToken` has to be set before *any* Mapbox object exists, and
    /// `MapboxOfflineMaps.init` immediately builds a `TileStore` and starts walking it. So the token is
    /// read and pinned first, and the real implementation is constructed only on the branch where that
    /// succeeded.
    ///
    /// **A build with no token gets `UnavailableOfflineMaps` rather than a configured-looking SDK.** It
    /// is not a stub: it draws the same `MapKit` card this page drew before the feature, reports
    /// `isSupported == false`, and so the session screen never offers the switch. That is the honest
    /// answer for a clone that has not been through `README.md` §Building — the alternative, offering a
    /// switch whose only outcome is a blank frame, is the fabricated-capability failure this repo's
    /// absence rules exist to prevent.
    ///
    /// **The preview branch above deliberately does not get this.** `DIContainer.preview` keeps the
    /// default, so a canvas draws the `MapKit` card — which is what a preview can actually render,
    /// needing neither a token nor a network.
    private static var offlineMaps: any OfflineMapRendering {
        #if canImport(MapboxMaps)
        if MapboxSetup.configure() {
            return MapboxOfflineMaps()
        }
        #endif

        return UnavailableOfflineMaps()
    }

    var body: some Scene {
        WindowGroup {
            WhoopsyAppView(environment: environment)
        }
    }
}
