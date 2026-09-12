import Foundation
import SwiftUI

@MainActor @Observable public final class ActiveWorkoutViewModel {
    public enum Status: Sendable, Equatable { case ready, active, paused, finished, permissionDenied }
    public var status: Status = .ready; public var heartRate = 0; public var strain = 0.0; public var zone: HeartRateZoneIndex = .zone1; public var route: [WorkoutRoutePoint] = []; public var splits: [WorkoutSplit] = []; public var elapsed: TimeInterval = 0; public var completedWorkout: WorkoutSession?
    private let stream: StreamBiometricsUseCase; private let save: SaveWorkoutUseCase; private let location: any LocationTracking; private var telemetryTask: Task<Void, Never>?; private var locationTask: Task<Void, Never>?; private var timerTask: Task<Void, Never>?; private var startedAt: Date?
    public init(stream: StreamBiometricsUseCase, save: SaveWorkoutUseCase, location: any LocationTracking) { self.stream = stream; self.save = save; self.location = location }
    public func start() { guard status == .ready || status == .paused else { return }; if location.permission == .undetermined { location.requestPermission() }; guard location.permission == .authorized else { status = .permissionDenied; return }; if startedAt == nil { startedAt = .now }; status = .active; subscribe() }
    public func pause() { guard status == .active else { return }; status = .paused; telemetryTask?.cancel(); locationTask?.cancel(); timerTask?.cancel(); location.stop() }
    public func split() { guard status == .active else { return }; splits.append(WorkoutSplit(elapsed: elapsed, strain: strain)) }
    public func finish() async { guard let startedAt else { return }; pause(); let rates = route.map(\.heartRate).filter { $0 > 0 }; let workout = WorkoutSession(startedAt: startedAt, endedAt: .now, strain: strain, averageHeartRate: rates.isEmpty ? heartRate : rates.reduce(0, +) / rates.count, maxHeartRate: max(heartRate, rates.max() ?? 0), route: route, splits: splits); try? await save.execute(workout); completedWorkout = workout; status = .finished }
    private func subscribe() { telemetryTask?.cancel(); telemetryTask = Task { [weak self, stream] in for await sample in stream.execute() { guard !Task.isCancelled else { return }; self?.consume(sample) } }; let locationStream = location.start(); locationTask?.cancel(); locationTask = Task { [weak self] in for await point in locationStream { guard !Task.isCancelled else { return }; self?.route.append(WorkoutRoutePoint(latitude: point.latitude, longitude: point.longitude, timestamp: point.timestamp, heartRate: self?.heartRate ?? 0)) } }; timerTask = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); guard self?.status == .active else { return }; self?.elapsed += 1 } } }
    private func consume(_ sample: BiometricSample) { heartRate = sample.heartRate; zone = zone(for: sample.heartRate); strain = min(21, strain + zone.strainWeight / 3600) }
    private func zone(for bpm: Int) -> HeartRateZoneIndex { switch bpm { case ..<117: .zone1; case ..<133: .zone2; case ..<149: .zone3; case ..<165: .zone4; default: .zone5 } }
}
