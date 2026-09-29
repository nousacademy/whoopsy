import SwiftUI

/// The offline map's **drawing** half — the one method that needs `SwiftUI`, on top of the control
/// surface ``OfflineMapServing`` declares in `Domain`.
///
/// ## Why this is a second protocol and not the same one
///
/// The switch that starts a download is thrown from `LiveSessionUseCase`, which is `Domain`, so the
/// control surface has to be reachable from there — and a `Domain` type holding a `Presentation`
/// protocol would invert the one dependency rule this codebase states and enforces. `map(route:unit:)`
/// is the only member that could not go with it: it takes `ActivityRoute` and returns `AnyView`, and
/// both are `Presentation` types.
///
/// So the split is at that member and nowhere else. Everything a `Domain` caller does goes through
/// ``OfflineMapServing``; everything a `View` does goes through this.
///
/// ## Why `map` returns `AnyView`
///
/// Because the concrete type is in a module this package cannot name. `MapboxRouteMapView` lives in
/// `App/Map/`, which the SwiftPM build never compiles and which exists only in the Xcode app target —
/// the same place, and for the same reason, as the Live Activity widget. `AnyView` is the price of a
/// seam that has to be drawn by code the compiler of this half cannot see; it is paid once per card, on
/// a page that holds one map.
@MainActor
public protocol OfflineMapRendering: OfflineMapServing {

    /// The route card for a region that is `.ready`.
    ///
    /// Only ever called on that branch — `RouteMapRenderer.resolve` is what guarantees it — so an
    /// implementation may assume its tiles are present.
    ///
    /// `unit` is threaded through rather than read inside, because the caption under the card prints
    /// distance and speed in the device's own system and the renderer must not form a second opinion
    /// about which one that is.
    func map(route: ActivityRoute, unit: ActivityRoute.Unit, regionID: String) -> AnyView
}

/// The offline map, in a build that does not have one.
///
/// **This is not a stub and its answers are not placeholders.** It is the correct implementation for
/// every build where the SDK is absent, which is every host build, the test runner, and any iOS build
/// where the package did not resolve — and its `map` draws **the same `MapKit` card the page drew
/// before this feature existed**, so a build without Mapbox is a build that behaves exactly as it
/// always did rather than one with a hole in it.
///
/// It is also the environment's default value, which is the property that makes the whole seam safe: a
/// view that is never handed a service falls back to this, and the fallback is today's behaviour. The
/// failure mode of forgetting to inject is therefore a card that needs a network, not a blank one.
public final class UnavailableOfflineMaps: OfflineMapRendering {

    /// `nonisolated` because the environment's default value is built in a nonisolated static
    /// initialiser. The type holds nothing, so there is no state for the main actor to protect.
    public nonisolated init() {}

    public var isSupported: Bool { false }

    /// `.unsupported` rather than `.absent`, and the distinction is the point of having both: `.absent`
    /// means *this app could download here and has not*, which is a state the user can act on. This is
    /// *this build cannot*, which is not.
    public func state(for regionID: String) -> OfflineMapState { .unsupported }

    /// A no-op, and the switch is never offered, so nothing reaches it. It does not throw and it does not
    /// log a failure: there is no failure here, only a capability this build does not have.
    public func download(
        regionID: String, latitude: Double, longitude: Double,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async {}

    public func cancelDownload() {}

    public func delete(regionID: String) async {}

    /// The iOS map, unchanged. See the type's own note: this is the reason a build without the SDK
    /// loses nothing.
    public func map(route: ActivityRoute, unit: ActivityRoute.Unit, regionID: String) -> AnyView {
        AnyView(ActivityRouteMapView(route: route, unit: unit))
    }
}

// **There is no environment value for this, and there was one.** A `\.offlineMapService` key with
// `UnavailableOfflineMaps` as its default was the first shape, on the reasoning that the thing which
// varies — whether an SDK exists — is a fact about the *build* rather than about the page.
//
// It was removed because it gave the same object two routes to the same screen. `DIContainer` already
// holds the instance as a stored `let` and already defaults it to `UnavailableOfflineMaps`, so the
// safety the environment key was there to provide is provided twice — and a second route is a second
// answer waiting to differ from the first, which is what `ActivityDetailViewModel.offlineMaps` being a
// plain injected dependency avoids. `MainContainerView` is this repo's only place a view model is
// built and `DIContainer` its only source of use cases; a view reached past both to an environment
// value held by no one in particular.
