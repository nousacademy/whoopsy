import Foundation

/// What is on disk for one offline map region — the whole of what the route card needs to know about a
/// map SDK it cannot see.
///
/// ## Why the state is a value here rather than a query into the SDK
///
/// The offline map is **Mapbox**, and Mapbox cannot be a dependency of this package. It is an iOS-only
/// binary artifact, and `Package.swift` declares `.iOS(.v17)` *and* `.macOS(.v14)` on a library that the
/// host executable, `make build` and the 1,668-assertion test runner all link — so declaring it would
/// break every one of them. A `#if canImport(MapboxMaps)` inside `Sources/` cannot rescue that either,
/// because a manifest's dependencies are not platform-conditional: the import is simply false on the
/// host, which means the whole feature would silently not exist in a build that compiled.
///
/// So the SDK lives in `App/Map/`, outside the package, arriving only through the Xcode project — the
/// arrangement `App/LiveActivity/` already uses for `WidgetKit`. Everything in this file is the part of
/// that feature the *package* is allowed to hold: the vocabulary, the decision, and the seam's control
/// half.
///
/// ## The four states, and which of them draws a map
///
/// `unsupported`, `absent`, `downloading` and `failed` all resolve to the iOS map. **Only `ready` draws
/// the offline one**, and that is the whole safety property of this design: a switch the user turned on
/// before losing signal can never leave them with an empty card, because until the tiles are actually on
/// disk the card they were already seeing is still drawn by the same `MapKit` code path as always.
public enum OfflineMapState: Equatable, Sendable {

    /// This build has no map SDK behind it — every host build, and any iOS build where the package
    /// failed to resolve. Distinguishable from `absent` so the session screen can explain the difference
    /// rather than offering a switch that cannot do anything.
    case unsupported

    /// Nothing has been downloaded for this region. The ordinary state before the user asks, and the
    /// state a region returns to if it is deleted.
    case absent

    /// A download is in flight, `0…1`. Drawn as a progress figure on the session screen and nothing else:
    /// a half-downloaded region is **not** half a map, so the card ignores this state entirely.
    case downloading(fraction: Double)

    /// The tiles are on disk and the region can be drawn with no network. The only state that reaches
    /// the card.
    case ready

    /// The download failed, carrying **an authored sentence** and never a bare error.
    ///
    /// The same rule the route's own refusals follow (`LiveSessionUseCase.routeError`): a `String` the
    /// user can read and act on, because the failure they will actually hit — no signal, which is the
    /// whole reason they turned the switch on — is not a thing an `Error` description explains.
    case failed(String)
}

/// Which renderer a session's route card draws with.
///
/// **A decision, and the only place it is made.** The view model resolves one of these once and the view
/// switches on it, so the rule cannot be restated — and mis-stated — inside a `body`, which is this
/// repo's standing arrangement for anything the runner is supposed to be able to check.
public enum RouteMapRenderer: Equatable, Sendable {

    /// The iOS map — `ActivityRouteMapView`, exactly as this page has always drawn it.
    case mapKit

    /// Mapbox, drawing from the tiles on disk for `regionID`.
    case offline(regionID: String)

    /// The renderer for a session, given the state of the region it asked for.
    ///
    /// ## `.offline` is reachable from `.ready` alone
    ///
    /// Every other state resolves to `.mapKit`, and each for its own reason rather than by a shared
    /// default. `unsupported` has no SDK to draw with. `absent` has nothing on disk. `downloading` is a
    /// download that has not finished, and half a tile set draws a map with a hole in it. `failed` is the
    /// offline case the user turned the switch on to survive, and the honest response to it is the map
    /// that needs a network — because a card with nothing on it is worse than a card that might not
    /// resolve, and the user still has the tiles' absence recorded on their session.
    ///
    /// ## `session` and `state` are two halves of one question
    ///
    /// Neither answers it alone. `session.offlineRegionID` names *which* region this session asked for —
    /// `nil` for the switch that was off, which is most sessions — and `state` says what became of it.
    /// The caller therefore passes the state **of that region**, and a session with no id passes
    /// ``OfflineMapState/absent``, which is literally true of it: nothing was downloaded for this
    /// session.
    ///
    /// The region id is returned rather than re-derived by the view, because the view has no way to
    /// derive it and the two must not be free to disagree about which region is on screen.
    public static func resolve(session: WorkoutSession, state: OfflineMapState) -> RouteMapRenderer {
        guard let regionID = session.offlineRegionID, state == .ready else { return .mapKit }
        return .offline(regionID: regionID)
    }
}

