import SwiftUI
import MapKit

public struct ActiveWorkoutHUDView: View {
    @State private var viewModel: ActiveWorkoutViewModel
    public init(viewModel: ActiveWorkoutViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View { ZStack { Theme.backgroundDark.ignoresSafeArea(); VStack(spacing: 16) { HStack { Text("LIVE ACTIVITY").font(.caption.bold()).tracking(1.5); Spacer(); Text(viewModel.elapsed.formattedHoursMinutes()).monospacedDigit().foregroundStyle(Theme.textSecondary) }.padding(.horizontal)
        routeMap.frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 24)).padding(.horizontal)
        // A dash, not a default. This rendered a literal `72` whenever there was no reading — a
        // plausible resting heart rate, invented, displayed in the same 76pt type as a real one.
        // `ActiveWorkoutViewModel.consume` sets this from the strap's sample and nothing else, so
        // zero means "no reading yet" and there is no measurement to show.
        Text(viewModel.heartRate == 0 ? "—" : "\(viewModel.heartRate)").font(.system(size: 76, weight: .black, design: .rounded)).foregroundStyle(viewModel.heartRate == 0 ? Theme.textMuted : Theme.textPrimary).monospacedDigit(); Text("BPM").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
        HStack { GaugeRingView(progress: viewModel.strain / 21, scoreText: String(format: "%.1f", viewModel.strain), label: "Strain", ringColor: Theme.strainPrimary, size: 104); zonePills }.glassCard()
        controls
    } }.sheet(item: $viewModel.completedWorkout) { WorkoutSummaryView(workout: $0) }.preferredColorScheme(.dark) }
    private var routeMap: some View { Map(initialPosition: .region(region)) { ForEach(segments) { segment in MapPolyline(coordinates: segment.coordinates).stroke(segment.color, lineWidth: 5) } } .mapStyle(.imagery(elevation: .realistic)) }
    private var region: MKCoordinateRegion { guard let point = viewModel.route.last else { return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.7411, longitude: -73.9897), span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)) }; return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)) }
    private var segments: [RouteSegment] { zip(viewModel.route, viewModel.route.dropFirst()).map { RouteSegment(coordinates: [CLLocationCoordinate2D(latitude: $0.0.latitude, longitude: $0.0.longitude), CLLocationCoordinate2D(latitude: $0.1.latitude, longitude: $0.1.longitude)], color: zoneColor($0.1.heartRate)) } }
    private var zonePills: some View { VStack(alignment: .leading, spacing: 6) { ForEach(HeartRateZoneIndex.allCases) { item in Text("ZONE \(item.rawValue)").font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(viewModel.zone == item ? zoneColor(item.rawValue * 20 + 100) : Theme.cardBackground).clipShape(Capsule()) } } }
    private var controls: some View { VStack(spacing: 10) {
        // `start()` refuses to run without location and sets `.permissionDenied`, which the buttons
        // below cannot show — Start would simply look broken. The session's route map is the reason
        // the guard exists at all; a Home-started workout is asked for the same permission a
        // Workout-tab one is.
        if viewModel.status == .permissionDenied {
            Text("Location access is needed to record a session's route. Enable it for Whoopsy in Settings, then tap Start again.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(Theme.recoveryYellow)
                .padding(.horizontal, 24)
        }
        HStack { Button("Split") { viewModel.split() }.buttonStyle(.bordered); Button(viewModel.status == .active ? "Pause" : "Start") { viewModel.status == .active ? viewModel.pause() : viewModel.start() }.buttonStyle(.borderedProminent).tint(Theme.strainPrimary); Button("End") { Task { await viewModel.finish() } }.buttonStyle(.bordered).tint(Theme.recoveryRed) }
    }.padding() }
    private func zoneColor(_ bpm: Int) -> Color { switch bpm { case ..<117: .gray; case ..<133: Theme.livePulseCyan; case ..<149: Theme.recoveryGreen; case ..<165: Theme.recoveryYellow; default: Theme.recoveryRed } }
}

private struct RouteSegment: Identifiable { let id = UUID(); let coordinates: [CLLocationCoordinate2D]; let color: Color }
