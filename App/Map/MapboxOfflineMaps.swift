import CoreLocation
import MapboxMaps
import SwiftUI
import Whoopsy

/// The offline map, for a build that has one.
///
/// ## Where this sits
///
/// `OfflineMapServing` (`Domain`) is the control surface `LiveSessionUseCase` throws the switch
/// through; `OfflineMapRendering` (`Presentation`) adds the one method that returns a view. This class
/// is the implementation of both, and it is the only object in the app that holds Mapbox state.
///
/// **It lives outside the package because it must.** Mapbox Maps is an iOS-only binary artifact, and
/// `Package.swift` declares `.iOS(.v17)` *and* `.macOS(.v14)` on a library that the host build and the
/// 1,700-assertion test runner both link — the same arrangement `App/LiveActivity/` already uses for
/// `WidgetKit`. Everything this class *decides* is therefore written down in `Domain` where the suite
/// can reach it; what is left here is the SDK calls, which no build on a development machine compiles
/// except `make ios`.
///
/// ## The safety property, restated because this is the file that could break it
///
/// `RouteMapRenderer.resolve` draws the offline card from `OfflineMapState.ready` alone. Every other
/// state draws `MapKit`. So the worst outcome of a bug in this file is a card that needs a network —
/// which is what the page drew before this feature existed — and never a blank card. That is why
/// `isSupported` answers from `MapboxSetup.isConfigured` rather than from "did the SDK link": a build
/// with no token behaves exactly like `UnavailableOfflineMaps`.
@MainActor
final class MapboxOfflineMaps: OfflineMapRendering {

    /// The app's own tile store — the same instance `MapboxSetup.configure()` pinned for the maps to
    /// read. Never a second `TileStore`: a store per file path is Mapbox's own rule, and filling one the
    /// map does not read is the silent blank-frame failure this file exists to avoid.
    private let tileStore: TileStore

    /// Held rather than built per call for `DIContainer`'s stored-`let` reason: this is the object that
    /// creates descriptors and loads style packs, and a fresh one per read would be a second client of
    /// the same store with no benefit.
    private let offlineManager: OfflineManager

    /// This app's record of what it has asked for, keyed by region id.
    ///
    /// **In memory, and that is a constraint rather than a shortcut.** `OfflineMapServing.state(for:)`
    /// is synchronous, while every read the `TileStore` offers is completion-callback based — so there
    /// is no way to answer it from the store on demand. `prime()` is what makes the answer survive a
    /// relaunch, by walking what is already on disk once at construction.
    private var states: [String: OfflineMapState] = [:]

    private var inFlight: Cancelable?

    /// Set when a cancel arrives before there is anything to cancel — see `cancelDownload()`.
    private var cancelRequested = false

    /// The one-time walk of the tile store, started in `init`.
    private var priming: Task<Void, Never>?

    init() {
        self.tileStore = TileStore.default
        self.offlineManager = OfflineManager()
        // Started here rather than on first use, because the *card* is the first reader and it asks
        // before any download has happened: without this, reopening a page for a region downloaded
        // yesterday would report `.absent` and draw the `MapKit` card over tiles that are on disk.
        //
        // `self` is usable in an escaping closure at this point — every stored property above is
        // initialised, so the class is past phase 1.
        self.priming = Task { @MainActor [weak self] in await self?.prime() }
    }

    // MARK: - OfflineMapServing

    /// Whether the SDK was configured, which is a question about the build's `Info.plist` and not about
    /// the network.
    var isSupported: Bool { MapboxSetup.isConfigured }

    func state(for regionID: String) -> OfflineMapState { states[regionID] ?? .absent }

