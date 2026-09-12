import SwiftUI

public struct CoachDashboardView: View {
    @State private var viewModel: CoachViewModel
    public init(viewModel: CoachViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View { ScrollView { VStack(spacing: 14) { DashboardHeader("Coach", subtitle: "Your daily review"); ForEach(viewModel.insights) { insight in VStack(alignment: .leading, spacing: 10) { Label(insight.title, systemImage: icon(insight.tone)).font(.headline).foregroundStyle(color(insight.tone)); Text(insight.message).foregroundStyle(Theme.textSecondary); Text("LOCAL INSIGHT").font(.caption2.bold()).tracking(1).foregroundStyle(Theme.textMuted) }.frame(maxWidth: .infinity, alignment: .leading).glassCard() } }.padding() }.background(Theme.backgroundDark).task { await viewModel.load() }.preferredColorScheme(.dark) }
    private func icon(_ tone: CoachInsight.Tone) -> String { switch tone { case .recovery: "waveform.path.ecg"; case .activity: "flame.fill"; case .sleep: "moon.fill" } }
    private func color(_ tone: CoachInsight.Tone) -> Color { switch tone { case .recovery: Theme.recoveryGreen; case .activity: Theme.strainPrimary; case .sleep: Theme.sleepIndigo } }
}
