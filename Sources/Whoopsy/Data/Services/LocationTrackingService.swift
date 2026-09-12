import Foundation
@preconcurrency import CoreLocation

public enum LocationPermission: Sendable { case undetermined, authorized, denied }
@MainActor public protocol LocationTracking: AnyObject { var permission: LocationPermission { get }; func requestPermission(); func start() -> AsyncStream<WorkoutRoutePoint>; func stop() }

#if os(iOS)
@MainActor public final class CoreLocationTrackingService: NSObject, LocationTracking, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager(); private var continuation: AsyncStream<WorkoutRoutePoint>.Continuation?
    public override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest }
    public var permission: LocationPermission { switch manager.authorizationStatus { case .notDetermined: .undetermined; case .authorizedAlways, .authorizedWhenInUse: .authorized; default: .denied } }
    public func requestPermission() { manager.requestWhenInUseAuthorization() }
    public func start() -> AsyncStream<WorkoutRoutePoint> { AsyncStream { continuation in self.continuation = continuation; self.manager.startUpdatingLocation() } }
    public func stop() { manager.stopUpdatingLocation(); continuation?.finish(); continuation = nil }
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { guard let location = locations.last else { return }; continuation?.yield(WorkoutRoutePoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, heartRate: 0)) }
}
#else
@MainActor public final class CoreLocationTrackingService: LocationTracking { public init() {}; public var permission: LocationPermission { .authorized }; public func requestPermission() {}; public func start() -> AsyncStream<WorkoutRoutePoint> { AsyncStream { $0.finish() } }; public func stop() {} }
#endif

@MainActor public final class PreviewLocationTrackingService: LocationTracking {
    public var permission: LocationPermission = .authorized
    public init() {}
    public func requestPermission() { permission = .authorized }
    public func start() -> AsyncStream<WorkoutRoutePoint> { AsyncStream { continuation in let points = [(40.7411, -73.9897), (40.7420, -73.9888), (40.7430, -73.9899), (40.7423, -73.9910), (40.7411, -73.9897)]; for (index, point) in points.enumerated() { continuation.yield(WorkoutRoutePoint(latitude: point.0, longitude: point.1, timestamp: .now.addingTimeInterval(Double(index) * 30), heartRate: 112 + index * 12)) } } }
    public func stop() {}
}