/// The offline map's control surface: the switch, the state it is in, and the two ways to change it.
///
/// ## Why this half is in `Domain` and the drawing half is not
///
/// **This protocol is held by `LiveSessionUseCase`, which is `Domain`.** The session screen's switch is
/// what starts a download, so the use case needs a way to ask for one — and a `Domain` type reaching
/// for a `Presentation` protocol would invert the one dependency rule this codebase states and enforces
/// (`Presentation → Domain ← Data`, never the reverse).
///
/// So the seam is split along the line that was already there. Everything here is expressible in
/// `Foundation`: a `Bool`, a value type, two `Double`s and a `String`. `OfflineMapRendering` in
/// `Presentation` refines it with the one method that needs `SwiftUI` — `map(route:unit:regionID:)`,
/// returning `AnyView` and taking `ActivityRoute`. The use case never sees that half, and the view
/// never sees this one without it.
///
/// `@MainActor` for `CoreLocationTrackingService`'s reason: this is a stateful capability service whose
/// callbacks land on the main actor, and `@Observable` view models call it from there.
@MainActor
public protocol OfflineMapServing: AnyObject, Sendable {

    /// Whether this build has a map SDK behind it at all.
    ///
    /// Read before the switch is offered, not after it is turned on — the switch is drawn disabled with
    /// a sentence rather than accepted and then quietly ignored.
    var isSupported: Bool { get }

    /// What is on disk for `regionID`. Cheap: no network, no tile store walk, just this app's own record
    /// of what it asked for.
    func state(for regionID: String) -> OfflineMapState

    /// Downloads a tile region covering a radius around a point, while the user still has signal.
    ///
    /// The centre is a plain coordinate pair rather than a value type, because the caller is
    /// `LiveSessionUseCase` holding a first GPS fix and this protocol must not drag `ActivityRoute` —
    /// a `Presentation` type — into a signature that a non-drawing screen also calls.
    ///
    /// ## Why progress is a callback and not a return value
    ///
    /// **`await download(...)` returns once, at the end**, so a caller that only awaited it would have
    /// no way to tell a download in progress from one that never started — and `OfflineMapState`'s
    /// `.downloading(fraction:)` would carry a `0` nothing ever moved. A fraction that is always zero is
    /// a fabricated figure on a screen, which is the thing this codebase's absence rules exist to
    /// prevent, so the progress is pushed out as it arrives rather than invented at the call site.
    ///
    /// `onProgress` arrives on the **main actor**, in `0…1`, possibly many times and possibly not at
    /// all: Mapbox reports progress from a `TileStore` worker thread, and an implementation must hop
    /// before calling it. It is never called after this method returns.
    ///
    /// **`@escaping` is required rather than stylistic, and it is the only escaping closure parameter
    /// in this protocol.** A conforming implementation has to hand the callback to a framework whose
    /// own progress parameter is escaping — `TileStore.loadTileRegion`'s `progress:` closure is invoked
    /// from a worker thread long after the call returns — and Swift refuses to capture a non-escaping
    /// parameter in an escaping closure. Declaring it here is what makes the capture legal; the
    /// "never called after this method returns" promise above is this protocol's own contract and is
    /// unaffected by the annotation, which describes what the *implementation* may do with the value
    /// rather than what it does.
    func download(
        regionID: String,
        latitude: Double,
        longitude: Double,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async

    /// Abandons an in-flight download. A no-op when nothing is downloading.
    ///
    /// **Turning the switch off after the download finished does not call this**, and must not: the tiles
    /// are already on disk and the session's row already names them, so cancelling there would leave a
    /// region the session claims and the store does not have.
    func cancelDownload()

    /// Removes a region's tiles from disk.
    ///
    /// **Note what this cannot do.** `TileStore.removeTileRegion(forId:)` unmarks a region's tile packs;
    /// it does not delete them. Disk is reclaimed by the store's own quota accounting, not by this call,
    /// which is why `MapboxSetup` sets a quota rather than relying on deletion to bound the footprint.
    func delete(regionID: String) async
}
