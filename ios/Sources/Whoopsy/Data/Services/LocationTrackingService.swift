import Foundation
@preconcurrency import CoreLocation

// `LocationTracking` and `LocationPermission` are declared in
// `Domain/Repositories/LocationTracking.swift` — a use case depends on the protocol, and `Domain`
// may not name a type that lives in `Data`. This file holds only the three implementations, which
// is the same split `LiveActivityControlling` and `LiveActivityController` use.

#if os(iOS)
/// The real GPS, over `CoreLocation`.
///
/// ### The settings are each a way a route comes out wrong
///
/// None of these is a preference. `distanceFilter` at zero writes a jitter cluster for a phone
/// sitting on a bench; set too wide it cuts the corner off a turn. `activityType = .fitness` is what
/// tells CoreLocation to expect human locomotion rather than a drive. And
/// `pausesLocationUpdatesAutomatically` defaults to `true`, which lets the system decide the user
/// has stopped and silently end the route at a rest stop — the failure is invisible, because the
/// session keeps running and only the route stops growing.
///
/// `desiredAccuracy` stays `kCLLocationAccuracyBest`: `BestForNavigation` is for turn-by-turn and
/// spends more power for a precision no route drawing can show.
///
/// ### `allowsBackgroundLocationUpdates` needs the plist, and is an exception without it
///
/// Setting it `true` when `UIBackgroundModes` does not declare `location` raises
/// `NSInternalInconsistencyException` — a crash at launch, not a refusal. `App/iOS/Info.plist`
/// declares the mode; the two are a pair and neither is optional.
/// `showsBackgroundLocationIndicator` is its counterpart and is not: once fixes keep arriving with
/// the app off screen, the user is entitled to see that they are, and this is the only thing that
/// tells them.
@MainActor
public final class CoreLocationTrackingService: NSObject, LocationTracking, @preconcurrency CLLocationManagerDelegate {

    /// The manager, and **`nil` until the first call that needs one**.
    ///
    /// The laziness is not an optimisation. `DIContainer.init` is `nonisolated` — that is what lets it
    /// build an app's worth of main-actor services without being one — and a `CLLocationManager`
    /// cannot be constructed or configured off the main actor. So `init` has to be `nonisolated`, and a
    /// `nonisolated init` cannot assign a main-actor-isolated stored property. `LiveActivityController`
    /// solves the same problem by giving its handle a default of `nil`; here the object itself is what
    /// cannot exist yet, so it is built on first use by `activeManager` instead.
    private var managerStorage: CLLocationManager?

    private var continuation: AsyncStream<WorkoutRoutePoint>.Continuation?

    /// The parked answer to an in-flight `requestPermission()`, or `nil` when none is pending.
    ///
    /// Nil'd **before** it is resumed, which is what makes a second delegate callback harmless: iOS
    /// delivers the authorization callback once when the delegate is assigned and again when the user
    /// answers, and resuming an already-resumed continuation is a crash rather than a no-op.
    private var permissionContinuation: CheckedContinuation<LocationPermission, Never>?

    public nonisolated override init() { super.init() }

    /// The one place a manager is built, and therefore the one place the settings live.
    ///
    /// Every consumer is `@MainActor`, so this always runs there and the delegate assignment is safe.
    private var activeManager: CLLocationManager {
        if let managerStorage { return managerStorage }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyBest
        created.distanceFilter = 5
        created.activityType = .fitness
        created.pausesLocationUpdatesAutomatically = false
        created.allowsBackgroundLocationUpdates = true
        created.showsBackgroundLocationIndicator = true
        managerStorage = created
        return created
    }

    public var permission: LocationPermission { Self.permission(for: activeManager.authorizationStatus) }

    /// Asks if nobody has answered yet; otherwise returns the answer already on file.
    ///
    /// **The short-circuit is load-bearing.** `requestWhenInUseAuthorization()` is a no-op when the
    /// status is already determined, and iOS does **not** deliver
    /// `locationManagerDidChangeAuthorization` in that case — so a continuation parked
    /// unconditionally before the call is never resumed and the caller waits forever behind a prompt
    /// that never appears. Read the status first; park only when the answer is genuinely pending.
    public func requestPermission() async -> LocationPermission {
        let manager = activeManager
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return Self.permission(for: current) }

        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    public func start() -> AsyncStream<WorkoutRoutePoint> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.activeManager.startUpdatingLocation()
        }
    }

    public func stop() {
        managerStorage?.stopUpdatingLocation()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        // Taken before the resume so a second callback cannot resume it again.
        let pending = permissionContinuation
        permissionContinuation = nil
        pending?.resume(returning: Self.permission(for: manager.authorizationStatus))
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // `heartRate: 0` is the documented sentinel for "the strap had no reading then" — see
        // `WorkoutRoutePointRecord`. This service knows only position, so it has nothing to stamp;
        // `LiveSessionUseCase` is what holds a heart rate and re-stamps each point.
        continuation?.yield(WorkoutRoutePoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            heartRate: 0
        ))
    }

    private static func permission(for status: CLAuthorizationStatus) -> LocationPermission {
        switch status {
        case .notDetermined: .undetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        default: .denied
        }
    }
}
#else
/// The host build's stand-in, so `make build` compiles the one type name `DIContainer` names.
///
/// It reports `.authorized` and yields nothing, and it is never reached by anything that matters: the
/// app cannot present `LiveSessionView` on the host, and the test runner injects its own spy. Its
/// answer is therefore unread rather than wrong — but do not copy it as a model.
@MainActor
public final class CoreLocationTrackingService: LocationTracking {
    public nonisolated init() {}
    public var permission: LocationPermission { .authorized }
    public func requestPermission() async -> LocationPermission { .authorized }
    public func start() -> AsyncStream<WorkoutRoutePoint> { AsyncStream { $0.finish() } }
    public func stop() {}
}
#endif

/// SwiftUI previews' GPS: a short closed loop in lower Manhattan, delivered at once.
///
/// Like the real service it yields `heartRate: 0`, because a position service has no reading to
/// stamp and the session overwrites the field anyway.
@MainActor
public final class PreviewLocationTrackingService: LocationTracking {

    /// `= .authorized` is required by the `nonisolated init` below rather than decoration, exactly as
    /// it is on `LiveActivityController`: a `@MainActor` class cannot assign an isolated stored property
    /// from a nonisolated initialiser, so the property has to carry its own default.
    public var permission: LocationPermission = .authorized
    public nonisolated init() {}

    public func requestPermission() async -> LocationPermission {
        permission = .authorized
        return permission
    }

    public func start() -> AsyncStream<WorkoutRoutePoint> {
        AsyncStream { continuation in
            let points = [(40.7411, -73.9897), (40.7420, -73.9888), (40.7430, -73.9899), (40.7423, -73.9910), (40.7411, -73.9897)]
            for (index, point) in points.enumerated() {
                continuation.yield(WorkoutRoutePoint(
                    latitude: point.0,
                    longitude: point.1,
                    timestamp: .now.addingTimeInterval(Double(index) * 30),
                    heartRate: 0
                ))
            }
        }
    }

    public func stop() {}
}
