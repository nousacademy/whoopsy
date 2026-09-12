import SwiftUI
import MapKit

public struct WorkoutSummaryView: View {
    public let workout: WorkoutSession
    @Environment(\.dismiss) private var dismiss
    public init(workout: WorkoutSession) { self.workout = workout }
    public var body: some View { NavigationStack { ScrollView { VStack(spacing: 18) { DashboardHeader("Workout complete", subtitle: workout.endedAt.formatted(date: .abbreviated, time: .shortened)); GaugeRingView(progress: workout.strain / 21, scoreText: String(format: "%.1f", workout.strain), label: "Workout strain", ringColor: Theme.strainPrimary, size: 180).glassCard(); Map { MapPolyline(coordinates: workout.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }).stroke(Theme.strainPrimary, lineWidth: 5) }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 20)); HStack { MetricCardView(title: "Average HR", value: "\(workout.averageHeartRate)", unit: "bpm", iconName: "heart.fill", accentColor: Theme.recoveryRed); MetricCardView(title: "Splits", value: "\(workout.splits.count)", unit: "", iconName: "flag.fill", accentColor: Theme.strainPrimary) }; ForEach(workout.splits) { Text("Split \($0.id.uuidString.prefix(4))  •  \($0.elapsed.formattedHoursMinutes())  •  \(String(format: "%.1f", $0.strain)) strain").frame(maxWidth: .infinity, alignment: .leading).glassCard() } }.padding() }.background(Theme.backgroundDark).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }.preferredColorScheme(.dark) }
}
