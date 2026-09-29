import Foundation
import MapboxMaps

/// The one place Mapbox is configured, and the only place its three settings are stated.
///
/// ## Why this is a separate file from the two that use it
///
/// Because the settings are read by *both* of them and they must agree. `MapboxOfflineMaps` downloads
/// tiles; `MapboxRouteMapView` draws them. If each named the style, or the zoom range, or a tile store
/// of its own, the downloader could fill a store the map never reads — which fails the way this whole
/// feature fails worst: silently, with a map that draws a blank frame over tiles that are provably on
/// disk. One `enum` with no cases holds them so that cannot be expressed.
///
/// ## What `configure()` is for, and what a `false` from it means
///
/// `MapboxOptions.accessToken` must be set before any Mapbox object is constructed, and `MBXAccessToken`
/// lives in the app bundle's `Info.plist`. `WhoopsyApp.init` calls this **before** it builds
/// `DIContainer`, so by the time anything asks `isSupported` the answer is settled.
///
/// A `false` return is not an error path to be recovered from — it is the answer for a build whose
/// `Info.plist` carries no usable token, which is every build made from a clone that has not been
/// through `README.md` §Building. The switch is then simply not offered, and the card draws `MapKit`.
/// That is
/// `UnavailableOfflineMaps`' behaviour reached by a different route, and it is deliberate: the
/// alternative — offering the switch and drawing a blank map — is the fabricated-capability failure this
/// repo's absence rules exist to prevent.
@MainActor
enum MapboxSetup {

    /// The `Info.plist` key Mapbox itself reads. Named here rather than at the call site because it is
    /// spelled in a plist the compiler cannot check, so there must be exactly one place to look when a
    /// token appears not to be found.
    ///
    /// **This is the public (`pk.…`) token and it is not a secret.** The Mapbox *secret* token
    /// (`sk.…`, with `Downloads:Read`) is a build-time credential for SwiftPM's package resolution and
    /// lives in `~/.netrc` — never in this repository, never in `Info.plist`, never in the app.
    static let tokenKey = "MBXAccessToken"

    /// The prefix every Mapbox **public** token carries, and the whole of the validation below.
    ///
    /// **It exists because the value in `Info.plist` is a build setting, not a literal.** The key reads
    /// `$(MBX_ACCESS_TOKEN)`, and that setting resolves through two files: the committed
    /// `App/Config/Mapbox.xcconfig`, which sets it empty, and the gitignored
    /// `App/Config/Mapbox.local.xcconfig` beside it, which the committed file pulls in through
    /// `#include?` when it exists. So a clone with no token gets a genuinely **empty** string here —
    /// which is exactly what the first case below catches.
    ///
    /// One `hasPrefix` covers two cases with one answer, and neither is the mechanism that gets a fresh
    /// clone to `false` (the empty value does that on its own). It catches a **secret** `sk.…` token
    /// pasted into the wrong file — the mistake worth catching, because the outcome of not catching it
    /// is a secret shipped inside a built app — and any other value that is not a Mapbox public token,
    /// including a placeholder someone typed instead of their own. Mapbox public tokens always begin
    /// `pk.`, so nothing legitimate is refused.
    ///
    /// **A missing token file is not what this guards, because the build never reaches here.**
    /// `xcodebuild` treats an unopenable `baseConfigurationReference` as a hard error and stops — so
    /// deleting `App/Config/Mapbox.xcconfig` fails the build outright rather than leaving a plist with
    /// an unexpanded `$(MBX_ACCESS_TOKEN)` in it. That is why the file with the token *in* it is the
    /// optional one, and why a clone can build with no credentials at all.
    static let publicTokenPrefix = "pk."

    /// The style the card draws in, and the same one the live `MapKit` card approximates.
    ///
    /// `outdoors-v12` rather than the default: this feature exists for hiking, and the outdoors style
    /// draws trails and contour lines that the standard style leaves out. The `MapKit` card uses
    /// `.standard(pointsOfInterest: .excludingAll)` because Apple exposes no equivalent, so the two
    /// cards' *cartography* differs — which is a property of the SDKs and not a seam this app can close.
    static let styleURI = StyleURI.outdoors