    func download(
        regionID: String,
        latitude: Double,
        longitude: Double,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async {
        // The store walk settles what is already on disk before anything overwrites the record for this
        // region. Without this await a download started in the first moments after launch could be
        // followed by `prime()` writing `.ready` or `.absent` over the state it just reached.
        await priming?.value

        // A task cancelled before it started has nothing to abandon, so nothing is left to cancel and
        // `withTaskCancellationHandler` below would have no `Cancelable` to reach. The session screen
        // turns the switch off by cancelling this task, so this is a reachable path and not a formality.
        guard !Task.isCancelled else {
            states[regionID] = .absent
            return
        }

        states[regionID] = .downloading(fraction: 0)

        // 1. The style pack: the style document, its fonts and its sprites.
        //
        // **Its failure is not fatal, and that is a decision.** The pack is what lets the map draw at
        // all, so a failure here is fatal *in effect* — `createTilesetDescriptor` below resolves against
        // the style, and a region loaded without one could not be drawn. But it is not fatal *in
        // control flow*, because the case worth not breaking is the cheap one: a region whose tiles and
        // whose style pack are both already on disk, re-downloaded by a user standing at a trailhead with
        // no signal. There `loadStylePack` fails on the network while everything needed is present, and
        // the tile region load below succeeds from cache. Treating the pack as fatal would turn a
        // perfectly drawable region into `.failed`.
        await loadStylePack()

        // 2. The descriptor, which is what ties a style to a set of zoom levels.
        let descriptor = offlineManager.createTilesetDescriptor(
            for: TilesetDescriptorOptions(
                styleURI: MapboxSetup.styleURI,
                zoomRange: MapboxSetup.zoomRange,
                tilesets: nil))

        // 3. The region itself: a 60-sided polygon approximating a circle ten miles across from the
        //    point the session's first GPS fix landed on.
        //
        //    **`vertices: 60` is inline rather than a named constant on purpose** — the parameter's
        //    integer type is MapboxCommon's and cannot be checked from here, while an integer literal
        //    infers to whatever it is. Sixty sides on a ten-mile circle is a vertex every third of a
        //    mile, which is well under a pixel at any zoom the card draws.
        //
        //    Both this and the style pack carry the same metadata pair. It is Mapbox's own field and it
        //    is for a human reading a debugger; nothing in this app queries it.
        guard
            let options = TileRegionLoadOptions(
                geometry: .polygon(
                    Polygon(
                        center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        radius: MapboxSetup.radiusMeters,
                        vertices: 60)),
                descriptors: [descriptor],
                metadata: [MapboxSetup.metadataKey: MapboxSetup.metadataTag],
                acceptExpired: true)
        else {
            // Only reachable when the metadata is not a valid JSON object, which a two-string literal
            // always is. Kept because the initialiser is failable and an unhandled `nil` here would be a
            // crash rather than a sentence.
            states[regionID] = .failed(
                "The map for this session could not be prepared. Your session is still recording.")
            return
        }

        // 4. The load.
        //
        //    **The cancellation handler is required and not defensive.** `LiveSessionUseCase` cancels
        //    this task when the switch goes off, and a cancelled Swift `Task` does **not** resume a
        //    `withCheckedContinuation` — the completion would never fire and the caller would wait
        //    forever. So the task's cancellation is translated into Mapbox's own `Cancelable.cancel()`,
        //    which does invoke the completion, with `TileRegionError.canceled`.
        let result: Result<TileRegion, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let load = tileStore.loadTileRegion(
                    forId: regionID,
                    loadOptions: options,
                    progress: { progress in
                        // Mapbox's own note on this closure: *"These closures do not get called from the
                        // main thread"* — they arrive on a `TileStore` worker thread, so every touch of
                        // this object and of `onProgress` hops first. That hop is the SDK's documented
                        // idiom and not a precaution.
                        let required = progress.requiredResourceCount
                        let fraction = required > 0
                            ? Double(progress.completedResourceCount) / Double(required)
                            : 0
                        Task { @MainActor [weak self] in
                            // A late tick must not resurrect a download that has been cancelled or has
                            // already finished — an unconditional write here would redraw a progress
                            // figure on a screen that has moved on.
                            guard let self, let state = self.states[regionID],
                                case .downloading = state
                            else { return }
                            self.states[regionID] = .downloading(fraction: fraction)
                            onProgress(fraction)
                        }
                    }
                ) { result in
                    continuation.resume(returning: result)
                }

                self.inFlight = load

                // The other half of the race with `cancelDownload()`: a cancel that arrived while this
                // call was being set up had nothing to cancel, so it left a flag instead. Both run on the
                // main actor, so this check cannot interleave with it.
                if self.cancelRequested {
                    self.cancelRequested = false
                    load.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDownload() }
        }

        inFlight = nil

        // **The terminal state is committed before this method returns**, because
        // `LiveSessionUseCase` reads `state(for:)` on the line after `await download(...)` — a state
        // written from a later turn would be read as `.downloading` and the session screen would report
        // a download that had already finished.
        switch result {
        case .success(let region):
            // A region is `.ready` only when it is provably whole. `requiredResourceCount` can exceed
            // `completedResourceCount` on a load that still reported success — Mapbox says a style pack
            // "proceeds trying to load the remaining resources" after a partial failure — and a partly
            // present tile set is a map with a hole in it, which is the one thing this state exists to
            // rule out. Uncertain resolves to `.absent`, which draws `MapKit`: the safe direction.
            let complete =
                region.requiredResourceCount > 0
                && region.completedResourceCount >= region.requiredResourceCount
            states[regionID] = complete ? .ready : .absent
        case .failure(let error):
            if Self.isCancellation(error) {
                // Cancelling leaves nothing behind, which is exactly what `.absent` means. It is not a
                // failure and must not be reported as one — the user turned the switch off.
                states[regionID] = .absent
            } else {
                AppLogger.ui.error(
                    "Offline map download failed: \(String(describing: error), privacy: .public)")
                states[regionID] = .failed(Self.sentence(for: error))
            }
        }
    }

