import Foundation

/// Whether this app may read the device's location, in the three answers iOS actually gives.
///
/// Three cases rather than an optional `Bool`, because the middle one is the state a screen must not
/// render as a refusal: `.undetermined` means *nobody has been asked yet*, and a note saying location
/// is unavailable would be wrong at the exact moment the user is deciding.
public enum LocationPermission: Sendable {

    /// Nobody has been asked, or the request is still on screen.
    case undetermined

    /// Granted, for this app's use while it is running and after it goes to the background.
    case authorized

    /// Refused, or restricted by a device policy the user cannot change from here.
    case denied
}

/// The seam between a running session and the phone's GPS.
///
/// `CoreLocation` is `@available(macOS, unavailable)` for the parts this needs and this module is
/// built for macOS by `make build` / `make test`, so `Domain` cannot name it. This protocol is what
/// the use case depends on instead; `Data/Services/LocationTrackingService.swift` holds the real
/// implementation behind `#if os(iOS)` and a stub in the `#else`, **under one type name on both
/// platforms** so `DIContainer` contains no `#if` at all. That is `LiveActivityControlling`'s
/// arrangement and `HealthStoreClient`'s before it.
///
/// ### `@MainActor` and `Sendable` together, which is not decoration
///
/// A `@MainActor @Observable` class cannot hold this as a plain `let` — the stored property must be
/// `private nonisolated let locationTracking: any LocationTracking`, which requires the protocol to
/// refine `Sendable`. Dropping either refinement is a compile error at the use case rather than a
/// silent data race, which is the only reason this note is short. `LiveActivityControlling` carries
/// the same pair for the same reason.
///
/// ### `start()` and `stop()` must be called on the *same instance*
///
/// A `CLLocationManager` keeps delivering fixes until the object that called `startUpdatingLocation`
/// is told to stop, so a caller that builds a fresh service per read creates a stream nothing can
/// end: the second instance's `stop()` stops a manager that never started, and the first one keeps
/// the GPS awake for the life of the process. That is why `DIContainer` holds one as a stored `let`
/// rather than the computed property it used to be — the same defect `liveActivityController`'s doc
/// comment describes for the card.
///
/// ### A refused permission must never stop the session
///
/// The strap side of a session has nothing to do with whether the phone will share its position, so
/// `LiveSessionUseCase` records `.denied` into `routeError` and keeps running — the status is a
/// property of the device and the user's choice, neither of which is a reason to stop measuring. The
/// absence rule, applied to a capability: a route that cannot be drawn is a missing route, not a
/// missing session.
@MainActor
public protocol LocationTracking: AnyObject, Sendable {

    /// The current answer, without asking for one.
    ///
    /// Read to decide whether a request is needed at all; `requestPermission()` is what the user
    /// sees. A screen must not present `.denied` from here as a fresh refusal without also checking
    /// that a request was made — see `setRouteRecording(_:)` for the shape that keeps the two apart.
    var permission: LocationPermission { get }

    /// Asks the user, if they have not already answered, and returns where things stand.
    ///
    /// **The return value is the point.** A fire-and-forget request cannot distinguish "the user said
    /// no" from "the prompt is still on screen", and the caller has to wait for one of those two
    /// answers before it can decide whether to start. Returns the current status immediately when it
    /// is already determined, without prompting.
    func requestPermission() async -> LocationPermission

    /// Begins delivering fixes.
    ///
    /// The stream finishes when `stop()` is called. Each point carries a location and a zero heart
    /// rate; the session stamps the reading, because the session is what holds one — see
    /// `LiveSessionUseCase` and `WorkoutRoutePointRecord`'s note on the zero.
    func start() -> AsyncStream<WorkoutRoutePoint>

    /// Stops delivering fixes and finishes the stream from `start()`.
    ///
    /// Safe to call when nothing is running, so an `end()` path does not have to ask first.
    func stop()
}
