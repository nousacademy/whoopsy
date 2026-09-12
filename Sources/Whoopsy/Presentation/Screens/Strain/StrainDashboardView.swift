import SwiftUI

public struct StrainDashboardView: View {
    @State private var viewModel: StrainViewModel

    /// This tab's own day, independent of the other tabs by design — see `RecoveryDashboardView`.
    @State private var selectedDate: Date = Date()
    public init(viewModel: StrainViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View { NavigationStack { ScrollView { VStack(spacing: 18) { DashboardHeader("Strain", subtitle: hasStrain ? "Cardiovascular load" : "No data recorded")
        DayNavigationBar(date: $selectedDate)
        GaugeRingView(progress: gaugeProgress, scoreText: gaugeText, label: gaugeLabel, ringColor: gaugeColor, lineWidth: 18, size: 190).glassCard()
        HStack { MetricCardView(title: "Average HR", value: heartRate(viewModel.strain?.averageHeartRate), unit: hasHeartRate(viewModel.strain?.averageHeartRate) ? "bpm" : "", iconName: "heart.fill", accentColor: Theme.recoveryRed); MetricCardView(title: "Peak HR", value: heartRate(viewModel.strain?.maxHeartRate), unit: hasHeartRate(viewModel.strain?.maxHeartRate) ? "bpm" : "", iconName: "bolt.heart.fill", accentColor: Theme.strainPrimary) }
        if hasZones { HeartRateZoneBar(zones: viewModel.strain!.zones) }
        else { VStack(alignment: .leading, spacing: 8) { SectionLabel("Heart rate zones"); Text("No zone data recorded.").font(.caption).foregroundStyle(Theme.textSecondary) }.glassCard() }
        VStack(alignment: .leading) { SectionLabel("Target strain"); HStack { Text(String(format: "%.1f", viewModel.target)).font(.title.bold()); Slider(value: $viewModel.target, in: 0...21, step: 0.1).tint(Theme.strainPrimary) }; ProgressView(value: (viewModel.strain?.score ?? 0), total: viewModel.target).tint(Theme.strainPrimary) }.glassCard()
    }.padding() }.background(Theme.backgroundDark).task { await viewModel.load(for: selectedDate) }
    .onChange(of: selectedDate) { _, newDate in Task { await viewModel.load(for: newDate) } } }.preferredColorScheme(.dark) }

    /// A day with nothing stored has no strain, and `GRDBStrainRepository` returns nil rather than a
    /// substituted row. Rendering a plausible 10.2 here would report a fabricated day as a measured
    /// one — the exact failure every no-data rule in this codebase exists to prevent.
    ///
    /// A row *existing* is not the same question, which is why this tests the flag and not the
    /// optional. `CalculateStrainUseCase` no longer writes a row for a day it recorded nothing for,
    /// but an older build did — a real row holding `0.0` — and `strain != nil` is true for both. The
    /// flag is what separates them, and it is the only thing that does.
    private var hasStrain: Bool { viewModel.strain?.hasMeasurement == true }
    private var dash: String { "—" }
    private var gaugeProgress: Double { hasStrain ? (viewModel.strain?.score ?? 0) / 21 : 0 }
    private var gaugeText: String { hasStrain ? String(format: "%.1f", viewModel.strain?.score ?? 0) : dash }
    private var gaugeLabel: String { hasStrain ? "Day strain" : "No data" }
    private var gaugeColor: Color { hasStrain ? Theme.strainPrimary : Theme.textSecondary }

    /// The zone breakdown is absent for every imported day: WHOOP's export carries the finished
    /// strain score but no heart-rate series, and no amount of arithmetic recovers a distribution
    /// from a total. The demo bar this screen used to fall back to was not a measurement.
    ///
    /// The `hasStrain` test is not redundant. An unmeasured row is *not* zoneless — the empty branch
    /// of `CalculateStrainUseCase` built all five zones and left every duration at zero, which is what
    /// rows written before that branch stopped storing anything still hold — so testing emptiness
    /// alone would draw a bar asserting the user spent no time in any zone, which is a claim about a
    /// day nobody measured.
    private var hasZones: Bool { hasStrain && viewModel.strain?.zones.isEmpty == false }

    /// `0` is the reserved "not measured" value in these columns, not a heart rate. The strap path
    /// only writes a value it observed, so a zero here means the export had no figure for that day.
    private func hasHeartRate(_ bpm: Int?) -> Bool { (bpm ?? 0) > 0 }
    private func heartRate(_ bpm: Int?) -> String { hasHeartRate(bpm) ? "\(bpm!)" : dash }
}