    /// The zoom levels downloaded, and the reason it is `0...14` rather than a round number.
    ///
    /// Mapbox ships tiles in four batches and says so in `TilesetDescriptorOptions`' own documentation:
    /// *"Global coverage: 0 - 5 / Regional information: 6 - 10 / Local information: 11 - 14 / Streets
    /// detail: 15 - 16"*, with the explicit recommendation to *"choose the minZoom and maxZoom values in
    /// accordance with the tile batches zoom ranges"*. `0...14` therefore covers three whole batches and
    /// stops on a boundary.
    ///
    /// **Stopping at 14 and not 15 is the affordability decision.** z15–16 is street detail — house
    /// numbers, footpath names — and it is also where the tile count explodes. The card this feeds is
    /// 172 pt tall, static, and framed on the whole route, so it draws at roughly z10–13 for a run and
    /// never reaches z14. Buying the fourth batch would multiply the download to fill a frame nothing
    /// ever draws.
    static let zoomRange: ClosedRange<UInt8> = 0...14

    /// The viewport's ceiling, derived from `zoomRange` so the two cannot disagree.
    ///
    /// A viewport allowed past the downloaded levels asks the network for tiles that are not on disk,
    /// which offline means blank ground at the frame's edge — the exact failure this feature exists to
    /// remove, reintroduced by a constant.
    static var maximumZoom: Double { Double(zoomRange.upperBound) }

    /// Ten miles, in metres.
    ///
    /// The user's own number — *"can we download 10 mile radius for offline version"* — kept as a radius
    /// around a point rather than a bounding box because that is the shape `Polygon(center:radius:)`
    /// takes and the shape the request was made in.
    static let radiusMeters: Double = 16_093

    /// The keys Mapbox stores alongside a region and a style pack. Metadata is Mapbox's own field and
    /// this app writes exactly one pair into it.
    ///
    /// It is for a human reading a debugger, not for a query: `TileStore` is the app's own store inside
    /// the app's own container, so every region in it was put there by this app. See `prime()` for why
    /// nothing filters on this.
    static let metadataKey = "tag"
    static let metadataTag = "whoopsy-offline-region"

    /// Whether `configure()` has run and succeeded. Read by `MapboxOfflineMaps.isSupported`, which is
    /// what the session screen gates the switch on.
    private(set) static var isConfigured = false

    /// Reads the token and pins the two settings that decide whether the map can see the tiles.
    ///
    /// - Returns: `true` when the SDK is usable. `false` leaves **everything unset** — a half-configured
    ///   SDK is worse than none, because `isConfigured` would then be the only thing standing between a
    ///   running app and a blank map.
    @discardableResult
    static func configure() -> Bool {
        guard !isConfigured else { return true }

        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: tokenKey) as? String,
            case let token = raw.trimmingCharacters(in: .whitespacesAndNewlines),
            token.hasPrefix(publicTokenPrefix)
        else {
            return false
        }

        MapboxOptions.accessToken = token

        // **Both of these are the documented defaults, and both are set anyway.**
        //
        // They are not belt-and-braces. `tileStoreUsageMode` is the switch that decides whether a `Map`
        // reads the tile store at all: the default is `.readOnly`, and a build that shipped `.disabled`
        // would draw a map that ignores every downloaded tile while the session screen reported the
        // region `.ready` — a blank card over provably present data, with nothing on screen to say why.
        // `tileStore` pins the instance so the store the downloader fills and the store the map reads are
        // one object rather than two that are equal by default today.
        //
        // `TileStoreOptions.diskQuota` is deliberately **not** set, and that is a decision rather than an
        // omission: `TileStoreOptions` lives in MapboxCommon, a closed binary that appears nowhere in
        // Mapbox's published source, so its spelling cannot be verified here — and a guessed symbol in a
        // closed binary is a build error the user would have to diagnose. A 10-mile radius capped at z14
        // is 5–15 MB, so a quota is not load-bearing.
        MapboxMapsOptions.tileStoreUsageMode = .readOnly
        MapboxMapsOptions.tileStore = TileStore.default

        isConfigured = true
        return true
    }
}