    func cancelDownload() {
        guard let inFlight else {
            // **Not a no-op, and this is the case that would hang.** `withTaskCancellationHandler`'s
            // `onCancel` can fire before the `Cancelable` exists, and dropping that cancel would leave a
            // download running with nobody waiting for it. The flag is read back at the one point the
            // `Cancelable` becomes available.
            cancelRequested = true
            return
        }
        inFlight.cancel()
        self.inFlight = nil
    }

    func delete(regionID: String) async {
        // **What this cannot do.** `removeRegion` unmarks a region's tile packs; it does not delete the
        // bytes. Disk is reclaimed by the store's own accounting, which is why `MapboxSetup` pins the
        // usage mode rather than relying on this call to bound the footprint.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tileStore.removeRegion(forId: regionID) { _ in
                continuation.resume()
            }
        }
        states[regionID] = .absent
    }

    // MARK: - OfflineMapRendering

    func map(route: ActivityRoute, unit: ActivityRoute.Unit, regionID: String) -> AnyView {
        // `regionID` is unused at draw time, and that is not an omission. The tile store is keyed
        // globally and a `Map` reads whatever its style and viewport ask for, so the region a session
        // named has already done its work by existing — `RouteMapRenderer.resolve` is what guarantees
        // this method is only reached on `.ready`. Taking the parameter anyway keeps the two halves of
        // the seam the same shape, so a caller cannot reach the drawing half without having answered
        // the question the control half asks.
        //
        // The card is `Presentation`'s — this supplies the picture inside a frame the card has fixed,
        // and the caption, the corner radius and the accessibility sentence are the same code the
        // `MapKit` card runs. See `ActivityRouteMapView.init(route:unit:mapSurface:)`.
        AnyView(
            ActivityRouteMapView(
                route: route,
                unit: unit,
                mapSurface: AnyView(MapboxRouteMapView(route: route))))
    }

    // MARK: - The one-time walk

    /// Reads what is already on disk into `states`.
    ///
    /// A region counts as `.ready` only when it is provably whole, on the same rule the download's own
    /// success branch uses — so a region left half-loaded by a killed process reads `.absent` and the
    /// `MapKit` card is drawn, rather than a partial tile set being presented as a complete one.
    ///
    /// **Nothing filters these by `MapboxSetup.metadataTag`, deliberately.** The tile store is the app's
    /// own, inside the app's own container, so every region in it was put there by this app; the tag is
    /// for a human reading a debugger. Filtering would mean a second spelling of the tag that could
    /// drift from the one written above.
    private func prime() async {
        let existing: [TileRegion] = await withCheckedContinuation { continuation in
            tileStore.allTileRegions { result in
                continuation.resume(returning: (try? result.get()) ?? [])
            }
        }

        for region in existing {
            let complete =
                region.requiredResourceCount > 0
                && region.completedResourceCount >= region.requiredResourceCount
            states[region.id] = complete ? .ready : .absent
        }
    }

    /// Loads the style the card draws in, and says nothing when it fails.
    ///
    /// `acceptExpired: true` matches the tile region load below: a style pack slightly past its
    /// expiration is far better than a card with no style at all, and Mapbox refreshes what it can.
    private func loadStylePack() async {
        guard
            let options = StylePackLoadOptions(
                glyphsRasterizationMode: .ideographsRasterizedLocally,
                metadata: [MapboxSetup.metadataKey: MapboxSetup.metadataTag],
                acceptExpired: true)
        else { return }

        let result: Result<StylePack, Error> = await withCheckedContinuation { continuation in
            offlineManager.loadStylePack(for: MapboxSetup.styleURI, loadOptions: options) { result in
                continuation.resume(returning: result)
            }
        }

        if case .failure(let error) = result {
            // Logged and not surfaced. See `download`'s step 1: the tile region load is the call that
            // decides whether this region can be drawn, and it will fail on its own terms if the style
            // really is missing.
            AppLogger.ui.error(
                "Offline map style pack unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Failure, in words

    /// Whether an error means *the user turned the switch off* rather than *this did not work*.
    ///
    /// Both halves are needed: Mapbox reports its own cancellation as `TileRegionError.canceled`, and a
    /// task cancelled while the completion was already in flight arrives with `Task.isCancelled` set.
    private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled { return true }
        guard let regionError = error as? TileRegionError,
            case .canceled = regionError
        else { return false }
        return true
    }

    /// An authored sentence for a screen, never a bare `Error` description.
    ///
    /// The rule the route's own refusals already follow (`LiveSessionUseCase.routeError`): the failure
    /// a user actually hits here — no signal, which is the whole reason they turned the switch on — is
    /// not something a framework's error text explains. Every sentence below says what happened *and*
    /// that the session is unaffected, because a download is not the recording.
    private static func sentence(for error: Error) -> String {
        guard let regionError = error as? TileRegionError else {
            return "The map for this session could not be downloaded. Your session is still recording — "
                + "connect to the internet and turn the switch on again."
        }

        switch regionError {
        case .diskFull:
            return "There is not enough free space to save this session's map. Your session is still "
                + "recording — free up some space and turn the switch on again."
        case .tileCountExceeded:
            return "Mapbox's limit on saved map areas has been reached, so nothing was saved for this "
                + "session. Your session is still recording."
        case .tilesetDescriptor:
            return "The map style could not be prepared, so nothing was saved for this session. Your "
                + "session is still recording — connect to the internet and try again."
        case .doesNotExist:
            return "The map download could not be started, so nothing was saved for this session. Your "
                + "session is still recording."
        case .canceled:
            return "The map download was stopped."
        case .other:
            return "The map for this session could not be downloaded. Your session is still recording — "
                + "connect to the internet and turn the switch on again."
        @unknown default:
            // **Required, not defensive.** `TileRegionError` is imported from the Mapbox binary and is
            // not a frozen enum, so Swift 6 refuses a switch that covers only the six cases 11.31.1
            // happens to declare — a future SDK adding a seventh would otherwise fall through with no
            // sentence at all. The arm is unreachable today, and the sentence is deliberately the same
            // generic one `.other` gives, because a case this build cannot name is a case it cannot
            // explain either.
            return "The map for this session could not be downloaded. Your session is still recording — "
                + "connect to the internet and turn the switch on again."
        }
    }
}
